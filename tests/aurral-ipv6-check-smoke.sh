#!/usr/bin/env bash
# Drives experiments/aurral/validate.sh's container_global_ipv6 with no
# container and no root, through the AURRAL_VALIDATE_LIB seam.
#
# The check this replaces read `docker inspect -f '{{.GlobalIPv6Address}}'` and
# reported "container has a global IPv6 address: invalid IP" against a
# container that had none. On Docker 29.10.0 that field is a `netip.Addr` whose
# ZERO value String()s to the literal "invalid IP", so an absent address was
# indistinguishable from a present one. Section 1 is the load-bearing case.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad()  { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }

# /proc/net/if_inet6 columns: addr ifindex prefixlen SCOPE flags name
LO='00000000000000000000000000000001 01 80 10 80       lo'
LINKLOCAL='fe800000000000000042acfffe13000a 03 40 20 80     eth0'
GLOBAL='20010db8000000000000000000000001 03 40 00 00     eth0'

# $1 = what the stubbed `docker exec` prints, $2 = its exit status.
# $3 (optional) = path to the script under test, defaults to the real one.
drive() {
  local content="$1" rc="$2" target="${3:-$ROOT/experiments/aurral/validate.sh}"
  printf '%s' "$content" > "$TMP/inet6"
  DOCKER_STUB_RC="$rc" DOCKER_STUB_FILE="$TMP/inet6" bash -c '
    set -uo pipefail
    docker() { [ "${DOCKER_STUB_RC}" -ne 0 ] && return "${DOCKER_STUB_RC}"; cat "${DOCKER_STUB_FILE}"; }
    export -f docker 2>/dev/null || true
    AURRAL_VALIDATE_LIB=1 source "$1"
    out="$(container_global_ipv6 some-container)"; rc=$?
    printf "RC=%s\nOUT=[%s]\n" "$rc" "$out"
  ' _ "$target"
}

sect "1. only ::1 on lo -- the REAL state of this container. Must be no global address."
r="$(drive "$LO" 0)"
grep -q 'RC=0' <<< "$r" && ok "rc 0 (the file was readable)" || { bad "expected rc 0: $r"; }
grep -q 'OUT=\[\]' <<< "$r" && ok "reports NO global address" || bad "expected empty output, got: $r"

sect "2. a link-local address (scope 20) is NOT a global address"
r="$(drive "$LO
$LINKLOCAL" 0)"
grep -q 'OUT=\[\]' <<< "$r" && ok "link-local is not reported as global" || bad "link-local misreported: $r"

sect "3. a real GLOBAL address (scope 00) must be detected"
r="$(drive "$LO
$LINKLOCAL
$GLOBAL" 0)"
grep -q '20010db8000000000000000000000001' <<< "$r" && ok "global address detected and named" || bad "missed the global address: $r"

sect "4. an unreadable file is rc 2 -- UNKNOWN, never a pass"
r="$(drive "" 1)"
grep -q 'RC=2' <<< "$r" && ok "docker exec failure => rc 2" || bad "expected rc 2: $r"
r="$(drive "" 0)"
grep -q 'RC=2' <<< "$r" && ok "empty output => rc 2 (a running container always has ::1)" || bad "expected rc 2 for empty: $r"

sect "5. the lib seam defines the helper and runs NO check"
out="$(AURRAL_VALIDATE_LIB=1 bash -c 'source "$1" && declare -F container_global_ipv6' _ "$ROOT/experiments/aurral/validate.sh" 2>&1)"
grep -q 'container_global_ipv6' <<< "$out" && ok "helper is defined when sourced as a lib" || bad "helper not defined: $out"
grep -qE '^(  ok|  FAIL|== )' <<< "$out" && bad "sourcing as a lib ran checks: $out" || ok "no check ran on source"

sect "6. the retired template form is gone, and the JSON form is used"
v="$ROOT/experiments/aurral/validate.sh"
code="$(sed 's/#.*//' "$v")"
grep -qF '{{.GlobalIPv6Address}}' <<< "$code" && bad "still reads the field through Go's String()" || ok "no bare {{.GlobalIPv6Address}} in code"
grep -qF '{{json .GlobalIPv6Address}}' <<< "$code" && ok "reads the metadata as JSON" || bad "the JSON form is missing"

sect "7. MUTATION: match any scope -- a link-local must then read as global"
MUT="$TMP/validate-mutant.sh"
cp "$v" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  awk '$4 == "00" { print $1 }' <<< "$raw\""""
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, """  awk '{ print $1 }' <<< "$raw\""""))
PY
if [[ $? -ne 0 ]]; then bad "7: the mutation did not apply"; else
  r="$(drive "$LO
$LINKLOCAL" 0 "$MUT")"
  grep -q 'fe800000000000000042acfffe13000a' <<< "$r" \
    && ok "without the scope filter a link-local reads as global -- the filter is load-bearing" \
    || bad "mutant did not change the answer: $r"
fi

printf '\n%s checks, %s failures\n' "$n" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
