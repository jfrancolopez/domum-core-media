#!/usr/bin/env bash
set -euo pipefail

# Drive the real tracked-file audit against isolated, committed fixture repos.
# Identifier values are assembled from pieces so this test never contains a
# literal that the audit itself should flag.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/identifier-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name "identifier audit smoke"
  git -C "$dir" config user.email "identifier-audit@example.test"
}
commit_fixture() {
  local dir="$1"
  git -C "$dir" add .
  git -C "$dir" commit -qm "fixture"
}

BAD="$TMP/bad"
init_repo "$BAD"
mkdir -p "$BAD/docs"
private="$(printf '%s.%s.%s.%s' 172 16 4 9)"
tailnet="$(printf '%s.%s.%s.%s' 100 64 1 8)"
account="u""12345"
printf 'private=%s\ntailnet=%s\naccount=%s\n' \
  "$private" "$tailnet" "$account" > "$BAD/docs/identifiers.txt"
commit_fixture "$BAD"

set +e
bad_output="$(python3 "$AUDIT" "$BAD" 2>&1)"
bad_status=$?
set -e
[[ "$bad_status" -ne 0 ]] || fail "prohibited identifiers unexpectedly passed"
for expected in \
  'RFC1918 address [redacted] at docs/identifiers.txt:1' \
  'Tailscale CGNAT address [redacted] at docs/identifiers.txt:2' \
  'backup account pattern [redacted] at docs/identifiers.txt:3'; do
  grep -Fq -- "$expected" <<< "$bad_output" || fail "missing redacted finding location/type"
done
[[ "$bad_output" != *"$private"* && "$bad_output" != *"$tailnet"* \
   && "$bad_output" != *"$account"* ]] \
  || fail "audit output exposed a matched value"
echo "PASS: prohibited address/account fixtures fail with redacted locations"

GOOD="$TMP/good"
init_repo "$GOOD"
mkdir -p "$GOOD/docs"
allowed_example="$(printf '%s.%s.%s.%s' 10 0 0 12)"
product_version="$(printf '%s.%s.%s.%s' 10 11 11 10)"
printf 'Documented service example: %s\n' "$allowed_example" > "$GOOD/docs/examples.md"
printf 'The database reports product version `%s` — in its metadata.\n' \
  "$product_version" > "$GOOD/docs/RECOVERY-POINT-IDENTITY.md"
commit_fixture "$GOOD"
good_output="$(python3 "$AUDIT" "$GOOD" 2>&1)" \
  || fail "documented examples unexpectedly failed the audit"
grep -Fq 'scanned 2 tracked text file(s)' <<< "$good_output" \
  || fail "pass fixture did not prove the audit scanned tracked text files"
grep -Fq 'no prohibited infrastructure identifiers found' <<< "$good_output" \
  || fail "pass fixture did not report a clean result"
echo "PASS: documented 10.0.0.x and labeled product-version examples pass"

EMPTY="$TMP/empty"
init_repo "$EMPTY"
set +e
empty_output="$(python3 "$AUDIT" "$EMPTY" 2>&1)"
empty_status=$?
set -e
[[ "$empty_status" -ne 0 ]] \
  || fail "empty repository passed without scanning text files"
grep -Fq 'no text files were scanned' <<< "$empty_output" \
  || fail "empty-repository failure was not explained"
echo "PASS: audit fails when it scans zero text files"
