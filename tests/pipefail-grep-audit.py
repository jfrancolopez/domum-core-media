"""Ban `cmd | grep -q` in the shell entrypoints and operator wrappers.

`grep -q` exits at the FIRST match. The left-hand command then takes SIGPIPE,
and under `set -o pipefail` the PIPELINE reports 141 -- so **a match reads as a
no-match**. It is intermittent, because it only bites when the left side is
still writing when grep exits, which makes it worse than a deterministic bug.

Measured in this repository: `sed bin/domum-media | grep -q <hit>` returned 141.

Ten instances were found at once, and the direction of failure differed:

  * `phasea_name_free` -- the guard that keeps the disposable Immich harness
    away from PRODUCTION containers; a name that exists would read as free;
  * the config render check -- an unresolved `${PLACEHOLDER}` would be written;
  * `cleanup images` protection -- "THE OLD IMAGE IS A DELETION CANDIDATE"
    would be silently skipped;
  * three copies of the managed-service gate -- `die` on a VALID service name,
    aborting a correct upgrade or rollback;
  * the operator wrapper's post-migration check -- abort a migration that had
    completed perfectly, which is the failure that wrapper has caused three
    times in other forms.

The fix is always the same: capture first (`out="$(cmd)"`), then match against
`<<< "$out"`, which involves no pipe.
"""
import re
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
TARGETS = ["bin/domum-media", "bin/domum-media-backup", "bin/domum-media-report",
           "install.sh"] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / "operator").glob("*.sh"))

# A pipe into a consumer that STOPS EARLY. `grep -q` was the known one; the
# same SIGPIPE mechanism applies to anything that closes its input before the
# writer is finished:
#
#   grep -q / -m N   stop at the first (or Nth) match
#   head -N          stop after N lines
#   sed Nq / sed -n '1,Nq'  quit at a line number
#
# Found in production, 2026-10-12: `sed … "$missing" | head -20 | sed …` in
# verify-snapshot-coverage. With MORE than 20 originals missing the first sed
# took SIGPIPE, the pipeline reported 141, and under `set -e` the function died
# right there -- losing the "... and N more" line AND its own
# "result : INCOMPLETE" verdict, and exiting 141 instead of 1. It only bites
# when the list is long, i.e. exactly when the finding matters.
#
# `(?<!\|)` keeps `|| grep -q … <<< "$x"` -- the CORRECT capture-first form
# reached through an or-list -- from matching; without it this audit flags the
# very fix it exists to require.
# Scope, stated rather than hidden. Flagged:
#
#   | grep -q / -m N   stops at the first (or Nth) match
#   | head             with NO count, or a count that is not 1, or a variable
#                      count -- i.e. used to TRUNCATE a list expected to be
#                      longer, which is the shape that bit us
#   | sed Nq           quits at a line number
#
# NOT flagged: `| head -1` after a `sed -nE 's/^KEY=…/p'` on a metadata file,
# of which there are about sixty here. The mechanism is the same, but the
# producer emits at most a line or two, so there is nothing left to write when
# head exits. Flagging them would make this audit noise, and an audit that
# cries wolf is one somebody switches off. `sort | head -1` is safer still:
# sort cannot emit anything until it has read all of its input.
#
# `(?<!\|)` keeps `|| grep -q … <<< "$x"` -- the CORRECT capture-first form
# reached through an or-list -- from matching; without it this audit flags the
# very fix it exists to require.
_PIPE = r"(?<!\|)\|(?!\|)\s*"
QUIET_GREP = re.compile(_PIPE + r"grep\s+(?:-[A-Za-z]*[qm][A-Za-z]*\s*)+")
SED_QUIT = re.compile(_PIPE + r"sed\s+(?:-n\s+)?['\"]?[0-9]*q")
# `head`, then whatever follows it on the line.
HEAD = re.compile(_PIPE + r"head\b([^|]*)")
# The one exempt form: a count of exactly 1.
HEAD_ONE = re.compile(r"^\s*(?:-n\s*|-)?1\s*(?:$|[^0-9])")


def offending(code):
    """The matched text of the first banned pipeline on this line, or None."""
    for rx in (QUIET_GREP, SED_QUIT):
        m = rx.search(code)
        if m:
            return m.group(0).strip()
    m = HEAD.search(code)
    if m and not HEAD_ONE.match(m.group(1)):
        return ("| head" + m.group(1)).strip()
    return None

bad = []
scanned = 0
for rel in TARGETS:
    f = ROOT / rel
    if not f.exists():
        continue
    raw = f.read_text().split("\n")
    # A pipeline may be split across lines with a trailing backslash, and the
    # `| grep -q` half then starts the NEXT line. Both real instances found by
    # this audit had that shape, so each line is matched together with its
    # continuation.
    joined = []
    for i, ln in enumerate(raw, 1):
        nxt = raw[i] if i < len(raw) else ""
        joined.append((i, ln, ln.rstrip().rstrip("\\") + " " + nxt.strip()
                       if ln.rstrip().endswith("\\") else ln))
    for i, ln, subject in joined:
        # Strip comments before asserting that code does NOT contain something:
        # this audit's own explanation quotes the banned form, and so do the
        # comments that document each fix.
        code = re.sub(r"(^|\s)#.*$", "", subject)
        scanned += 1
        hit = offending(code)
        if hit:
            bad.append((rel, i, ln.strip()[:100]))

print("== scanned %d line(s) across %d file(s)" % (scanned, len([r for r in TARGETS if (ROOT / r).exists()])))
for rel, i, text in bad:
    print("   !! %s:%d  %s" % (rel, i, text))
if bad:
    print("Capture first -- out=\"$(cmd)\" -- then `grep -q … <<< \"$out\"`.")
sys.exit(1 if bad else 0)
