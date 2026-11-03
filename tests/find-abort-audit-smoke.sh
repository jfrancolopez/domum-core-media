#!/usr/bin/env bash
# The find-abort audit, driven against fixtures.
#
# An audit that has only been read has not been tested, and this one has to be
# precise in both directions: it must catch a `find` in a command substitution
# that can abort the shell, and it must ACCEPT the fix -- otherwise the fix it
# prescribes fails its own check and somebody switches it off.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/find-abort-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

run_audit() {  # $1.. = fixture basenames under $TMP
  local t="" n
  for n in "$@"; do t="${t:+$t:}$n"; done
  FIND_AUDIT_ROOT="$TMP" FIND_AUDIT_TARGETS="$t" python3 "$AUDIT" 2>&1
}

sect "the banned shape is CAUGHT"
cat > "$TMP/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n="$(find "$dir" -type f 2>/dev/null | wc -l)"
echo "$n"
EOF
out="$(run_audit bad.sh)"
grep -q 'FAIL' <<< "$out" || fail "an unguarded find in a substitution was accepted: $out"
grep -q 'bad.sh:3' <<< "$out" || fail "the finding does not name the line: $out"
echo "  caught, with the line named"

sect "the PRESCRIBED FIX is accepted"
# If the audit rejected its own remedy it would be unusable.
cat > "$TMP/good.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n="$(find "$dir" -type f 2>/dev/null | wc -l || true)"
echo "$n"
EOF
out="$(run_audit good.sh)"
grep -q 'PASS' <<< "$out" || fail "the prescribed || true fix was rejected: $out"
echo "  accepted"

sect "a CONTINUED pipeline is joined before the check"
# Two of the ten pipefail-audit findings were invisible to a line-at-a-time
# search because the pipeline was split across lines. Same hazard here.
cat > "$TMP/cont.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n="$(find "$dir" -type f -printf '%s\n' 2>/dev/null \
  | awk '{b+=$1} END{print b+0}' || true)"
EOF
out="$(run_audit cont.sh)"
grep -q 'PASS' <<< "$out" \
  || fail "a guard on the CONTINUATION line was not seen, so the audit would
demand a second guard on a line that already has one: $out"
cat > "$TMP/cont-bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n="$(find "$dir" -type f -printf '%s\n' 2>/dev/null \
  | awk '{b+=$1} END{print b+0}')"
EOF
out="$(run_audit cont-bad.sh)"
grep -q 'FAIL' <<< "$out" || fail "an unguarded CONTINUED pipeline was accepted: $out"
echo "  joined: the guarded form passes and the unguarded one is caught"

sect "an explicit MARKER exempts its own line, and is PRINTED"
# An allowance nobody can see is how a real defect gets a marker stuck on it.
# The marker goes on the line it exempts, matching the pipefail audit's
# convention. A marker on a PRECEDING line would drift away from the line it
# vouches for -- the same problem as a comment between a warning and its
# remedy -- so that form is asserted NOT to exempt.
cat > "$TMP/marked.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n="$(find "$dir" -type f 2>/dev/null | wc -l)"  # find-audit: ensure_dirs creates it first
EOF
out="$(run_audit marked.sh)"
grep -q 'PASS' <<< "$out" || fail "the marker did not exempt its own line: $out"
grep -q 'exempt (marker)' <<< "$out" \
  || fail "the exemption was silent. An allowance nobody can see is how a real
defect gets a marker stuck on it: $out"

cat > "$TMP/marked-above.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# find-audit: this marker is on the WRONG line
n="$(find "$dir" -type f 2>/dev/null | wc -l)"
EOF
out="$(run_audit marked-above.sh)"
grep -q 'FAIL' <<< "$out" \
  || fail "a marker on a PRECEDING line exempted the find. A marker that is not
on the line it vouches for drifts away from it: $out"
echo "  exempted on its own line, printed, and not from the line above"

sect "a QUOTED heredoc body is DATA and is not scanned"
# A suite reproducing the defect it must catch has to be able to contain it.
cat > "$TMP/heredoc.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null <<'INNER'
n="$(find "$dir" -type f 2>/dev/null | wc -l)"
INNER
m="$(find "$dir" -type f 2>/dev/null | wc -l || true)"
EOF
out="$(run_audit heredoc.sh)"
grep -q 'PASS' <<< "$out" \
  || fail "the shape inside a QUOTED heredoc was treated as code: $out"
echo "  quoted heredoc ignored; the real line still checked"

sect "it cannot pass VACUOUSLY"
# If the extraction breaks, zero matches must be a failure rather than silence.
cat > "$TMP/nofind.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "no find here at all"
EOF
out="$(run_audit nofind.sh)"
grep -q 'FAIL' <<< "$out" || fail "a file with no find at all reported PASS: $out"
grep -qi 'matched no' <<< "$out" || fail "it does not say the pattern matched nothing: $out"
echo "  zero matches is a failure, not a pass"

sect "a MISSING target is reported, not skipped"
out="$(run_audit absent-file.sh)"
grep -q 'FAIL' <<< "$out" || fail "a target that does not exist was skipped: $out"
grep -qi 'stale' <<< "$out" || fail "it does not say the target list is stale: $out"
echo "  a stale target list fails"

sect "the REAL tree passes"
out="$(python3 "$AUDIT" 2>&1)"
grep -q 'PASS' <<< "$out" || fail "the repository does not satisfy its own audit: $out"
echo "  ${out##*PASS: }"

echo "ALL FIND-ABORT AUDIT CHECKS PASSED"
