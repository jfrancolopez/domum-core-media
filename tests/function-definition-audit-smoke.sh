#!/usr/bin/env bash
set -uo pipefail

# Proves tests/function-definition-audit.py actually detects a function that is
# called but never defined, and does NOT flag the shell forms that merely look
# like calls.
#
# WHY IT EXISTS. `service_upgrade` shipped to production calling
# `assert_pre_upgrade_possible`, a helper from a refactor that was attempted,
# broke, and was reverted -- leaving the call behind. Nothing caught it:
#
#   * `bash -n` parses; a function call is an ordinary command resolved at RUN
#     time, so a missing definition is syntactically perfect.
#   * shellcheck does not report unresolved commands either.
#   * 41 test suites passed, because no test invoked service_upgrade.
#
# The upgrade would have died mid-operation, under `set -e`, AFTER stopping the
# container. So the audit is only worth having if it is non-vacuous, and only
# usable if it is quiet on legitimate code: the first three drafts flagged an
# awk program, a jq program, a `\` continuation and arithmetic `(( ))`.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
AUDIT="$REPO_ROOT/tests/function-definition-audit.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

[ -x "$AUDIT" ] || fail "the audit is not executable"

echo "== 1. the audit passes on the real tree =="
"$AUDIT" >"$TMP_DIR/clean.log" 2>&1 \
  || { cat "$TMP_DIR/clean.log"; fail "the audit fails on unmodified HEAD"; }
grep -q '^PASS' "$TMP_DIR/clean.log" || fail "no PASS line on a clean tree"
echo "  clean"

# The audit resolves whole scopes, so mutation has to happen in a copy of the
# repo rather than against a synthetic one-file fixture: a fixture would prove
# the regex works, not that the real files are covered.
run_mutated() {  # $1 = sed program applied to bin/domum-media
  rm -rf "$TMP_DIR/repo"
  mkdir -p "$TMP_DIR/repo/tests" "$TMP_DIR/repo/bin"
  cp "$REPO_ROOT"/bin/domum-media "$REPO_ROOT"/bin/domum-media-report \
     "$REPO_ROOT"/bin/domum-media-backup "$TMP_DIR/repo/bin/"
  cp "$REPO_ROOT"/install.sh "$TMP_DIR/repo/"
  cp "$AUDIT" "$TMP_DIR/repo/tests/"
  sed -i "$1" "$TMP_DIR/repo/bin/domum-media" || return 99
  python3 "$TMP_DIR/repo/tests/function-definition-audit.py" >"$TMP_DIR/mut.log" 2>&1
  echo $?
}

# Section 5 mutates the AUDIT itself, not the CLI, so it needs its own helper.
# (run_mutated's sed targets bin/domum-media; pointing an audit-shaped mutation
# at it silently applies to nothing and the audit then passes for the wrong
# reason -- which is exactly what happened when this test was written.)
run_mutated_audit() {  # $1 = sed program applied to the audit
  rm -rf "$TMP_DIR/repo"
  mkdir -p "$TMP_DIR/repo/tests" "$TMP_DIR/repo/bin"
  cp "$REPO_ROOT"/bin/domum-media "$REPO_ROOT"/bin/domum-media-report \
     "$REPO_ROOT"/bin/domum-media-backup "$TMP_DIR/repo/bin/"
  cp "$REPO_ROOT"/install.sh "$TMP_DIR/repo/"
  cp "$AUDIT" "$TMP_DIR/repo/tests/"
  sed -i "$1" "$TMP_DIR/repo/tests/function-definition-audit.py" || return 99
  grep -q 'CALL_PATTERNS = \[\]\|(?!x)x' "$TMP_DIR/repo/tests/function-definition-audit.py" \
    || return 98
  python3 "$TMP_DIR/repo/tests/function-definition-audit.py" >"$TMP_DIR/mut.log" 2>&1
  echo $?
}

echo "== 2. mutation: an undefined call is caught in every command position =="
# Each mutant injects a call to a function that does not exist, in a different
# syntactic position. The audit must fail on all of them.
mutate_at="/^  domum_acquire_lock \"pre-upgrade-point/i\\"
declare -a MUTANTS=(
  '  zz_undefined_helper "$service"'
  '  zz_undefined_helper'
  '  if zz_undefined_helper; then :; fi'
  '  true \&\& zz_undefined_helper'
  '  true; zz_undefined_helper'
  '  local v; v="$(zz_undefined_helper)"'
  '  zz_undefined_helper || die "no"'
  '  echo x | zz_undefined_helper'
)
caught=0
for m in "${MUTANTS[@]}"; do
  rc="$(run_mutated "${mutate_at}${m}")"
  [ "$rc" = "99" ] && fail "mutant could not be applied: $m"
  if [ "$rc" = "0" ]; then
    echo "  !! NOT CAUGHT: $m" >&2
  else
    grep -q 'zz_undefined_helper' "$TMP_DIR/mut.log" \
      || fail "the audit failed but did not name zz_undefined_helper for: $m"
    caught=$((caught + 1))
  fi
done
[ "$caught" -eq "${#MUTANTS[@]}" ] \
  || fail "only $caught of ${#MUTANTS[@]} undefined-call mutants were caught"
echo "  $caught/${#MUTANTS[@]} undefined-call mutants caught, each named"

echo "== 3. mutation: removing a real definition is caught =="
# The exact defect: the call stays, the definition goes.
rc="$(run_mutated '/^assert_pre_upgrade_possible() {/,/^}$/d')"
[ "$rc" = "0" ] && fail "deleting assert_pre_upgrade_possible's definition was NOT caught"
grep -q 'assert_pre_upgrade_possible' "$TMP_DIR/mut.log" \
  || fail "the audit did not name the function whose definition was deleted"
echo "  caught, and named -- this is the production defect's exact shape"

echo "== 4. the audit is quiet on forms that only look like calls =="
# Every one of these was a real false positive during development.
declare -a BENIGN=(
  '/^  domum_acquire_lock "pre-upgrade-point/i\  (( zz_not_a_call == 0 \&\& zz_also_not == 0 )) \&\& true'
  '/^  domum_acquire_lock "pre-upgrade-point/i\  awk '"'"'BEGIN { zz_awk_var = 1; print zz_awk_var }'"'"' </dev/null'
  '/^  domum_acquire_lock "pre-upgrade-point/i\  local zz_assigned_var=1; echo "$zz_assigned_var"'
  '/^  domum_acquire_lock "pre-upgrade-point/i\  echo a \\\n    zz_continuation_arg >/dev/null'
  '/^  domum_acquire_lock "pre-upgrade-point/i\  cat <<'"'"'ZZEOF'"'"'\nzz_heredoc_word|zz_other_word\nZZEOF'
)
quiet=0
for b in "${BENIGN[@]}"; do
  rc="$(run_mutated "$b")"
  [ "$rc" = "99" ] && fail "benign case could not be applied: $b"
  if [ "$rc" != "0" ]; then
    echo "  !! FALSE POSITIVE on: $b" >&2
    grep '!!' "$TMP_DIR/mut.log" >&2
  else
    quiet=$((quiet + 1))
  fi
done
[ "$quiet" -eq "${#BENIGN[@]}" ] \
  || fail "the audit reported $(( ${#BENIGN[@]} - quiet )) false positive(s); it will be disabled by whoever hits one"
echo "  $quiet/${#BENIGN[@]} benign forms correctly ignored (arithmetic, awk, assignment, continuation, quoted heredoc)"

echo "== 5. the audit cannot pass vacuously =="
# If its patterns stop matching, it must fail rather than report success.
# Note: `CALL_PATTERNS = [] or [...]` does NOT empty the list -- `[] or X`
# evaluates to X. The reassignment has to come after the definition.
rc="$(run_mutated_audit 's/^SHELL_WORDS = {/CALL_PATTERNS = []\nSHELL_WORDS = {/')"
[ "$rc" = "98" ] && fail "the vacuity mutation did not apply to the audit"
[ "$rc" = "99" ] && fail "the vacuity mutation could not be applied"
[ "$rc" = "0" ] && fail "the audit passes with no call patterns -- it can report
success without having examined anything"
grep -q 'matched no call-shaped words' "$TMP_DIR/mut.log" \
  || fail "it failed for some other reason than the empty pattern set:
$(tail -3 "$TMP_DIR/mut.log")"

# And if it can no longer find DEFINITIONS, it must not conclude everything is
# undefined and emit hundreds of findings -- it must say its pattern is broken.
rc="$(run_mutated_audit 's/^DEF = re.compile/DEF = re.compile("(?!x)x") or re.compile/')"
[ "$rc" = "98" ] && fail "the broken-definition mutation did not apply to the audit"
[ "$rc" = "0" ] && fail "the audit passes when it can no longer find definitions"
grep -q 'DEF\|no definitions found' "$TMP_DIR/mut.log" \
  || fail "a broken definition pattern is not reported as such"
echo "  an audit that matches nothing fails instead of passing, in both directions"

echo "== 6. assert_pre_upgrade_possible is the single implementation =="
grep -q '^assert_pre_upgrade_possible() {' "$CLI" || fail "it is not defined"
for caller in service_upgrade storage_pre_upgrade_point; do
  body="$(awk "/^${caller}\(\) \{/,/^\}\$/" "$CLI")"
  [ -n "$body" ] || fail "could not isolate $caller"
  grep -q 'assert_pre_upgrade_possible' <<< "$body" \
    || fail "$caller does not route through assert_pre_upgrade_possible"
done
# The subvolume refusal must exist once, inside the helper. A second copy is how
# the two callers drift apart about what counts as protectable.
copies="$(grep -c 'is not a Btrfs subvolume, so no snapshot can be taken' "$CLI")"
[ "$copies" -eq 1 ] \
  || fail "the subvolume refusal appears $copies times; it must have one implementation"
helper="$(awk '/^assert_pre_upgrade_possible\(\) \{/,/^\}$/' "$CLI")"
grep -q 'is not a Btrfs subvolume' <<< "$helper" \
  || fail "the one copy of the refusal is not inside the helper"
echo "  defined once, both callers route through it"

echo "== 7. it refuses while the service is still RUNNING =="
# The whole point of asking early: a service that cannot be snapshotted must be
# refused before it is stopped, not after.
su="$(awk '/^service_upgrade\(\) \{/,/^\}$/' "$CLI")"
assert_line="$(grep -n 'assert_pre_upgrade_possible' <<< "$su" | head -1 | cut -d: -f1)"
[ -n "$assert_line" ] || fail "service_upgrade does not call the assertion"
stop_line="$(grep -n 'compose_cmd stop\|storage_pre_upgrade_point\|create_upgrade_rollback_point' <<< "$su" | head -1 | cut -d: -f1)"
[ -n "$stop_line" ] || fail "could not find where service_upgrade first touches the service"
[ "$assert_line" -lt "$stop_line" ] \
  || fail "service_upgrade asserts at line $assert_line but first touches the service at
$stop_line -- the refusal would arrive after the container was already stopped"
echo "  asserted at line $assert_line, service first touched at line $stop_line"

echo "== 8. the helper prints ONLY the path, so callers can use it as a value =="
grep -q "printf '%s\\\\n' \"\$path\"" <<< "$helper" \
  || fail "the helper does not print the path"
# Any human-facing text on stdout would be captured into the caller's variable.
while IFS= read -r line; do
  case "$line" in
    *'echo '*|*'[domum-media]'*)
      fail "the helper writes human text to stdout: $line
A caller does path=\"\$(assert_pre_upgrade_possible ...)\", so that text becomes the path." ;;
  esac
done <<< "$helper"
grep -q 'path="$(assert_pre_upgrade_possible "$service")"' "$CLI" \
  || fail "storage_pre_upgrade_point no longer captures the path from the helper"
echo "  stdout carries the path and nothing else"

echo
echo "PASS: function definition audit smoke"
