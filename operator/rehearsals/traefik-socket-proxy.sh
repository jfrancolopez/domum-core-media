#!/usr/bin/env bash
set -euo pipefail

# Disposable end-to-end rehearsal. It reuses only the running Traefik image ID;
# all created containers/networks are uniquely named and the proxy permits only
# Docker GET/HEAD API operations. No production network or volume is attached.
fail() { echo "FAIL: $*" >&2; exit 1; }
blocked() { echo "BLOCKED: $*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || blocked "docker is unavailable"
docker compose version >/dev/null 2>&1 || blocked "Docker Compose plugin is unavailable"
context_host="$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
[[ "$context_host" == unix://* ]] \
  || blocked "use a local Unix-socket Docker context; remote contexts are not rehearsed"

PROJECT="domum-socket-proxy-$(date +%s)-$$"
TRAEFIK_CONTAINER="${PROJECT}-traefik"
PROXY_CONTAINER="${PROJECT}-docker-socket-proxy"
WHOAMI_CONTAINER="${PROJECT}-whoami"
CONTROL_NETWORK="${PROJECT}_control"
APP_NETWORK="${PROJECT}_app"
PROXY_IMAGE="lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105"
WHOAMI_IMAGE="traefik/whoami:v1.11.0"
CURL_IMAGE="curlimages/curl:8.12.1"
ROUTE_HOST="whoami.${PROJECT}.test"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/traefik-socket-proxy.XXXXXX")"
COMPOSE_FILE="$TMP/compose.yml"
COMPOSE_STARTED=0
BASELINE_CONTAINERS=""

compose() { docker compose --project-name "$PROJECT" --file "$COMPOSE_FILE" "$@"; }

cleanup() {
  local result="$?" current remaining networks
  set +e
  if (( COMPOSE_STARTED )); then
    compose down --remove-orphans >/dev/null 2>&1 || result=1
  fi
  if [[ -n "$BASELINE_CONTAINERS" ]]; then
    current="$(docker ps -a --no-trunc --format '{{.ID}}|{{.Names}}' | sort)"
    [[ "$current" == "$BASELINE_CONTAINERS" ]] || {
      echo "FAIL: Docker container IDs/names changed during rehearsal" >&2
      result=1
    }
    remaining="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")"
    [[ -z "$remaining" ]] || {
      echo "FAIL: rehearsal containers remain after teardown" >&2
      result=1
    }
    networks="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")"
    [[ -z "$networks" ]] || {
      echo "FAIL: rehearsal networks remain after teardown" >&2
      result=1
    }
  fi
  rm -rf -- "$TMP"
  exit "$result"
}
trap cleanup EXIT

# Assert the generated names and project scope are clear before any image pull or
# container creation. Production Traefik is inspected read-only for its image ID.
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]] \
  || blocked "generated Compose project already has containers"
[[ -z "$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")" ]] \
  || blocked "generated Compose project already has networks"
if docker inspect "$TRAEFIK_CONTAINER" >/dev/null 2>&1 \
  || docker inspect "$PROXY_CONTAINER" >/dev/null 2>&1 \
  || docker inspect "$WHOAMI_CONTAINER" >/dev/null 2>&1; then
  blocked "a generated container name already exists"
fi
production_traefik="$(docker inspect traefik --format '{{.Id}} {{.Image}} {{.State.Running}}' 2>/dev/null)" \
  || blocked "no running production Traefik container is available to read its image ID"
read -r PRODUCTION_TRAEFIK_ID TRAEFIK_IMAGE_ID TRAEFIK_RUNNING <<< "$production_traefik"
[[ "$TRAEFIK_RUNNING" == true && -n "$TRAEFIK_IMAGE_ID" ]] \
  || blocked "the existing Traefik container is not running"
echo "  source Traefik container=$PRODUCTION_TRAEFIK_ID; pinned image=$TRAEFIK_IMAGE_ID"
BASELINE_CONTAINERS="$(docker ps -a --no-trunc --format '{{.ID}}|{{.Names}}' | sort)"
[[ -n "$BASELINE_CONTAINERS" ]] || blocked "could not capture the pre-rehearsal container inventory"

cat > "$COMPOSE_FILE" <<'YAML'
services:
  docker-socket-proxy:
    image: ${PROXY_IMAGE}
    container_name: ${PROXY_CONTAINER}
    restart: "no"
    environment:
      CONTAINERS: "1"
      EVENTS: "1"
      NETWORKS: "1"
      POST: "0"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - control
    read_only: true
    tmpfs:
      - /run

  traefik:
    image: ${TRAEFIK_IMAGE_ID}
    container_name: ${TRAEFIK_CONTAINER}
    restart: "no"
    command:
      - --api.insecure=true
      - --entrypoints.web.address=:80
      - --providers.docker=true
      - --providers.docker.endpoint=tcp://docker-socket-proxy:2375
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=${APP_NETWORK}
      - --providers.docker.constraints=Label(`com.docker.compose.project`,`${PROJECT}`)
      - --log.level=INFO
    networks:
      - control
      - app

  whoami:
    image: ${WHOAMI_IMAGE}
    container_name: ${WHOAMI_CONTAINER}
    restart: "no"
    networks:
      - app
    labels:
      - traefik.enable=true
      - traefik.docker.network=${APP_NETWORK}
      - traefik.http.routers.socket-proxy-smoke.rule=Host(`${ROUTE_HOST}`)
      - traefik.http.routers.socket-proxy-smoke.entrypoints=web
      - traefik.http.services.socket-proxy-smoke.loadbalancer.server.port=80

networks:
  control:
    name: ${CONTROL_NETWORK}
    internal: true
  app:
    name: ${APP_NETWORK}
    internal: true
YAML

export PROJECT TRAEFIK_CONTAINER PROXY_CONTAINER WHOAMI_CONTAINER
export PROXY_IMAGE WHOAMI_IMAGE TRAEFIK_IMAGE_ID CONTROL_NETWORK APP_NETWORK ROUTE_HOST

echo "== pin disposable Traefik to the running image ID and pull test images =="
docker pull "$PROXY_IMAGE" >/dev/null
docker pull "$WHOAMI_IMAGE" >/dev/null
docker pull "$CURL_IMAGE" >/dev/null

echo "== start only the disposable project =="
COMPOSE_STARTED=1
compose up -d --pull never

route_ok=0
for _attempt in $(seq 1 30); do
  route_response="$(docker run --rm --network "container:$TRAEFIK_CONTAINER" \
    "$CURL_IMAGE" \
    --silent --show-error --fail --max-time 3 \
    --write-out '\n__HTTP_STATUS__%{http_code}' \
    -H "Host: $ROUTE_HOST" http://127.0.0.1/ 2>/dev/null || true)"
  if [[ "$route_response" == *"Hostname:"* && "$route_response" == *"__HTTP_STATUS__200"* ]]; then
    route_ok=1
    break
  fi
  sleep 1
done
if [[ "$route_ok" -ne 1 ]]; then
  echo "== disposable Traefik diagnostics (route did not appear) ==" >&2
  compose logs --no-color traefik docker-socket-proxy >&2 || true
  docker run --rm --network "container:$TRAEFIK_CONTAINER" \
    "$CURL_IMAGE" \
    --silent --show-error --max-time 3 --write-out '\nHTTP %{http_code}\n' \
    http://127.0.0.1:8080/api/rawdata >&2 || true
  fail "Traefik did not route to the labeled whoami container"
fi
echo "  labeled route returned HTTP 200 through the disposable Traefik instance"

status="$(docker run --rm --network "container:$TRAEFIK_CONTAINER" \
  "$CURL_IMAGE" \
  --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --max-time 5 -X POST \
  "http://docker-socket-proxy:2375/containers/create?name=${PROJECT}-must-not-exist" \
  -H 'Content-Type: application/json' --data '{}')"
[[ "$status" == 403 ]] || fail "Docker create API returned HTTP $status, expected 403"
[[ -z "$(docker ps -aq --filter "name=^/${PROJECT}-must-not-exist$")" ]] \
  || fail "the denied create request nevertheless created a container"
echo "  container-create POST from Traefik's network namespace returned 403"

echo "PASS: Traefik socket-proxy rehearsal"
