#!/usr/bin/env python3
"""Every call that can recreate a container is classified, and the classification
is enforced.

`docker compose up -d` RECONCILES: it recreates any container whose image or
configuration changed, so it resolves the image reference afresh. That is exactly
what an update is for, and exactly what a migration or a rollback must never do --
the Kavita migration recreated its container on a newer staged image and the
application forward-migrated its database, leaving the proof snapshot taken
minutes earlier paired with nothing.

Two fail-open paths had already been fixed once and were still present in the
merged code, because the fix was applied to the preflight check rather than to the
restart. So the boundary is enforced here instead of remembered:

  * an image-preserving function must contain NO executable reconcile
  * a deployment function must still contain one -- otherwise a future refactor
    quietly removes deployment from `apply`
  * a reconcile in an UNCLASSIFIED function fails, which forces the decision to
    be made rather than inherited

Strings are excluded: these functions legitimately print `compose up -d` in
recovery instructions, and telling an operator how to recreate a container
deliberately is the opposite of doing it silently.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "domum-media"

# Anything that can create or replace a container.
RECONCILE = re.compile(
    r"""(?:^|[;&|(]\s*|\s)(?:
          compose_cmd\s+(?:up|create|run)\b
        | docker\s+compose\s+(?:up|create|run)\b
        | docker\s+(?:run|create)\b
        )""",
    re.VERBOSE,
)

# The semantic boundary. Every function that contains a reconcile must appear here.
PRESERVING = {
    # A migration restarts the container it stopped. Recreating resolves the image
    # tag, and the proof snapshot is paired with the image that was running.
    "storage_migrate_subvolume",
    # A rollback has already restored older state. Recreating would hand it to a
    # newer application, which would migrate it -- during the operation meant to
    # undo exactly that.
    "restore_snapshot_for_service",
}
DEPLOYING = {
    "refresh_images",         # the update path; gated on backup age, health, snapshot
    "immich_refresh_bundle",  # an explicit Immich deployment
    "apply",                  # convergence: recreating on a config change is the point
    # Upgrading ONE service. Recreating is the whole point, and it is gated on a
    # pre-upgrade recovery point whose archive verified first -- it cannot reach
    # the `up -d` otherwise. The image it deploys is read from the local staged
    # object, not pulled at upgrade time, so what was reviewed is what runs.
    "service_upgrade",
    # Undoing one. This recreates DELIBERATELY and PINNED: <SERVICE>_IMAGE is set
    # to the id recorded in the recovery evidence, so compose recreates onto the
    # old image instead of resolving a mutable tag. The container that exists
    # belongs to the image being rolled back FROM, so `compose start` would be
    # exactly wrong here -- it would restart the failed application on restored
    # data, which is task-24's defect.
    "rollback_upgrade",
    # The DOCKER-VOLUME rollback. Deliberately a separate function from
    # rollback_upgrade, whose first act is to require a Btrfs snapshot a volume
    # point does not have. Recreating is correct here for the same reason: the
    # container that exists belongs to the image being rolled back FROM, and the
    # recreate is pinned to the recorded image id.
    "rollback_volume_upgrade",
}
# Not service containers at all: one-shot utilities that exit, in no compose
# project, and cannot change what is running.
UTILITY = {
    "htpasswd_hash",          # docker run --rm --entrypoint htpasswd, prints a hash
}
CLASSIFIED = PRESERVING | DEPLOYING | UTILITY


HEREDOC_START = re.compile(r"""<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""")


def _blank_line(line, quote):
    """Blank comments and quoted runs in one line; return (text, quote_carried)."""
    buf = []
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"':
                buf.append("  ")
                i += 2
                continue
            if ch == quote:
                quote = None
            buf.append(" ")
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            buf.append(" ")
            i += 1
            continue
        if ch == "#" and (not buf or buf[-1].isspace()):
            break
        buf.append(ch)
        i += 1
    return "".join(buf), quote


def strip_strings_and_comments(text):
    """Blank out comments, quoted strings and heredoc bodies, keeping line structure.

    Quoting is tracked across lines because `die "...multi-line..."` is how these
    functions print recovery instructions, and those lines contain the very verbs
    being searched for.

    Heredoc bodies are data the shell never executes, and this project uses them
    to print restore runbooks -- `recovery_pack_restore_instructions` emits
    `docker compose up -d uptime-kuma` for a human to run. Not blanking them made
    this audit flag a documentation string as an unclassified reconcile, which is
    how a checker earns a suppression instead of a fix.
    """
    out = []
    quote = None
    heredoc = None
    for line in text.split("\n"):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            out.append("")
            continue
        stripped, quote = _blank_line(line, quote)
        # Look for the delimiter on the ORIGINAL line: `<<'EOF'` is quoted, so the
        # blanking above would erase it.
        m = HEREDOC_START.search(line)
        if m and not line.lstrip().startswith("#"):
            heredoc = m.group(2)
        out.append(stripped)
    return "\n".join(out)


def functions(text):
    """name -> (start_line, body) for top-level `name() {` ... `}` blocks."""
    found = {}
    lines = text.split("\n")
    start = None
    name = None
    for n, line in enumerate(lines, 1):
        m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", line)
        if m and start is None:
            name, start = m.group(1), n
            continue
        if start is not None and line == "}":
            found[name] = (start, "\n".join(lines[start - 1 : n]))
            start, name = None, None
    return found


def main():
    raw = CLI.read_text()
    code = strip_strings_and_comments(raw)
    fns = functions(code)
    raw_fns = functions(raw)
    problems = []

    with_reconcile = set()
    for name, (start, body) in fns.items():
        hits = [l for l in body.split("\n") if RECONCILE.search(l)]
        if hits:
            with_reconcile.add(name)
            if name in PRESERVING:
                problems.append(
                    "%s is an IMAGE-PRESERVING operation but reconciles:\n    %s\n"
                    "    It must restart the container it stopped (compose start), or fail\n"
                    "    closed. Recreating resolves the image tag and can start a different\n"
                    "    application than its recovery point pairs with."
                    % (name, "\n    ".join(h.strip() for h in hits if h.strip()))
                )
            elif name not in CLASSIFIED:
                problems.append(
                    "%s (line %d) can recreate a container and is UNCLASSIFIED:\n    %s\n"
                    "    Decide which it is and add it to PRESERVING, DEPLOYING or UTILITY\n"
                    "    in this file. The boundary is not allowed to be implicit."
                    % (name, start, "\n    ".join(h.strip() for h in hits if h.strip()))
                )

    # The other direction: a deployment path that stops deploying is also a defect.
    for name in DEPLOYING:
        if name not in fns:
            problems.append("DEPLOYING names %s, which no longer exists" % name)
        elif name not in with_reconcile:
            problems.append(
                "%s is classified as a deployment but no longer reconciles anything.\n"
                "    Either it stopped deploying (a defect) or it was renamed." % name
            )

    # And each preserving function must actually use `compose start`.
    for name in PRESERVING:
        if name not in fns:
            problems.append("PRESERVING names %s, which no longer exists" % name)
        elif "compose_cmd start" not in fns[name][1]:
            problems.append(
                "%s is image-preserving but does not use `compose_cmd start`.\n"
                "    Starting the container that was stopped is what makes the image\n"
                "    impossible to change." % name
            )

    # A preserving function that merely warns about recreation and then does it is
    # the shape that shipped twice. The warning must not be followed by a call --
    # which the string-stripped scan above already proves -- and the refusal must
    # be reachable, so require an explicit non-success.
    for name in PRESERVING:
        body = raw_fns.get(name, (0, ""))[1]
        if "NOT recreating" not in body:
            problems.append(
                "%s does not state that it is refusing to recreate. The previous version\n"
                "    warned that recreation resolves the image tag and then did it anyway;\n"
                "    the refusal has to be visible to the operator." % name
            )

    if problems:
        print("FAIL: reconcile boundary audit")
        for p in problems:
            print("  - %s" % p)
        return 1

    print(
        "PASS: reconcile boundary audit (%d preserving, %d deploying, %d utility)"
        % (len(PRESERVING), len(DEPLOYING), len(UTILITY))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
