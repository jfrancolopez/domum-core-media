#!/usr/bin/env bash
set -uo pipefail

# Proves tests/operator-wrapper-audit.py would have caught the assertions that
# actually aborted correct production states -- including by running it against
# the historical wrapper, which must be rejected.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/operator-wrapper-audit.py"
WRAPPER="$REPO_ROOT/operator/domum-media-upgrade-service.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

echo "== 1. the audit passes on the current wrapper =="
"$AUDIT" >"$TMP_DIR/clean.log" 2>&1 || { cat "$TMP_DIR/clean.log"; fail "fails on HEAD"; }
echo "  clean"

echo "== 2. the wrapper is syntactically valid and refuses without root =="
bash -n "$WRAPPER" || fail "the wrapper does not parse"
out="$(bash "$WRAPPER" plex --preflight-only 2>&1)"; rc=$?
if [ "$(id -u)" -ne 0 ]; then
  [ "$rc" -ne 0 ] || fail "the wrapper ran as a non-root user"
  grep -q 'must run as root' <<< "$out" || fail "wrong refusal: $out"
  echo "  parses; refuses as non-root"
else
  echo "  parses (running as root, so the root refusal was not exercised)"
fi
bash "$WRAPPER" plex --nonsense >/dev/null 2>&1
[ $? -eq 2 ] || fail "an unknown option did not exit 2"
# And no service at all is a usage error, checked BEFORE root -- argument
# validation should not need privilege.
bash "$WRAPPER" >/dev/null 2>&1
[ $? -eq 2 ] || fail "no service argument did not exit 2"
echo "  an unknown option exits 2; a missing service exits 2 before the root check"

run_against() {  # $1 = file content -> audit exit code
  rm -rf "$TMP_DIR/r"; mkdir -p "$TMP_DIR/r/operator" "$TMP_DIR/r/tests" "$TMP_DIR/r/bin"
  cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/r/bin/"
  cp "$AUDIT" "$TMP_DIR/r/tests/"
  cp "$1" "$TMP_DIR/r/operator/wrapper.sh"
  python3 "$TMP_DIR/r/tests/operator-wrapper-audit.py" >"$TMP_DIR/mut.log" 2>&1
  echo $?
}

echo "== 3. the HISTORICAL wrapper is rejected =="
# The exact assertions that aborted a correct production state.
cat > "$TMP_DIR/old.sh" <<'OLD'
#!/usr/bin/env bash
set -u
for fn in service_upgrade rollback_upgrade storage_verify_archive \
          make_pre_upgrade_point other_container_identities \
          recovery_point_image_pairs archive_image_to_file; do
  grep -q "^$fn()" /usr/local/bin/domum-media \
    || abort "the installed CLI has no $fn(). Deploy $REVISION before upgrading."
done
grep -q 'service_upgrade "\$1"' /usr/local/bin/domum-media \
  || abort "the installed CLI does not route 'updates apply --service'"
if domum-media cleanup images 2>/dev/null | grep -qE "^${OLD_IMG}( |$)"; then
  abort "the old image is a cleanup DELETION CANDIDATE"
fi
if domum-media storage verify-recovery plex "$POINT" | grep -q 'recovery point  : verified'; then
  :
fi
OLD
rc="$(run_against "$TMP_DIR/old.sh")"
[ "$rc" = "0" ] && fail "the audit ACCEPTS the historical wrapper. It would not have
caught the aborts it exists to prevent."
for want in 'private function' 'prose is not a contract'; do
  grep -q "$want" "$TMP_DIR/mut.log" \
    || fail "the rejection does not mention '$want': $(cat "$TMP_DIR/mut.log")"
done
n="$(grep -c '^   !!' "$TMP_DIR/mut.log")"
[ "$n" -ge 4 ] || fail "only $n violation(s) found in the historical wrapper; expected
the function greps, the dispatcher grep and both prose greps"
echo "  rejected with $n violations, naming private functions and prose parsing"

echo "== 4. mutation: reintroducing a private-function grep is caught =="
cp "$WRAPPER" "$TMP_DIR/m1.sh"
printf '\ngrep -q "^service_upgrade()" /usr/local/bin/domum-media || abort "nope"\n' >> "$TMP_DIR/m1.sh"
rc="$(run_against "$TMP_DIR/m1.sh")"
[ "$rc" = "0" ] && fail "a reintroduced private-function grep was NOT caught"
grep -q 'service_upgrade' "$TMP_DIR/mut.log" || fail "the function was not named"
echo "  caught, and named"

echo "== 4b. mutation: the historical LOOP form is caught =="
# The shape that actually shipped: the pattern is a VARIABLE, so no literal
# function name appears on the grep line and a name-based rule misses it.
cp "$WRAPPER" "$TMP_DIR/m1b.sh"
cat >> "$TMP_DIR/m1b.sh" <<'LOOP'

for fn in some_internal_helper another_one; do
  grep -q "^$fn()" /usr/local/bin/domum-media \
    || abort "the installed CLI has no $fn()."
done
LOOP
rc="$(run_against "$TMP_DIR/m1b.sh")"
[ "$rc" = "0" ] && fail "the loop form -- grepping the binary with a VARIABLE pattern --
was not caught. That is the exact shape that aborted a correct production state."
grep -q "greps the CLI's SOURCE" "$TMP_DIR/mut.log" \
  || fail "not reported as grepping the binary: $(cat "$TMP_DIR/mut.log")"
echo "  caught by the grep-the-binary rule, which needs no literal name"

echo "== 5. mutation: reintroducing a prose grep is caught =="
cp "$WRAPPER" "$TMP_DIR/m2.sh"
printf '\ndomum-media storage protection plex | grep -q protected || abort "nope"\n' >> "$TMP_DIR/m2.sh"
rc="$(run_against "$TMP_DIR/m2.sh")"
[ "$rc" = "0" ] && fail "a reintroduced prose grep was NOT caught"
grep -q 'prose is not a contract' "$TMP_DIR/mut.log" || fail "not reported as prose parsing"
echo "  caught"

echo "== 6. mutation: requiring a capability the CLI does not advertise =="
cp "$WRAPPER" "$TMP_DIR/m3.sh"
sed -i 's/^NEEDED_CAPS="service-scoped-upgrade/NEEDED_CAPS="no-such-capability service-scoped-upgrade/' "$TMP_DIR/m3.sh"
cmp -s "$WRAPPER" "$TMP_DIR/m3.sh" && fail "the NEEDED_CAPS block is no longer written as matched"
rc="$(run_against "$TMP_DIR/m3.sh")"
[ "$rc" = "0" ] && fail "a wrapper requiring a non-existent capability passed. It would
abort every run with a message the operator cannot act on."
grep -q 'no-such-capability' "$TMP_DIR/mut.log" || fail "the bad token was not named"
echo "  caught, and named"

echo "== 7. --json and capabilities piping are NOT flagged =="
# The audit must not forbid the structured interface it is steering people to.
cp "$WRAPPER" "$TMP_DIR/m4.sh"
printf '\n"$CLI" cleanup images --json | jq -e ".images[0]" >/dev/null\n' >> "$TMP_DIR/m4.sh"
printf '"$CLI" capabilities | grep -qx service-scoped-upgrade\n' >> "$TMP_DIR/m4.sh"
rc="$(run_against "$TMP_DIR/m4.sh")"
[ "$rc" = "0" ] \
  || fail "the audit flagged legitimate --json/capabilities use; whoever hits that
will disable the audit: $(cat "$TMP_DIR/mut.log")"
echo "  structured interfaces allowed"

echo "== 8. the audit cannot pass vacuously =="
rm -rf "$TMP_DIR/r"; mkdir -p "$TMP_DIR/r/operator" "$TMP_DIR/r/tests" "$TMP_DIR/r/bin"
cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/r/bin/"; cp "$AUDIT" "$TMP_DIR/r/tests/"
python3 "$TMP_DIR/r/tests/operator-wrapper-audit.py" >"$TMP_DIR/mut.log" 2>&1
[ $? -eq 0 ] && fail "the audit passes with NO operator scripts present"
grep -q 'no operator scripts' "$TMP_DIR/mut.log" || fail "an empty operator/ is not reported"
echo "  an empty operator/ fails instead of passing"

echo "== 9. the wrapper requires every capability the upgrade actually needs =="
for cap in service-scoped-upgrade pre-upgrade-point archive-image \
           verify-image-archive rollback-upgrade recovery-image-protection \
           machine-readable-cleanup-images protection-state; do
  grep -q "$cap" "$WRAPPER" || fail "the wrapper does not require '$cap'"
done
# And it must actually CHECK them, not merely list them.
grep -q 'capabilities --has "$cap"' "$WRAPPER" \
  || fail "NEEDED_CAPS is listed but never checked against the installed CLI"
echo "  all eight required and checked against the installed binary"

echo
echo "PASS: operator wrapper audit smoke"
