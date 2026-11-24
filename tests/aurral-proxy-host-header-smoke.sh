#!/usr/bin/env bash
# The Aurral proxy must forward the Host header WITH its port.
#
# Aurral's isCrossSite() compares the Origin header's host against the Host
# header. nginx's $host STRIPS the port, so `Origin: http://<addr>:3001` never
# matched `Host: <addr>`, and every request from a browser that sends Origin
# WITHOUT Sec-Fetch-Site was classified cross-site. In guards.ts that skips both
# the pre-onboarding exemption and the "auth not required" early return, so
# onboarding answered 401 "Authentication required" and the file browser 403
# "Admin access is required to browse storage paths" -- two symptoms, one cause.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/experiments/aurral/nginx.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad()  { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }

# Comments are stripped for the "must NOT contain" assertions: this config's
# comments quote the broken form in order to document it, which is how the fix
# explains itself -- and would otherwise trip the very assertions below.
code="$(sed 's/#.*//' "$CONF")"

sect "1. Host carries the port"
if grep -qE '^\s*proxy_set_header\s+Host\s+\$http_host\s*;' <<< "$code"; then
  ok 'Host is forwarded as $http_host (port preserved)'
else
  bad "Host is not forwarded as \$http_host: $(grep -E 'proxy_set_header\s+Host' <<< "$code" || echo MISSING)"
fi
grep -qE '^\s*proxy_set_header\s+Host\s+\$host\s*;' <<< "$code" \
  && bad 'Host is still $host, which strips the port' \
  || ok 'the port-stripping $host form is gone'

sect "2. X-Forwarded-Host is set, with the port"
grep -qE '^\s*proxy_set_header\s+X-Forwarded-Host\s+\$http_host\s*;' <<< "$code" \
  && ok 'X-Forwarded-Host is $http_host -- the other host isCrossSite() accepts' \
  || bad 'X-Forwarded-Host is not set to $http_host'

sect "3. the existing security properties are PRESERVED"
# X-Forwarded-For must be OVERWRITTEN with the real peer, never appended: both
# of Aurral's mitigated advisories were a client-supplied XFF being believed.
grep -qE '^\s*proxy_set_header\s+X-Forwarded-For\s+\$remote_addr\s*;' <<< "$code" \
  && ok 'X-Forwarded-For is still overwritten with $remote_addr' \
  || bad 'X-Forwarded-For no longer overwrites with $remote_addr'
grep -qE '\$proxy_add_x_forwarded_for' <<< "$code" \
  && bad 'X-Forwarded-For now APPENDS, so a client-supplied value would be believed' \
  || ok 'no $proxy_add_x_forwarded_for (a client value can never be appended)'
grep -qE '^\s*proxy_pass\s+http://aurral:3001;' <<< "$code" \
  && ok 'still one upstream, aurral:3001' || bad 'the upstream changed'

sect "4. BEHAVIOUR: run this config and see what the upstream receives"
# Needs docker and a LOCAL nginx image -- what gets tested must be what is
# already here, so nothing is pulled. Skips cleanly otherwise.
# Resolved by image ID, not by "repo:tag": this image is pulled BY DIGEST, so
# its tag is <none> and "nginx:<none>" is an invalid reference. Measured -- the
# first version of this section failed with `docker: invalid reference format`.
img="$(docker images --format '{{.Repository}} {{.ID}}' 2>/dev/null | awk '$1=="nginx"{print $2; exit}' || true)"
if [[ -z "$img" ]] || ! docker info >/dev/null 2>&1; then
  printf '  SKIP  no local nginx image or no docker -- text assertions above still apply\n'
else
  NET=aurral-hosttest-net; UP=aurral; PX=aurral-hosttest-proxy
  # Isolation asserted BEFORE anything is created.
  clash=0
  for name in "$UP" "$PX"; do
    docker ps -aq --filter "name=^${name}$" > "$TMP/x" 2>/dev/null || true
    [[ -s "$TMP/x" ]] && { bad "4: container name '$name' is already taken -- refusing to touch it"; clash=1; }
  done
  # Capture first: `cmd | grep -q` under pipefail makes a MATCH read as no-match
  # (grep exits at the first hit, the producer takes SIGPIPE, the pipeline
  # reports 141) -- so an existing network would have read as free, which is the
  # direction that matters in an isolation check.
  nets="$(docker network ls --format '{{.Name}}' 2>/dev/null || true)"
  grep -qx "$NET" <<< "$nets" && { bad "4: network $NET exists"; clash=1; }
  if (( clash == 0 )); then
    cleanup4() { docker rm -f "$PX" "$UP" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
    trap 'cleanup4; rm -rf "$TMP"' EXIT
    # An upstream that echoes back the Host header it was given.
    cat > "$TMP/up.conf" <<'UPEOF'
events {}
http {
  server {
    listen 3001;
    location / { default_type text/plain; return 200 "HOST=$http_host\n"; }
  }
}
UPEOF
    docker network create "$NET" >/dev/null 2>&1
    docker run -d --name "$UP" --network "$NET" --network-alias aurral \
      -v "$TMP/up.conf:/etc/nginx/nginx.conf:ro" "$img" >/dev/null 2>&1
    docker run -d --name "$PX" --network "$NET" -p 127.0.0.1:18081:8080 \
      -v "$CONF:/etc/nginx/nginx.conf:ro" "$img" >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s --max-time 2 -o /dev/null "http://127.0.0.1:18081/" && break
      sleep 1
    done
    got="$(curl -s --max-time 5 -H 'Host: example.test:9999' "http://127.0.0.1:18081/" 2>/dev/null | tr -d '\r\n')"
    if [[ "$got" == "HOST=example.test:9999" ]]; then
      ok "the upstream received the port: $got"
    else
      bad "the upstream received [$got], expected HOST=example.test:9999"
      docker logs "$PX" 2>&1 | sed -n '1,6p' | sed 's/^/        /'
    fi
    cleanup4
    docker ps -aq --filter "name=^${PX}$" > "$TMP/t" 2>/dev/null || true
    [[ -s "$TMP/t" ]] && bad "4: teardown left $PX behind" || ok "4: teardown complete"
    trap 'rm -rf "$TMP"' EXIT
  fi
fi

printf '\n%s checks, %s failures\n' "$n" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
