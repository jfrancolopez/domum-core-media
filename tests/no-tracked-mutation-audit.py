#!/usr/bin/env python3
"""A test must never WRITE to a tracked CLI.

A suite that mutates `bin/domum-media` in place and restores it afterwards is
sound only for a run that COMPLETES. It provides nothing for one that does not,
and twice a stopped run left phase 4's model guard neutralised in the working
tree -- the second time hidden inside a legitimately modified file, where
`git status` could not tell it from the intended change.

It is worse than residue. Measured 2026-11-12, two full-suite loops overlapping
by 16m53s made a deterministic suite (40/40 standalone) fail, because it read
`bin/domum-media` while the other loop's suites had it mutated. The residue case
needs an interruption; that one needs only overlap, and it manufactures a
failure indistinguishable from a real defect in whatever is under test.

The fix is always the same: mutate a COPY and point the driver at it. Several
suites already pass `CLI="$MUT"` as a prefix, so the pattern is proven rather
than invented here.

What is flagged, on tracked CLI paths only:
  * `cp <anything> "$CLI"`            -- a restore, which exists only because
                                         something mutated in place
  * `sed -i ... "$CLI"`
  * `python3 ... <generated script> ... "$CLI"` -- a generated script under $TMP
    writes; a shipped `tests/*.py` audit given the same path READS it, and that
    is the discriminator.

Scope notes, stated rather than left implicit:
  * continuations are joined, because two of the pipefail audit's findings were
    invisible to a line-at-a-time search;
  * a QUOTED heredoc body is DATA and is not scanned -- a suite reproducing a
    historical defect must be able to quote it;
  * `# tracked-mutation-audit: <reason>` exempts ITS OWN LINE only, is read
    BEFORE comments are stripped, and every exemption is PRINTED, because an
    allowance nobody can see is how a real defect gets a marker stuck on it.
"""
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
MARKER = "tracked-mutation-audit:"

# A tracked CLI, however the suite spells it.
TRACKED = r'("\$CLI"|"\$\{CLI\}"|"\$BACKUP_CLI"|"\$REPORT_CLI"|"\$REPO_ROOT/bin/[A-Za-z0-9._-]+")'
# The tracked path must be the DESTINATION, i.e. the FINAL argument. Without
# that, `cp "$CLI" "$MUT"` -- the prescribed fix, copying FROM the tracked
# file TO a copy -- was flagged, and an audit that rejects its own remedy is one
# somebody switches off. Caught by a dry run before shipping.
CP_ONTO = re.compile(r'\bcp\b[^;&|]*\s' + TRACKED + r'\s*(;|&&|\|\||\)|$)')
SED_I = re.compile(r'\bsed\b[^;&|]*-i[^;&|]*' + TRACKED)
# A generated mutation script (under $TMP / $TMP_DIR, or a heredoc-written file)
# handed a tracked path. A shipped tests/*.py given the same path reads it.
# As with cp, the tracked path must be the LAST argument -- the thing written.
# `python3 -I mut.py "$CLI" "$MUT2"` READS the tracked file and writes a copy,
# which is the prescribed pattern; flagging it would make the audit reject its
# own remedy. Caught by a dry run against the real tree, for the second time.
PY_MUT = re.compile(r'\bpython3\b[^;&|]*"\$(?:TMP|TMP_DIR)[^"]*\.py"[^;&|]*' + TRACKED + r'\s*(;|&&|\|\||\)|$)')


def join_continuations(text):
    out, buf, markers = [], "", []
    for raw in text.split("\n"):
        has_marker = MARKER in raw
        if raw.rstrip().endswith("\\"):
            buf += raw.rstrip()[:-1] + " "
            markers.append(has_marker)
            out.append(None)
            continue
        line = buf + raw
        buf = ""
        out.append((line, has_marker or any(markers)))
        markers = []
    if buf:
        out.append((buf, any(markers)))
    return out


def strip_quoted_heredocs(lines):
    """Blank the body of every <<'EOF' heredoc: it is data, not code."""
    out, delim = [], None
    for item in lines:
        if item is None:
            out.append(None)
            continue
        line, marked = item
        if delim is not None:
            out.append(("", marked))
            if line.strip() == delim:
                delim = None
            continue
        m = re.search(r"<<-?'([A-Za-z_][A-Za-z0-9_]*)'", line)
        out.append((line, marked))
        if m:
            delim = m.group(1)
    return out


def main():
    tdir = ROOT / "tests"
    targets = sorted(tdir.glob("*.sh")) + sorted((tdir / "integration").glob("*.sh"))
    problems, exempt = [], []
    for path in targets:
        text = path.read_text(encoding="utf-8")
        items = strip_quoted_heredocs(join_continuations(text))
        lineno = 0
        for item in items:
            lineno += 1
            if item is None:
                continue
            line, marked = item
            code = re.sub(r"#.*", "", line)
            if not code.strip():
                continue
            hit = CP_ONTO.search(code) or SED_I.search(code) or PY_MUT.search(code)
            if not hit:
                continue
            rel = path.relative_to(ROOT)
            if marked:
                exempt.append((rel, lineno, code.strip()[:90]))
            else:
                problems.append((rel, lineno, code.strip()[:110]))

    for rel, ln, src in exempt:
        print("   ~~ exempt %s:%s  %s" % (rel, ln, src))

    if problems:
        print("FAIL: %d test site(s) WRITE to a tracked CLI:" % len(problems))
        for rel, ln, src in problems:
            print("   %s:%s  %s" % (rel, ln, src))
        print("")
        print("Mutate a COPY and point the driver at it:")
        print('  MUT="$TMP/cli-mutant"; cp "$CLI" "$MUT"')
        print('  python3 -I "$TMP/mutate.py" "$MUT" || fail "the mutation did not apply"')
        print('  out="$(CLI="$MUT" driver ...)"')
        print("A suite that mutates a tracked file can be stopped mid-run and leave it")
        print("mutated, and makes any concurrent run unsound.")
        return 1

    # Vacuity guard, counted with listdir rather than the glob that built the
    # target list: re-asking the same glob could not detect that glob breaking.
    present = [f for f in os.listdir(tdir) if f.endswith(".sh")]
    if len(targets) < len(present):
        print("FAIL: scanned %d suites but %d *.sh files are present" % (len(targets), len(present)))
        return 1
    print("PASS: no test writes to a tracked CLI (%d suite(s) scanned, %d exemption(s))"
          % (len(targets), len(exempt)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
