#!/usr/bin/env bash
# Isolation and connectivity tests for the Aurral experiment. Run by the
# operator AFTER the approved `firewall.sh apply` and `up -d`.
#
# Read-only: it inspects containers, opens test sockets and reads the live
# firewall rules. It changes nothing. Exit 0 only if every check passes.
#
# It asserts BOTH directions deliberately. A suite that only proved things are
# blocked would pass against an experiment that cannot reach anything at all,
# which is not the configuration being approved -- and one that only proved
# the internet works would pass against no isolation whatsoever.
set -uo pipefail

# ---------------------------------------------------------------------------
# Whether the container holds a GLOBAL IPv6 address, as its own function so a
# test can drive it with no container and no root: source this file with
# AURRAL_VALIDATE_LIB=1 and it defines its helpers and returns.
#
# It deliberately does NOT read `docker inspect -f '{{.GlobalIPv6Address}}'`.
# Measured on Docker 29.10.0: that field is typed `netip.Addr`, and the ZERO
# value's String() is the literal "invalid IP" -- a string that is not an
# address and cannot be told apart from one, so an ABSENT address read as a
# present one and this check reported a false failure. It is Docker-wide
# rather than anything about this container: production traefik renders
# "invalid IP", and navidrome, attached to two networks, renders
# "invalid IPinvalid IP". `{{json}}` encodes the same zero value as "".
#
# The kernel's own answer has no formatter in the way. In /proc/net/if_inet6
# field 1 is the address and field 4 is the SCOPE: 00 global, 20 link-local,
# 10 host (::1 on lo). So only scope 00 is reportable here -- a link-local
# address is not routable off-link and is not what `enable_ipv6: false` is
# about.
#
# Exit 2 means the file could not be read at all. A running container always
# has at least ::1 on lo, so empty output is a failed read rather than an
# absence of addresses -- and "could not check it" must not read as a pass.
container_global_ipv6() {
  local raw
  raw="$(docker exec "$1" cat /proc/net/if_inet6 2>/dev/null)" || return 2
  [[ -n "$raw" ]] || return 2
  awk '$4 == "00" { print $1 }' <<< "$raw"
  return 0
}

if [[ -n "${AURRAL_VALIDATE_LIB:-}" ]]; then return 0; fi

ENV_FILE="${1:-/srv/data/experiments/aurral/aurral.env}"
# shellcheck disable=SC1090
# A value containing spaces must be QUOTED in that file: it is sourced, so
# bash would read the second word as a command.
source "$ENV_FILE" || {
  echo "cannot source $ENV_FILE -- a value containing spaces must be quoted," >&2
  echo "e.g. AURRAL_BLOCK_CIDRS=\"<range> <range> <range> <range>\"" >&2
  exit 2
}
: "${AURRAL_LAN_IP:?}" "${AURRAL_TAILSCALE_IP:?}" "${AURRAL_PROXY_IP:?}" \
  "${AURRAL_LAN_ROUTER_IP:?}" "${AURRAL_DNS:?}" "${AURRAL_BLOCK_CIDRS:?}"
A=aurral-experiment
P=aurral-experiment-proxy
BRIDGE=aurral0
LAN_IP="$AURRAL_LAN_IP"
TS_IP="$AURRAL_TAILSCALE_IP"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; n=0
ok()  { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad() { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }

# TCP reachability from INSIDE Aurral, using the node its own image ships.
probe() {
  docker exec "$A" node -e '
    const s = require("net").connect({host: process.argv[1], port: +process.argv[2], timeout: 5000});
    s.on("connect", () => { console.log("OPEN"); s.destroy(); process.exit(0); });
    s.on("timeout", () => { console.log("BLOCKED timeout"); process.exit(1); });
    s.on("error", (e) => { console.log("BLOCKED " + e.code); process.exit(1); });
  ' "$1" "$2" 2>&1 || true
}
# A full DNS + TCP + TLS + HTTP exchange, which is what "the API works" means.
# A TCP handshake alone would pass against a captive portal.
https_status() {
  docker exec "$A" node -e '
    const r = require("https").request({host: process.argv[1], path: process.argv[2] || "/",
      method: "GET", timeout: 12000, headers: {"User-Agent": "aurral-experiment-validate"}},
      (res) => { console.log("HTTP " + res.statusCode); res.destroy(); process.exit(0); });
    r.on("timeout", () => { console.log("ERR timeout"); process.exit(1); });
    r.on("error", (e) => { console.log("ERR " + e.code); process.exit(1); });
    r.end();
  ' "$1" "${2:-/}" 2>&1 || true
}
resolve() {
  docker exec "$A" node -e '
    require("dns").resolve4(process.argv[1], (e, a) => {
      if (e) { console.log("NXDOMAIN " + e.code); process.exit(1); }
      console.log(a.join(",")); process.exit(0);
    });
  ' "$1" 2>&1 || true
}
must_block() {  # host port label
  local r; r="$(probe "$1" "$2")"
  case "$r" in BLOCKED*) ok "$3 blocked ($r)" ;; *) bad "$3 REACHABLE: $1:$2 ($r)" ;; esac
}
must_reach() {  # host port label
  local r; r="$(probe "$1" "$2")"
  case "$r" in OPEN) ok "$3 reachable" ;; *) bad "$3 NOT reachable: $1:$2 ($r)" ;; esac
}

echo "== 1. firewall policy is installed"
# Asked FIRST. Every "blocked" result below is meaningless if the policy is
# not actually loaded -- a container that happens to be down looks blocked too.
fw="$("$HERE/firewall.sh" show "$ENV_FILE" 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "firewall.sh show failed (run it as root); the blocked results below prove nothing"
else
  for want in "AURRAL-EGRESS" "AURRAL-HOST" "AURRAL-EGRESS-DROP"; do
    hit="$(grep -cF "$want" <<< "$fw")"
    [[ "$hit" -gt 0 ]] && ok "$want chain present" || bad "$want chain missing"
  done
  # A blocked packet must be LOGGED before it is dropped. The allowed-egress
  # LOG sits AFTER the drops, so before this chain existed a dropped packet was
  # recorded nowhere -- measured, four of the seven host probes below were
  # blocked in complete silence. The ORDER is asserted rather than assumed,
  # because a chain that dropped first would still read as "present".
  dropsec="$(sed -n '/^== AURRAL-EGRESS-DROP/,$p' <<< "$fw")"
  lgs="$(grep -n 'aurral-egress-blocked' <<< "$dropsec" || true)"
  dps="$(grep -n ' DROP ' <<< "$dropsec" || true)"
  lg="${lgs%%:*}"; dp="${dps%%:*}"
  if [[ -n "$lg" && -n "$dp" ]] && (( lg < dp )); then
    ok "AURRAL-EGRESS-DROP logs (line $lg) before it drops (line $dp)"
  else
    bad "AURRAL-EGRESS-DROP does not log before dropping (log=${lg:-none} drop=${dp:-none})"
  fi
  jumps="$(grep -c "$BRIDGE" <<< "$fw")"
  [[ "$jumps" -ge 4 ]] && ok "jump rules on $BRIDGE present ($jumps)" \
    || bad "expected 4 jump rules on $BRIDGE, found $jumps"
fi

echo "== 2. containers and hardening"
for c in "$A" "$P"; do
  st="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)"
  [[ "$st" == true ]] && ok "$c running" || bad "$c not running ($st)"
done
h="$(docker inspect -f '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Privileged}}|{{.HostConfig.CapDrop}}|{{.HostConfig.CapAdd}}|{{.HostConfig.RestartPolicy.Name}}' "$A")"
[[ "$h" == "61001:61001|true|false|[ALL]|[]|no" ]] && ok "aurral hardening: $h" || bad "aurral hardening: $h"
lim="$(docker inspect -f '{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.PidsLimit}}' "$A")"
[[ "$lim" == "1610612736|1500000000|512" ]] && ok "resource limits: $lim" || bad "resource limits: $lim"
img="$(docker inspect -f '{{.Config.Image}}' "$A")"
case "$img" in *@sha256:*) ok "image pinned by digest" ;; *) bad "image not pinned by digest: $img" ;; esac
mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' "$A")"
sock="$(grep -cF 'docker.sock' <<< "$mounts")"
[[ "$sock" -eq 0 ]] && ok "no docker socket" || bad "docker socket is mounted"
others="$(grep -v -E '^/srv/(data|media)/experiments/aurral/' <<< "$mounts" | grep -v '^$')"
[[ -z "$others" ]] && ok "every mount is under the experiment paths" || bad "unexpected mounts: $others"
r="$(docker exec "$A" cloudflared --version 2>&1)"
cf="$(grep -cF 'disabled in the domum' <<< "$r")"
[[ "$cf" -eq 1 ]] && ok "cloudflared neutralised (no public share-link tunnel)" || bad "cloudflared ran: $r"
r="$(docker exec "$A" id -u 2>&1)"; [[ "$r" == 61001 ]] && ok "runs as uid 61001" || bad "uid is $r"

echo "== 3. the approved connectivity WORKS"
r="$(resolve data.aurral.org)"
case "$r" in NXDOMAIN*) bad "DNS does not work: $r" ;; *) ok "DNS resolves via the configured resolver ($r)" ;; esac
must_reach "$AURRAL_DNS" 53 "the approved resolver"
# The fallback is reached only when the primary does not answer, so a run
# that never needed it would leave it unproven. Asserted explicitly, with
# compose's own default where the env file does not name one.
must_reach "${AURRAL_DNS_FALLBACK:-1.0.0.1}" 53 "the approved fallback resolver"
for hp in data.aurral.org musicbrainz.org coverartarchive.org api.listenbrainz.org www.youtube.com; do
  r="$(https_status "$hp")"
  case "$r" in HTTP\ *) ok "$hp answers ($r)" ;; *) bad "$hp unreachable ($r)" ;; esac
done
r="$(docker exec "$A" yt-dlp --version 2>&1)"
case "$r" in [0-9][0-9][0-9][0-9].*) ok "yt-dlp is available for testing ($r)" ;; *) bad "yt-dlp not usable: $r" ;; esac

echo "== 4. everything private is BLOCKED"
must_block "$LAN_IP" 443 "this host's Traefik via its LAN address"
must_block "$LAN_IP" 22 "this host's sshd"
must_block "$LAN_IP" 111 "this host's rpcbind"
must_block "$TS_IP" 443 "this host via its Tailscale address"
# Read from the host, not from inside the container: the image is not
# guaranteed to carry iproute2, and a missing `ip` would make this report OK
# without having looked at anything.
gwip="$(docker network inspect aurral-experiment_aurral-net \
          -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
if [[ -n "$gwip" ]]; then must_block "$gwip" 22 "this host via the bridge gateway"
else bad "could not read the aurral bridge gateway; the host-isolation check had no subject"; fi
must_block "$AURRAL_LAN_ROUTER_IP" 80 "the LAN router"
must_block 169.254.169.254 80 "link-local cloud metadata"
# Production containers, by their real addresses rather than by gateway alone.
for net in domum-proxy domum-internal; do
  peers="$(docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
            | sed 's#/[0-9]*$##' | grep -v '^$')"
  if [[ -z "$peers" ]]; then bad "could not read $net membership"; continue; fi
  while read -r pname pip; do
    [[ -n "$pip" ]] || continue
    must_block "$pip" 443 "production container $pname on $net"
  done <<< "$peers"
  gw="$(docker network inspect "$net" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
  [[ -n "$gw" ]] && must_block "$gw" 443 "$net gateway" || bad "could not read $net gateway"
done
if [[ -n "${AURRAL_LAN_PEER_IP:-}" ]]; then must_block "$AURRAL_LAN_PEER_IP" 22 "a LAN device"
else ok "no AURRAL_LAN_PEER_IP set (optional; set one to test a real LAN device)"; fi
if [[ -n "${AURRAL_TAILSCALE_PEER_IP:-}" ]]; then must_block "$AURRAL_TAILSCALE_PEER_IP" 22 "a tailnet device"
else ok "no AURRAL_TAILSCALE_PEER_IP set (optional; set one to test a real tailnet device)"; fi
# Production service names must not resolve: Docker's DNS is per network and
# Aurral shares none with them.
for name in immich_postgres immich_server traefik navidrome; do
  r="$(resolve "$name")"
  case "$r" in NXDOMAIN*) ok "DNS: $name does not resolve" ;; *) bad "DNS: $name resolves to $r" ;; esac
done
# IPv6: no GLOBAL address at all, so there is nothing to route anywhere.
# Asked twice, independently: the kernel inside the container's own netns, and
# Docker's metadata read as JSON rather than through Go's String().
v6_rc=0
v6="$(container_global_ipv6 "$A")" || v6_rc=$?
if (( v6_rc == 2 )); then
  bad "could not read /proc/net/if_inet6 in $A -- IPv6 state UNKNOWN, not proven absent"
elif [[ -n "$v6" ]]; then
  bad "container has a global IPv6 address: $v6"
else
  ok "no global IPv6 address in the container's netns"
fi
v6_meta="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{json .GlobalIPv6Address}}{{end}}' "$A" 2>/dev/null | tr -d '"')"
[[ -z "$v6_meta" ]] && ok "docker reports no global IPv6 on any attached network" \
                    || bad "docker reports a global IPv6: $v6_meta"

echo "== 5. the proxy is the only ingress"
# The proxy serves one static config and initiates nothing, so its egress is
# dropped too: the external surface is one container, not two. Asserted,
# because a tightening nobody tests is a comment.
# A POSITIVE CONTROL first, with the same tool: the proxy must be able to
# reach Aurral on this bridge. Without it, an absent or differently-flagged
# `nc` would report "blocked" for everything and the section would pass while
# having tested nothing -- which is worse than not having the check.
pnc() { docker exec "$P" sh -c "nc -w 4 '$1' '$2' </dev/null >/dev/null 2>&1; echo \$?" 2>/dev/null; }
ctl="$(pnc aurral 3001)"
if [[ "$ctl" != 0 ]]; then
  bad "the proxy's own probe tool does not work (rc=$ctl reaching aurral:3001); its egress is UNTESTED"
else
  ok "proxy probe control: it can reach aurral on this bridge"
  pr="$(pnc "$AURRAL_DNS" 53)"
  [[ "$pr" != 0 ]] && ok "the proxy cannot initiate egress (rc=$pr to the resolver Aurral can reach)" \
    || bad "the proxy reached off-bridge, which only Aurral should be able to do"
fi
r="$(probe "$AURRAL_PROXY_IP" 8080)"
[[ "$r" == OPEN ]] && ok "the proxy is reachable from aurral" || bad "proxy not reachable from aurral ($r)"
for ip in "$LAN_IP" "$TS_IP"; do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ip:3001/")"
  [[ "$c" =~ ^(200|302)$ ]] && ok "UI reachable on $ip:3001 ($c)" || bad "UI not reachable on $ip:3001 ($c)"
done
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:3001/)"
[[ "$c" == 000 ]] && ok "not bound on 127.0.0.1" || bad "bound on 127.0.0.1 ($c)"
# The Traefik router IS intentional as of d0270f3 -- Aurral is reachable at
# https://aurral.<domain> through the FILE provider. This used to assert a 404,
# which was correct only while no router existed; keeping it would have required
# the deliberate feature to look like a defect.
#
# What that assertion was really protecting is the ISOLATION, and that is what
# is asserted now. The router must NOT have been achieved by attaching Aurral's
# proxy to domum-proxy: AURRAL-EGRESS matches `-i aurral0`, so traffic leaving
# through a domum-proxy interface would never enter the chain and rule 3 would
# silently stop applying. The file provider routes to the LAN address instead,
# which joins no network.
c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve aurral.ladomum.com:443:127.0.0.1 https://aurral.ladomum.com/)"
case "$c" in
  200|302) ok "Traefik serves the aurral router ($c)" ;;
  404)     bad "Traefik has NO route for aurral (404) -- the file-provider router is missing" ;;
  *)       bad "Traefik answered $c for aurral" ;;
esac
pnets="$(docker inspect -f '{{range $n,$v := .NetworkSettings.Networks}}{{$n}} {{end}}' "$P" 2>/dev/null)"
case "$pnets" in
  *domum-proxy*) bad "the proxy is attached to domum-proxy -- this VOIDS the aurral0 egress policy: $pnets" ;;
  "")            bad "could not read the proxy's networks; the isolation claim is UNVERIFIED" ;;
  *)             ok "the router joins no production network (proxy nets: $pnets)" ;;
esac
pp="$(docker port "$P" 2>/dev/null)"
wild="$(grep -c -E '0\.0\.0\.0|\[::\]' <<< "$pp")"
[[ "$wild" -eq 0 ]] && ok "published only on LAN + Tailscale" || bad "published on a wildcard: $pp"
aport="$(docker port "$A" 2>/dev/null)"
[[ -z "$aport" ]] && ok "aurral publishes no port of its own" || bad "aurral publishes: $aport"
xff="$(docker exec "$P" grep -c 'X-Forwarded-For \$remote_addr' /etc/nginx/nginx.conf 2>&1)"
[[ "$xff" == 1 ]] && ok "the proxy overwrites X-Forwarded-For" || bad "proxy XFF handling: $xff"
tp="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$A" | sed -nE 's/^TRUST_PROXY=(.*)$/\1/p')"
[[ "$tp" == "$AURRAL_PROXY_IP" ]] && ok "TRUST_PROXY is the proxy only" || bad "TRUST_PROXY is '$tp'"

echo "== 6. the music stays yours"
lib=/srv/media/experiments/aurral/library
if [[ -d "$lib" ]]; then
  ok "library directory exists on the host: $lib"
  f="$(find "$lib" -type f -print -quit 2>/dev/null)"
  if [[ -n "$f" ]]; then
    head -c 1 "$f" >/dev/null 2>&1 && ok "a library file is readable outside the container" \
      || bad "a library file is NOT readable outside the container: $f"
  else
    ok "library is empty (nothing to read yet)"
  fi
else
  bad "library directory is missing: $lib"
fi

echo "== 7. production untouched"
# NOT a hardcoded count. `-eq 11` was an absolute assertion about production
# state, which CLAUDE.md forbids for exactly the reason it broke: #199 added
# docker-socket-proxy as a legitimate 12th managed container and a correct
# production state started reading as a failure. The intent here is "the Aurral
# experiment did not disturb production", and that is expressed by requiring
# every container of the production compose project to be RUNNING and none
# UNHEALTHY, with the count printed rather than asserted. A stopped production
# container still fails this; adding a service does not.
prod="$(docker ps -a --filter 'label=com.docker.compose.project=domum-media' \
        --format '{{.Names}} {{.State}}' | sort)"
nc="$(grep -c . <<< "$prod" || true)"
printf '  production containers (%s): %s\n' "$nc" "$(awk '{printf "%s ", $1}' <<< "$prod")"
if (( nc == 0 )); then
  bad "no container carries the production compose project label; this check had no subject"
else
  # Health is NOT re-checked here: the next check already asks it across every
  # container, which is broader. Two findings with identical text make the host
  # look twice as bad as it is.
  notrunning="$(awk '$2!="running"{printf "%s(%s) ", $1, $2}' <<< "$prod")"
  [[ -z "$notrunning" ]] && ok "every production container is running ($nc)" \
                         || bad "production containers NOT running: $notrunning"
fi
unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')"
[[ -z "$unhealthy" ]] && ok "no unhealthy production container" || bad "unhealthy: $unhealthy"

printf '\n%d of %d checks failed\n' "$fails" "$n"
if [[ "$fails" -eq 0 ]]; then
  cat <<'NOTE'

What Aurral actually contacted, since the policy was applied:
  sudo journalctl -k --since today | sed -nE 's/.*aurral-egress .*DST=([0-9.]+).*DPT=([0-9]+).*/\1:\2/p' | sort | uniq -c | sort -rn
Blocked attempts at this host, if any:
  sudo journalctl -k --since today | grep -c aurral-host-blocked
NOTE
fi
(( fails == 0 ))
