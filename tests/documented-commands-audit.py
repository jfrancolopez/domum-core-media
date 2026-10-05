#!/usr/bin/env python3
"""Every `domum-media` command the documentation tells an operator to run must exist.

I told the operator to run

    sudo domum-media storage verify-recovery navidrome <point>

and they got

    ERROR: Usage: domum-media storage {migrate-subvolume <service>|topology [--verify <file>]}

The subcommand existed only on an unmerged branch. The repository was ahead of
production and the advice came from the repository.

`tests/unit-subcommands-exist-smoke.sh` already checks systemd units this way,
because a timer firing a nonexistent subcommand fails silently in the journal.
Runbooks have the same failure mode with a person on the other end, and the docs
are full of commands to run during a recovery -- the worst moment to find out.

What this CANNOT check is what is DEPLOYED. That gap is why the migration wrapper
feature-gates on the installed binary, and why a documented command is only safe
advice once the revision carrying it is deployed.

Only code is read: fenced blocks and inline `backticks`. Prose is skipped, because
"another domum-media operation holds the lock" is a sentence, not a command.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin" / "domum-media"
BACKUP = ROOT / "bin" / "domum-media-backup"

# Groups whose second word is a subcommand of the SAME script.
GROUPS = {"storage", "snapshot", "rollback", "cleanup", "immich", "recovery-pack", "updates"}
# `backup` execs bin/domum-media-backup, so its arguments belong to that script.
DELEGATES = {"backup": BACKUP}
# `compose` is a passthrough to `docker compose`; its words are docker's verbs.
PASSTHROUGH = {"compose"}
# Documented as NOT existing. CLAUDE.md section 9 records the disabled host unit
# invoking `domum-media hot prune` against a CLI that has no `hot` subcommand --
# naming a defect is not advising a command.
KNOWN_ABSENT = {"hot"}

PLACEHOLDER = re.compile(r"^[<{\[-]")


def dispatched(script, sub):
    src = script.read_text()
    for pat in (
        r"^[ \t]+%s\)" % re.escape(sub),                    # `  sub)`
        r"^[ \t]+[a-z0-9|_.-]*\|%s\)" % re.escape(sub),     # `  a|sub)`
        r"^[ \t]+%s\|" % re.escape(sub),                    # `  sub|a)`
    ):
        if re.search(pat, src, re.M):
            return True
    # domum-media-backup takes --flags.
    if sub.startswith("--") and re.search(re.escape(sub) + r"\)", src):
        return True
    return False


def code_spans(text):
    """Yield the contents of fenced blocks and inline code spans."""
    fence = False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            yield line
        else:
            for m in re.finditer(r"`([^`]+)`", line):
                yield m.group(1)


def main():
    # Anchored to COMMAND POSITION: start of the span, optionally after a prompt
    # or `sudo`. Fenced blocks also carry quoted error output, and
    #
    #   Another domum-media operation holds the lock: 21847 ...
    #
    # is a sentence in which `domum-media` happens to appear -- matching it
    # mid-line turned a quoted message into a nonexistent `domum-media operation`.
    cmd = re.compile(
        r"^[ \t]*(?:[$#]\s*)?(?:sudo\s+)?domum-media\s+([a-z][a-z0-9-]*)(?:\s+(\S+))?"
    )
    seen = {}
    for doc in sorted(list((ROOT / "docs").glob("*.md")) + [ROOT / "README.md", ROOT / "CLAUDE.md"]):
        if not doc.is_file():
            continue
        for span in code_spans(doc.read_text()):
                m = cmd.match(span)
                if m:
                    seen.setdefault((m.group(1), m.group(2)), set()).add(doc.name)

    missing = []
    checked = 0
    for (sub, nested), where in sorted(seen.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
        if sub in KNOWN_ABSENT:
            continue
        checked += 1
        if not dispatched(CLI, sub):
            missing.append(("domum-media %s" % sub, where))
            continue
        if nested is None or PLACEHOLDER.match(nested):
            continue
        if sub in PASSTHROUGH:
            continue
        if sub in DELEGATES:
            checked += 1
            if not dispatched(DELEGATES[sub], nested):
                missing.append(("domum-media %s %s" % (sub, nested), where))
            continue
        if sub in GROUPS:
            checked += 1
            if not dispatched(CLI, nested):
                missing.append(("domum-media %s %s" % (sub, nested), where))

    if missing:
        print("FAIL: the documentation names %d command(s) that do not exist:" % len(missing))
        for name, where in missing:
            print("  %-46s  (%s)" % (name, ", ".join(sorted(where))))
        print("\nA runbook command that does not exist is discovered during a recovery.")
        return 1

    if checked == 0:
        print("FAIL: no documented commands were checked; this audit is not looking at anything")
        return 1

    print("PASS: documented commands audit (%d documented command(s) checked)" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
