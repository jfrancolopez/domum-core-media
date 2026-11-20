#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
PROXY_COMPOSE="$REPO_ROOT/compose/proxy/docker-socket-proxy.yml"
TRAEFIK_COMPOSE="$REPO_ROOT/compose/proxy/traefik.yml"
TRAEFIK_CONFIG="$REPO_ROOT/compose/proxy/traefik/traefik-socket-proxy.yml"
# The file a Traefik container created BEFORE the proxy existed loads on its
# next start. The directory is bind-mounted live from the production checkout,
# so a fast-forward rewrites it under a running container; it must therefore
# keep working with the socket mount that container still has.
TRAEFIK_DEFAULT_CONFIG="$REPO_ROOT/compose/proxy/traefik/traefik.yml"
fail() { echo "FAIL: $*" >&2; exit 1; }

compose_files() {  # $1 = ENABLE_TRAEFIK
  (
    export DOMUM_DIR="$REPO_ROOT"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    export ENABLE_TRAEFIK="$1"
    export ENABLE_TAILSCALE=0 ENABLE_IMMICH=0 ENABLE_JELLYFIN=0 ENABLE_PLEX=0
    export ENABLE_NAVIDROME=0 ENABLE_CALIBRE_WEB=0 ENABLE_KAVITA=0
    export ENABLE_UPTIME_KUMA=0 ENABLE_RESTIC_REST_SERVER=0
    compose_files_for_enabled_services
  )
}

echo "== Traefik registration includes its socket proxy as one unit =="
enabled="$(compose_files 1)"
grep -Fq -- "$TRAEFIK_COMPOSE" <<< "$enabled" \
  || fail "Traefik fragment was not registered"
grep -Fq -- "$PROXY_COMPOSE" <<< "$enabled" \
  || fail "socket-proxy fragment was not registered with Traefik"
disabled="$(compose_files 0)"
if grep -Fq -- "$PROXY_COMPOSE" <<< "$disabled"; then
  fail "socket proxy was registered while Traefik was disabled"
fi
echo "  enabled together; absent when Traefik is disabled"

echo "== the proxy is a managed, stateless service =="
managed="$(
  export DOMUM_DIR="$REPO_ROOT"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  managed_image_specs
)"
grep -Fq 'docker-socket-proxy|ENABLE_TRAEFIK|DOCKER_SOCKET_PROXY_IMAGE|DOCKER_SOCKET_PROXY_AUTO_UPDATE|DOCKER_SOCKET_PROXY_AUTO_UPDATE_DELAY_DAYS|docker-socket-proxy' \
  <<< "$managed" || fail "proxy is missing from managed image specifications"
image_setting='DOCKER_SOCKET_PROXY_IMAGE=lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105'
grep -Fqx "$image_setting" "$REPO_ROOT/config/domum-media.conf.example" \
  || fail "example config is missing the pinned socket-proxy image"
grep -Fqx "$image_setting" "$REPO_ROOT/config/ci.env" \
  || fail "CI Compose environment is missing the pinned socket-proxy image"
model="$(
  export DOMUM_DIR="$REPO_ROOT" DOMUM_DATA_ROOT=/tmp/socket-proxy-smoke
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  docker() { return 0; }
  service_state_model docker-socket-proxy
)"
[[ "$model" == stateless* ]] || fail "proxy state model is not stateless: $model"
echo "  managed image registration and stateless model present"

echo "== socket and network access is constrained =="
grep -Fq 'container_name: docker-socket-proxy' "$PROXY_COMPOSE" \
  || fail "proxy container_name differs from its service key"
grep -Fq '/var/run/docker.sock:/var/run/docker.sock:ro' "$PROXY_COMPOSE" \
  || fail "proxy socket mount is not read-only"
for access in CONTAINERS EVENTS NETWORKS; do
  grep -Fq -- "- $access=1" "$PROXY_COMPOSE" \
    || fail "proxy does not enable $access reads"
done
for metadata in PING VERSION; do
  grep -Fq -- "- $metadata=1" "$PROXY_COMPOSE" \
    || fail "proxy does not enable required $metadata metadata reads"
done
enabled_sections="$(grep -E '^[[:space:]]+- [A-Z_]+=1$' "$PROXY_COMPOSE" \
  | sed -E 's/^[[:space:]]+- //' | sort)"
expected_sections="$(printf '%s\n' CONTAINERS=1 EVENTS=1 NETWORKS=1 PING=1 VERSION=1 | sort)"
[[ "$enabled_sections" == "$expected_sections" ]] \
  || fail "proxy enables unexpected Docker API sections"
grep -Fq -- '- POST=0' "$PROXY_COMPOSE" \
  || fail "proxy does not explicitly disable write requests"
if grep -Eq '^[[:space:]]+ports:' "$PROXY_COMPOSE"; then
  fail "proxy publishes a port"
fi
grep -Fq 'internal: true' "$REPO_ROOT/compose/base.yml" \
  || fail "the dedicated network is not internal"
grep -Fq -- '- traefik-docker' "$PROXY_COMPOSE" \
  || fail "socket proxy is not attached to the dedicated Docker API network"
grep -Fq -- '- traefik-docker' "$TRAEFIK_COMPOSE" \
  || fail "Traefik is not attached to the dedicated Docker API network"
grep -Fq 'tcp://docker-socket-proxy:2375' "$TRAEFIK_CONFIG" \
  || fail "Traefik does not use the proxy endpoint"
if grep -Fq '/var/run/docker.sock' "$TRAEFIK_COMPOSE"; then
  fail "Traefik still mounts the Docker socket"
fi
# A MOUNT, i.e. "/var/run/docker.sock:" -- the static config names the socket
# as an endpoint URL, which is not a mount and must not count as one.
socket_files="$(grep -RIl --include='*.yml' '/var/run/docker.sock:' "$REPO_ROOT/compose" \
  | sed "s#^$REPO_ROOT/##" | sort)"
[[ "$socket_files" == "compose/proxy/docker-socket-proxy.yml" ]] \
  || fail "the socket mount is not isolated to the proxy fragment"
echo "  read-only socket, GET-only API, internal network, no published port"

echo "== a restart of a PRE-proxy Traefik keeps working (2026-11-20) =="
# Production: the fast-forward to f647aa2 rewrote traefik.yml to point at the
# proxy while the running container (created 2026-08-17, socket mounted, no
# proxy anywhere) kept --configFile=/etc/traefik/traefik.yml. Its next start
# would have lost every label-defined route. The proxy endpoint therefore lives
# in its own file, selected by the compose definition, so the switch happens
# only when the container is recreated from that definition.
restart_safe() {  # $1 = static config a pre-proxy container would load
  grep -Fq 'endpoint: "unix:///var/run/docker.sock"' "$1" || return 1
  if grep -Fq 'docker-socket-proxy' "$1"; then return 1; fi
  return 0
}
restart_safe "$TRAEFIK_DEFAULT_CONFIG" \
  || fail "traefik.yml no longer works for a Traefik created before the proxy: it must keep the unix socket endpoint"
grep -Fq -- '- --configFile=/etc/traefik/traefik-socket-proxy.yml' "$TRAEFIK_COMPOSE" \
  || fail "the compose definition does not select the proxy static config"
if grep -Fq -- '--configFile=/etc/traefik/traefik.yml' "$TRAEFIK_COMPOSE"; then
  fail "the compose definition still loads traefik.yml, so the proxy file is never used"
fi
case "$TRAEFIK_CONFIG" in
  */dynamic/*) fail "the proxy static config sits in the WATCHED dynamic directory" ;;
esac
# Negative control: the shape that shipped in #199 must be rejected, or the
# check above could pass by matching nothing.
neg="$(mktemp)"; trap 'rm -f "$neg"' EXIT
sed 's#endpoint: "unix:///var/run/docker.sock"#endpoint: "tcp://docker-socket-proxy:2375"#' \
  "$TRAEFIK_DEFAULT_CONFIG" > "$neg"
if restart_safe "$neg"; then
  fail "negative control: a traefik.yml pointing at the proxy was accepted"
fi
echo "  traefik.yml keeps the socket; the proxy file is selected only by the compose definition"

echo "PASS: socket-proxy smoke"
