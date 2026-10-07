#!/usr/bin/env bash
set -uo pipefail

# The capability contract replaces operator scripts grepping the installed binary
# for private Bash function names.
#
# WHY IT EXISTS. The Plex upgrade wrapper did exactly that:
#
#   for fn in service_upgrade rollback_upgrade make_pre_upgrade_point ...; do
#     grep -q "^$fn()" /usr/local/bin/domum-media || abort ...
#
# `make_pre_upgrade_point` came from a refactor that was attempted and reverted,
# so it never existed in any merged revision -- and the wrapper aborted against a
# perfectly correct production state. Same shape as the wrapper that grepped for
# the prose `recovery point  : verified`.
#
# A contract is only worth having if it cannot lie, so these assertions pin both
# directions: a token must not be advertised when the behaviour is unreachable,
# and `--has` must not answer yes by default.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
AUDIT="$REPO_ROOT/tests/capabilities-contract-audit.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

echo "== 1. the audit passes, and every required token is advertised =="
"$AUDIT" >"$TMP_DIR/audit.log" 2>&1 || { cat "$TMP_DIR/audit.log"; fail "audit fails on HEAD"; }
listed="$("$CLI" capabilities)" || fail "capabilities exited non-zero"
for t in service-scoped-upgrade pre-upgrade-point archive-image verify-image-archive \
         rollback-upgrade recovery-image-protection machine-readable-cleanup-images; do
  grep -qxF "$t" <<< "$listed" || fail "the required token '$t' is not advertised"
done
echo "  $(wc -l <<< "$listed") tokens advertised, all 7 required ones present"

echo "== 2. --has distinguishes supported, unsupported and UNKNOWN =="
"$CLI" capabilities --has service-scoped-upgrade || fail "a supported token did not exit 0"
"$CLI" capabilities --has definitely-not-a-capability
rc=$?
[ "$rc" -ne 0 ] || fail "an UNKNOWN token exited 0 -- a script asking about a token this
binary has never heard of would read that as a yes"
[ "$rc" -eq 2 ] || fail "an unknown token should be distinguishable (expected 2, got $rc)"
"$CLI" capabilities --has >/dev/null 2>&1
[ $? -ne 0 ] || fail "--has with no token exited 0"
"$CLI" capabilities --bogus-mode >/dev/null 2>&1
[ $? -ne 0 ] || fail "an unknown mode exited 0"
echo "  supported=0, unsupported=1, unknown=2, misuse non-zero"

echo "== 3. capabilities does not require root =="
# A preflight must be able to ask what is installed BEFORE escalating.
cap_body="$(awk '/^capabilities_cmd\(\) \{/,/^\}$/' "$CLI")"
grep -q 'need_root' <<< "$cap_body" \
  && fail "capabilities_cmd requires root; a preflight could not call it before sudo"
echo "  read-only, no root"

echo "== 4. every advertised token is backed by a DEFINED implementation =="
# This is the half `declare -F` covers at run time on the operator's host.
while IFS='|' read -r token argv impl; do
  [ -n "$token" ] || continue
  grep -q "^$impl() {" "$CLI" || fail "capability $token names $impl(), which is not defined"
done < <(awk '/^domum_capability_specs\(\) \{/,/^\}$/' "$CLI" | grep -F '|')
echo "  all implementations defined"

mutate() {  # $1 = sed program on bin/domum-media -> prints audit exit code
  rm -rf "$TMP_DIR/repo"; mkdir -p "$TMP_DIR/repo/tests" "$TMP_DIR/repo/bin"
  cp "$CLI" "$TMP_DIR/repo/bin/"; cp "$AUDIT" "$TMP_DIR/repo/tests/"
  sed -i "$1" "$TMP_DIR/repo/bin/domum-media" || return 99
  cmp -s "$CLI" "$TMP_DIR/repo/bin/domum-media" && return 98
  python3 "$TMP_DIR/repo/tests/capabilities-contract-audit.py" >"$TMP_DIR/mut.log" 2>&1
  echo $?
}

echo "== 5. mutation: a capability whose dispatcher line is removed must FAIL =="
# The required property: advertisement tied to actual command wiring.
declare -a DISPATCH_MUTANTS=(
  's|service_upgrade "$1" "${2:-}"|: removed|'
  's|storage_pre_upgrade_point "${1:-}" "${2:-}"|: removed|'
  's|storage_verify_archive "${1:-}"|: removed|'
  's|rollback_upgrade "${1:-}" "${2:-}"|: removed|'
  's|^        cleanup_images_json$|        : removed|'
  's|storage_topology_verify "$2"|: removed|'
)
caught=0
for m in "${DISPATCH_MUTANTS[@]}"; do
  rc="$(mutate "$m")"
  [ "$rc" = "99" ] && fail "mutant could not be applied: $m"
  [ "$rc" = "98" ] && fail "mutant changed nothing (pattern no longer matches): $m"
  if [ "$rc" = "0" ]; then
    echo "  !! NOT CAUGHT: $m" >&2
  else
    grep -q 'not dispatchable\|does not route\|no dispatcher branch\|nothing on that path' "$TMP_DIR/mut.log" \
      || fail "the audit failed but not for unreachability: $(tail -2 "$TMP_DIR/mut.log")"
    caught=$((caught + 1))
  fi
done
[ "$caught" -eq "${#DISPATCH_MUTANTS[@]}" ] \
  || fail "only $caught of ${#DISPATCH_MUTANTS[@]} removed-dispatcher mutants were caught"
echo "  $caught/${#DISPATCH_MUTANTS[@]} removed-dispatcher mutants caught"

echo "== 6. mutation: a token advertised with no implementation must FAIL =="
# Renaming the TOKEN is not a violation -- the behaviour is still reachable.
# What must fail is advertising an argv path the dispatcher does not route.
rc="$(mutate 's@^service-scoped-upgrade|updates apply@service-scoped-upgrade|nosuchtop apply@')"
[ "$rc" = "0" ] && fail "a capability advertising an unroutable top-level command passed"
grep -q 'does not route' "$TMP_DIR/mut.log" || fail "not reported as an unroutable command"
rc="$(mutate 's@^pre-upgrade-point|storage pre-upgrade-point@pre-upgrade-point|storage no-such-sub@')"
[ "$rc" = "0" ] && fail "a capability advertising a non-existent subcommand passed"
grep -q 'no dispatcher branch' "$TMP_DIR/mut.log" || fail "not reported as a missing branch"
echo "  an unroutable command and a missing subcommand are both caught"
rc="$(mutate "s|^archive-image.*|archive-image\\|storage pre-upgrade-point --archive-image\\|no_such_function|")"
[ "$rc" = "0" ] && fail "a capability naming an undefined implementation passed"
grep -q 'is not defined' "$TMP_DIR/mut.log" || fail "not reported as an undefined implementation"
echo "  an undefined implementation is named as such"

echo "== 7. mutation: both --has guards are load-bearing =="
# The single most dangerous failure here is a preflight that always passes, so
# each guard is removed in turn and the ANSWER is compared against the unmutated
# one. A mutant that changes nothing means the guard is dead code.
#
# NOTE the `@` sed delimiter: these patterns contain `||`, and `s|...|` makes sed
# error out. The first draft used `|`, sed failed, the helper returned 99, and
# neither assertion matched -- the section passed while testing nothing.
probe() {  # $1 = sed program, $2 = token -> rc of `capabilities --has $2`
  rm -rf "$TMP_DIR/bin2"; mkdir -p "$TMP_DIR/bin2"
  cp "$CLI" "$TMP_DIR/bin2/domum-media"
  if [ -n "$1" ]; then
    sed -i "$1" "$TMP_DIR/bin2/domum-media" || { echo 99; return; }
    cmp -s "$CLI" "$TMP_DIR/bin2/domum-media" && { echo 98; return; }
  fi
  bash "$TMP_DIR/bin2/domum-media" capabilities --has "$2" >/dev/null 2>&1
  echo $?
}

# Baseline, unmutated: unknown is distinguishable from unsupported.
base_unknown="$(probe '' definitely-not-a-capability)"
[ "$base_unknown" = "2" ] || fail "baseline: an unknown token gave $base_unknown, expected 2"

# Guard A: without it, `unknown` collapses into some other answer.
rc="$(probe 's@  (( known == 1 )) || return 2@  :@' definitely-not-a-capability)"
[ "$rc" = "99" ] && fail "the unknown-token mutation could not be applied (sed error)"
[ "$rc" = "98" ] && fail "the unknown-token guard is no longer present as written"
[ "$rc" != "$base_unknown" ] \
  || fail "removing the unknown-token guard changed nothing -- it is dead code, and
nothing distinguishes a token this binary has never heard of from an unsupported one"
echo "  unknown-token guard is load-bearing (unknown: $base_unknown -> $rc without it)"

# Guard B: a KNOWN token whose implementation is missing must not answer yes.
miss='s@^rollback-upgrade|rollback-upgrade|rollback_upgrade@rollback-upgrade|rollback-upgrade|gone_function@'
base_missing="$(probe "$miss" rollback-upgrade)"
[ "$base_missing" = "98" ] && fail "the capability table row is no longer present as written"
[ "$base_missing" = "1" ] \
  || fail "a known token with a missing implementation gave $base_missing, expected 1"
rc="$(probe "$miss"'; s@  (( supported == 1 )) || return 1@  :@' rollback-upgrade)"
[ "$rc" = "99" ] && fail "the supported-guard mutation could not be applied (sed error)"
[ "$rc" = "0" ] \
  || fail "removing the supported guard left the answer at $rc; the guard is not what
produces the refusal, so nothing here proves --has cannot answer yes for a
capability the installed binary cannot actually perform"
echo "  supported guard is load-bearing (missing impl: $base_missing -> $rc without it)"

echo "== 8. the audit cannot pass vacuously =="
rc="$(mutate 's|^service-scoped-upgrade.*||')"
[ "$rc" = "99" ] && fail "could not blank the table"
# Blanking one row must not be mistaken for "all rows pass".
rm -rf "$TMP_DIR/repo"; mkdir -p "$TMP_DIR/repo/tests" "$TMP_DIR/repo/bin"
cp "$CLI" "$TMP_DIR/repo/bin/"; cp "$AUDIT" "$TMP_DIR/repo/tests/"
python3 - "$TMP_DIR/repo/bin/domum-media" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1]); s = p.read_text()
s = re.sub(r"(domum_capability_specs\(\) \{\n  cat <<'EOF'\n).*?(EOF\n)", r"\1\2", s, flags=re.S)
p.write_text(s)
PY
python3 "$TMP_DIR/repo/tests/capabilities-contract-audit.py" >"$TMP_DIR/mut.log" 2>&1
[ $? -eq 0 ] && fail "an EMPTY capability table passes the audit -- it would report
success having verified nothing"
grep -q 'table is empty' "$TMP_DIR/mut.log" || fail "an empty table is not reported as such"
echo "  an empty table fails instead of passing"

echo
echo "PASS: capabilities contract smoke"
