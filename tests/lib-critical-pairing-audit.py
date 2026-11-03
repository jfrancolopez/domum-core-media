#!/usr/bin/env python3
"""Every `checkup_add critical` must carry a remedy within reach.

A critical opens the notifier's silence gate, so it MAILS. One with no remedy
sends the operator an alarm and no command -- worse than a warning with none,
which at least stays quiet. `tests/warning-remedy-smoke.sh` enforced the
warning side and nothing enforced this one.

A critical may be deliberately bare when it names the exact variable and its
legal values, which IS the remedy. That is declared with an explicit
`# critical-bare: <reason>` marker, read BEFORE comments are stripped so the
marker is visible, exempting only its own line, and PRINTED -- an allowance
nobody can see is how a real defect gets a marker stuck on it.

Exit 0 clean, 1 an unpaired critical or a scan that found too few sites to be
scanning at all.
"""
import io
import sys

WINDOW = 7          # lines after the critical in which a remedy counts
MIN_SITES = 10      # below this the scan is not scanning; fail rather than pass
MARKER = "# critical-bare:"


def main(path):
    raw = io.open(path, encoding="utf-8").read().split("\n")
    # Whole-line comments only, matching the warning scan: a comment quoting a
    # finding would otherwise be counted as the finding.
    code = [("" if l.strip().startswith("#") else l) for l in raw]

    total = 0
    exempt = []
    orphans = []
    for i, line in enumerate(code):
        if "checkup_add critical" not in line:
            continue
        total += 1
        if MARKER in raw[i]:
            exempt.append(raw[i].strip())
            continue
        window = "\n".join(code[i + 1:i + 1 + WINDOW])
        if "checkup_add action" in window or "checkup_add advice" in window:
            continue
        orphans.append((i + 1, line.strip()))

    for e in exempt:
        print("  ~~ exempt %s" % e[:100])
    for num, text in orphans:
        print("  !! %4d  %s" % (num, text[:100]))
    print("  scanned %d critical site(s), %d exempt, %d with no remedy"
          % (total, len(exempt), len(orphans)))

    if total < MIN_SITES:
        print("  the scan found only %d site(s); it is not scanning" % total)
        return 1
    return 1 if orphans else 0


if __name__ == "__main__":
    # Runs standalone in CI with no argument, like its sibling
    # lib-stdout-purity-audit.py, and takes a path so the smoke test can point
    # it at a mutant. A repo root is accepted too, so the CI invocation can
    # match the other audits' `<audit> .` form.
    import os

    if len(sys.argv) > 2:
        sys.exit("usage: lib-critical-pairing-audit.py [<repo root>|<path to bin/domum-media>]")
    if len(sys.argv) == 2:
        target = sys.argv[1]
        if os.path.isdir(target):
            target = os.path.join(target, "bin", "domum-media")
    else:
        target = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "bin", "domum-media")
    if not os.path.isfile(target):
        sys.exit("not a file: %s" % target)
    sys.exit(main(target))
