#!/usr/bin/env bash
# Docker writes the host's resolver list into a container when the container is
# CREATED and never revisits it. Measured on this host 2026-11-24: every
# production container carried `ExtServers: [host(127.0.0.1)]` from before the
# host moved to Tailscale DNS, so not one could resolve an external name --
# Traefik could not reach the ACME directory, so no certificate could be issued
# or RENEWED. The 2026-11-23 reboot restarted them all and did not clear it.
#
# The load-bearing case is section 3: a container with an explicit `dns:` is
# deliberately different from the host and must NOT be reported. Without that,
# the check would mail a false critical about the Aurral experiment every run.
set -uo pipefail

CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/domum-media"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad()  { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }

# Documentation ranges, deliberately: identifier-audit.py rejects a CGNAT or
# RFC1918 literal in a tracked file, and the comparison only needs the sets to
# overlap or be disjoint. 127.0.0.1 is kept because it IS the stale value Docker
# recorded, and loopback is not an infrastructure identifier.
HOST_RC='nameserver 203.0.113.53
nameserver 2001:db8::53'
# The real shape measured on this host, from a container on a user-defined network.
STALE_RC='nameserver 127.0.0.11
# ExtServers: [host(127.0.0.1) host(::1)]'
CURRENT_RC='nameserver 203.0.113.53
nameserver 127.0.0.11'
BRIDGE_RC='nameserver 203.0.113.53'
BRIDGE_STALE_RC='nameserver 127.0.0.1'

# $1 explicit dns json, $2 container resolv.conf, $3 host resolv.conf
state() {
  bash -c 'source "$1" >/dev/null 2>&1 || true; container_dns_upstream_state "$2" "$3" "$4"' \
    _ "$CLI" "$1" "$2" "$3" 2>/dev/null
}

sect "1. the measured stale shape is reported STALE"
r="$(state '[]' "$STALE_RC" "$HOST_RC")"
[[ "$r" == stale ]] && ok "ExtServers host(127.0.0.1) vs host 203.0.113.53 => stale" || bad "got '$r', expected stale"

sect "2. an overlapping upstream is CURRENT (one match is enough to resolve)"
r="$(state '[]' "$CURRENT_RC" "$HOST_RC")"
[[ "$r" == current ]] && ok "shares 203.0.113.53 => current" || bad "got '$r', expected current"

sect "3. an explicit dns: is CONFIGURED, never stale -- the false-alarm guard"
# Disjoint from the host ON PURPOSE: this is exactly the Aurral experiment.
r="$(state '["1.1.1.1","1.0.0.1"]' "$STALE_RC" "$HOST_RC")"
[[ "$r" == configured ]] && ok "explicit public resolvers => configured, not stale" || bad "got '$r', expected configured"
r="$(state '["1.1.1.1"]' "$CURRENT_RC" "$HOST_RC")"
[[ "$r" == configured ]] && ok "explicit dns wins regardless of the file" || bad "got '$r', expected configured"

sect "4. the default-bridge shape (no ExtServers comment)"
r="$(state '[]' "$BRIDGE_RC" "$HOST_RC")"
[[ "$r" == current ]] && ok "nameserver == host resolver => current" || bad "got '$r', expected current"
r="$(state '[]' "$BRIDGE_STALE_RC" "$HOST_RC")"
[[ "$r" == stale ]] && ok "nameserver is a resolver the host dropped => stale" || bad "got '$r', expected stale"

sect "5. UNKNOWN is neither verdict"
r="$(state '[]' "" "$HOST_RC")"
[[ "$r" == unknown ]] && ok "unreadable container resolv.conf => unknown" || bad "got '$r', expected unknown"
r="$(state '[]' "$STALE_RC" "")"
[[ "$r" == unknown ]] && ok "unreadable HOST resolv.conf => unknown, not stale" || bad "got '$r', expected unknown"
r="$(state '[]' 'nameserver 127.0.0.11' "$HOST_RC")"
[[ "$r" == unknown ]] && ok "only the embedded resolver and no ExtServers => unknown" || bad "got '$r', expected unknown"

sect "6. IPv6 upstreams compare correctly"
r="$(state '[]' 'nameserver 127.0.0.11
# ExtServers: [host(2001:db8::53)]' "$HOST_RC")"
[[ "$r" == current ]] && ok "an IPv6 upstream the host still uses => current" || bad "got '$r', expected current"

sect "7. the WRAPPER: a stale container must be CRITICAL with a paired action"
mkrc() { printf '%s\n' "$2" > "$TMP/$1.rc"; printf '%s' "$TMP/$1.rc"; }
printf '%s\n' "$HOST_RC" > "$TMP/host.rc"
printf '%s\n' "$STALE_RC"   > "$TMP/c1.rc"
printf '%s\n' "$CURRENT_RC" > "$TMP/c2.rc"
cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  ps) printf 'c1\nc2\n' ;;
  inspect)
    id="\$2"; fmt="\$4"
    case "\$fmt" in
      *Name*)            printf '/%s\n' "\$id" ;;
      *HostConfig.Dns*)  printf '[]\n' ;;
      *ResolvConfPath*)  printf '%s/%s.rc\n' "$TMP" "\$id" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/docker"
drive() {
  PATH="$TMP:$PATH" DOMUM_HOST_RESOLV_CONF="$1" bash -c '
    source "$1" >/dev/null 2>&1 || true
    CHECKUP_CRITICAL=(); CHECKUP_ACTIONS=(); CHECKUP_WARNINGS=(); CHECKUP_ADVICE=(); CHECKUP_HEALTHY=()
    checkup_container_dns
    printf "CRIT:%s\n" "${CHECKUP_CRITICAL[*]-}"
    printf "ACT:%s\n"  "${CHECKUP_ACTIONS[*]-}"
    printf "WARN:%s\n" "${CHECKUP_WARNINGS[*]-}"
    printf "ADV:%s\n"  "${CHECKUP_ADVICE[*]-}"
    printf "OK:%s\n"   "${CHECKUP_HEALTHY[*]-}"
  ' _ "$CLI" 2>/dev/null
}
out="$(drive "$TMP/host.rc")"
grep -q '^CRIT:.*c1' <<< "$out" && ok "the stale container is named in a CRITICAL" || { bad "no critical naming c1"; sed -n '1,6p' <<< "$out" | sed 's/^/      /'; }
grep -q '^CRIT:.*c2' <<< "$out" && bad "the CURRENT container was wrongly named" || ok "the current container is not named"
grep -q '^ACT:.*recreat' <<< "$out" && ok "the critical carries an action naming a recreate" || bad "no paired action"
grep -q '^CRIT:.*RENEWED' <<< "$out" && ok "it states the renewal consequence, not just the symptom" || bad "the consequence is not stated"
grep -q '^CRIT:.*restart does NOT fix' <<< "$out" && ok "it says a restart will not help" || bad "missing the restart caveat"

sect "8. all-current must be HEALTHY and must NOT mail"
printf '%s\n' "$CURRENT_RC" > "$TMP/c1.rc"
out="$(drive "$TMP/host.rc")"
[[ "$(grep '^CRIT:' <<< "$out")" == "CRIT:" ]] && ok "no critical when every container is current" || bad "a critical fired on a healthy host: $(grep '^CRIT:' <<< "$out")"
grep -q '^OK:.*Container DNS upstreams match' <<< "$out" && ok "reports healthy with a count" || bad "no healthy line"

sect "9. an unreadable HOST resolv.conf is a WARNING with advice, never healthy"
out="$(drive "$TMP/does-not-exist.rc")"
grep -q '^WARN:.*not checked' <<< "$out" && ok "warns that it could not check" || bad "no warning"
grep -q '^ADV:' <<< "$out" && ok "the warning carries advice" || bad "no advice paired"
grep -q '^OK:.*match' <<< "$out" && bad "claimed healthy while unable to check" || ok "did not claim healthy"

sect "10. MUTATION: drop the explicit-dns guard -- section 3 must break"
MUT="$TMP/cli-mutant"; cp "$CLI" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """  [[ -z "${explicit_dns//[[:space:]\\[\\]]/}" ]] || { printf 'configured'; return 0; }\n"""
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, "", 1))
PY
if [[ $? -ne 0 ]]; then bad "10: the mutation did not apply"; else
  r="$(bash -c 'source "$1" >/dev/null 2>&1 || true; container_dns_upstream_state "$2" "$3" "$4"' \
        _ "$MUT" '["1.1.1.1","1.0.0.1"]' "$STALE_RC" "$HOST_RC" 2>/dev/null)"
  [[ "$r" == stale ]] && ok "without the guard a deliberately-configured container reads STALE -- the false alarm the guard prevents" \
                      || bad "mutant gave '$r'; the guard is not what prevents it"
fi

printf '\n%s checks, %s failures\n' "$n" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
