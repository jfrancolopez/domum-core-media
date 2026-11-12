#!/usr/bin/env bash
set -uo pipefail

# Drives tests/no-tracked-mutation-audit.py in BOTH directions. A single
# direction cannot tell this audit from one that never fires -- and this audit
# nearly shipped rejecting its own remedy twice, because `cp "$CLI" "$MUT"` and
# `python3 mut.py "$CLI" "$MUT2"` both READ the tracked file to produce a copy.
# Both were caught by a dry run against the real tree; both are pinned here.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/no-tracked-mutation-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fixture() {  # $1 = subdir, $2.. = lines of the fake suite
  local d="$TMP/$1"; shift
  mkdir -p "$d/tests"
  printf '%s\n' "$@" > "$d/tests/fake-smoke.sh"
  printf '%s' "$d"
}

run_audit() { python3 -I "$AUDIT" "$1" 2>&1; }

# ---------------------------------------------------------------------------
# 1. REJECTED: a restore onto the tracked CLI -- the tell-tale of an in-place
#    mutation, which exists only because something mutated it.
# ---------------------------------------------------------------------------
d="$(fixture reject1 'cp "$TMP/cli.orig" "$CLI"')"  # tracked-mutation-audit: hostile fixture
out="$(run_audit "$d")"
grep -q '^FAIL' <<< "$out" || fail "1: a restore onto the tracked CLI was accepted: $out"
grep -q 'cli.orig' <<< "$out" || fail "1: the finding does not name the site: $out"
echo "  1: a restore onto the tracked CLI is rejected"

# ---------------------------------------------------------------------------
# 2. REJECTED: sed -i, and a generated mutation script given the tracked path.
# ---------------------------------------------------------------------------
d="$(fixture reject2 'sed -i "s/a/b/" "$CLI"')"  # tracked-mutation-audit: hostile fixture
grep -q '^FAIL' <<< "$(run_audit "$d")" || fail "2: sed -i on the tracked CLI was accepted"
d="$(fixture reject3 'python3 -I "$TMP/mutate.py" "$CLI"')"  # tracked-mutation-audit: hostile fixture
grep -q '^FAIL' <<< "$(run_audit "$d")" || fail "2: a generated mutation script writing the tracked CLI was accepted"
d="$(fixture reject4 'cp "$TMP/backup.orig" "$BACKUP_CLI"')"  # tracked-mutation-audit: hostile fixture
grep -q '^FAIL' <<< "$(run_audit "$d")" || fail "2: the backup CLI is not covered"
echo "  2: sed -i, a generated mutation script, and the backup CLI are all rejected"

# ---------------------------------------------------------------------------
# 3. ACCEPTED: the prescribed fix. This is the direction that matters -- an
#    audit that rejects its own remedy is one somebody switches off.
# ---------------------------------------------------------------------------
d="$(fixture accept1 \
  'MUT="$TMP/cli-mutant"' \
  'cp "$CLI" "$MUT"' \
  'python3 -I "$TMP/mutate.py" "$MUT" || fail "the mutation did not apply"' \
  'out="$(CLI="$MUT" probe)"' \
  'cp "$CLI" "$PRISTINE"' \
  'python3 -I "$TMP/mutdup.py" "$CLI" "$MUT2"' \
  'cmp -s "$CLI" "$PRISTINE" || fail "mutated in place"')"
out="$(run_audit "$d")"
grep -q '^PASS' <<< "$out" || fail "3: the prescribed fix was REJECTED: $out"
echo "  3: copying FROM the tracked CLI, and reading it to write a copy, are accepted"

# ---------------------------------------------------------------------------
# 4. A quoted heredoc body is DATA: a suite must be able to quote the historical
#    defect it exists to catch.
# ---------------------------------------------------------------------------
d="$(fixture heredoc \
  "cat > \$TMP/x <<'PY'" \
  'cp "$TMP/cli.orig" "$CLI"' \
  'PY')"
grep -q '^PASS' <<< "$(run_audit "$d")" \
  || fail "4: a quoted heredoc body was scanned as code"
echo "  4: a quoted heredoc body is data"

# ---------------------------------------------------------------------------
# 5. The marker exempts its OWN line only, and every exemption is PRINTED.
# ---------------------------------------------------------------------------
d="$(fixture marker \
  'cp "$TMP/cli.orig" "$CLI"  # tracked-mutation-audit: deliberate, for this test' \
  'echo ok')"
out="$(run_audit "$d")"
grep -q '^PASS' <<< "$out" || fail "5: the marker did not exempt its line: $out"
grep -q 'exempt' <<< "$out" || fail "5: the exemption was not PRINTED: $out"
d="$(fixture marker2 \
  '# tracked-mutation-audit: a marker on the PRECEDING line must not exempt' \
  'cp "$TMP/cli.orig" "$CLI"')"
grep -q '^FAIL' <<< "$(run_audit "$d")" \
  || fail "5: a marker on the preceding line exempted the next one"
echo "  5: the marker exempts its own line only, and is printed"

# ---------------------------------------------------------------------------
# 6. The real tree passes, and the audit cannot pass by scanning nothing.
# ---------------------------------------------------------------------------
out="$(run_audit "$REPO_ROOT")"
grep -q '^PASS' <<< "$out" || fail "6: the real tree does not pass: $out"
n="$(sed -nE 's/.*\(([0-9]+) suite\(s\) scanned.*/\1/p' <<< "$out")"
[ -n "$n" ] && [ "$n" -gt 50 ] \
  || fail "6: the audit reported scanning $n suites, which cannot be right"
echo "  6: the real tree passes, with $n suites scanned"

echo "PASS: no-tracked-mutation audit smoke test"
