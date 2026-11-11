#!/usr/bin/env bash
# The queue-structure audit, driven in BOTH directions.
#
# A single-direction assertion cannot tell an audit from one that always passes,
# and this audit's own history is the reason: an escape-UNAWARE version of the
# same check reported three already-correct rows as broken, and acting on those
# false positives corrupted them. So the acceptance cases matter as much as the
# rejections.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/queue-table-structure-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# A fixture needs more rows than the vacuity floor, or every rejection case
# would be indistinguishable from "scanned almost nothing".
mkqueue() {
  local out="$1"; shift
  { echo "| id | item | status |"
    echo "|---|---|---|"
    local i
    for ((i = 1; i <= 45; i++)); do
      echo "| P9.$i | an item | **done** |"
    done
    printf '%s\n' "$@"
  } > "$out"
}

sect "a well-formed queue passes"
mkqueue "$TMP/ok.md"
python3 -I "$AUDIT" "$TMP/ok.md" >/dev/null 2>&1 \
  || fail "a well-formed queue was rejected"
echo "  accepted"

sect "an escaped pipe inside a code span is TEXT, not a delimiter"
# The false-positive direction. This row is CORRECT and must be accepted.
mkqueue "$TMP/esc.md" '| P9.90 | measure it | **done** — `docker save \| wc -c` and `44\|600` |'
python3 -I "$AUDIT" "$TMP/esc.md" >/dev/null 2>&1 \
  || fail "a correctly escaped pipe was reported as a broken row -- this is the
false positive that led to three good rows being corrupted"
echo "  accepted: \\| is text"

sect "a RAW pipe in the text is rejected"
mkqueue "$TMP/raw.md" '| P9.91 | measure it | **done** — `docker save | wc -c` |'
out="$(python3 -I "$AUDIT" "$TMP/raw.md" 2>&1)"
python3 -I "$AUDIT" "$TMP/raw.md" >/dev/null 2>&1 \
  && fail "a raw pipe splitting the cell was accepted: $out"
grep -q 'has 4 cells' <<< "$out" || fail "it did not name the cell count: $out"
grep -q 'write it as' <<< "$out" || fail "it did not name the remedy: $out"
echo "  rejected, naming the count and the remedy"

sect "a row with NO status cell is rejected -- the recorded P1.7 defect"
mkqueue "$TMP/nostatus.md" '| P9.92 | activate a production backup target for it |'
out="$(python3 -I "$AUDIT" "$TMP/nostatus.md" 2>&1)"
python3 -I "$AUDIT" "$TMP/nostatus.md" >/dev/null 2>&1 \
  && fail "a two-cell row was accepted: $out"
grep -q 'has 2 cells' <<< "$out" || fail "it did not name the count: $out"
echo "  rejected: the exact shape that survived four commits"

sect "an EMPTY status cell is rejected -- it reads as 'no status', not 'blocked'"
mkqueue "$TMP/blank.md" '| P9.93 | activate a production backup target for it |  |'
out="$(python3 -I "$AUDIT" "$TMP/blank.md" 2>&1)"
python3 -I "$AUDIT" "$TMP/blank.md" >/dev/null 2>&1 \
  && fail "a blank status was accepted: $out"
grep -q 'EMPTY status cell' <<< "$out" || fail "it did not name the cause: $out"
echo "  rejected: three cells is not enough if the status is blank"

sect "a DOUBLE backslash is rejected"
# The corruption my own escape-unaware repair introduced: \\| renders as a
# literal backslash, not as an escaped pipe.
mkqueue "$TMP/dbl.md" '| P9.94 | measure it | **done** — `44\\|600` |'
out="$(python3 -I "$AUDIT" "$TMP/dbl.md" 2>&1)"
python3 -I "$AUDIT" "$TMP/dbl.md" >/dev/null 2>&1 \
  && fail "a double backslash was accepted: $out"
grep -q 'double backslash' <<< "$out" || fail "it did not name the cause: $out"
echo "  rejected: the corruption an escape-unaware repair introduces"

sect "it cannot pass vacuously"
{ echo "| id | item | status |"; echo "|---|---|---|"
  echo "| P9.1 | an item | **done** |"; } > "$TMP/thin.md"
out="$(python3 -I "$AUDIT" "$TMP/thin.md" 2>&1)"
python3 -I "$AUDIT" "$TMP/thin.md" >/dev/null 2>&1 \
  && fail "one row was enough to pass: $out"
grep -q 'checking almost nothing' <<< "$out" || fail "it did not say why: $out"
echo "  a stale row pattern fails instead of reporting a clean sweep"

sect "a problem is reported even when the row count is also too low"
# The actionable half must not be hidden behind the vacuity guard.
{ echo "| id | item | status |"; echo "|---|---|---|"
  echo "| P9.1 | an item |"; } > "$TMP/both.md"
out="$(python3 -I "$AUDIT" "$TMP/both.md" 2>&1)"
grep -q 'has 2 cells' <<< "$out" \
  || fail "the malformed row was hidden behind the vacuity guard: $out"
echo "  the malformed row is named, not masked"

sect "a forgotten argument checks the REAL queue, not nothing"
python3 -I "$AUDIT" >/dev/null 2>&1 \
  || fail "the real queue does not pass its own audit"
out="$(python3 -I "$AUDIT" 2>&1)"
grep -qE 'scanned [0-9]{2,} backlog row' <<< "$out" \
  || fail "the default target scanned too few rows to be the real queue: $out"
echo "  defaults to the real queue"

echo "PASS: queue table structure smoke test"
