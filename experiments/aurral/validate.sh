#!/usr/bin/env bash
# Isolation tests for the Aurral experiment. Run by the operator AFTER the
# approved `up -d`. Read-only: it inspects containers and opens test sockets;
# it changes nothing. Exit 0 only if every check passes.
set -uo pipefail

ENV_FILE="${1:-/srv/data/experiments/aurral/aurral.env}"
# shellcheck disable=SC1090
source "$ENV_FILE" || { echo "cannot read $ENV_FILE" >&2; exit 2; }
: "${AURRAL_LAN_IP:?}" "${AURRAL_TAILSCALE_IP:?}" "${AURRAL_PROXY_IP:?}" "${AURRAL_LAN_ROUTER_IP:?}"
A=aurral-experiment
P=aurral-experiment-proxy
LAN_IP="$AURRAL_LAN_IP"
TS_IP="$AURRAL_TAILSCALE_IP"
fails=0; n=0
ok()  { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad() { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }

# Connect from INSIDE Aurral with its own node; prints OPEN or BLOCKED.
probe() {
  docker exec "$A" node -e '
    const s = require("net").connect({host: process.argv[1], port: +process.argv[2], timeout: 4000});
    s.on("connect", () => { console.log("OPEN"); process.exit(0); });
    s.on("timeout", () => { console.log("BLOCKED timeout"); process.exit(1); });
    s.on("error", (e) => { console.log("BLOCKED " + e.code); process.exit(1); });
  ' "$1" "$2" 2>&1 || true
}
must_block() {  # host port label
  local r; r="$(probe "$1" "$2")"
  case "$r" in BLOCKED*) ok "$3 blocked ($r)" ;; *) bad "$3 REACHABLE: $1:$2 ($r)" ;; esac
}

echo "== containers and hardening"
for c in "$A" "$P"; do
  st="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)"
  [[ "$st" == true ]] && ok "$c running" || bad "$c not running ($st)"
done
h="$(docker inspect -f '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Privileged}}|{{.HostConfig.CapDrop}}|{{.HostConfig.CapAdd}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.RestartPolicy.Name}}' "$A")"
[[ "$h" == "61001:61001|true|false|[ALL]|[]|"*"|no" ]] && ok "aurral hardening: $h" || bad "aurral hardening: $h"
mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' "$A")"
grep -q 'docker.sock' <<< "$mounts" && bad "docker socket is mounted" || ok "no docker socket"
others="$(grep -v -E '^/srv/(data|media)/experiments/aurral/' <<< "$mounts" | grep -v '^$' || true)"
[[ -z "$others" ]] && ok "every mount is under the experiment paths" || bad "unexpected mounts: $others"
r="$(docker exec "$A" yt-dlp --version 2>&1 || true)"
grep -q 'disabled in the domum' <<< "$r" && ok "yt-dlp neutralised" || bad "yt-dlp ran: $r"
r="$(docker exec "$A" cloudflared --version 2>&1 || true)"
grep -q 'disabled in the domum' <<< "$r" && ok "cloudflared neutralised" || bad "cloudflared ran: $r"
r="$(docker exec "$A" id -u 2>&1)"; [[ "$r" == 61001 ]] && ok "runs as uid 61001" || bad "uid is $r"

echo "== egress from Aurral (all must be BLOCKED)"
must_block one.one.one.one 443 "internet by name"
for ip in $(getent ahostsv4 one.one.one.one | awk '{print $1}' | sort -u); do
  must_block "$ip" 443 "internet by IP"
done
must_block "$LAN_IP" 443 "this host's Traefik via LAN IP"
must_block "$LAN_IP" 22 "this host's sshd"
must_block "$AURRAL_LAN_ROUTER_IP" 80 "LAN router"
for net in domum-proxy domum-internal; do
  gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$net" 2>/dev/null || true)"
  [[ -n "$gw" ]] && must_block "$gw" 443 "$net network gateway" || bad "could not read $net gateway"
done
must_block "$TS_IP" 443 "this host via Tailscale"
for name in immich_postgres immich_server traefik data.aurral.org musicbrainz.org www.youtube.com; do
  r="$(docker exec "$A" getent hosts "$name" 2>&1 || true)"
  [[ -z "$r" ]] && ok "DNS: $name does not resolve" || bad "DNS: $name resolves to $r"
done
r="$(probe "$AURRAL_PROXY_IP" 8080)"; [[ "$r" == OPEN ]] && ok "the proxy is the one reachable peer" || bad "proxy not reachable from aurral ($r)"

echo "== ingress"
for ip in "$LAN_IP" "$TS_IP"; do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ip:3001/" || true)"
  [[ "$c" =~ ^(200|302)$ ]] && ok "reachable on $ip:3001 ($c)" || bad "not reachable on $ip:3001 ($c)"
done
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:3001/ || true)"
[[ "$c" == 000 ]] && ok "not bound on 127.0.0.1" || bad "bound on 127.0.0.1 ($c)"
c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve aurral.ladomum.com:443:127.0.0.1 https://aurral.ladomum.com/ || true)"
[[ "$c" == 404 ]] && ok "no Traefik route (404)" || bad "Traefik answered $c for aurral"
pp="$(docker port "$P" 2>/dev/null)"
grep -q -E '0\.0\.0\.0|\[::\]' <<< "$pp" && bad "published on a wildcard: $pp" || ok "published only on LAN + Tailscale"
# X-Forwarded-For must be overwritten by the proxy, not appended.
r="$(docker exec "$P" grep -c 'X-Forwarded-For \$remote_addr' /etc/nginx/nginx.conf 2>&1 || true)"
[[ "$r" == 1 ]] && ok "proxy overwrites X-Forwarded-For" || bad "proxy XFF handling: $r"

echo "== production untouched"
running="$(docker ps --format '{{.Names}}' | grep -v -x -E "$A|$P" | sort | tr '\n' ' ')"
printf '  production containers: %s\n' "$running"
nc="$(wc -w <<< "$running")"; [[ "$nc" -eq 11 ]] && ok "11 production containers running" || bad "$nc production containers running"

printf '\n%d of %d checks failed\n' "$fails" "$n"
(( fails == 0 ))
