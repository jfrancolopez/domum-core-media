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

# A pipe into grep with a quiet flag. -q anywhere in the option cluster counts,
# so -qxF, -Fxq and -qiE are all caught. `(?<!\|)` keeps `|| grep -q … <<< "$x"`
# -- the CORRECT capture-first form reached through an or-list -- from matching;
# without it this audit flags the very fix it exists to require.
PIPE_TO_QUIET_GREP = re.compile(r"(?<!\|)\|(?!\|)\s*grep\s+(?:-[A-Za-z]*q[A-Za-z]*\s*)+")

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
        if PIPE_TO_QUIET_GREP.search(code):
            bad.append((rel, i, ln.strip()[:100]))

print("== scanned %d line(s) across %d file(s)" % (scanned, len([r for r in TARGETS if (ROOT / r).exists()])))
for rel, i, text in bad:
    print("   !! %s:%d  %s" % (rel, i, text))
if bad:
    print("Capture first -- out=\"$(cmd)\" -- then `grep -q … <<< \"$out\"`.")
sys.exit(1 if bad else 0)
