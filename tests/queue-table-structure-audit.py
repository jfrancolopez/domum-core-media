#!/usr/bin/env python3
"""Every backlog row has three cells and a non-blank status.

Two recorded defects, one in each direction.

P1.7 -- the row gating the whole selective-backup priority -- carried a
two-column row in a three-column table for four commits, because a
programmatic edit rebuilt the line from the PREFIX it had searched with and
dropped the status cell. A status column that is empty reads as "no status",
not as "blocked", so the item that mattered most for P1 looked unexamined in
the file whose entire purpose is to survive context compaction.

The other direction was committed while fixing the first: a raw `|` inside a
backticked code span splits the cell, so a status that renders as two phantom
columns. And checking that with an escape-unaware split produced FALSE
POSITIVES on three already-correct rows, which were then "repaired" into `\\|`.
So this audit is escape-aware: a `\\|` is text, not a delimiter. An audit that
cannot see escaping tells you to break correct rows.

It cannot pass vacuously, and the problems are reported BEFORE the vacuity
guard -- a stale row pattern yields zero matches AND a finding, and the finding
is the actionable half.
"""
import re
import sys
import pathlib

ROW = re.compile(r"^\| (P[0-9]+\.[0-9]+) \|")
QUEUE = pathlib.Path(__file__).resolve().parent.parent / "backlog" / "QUEUE.md"
MIN_ROWS = 40


def cells(line):
    """The row's cells, with escaped pipes kept as text."""
    return line.replace("\\|", "\x00").split("|")


def audit(path):
    problems = []
    scanned = 0
    for n, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        line = line.rstrip()
        m = ROW.match(line)
        if not m:
            continue
        scanned += 1
        key = m.group(1)
        f = cells(line)
        if len(f) - 2 != 3:
            problems.append(
                "%s:%d: %s has %d cells, not 3 -- an unescaped `|` in the text "
                "splits the cell (write it as \\|), or the row was spliced"
                % (path.name, n, key, len(f) - 2)
            )
            continue
        if not f[3].strip():
            problems.append(
                "%s:%d: %s has an EMPTY status cell, which reads as 'no status' "
                "rather than as blocked or open" % (path.name, n, key)
            )
        if "\\\\|" in line:
            problems.append(
                "%s:%d: %s contains \\\\| -- a double backslash, which renders as "
                "a literal backslash and not as an escaped pipe" % (path.name, n, key)
            )
    return scanned, problems


def main():
    # An argv path is the fixture seam. It defaults to the real queue, so a
    # forgotten argument checks production rather than nothing.
    target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else QUEUE
    if not target.exists():
        print("FAIL: %s does not exist" % target, file=sys.stderr)
        return 1
    scanned, problems = audit(target)
    for p in problems:
        print("  " + p, file=sys.stderr)
    if problems:
        print("FAIL: %d malformed backlog row(s)" % len(problems), file=sys.stderr)
        return 1
    if scanned < MIN_ROWS:
        print(
            "FAIL: only %d rows scanned (expected at least %d) -- the row pattern "
            "has gone stale and this audit is checking almost nothing"
            % (scanned, MIN_ROWS),
            file=sys.stderr,
        )
        return 1
    print("== scanned %d backlog row(s)" % scanned)
    print("   every row has 3 cells and a non-blank status")
    return 0


if __name__ == "__main__":
    sys.exit(main())
