#!/usr/bin/env python3
"""`find` inside a command substitution must not be able to abort the shell.

`find` on a directory that does not exist exits 1, and `2>/dev/null` hides the
MESSAGE, not the STATUS. Under `set -euo pipefail` the command substitution's
failure fails the assignment, and `set -e` kills the function -- typically
BEFORE the branch written to handle an empty result.

`| wc -l` does not save it: pipefail takes the rightmost non-zero status, so
`find /absent | wc -l` is a failed pipeline even though `wc` succeeded.

Measured instances this exists for:

  * `rollback_entries` ran `find` on a directory that need not exist, so
    `cleanup_image_decisions` aborted part-way and reported an EMPTY image set,
    i.e. "nothing to protect";
  * `dr_immich_summary` summed bytes under `thumbs/` and `encoded-video/`,
    which do not exist on a freshly restored host, so `dr-status` died
    part-way through the report it was asked for;
  * `checkup`'s `waiting_count` read `$DOMUM_STATE_ROOT/image-updates`, which
    does not exist until `ensure_dirs` has run. `checkup` prints only after
    every check has completed, so one abort produces a BLANK REPORT -- which is
    indistinguishable from a healthy one. That is the exact shape that blanked
    the report in production once already, with a `grep` instead of a `find`.

The rule is the one already recorded: when a function's failure is EXPECTED and
handled, capture it with `|| true`.

SCOPE, stated rather than left implicit:

  * `bin/*` only. The operator wrappers verify their paths far earlier than any
    window this could inspect, so flagging them would cry wolf -- and an audit
    that cries wolf is one somebody switches off.
  * A `find` whose logical line (continuations joined) ends in `|| true`, or
    carries an explicit `# find-audit: <reason>` marker, is accepted. Every
    exemption is PRINTED, because an allowance nobody can see is how a real
    defect gets a marker stuck on it.
  * A QUOTED heredoc body is data and is skipped.
  * Deliberately NOT a guard-detection audit. Recognising `[[ -d "$x" ]]`
    before a `find "$x/y"` is fragile and the guard is often many lines away;
    requiring `|| true` unconditionally is both simpler and strictly safer,
    since it costs nothing where the path is guaranteed.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Overridable ONLY so the audit can be driven against fixtures by its own smoke
# test -- an audit that has only been read has not been tested. It defaults to
# the real files, so CI needs no environment.
TARGETS = ["bin/domum-media", "bin/domum-media-backup", "bin/domum-media-report"]
if os.environ.get("FIND_AUDIT_TARGETS"):
    ROOT = os.environ.get("FIND_AUDIT_ROOT", ROOT)
    TARGETS = os.environ["FIND_AUDIT_TARGETS"].split(":")

# `find` inside a command substitution. `$(` then anything, then a `find` word.
FIND_IN_SUBST = re.compile(r"\$\([^)]*?\bfind\s")
MARKER = re.compile(r"#\s*find-audit:")
HEREDOC_QUOTED = re.compile(r"""<<-?\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1""")


def logical_lines(path):
    """Yield (first_lineno, joined_text, raw_block) with continuations joined
    and QUOTED heredoc bodies skipped."""
    with open(path, encoding="utf-8") as fh:
        raw = fh.read().splitlines()
    i = 0
    while i < len(raw):
        line = raw[i]
        m = HEREDOC_QUOTED.search(line)
        if m:
            term = m.group(2)
            i += 1
            while i < len(raw) and raw[i].rstrip() != term:
                i += 1
            i += 1
            continue
        start = i + 1
        block = [line]
        while line.rstrip().endswith("\\") and i + 1 < len(raw):
            i += 1
            line = raw[i]
            block.append(line)
        yield start, " ".join(b.rstrip().rstrip("\\") for b in block), "\n".join(block)
        i += 1


def main():
    problems = []
    exemptions = []
    scanned = 0
    for rel in TARGETS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            problems.append("%s does not exist; the target list is stale" % rel)
            continue
        for lineno, joined, block in logical_lines(path):
            # The marker is read BEFORE comments are stripped and exempts only
            # its own logical line.
            exempt = bool(MARKER.search(block))
            stripped = re.sub(r"#.*", "", joined)
            if not FIND_IN_SUBST.search(stripped):
                continue
            scanned += 1
            if exempt:
                exemptions.append("%s:%d  %s" % (rel, lineno, stripped.strip()[:96]))
                continue
            if re.search(r"\|\|\s*true", stripped):
                continue
            problems.append("%s:%d  %s" % (rel, lineno, stripped.strip()[:110]))

    for e in exemptions:
        print("   ~~ exempt (marker) %s" % e)

    # Problems are reported BEFORE the vacuity guard: a stale target list
    # produces zero matches AND a problem, and "the target list is stale" is
    # the actionable half. Checking vacuity first printed the less useful
    # message and hid the real one.
    if not problems and scanned == 0:
        print("FAIL: find abort audit matched no `find` in any command substitution.")
        print("  Either the extraction broke or the shape disappeared; both need a look.")
        return 1

    if problems:
        print("FAIL: find abort audit")
        for p in problems:
            print("   !! %s" % p)
        print(
            "`find` on a path that need not exist exits 1, and 2>/dev/null hides the\n"
            "message, not the status -- so under pipefail the assignment fails and\n"
            "`set -e` kills the function, usually before the branch written for an\n"
            "empty result. `| wc -l` does not help: pipefail takes the rightmost\n"
            "non-zero status. Append `|| true`, or add `# find-audit: <reason>`."
        )
        return 1

    print(
        "PASS: find abort audit (%d command substitution(s) with `find` across %d file(s), "
        "%d exempt)" % (scanned, len(TARGETS), len(exemptions))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
