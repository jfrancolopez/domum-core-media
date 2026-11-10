#!/usr/bin/env bash
set -euo pipefail

# Disposable startup rehearsal for the image families named by SEC-09. Images
# are pinned by ID from the running containers; no production mounts, networks,
# or named volumes are used. Single-service probes have no network at all, and
# the Immich fixture uses only an internal project network.
fail() { echo "FAIL: $*" >&2; exit 1; }
blocked() { echo "BLOCKED: $*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || blocked "docker is unavailable"
docker compose version >/dev/null 2>&1 || blocked "Docker Compose plugin is unavailable"
command -v python3 >/dev/null 2>&1 || blocked "python3 is unavailable"
context_host="$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
[[ "$context_host" == unix://* ]] \
  || blocked "use a local Unix-socket Docker context; remote contexts are not rehearsed"

image_id_from_running_container() {  # $1=production container
  local description image state
  description="$(docker inspect "$1" \
    --format '{{.Image}} {{.State.Status}}' 2>/dev/null)" \
    || blocked "source container '$1' is unavailable; no images were started"
  read -r image state <<< "$description"
  [[ "$state" == running && "$image" == sha256:* ]] \
    || blocked "source container '$1' is not running with a pinned image ID"
  printf '%s' "$image"
}

echo "== capture image IDs from running services (read-only) =="
CALIBRE_IMAGE="$(image_id_from_running_container calibre-web)"
NAVIDROME_IMAGE="$(image_id_from_running_container navidrome)"
KAVITA_IMAGE="$(image_id_from_running_container kavita)"
IMMICH_SERVER_IMAGE="$(image_id_from_running_container immich_server)"
IMMICH_POSTGRES_IMAGE="$(image_id_from_running_container immich_postgres)"
IMMICH_REDIS_IMAGE="$(image_id_from_running_container immich_redis)"
printf '  LinuxServer calibre-web=%s\n' "$CALIBRE_IMAGE"
printf '  Navidrome=%s\n' "$NAVIDROME_IMAGE"
printf '  Kavita=%s\n' "$KAVITA_IMAGE"
printf '  Immich server=%s; PostgreSQL=%s; Redis=%s\n' \
  "$IMMICH_SERVER_IMAGE" "$IMMICH_POSTGRES_IMAGE" "$IMMICH_REDIS_IMAGE"

TMP_BASE="${TMPDIR:-/tmp/opencode}"
[[ -d "$TMP_BASE" && -w "$TMP_BASE" ]] \
  || blocked "temporary base '$TMP_BASE' is missing or not writable"
PROJECT="domum-sec09-$(date +%s)-$$"
UID_VALUE="$(id -u)"
GID_VALUE="$(id -g)"
TMP_DIR=""
COMPOSE_FILE=""
COMPOSE_STARTED=0

container_inventory() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    docker inspect "$id" --format '{{.Id}} {{.Name}}'
  done < <(docker ps -aq) | sort
}

network_inventory() {
  docker network ls --no-trunc --format '{{.ID}} {{.Name}}' | sort
}

compose() {
  docker compose --project-name "$PROJECT" --file "$COMPOSE_FILE" "$@"
}

cleanup() {
  local status=$? cleanup_status=0 after_containers after_networks
  trap - EXIT
  set +e
  if [[ "$COMPOSE_STARTED" == 1 && -f "$COMPOSE_FILE" ]]; then
    compose down --volumes --remove-orphans >/dev/null 2>&1 || cleanup_status=1
  fi
  after_containers="$(container_inventory 2>/dev/null)" || cleanup_status=1
  after_networks="$(network_inventory 2>/dev/null)" || cleanup_status=1
  if [[ "$after_containers" != "$PRE_CONTAINERS" ]]; then
    echo "FAIL: container ID/name inventory changed after teardown" >&2
    diff -u <(printf '%s\n' "$PRE_CONTAINERS") <(printf '%s\n' "$after_containers") >&2 || true
    cleanup_status=1
  else
    echo "  teardown: existing container IDs/names unchanged"
  fi
  if [[ "$after_networks" != "$PRE_NETWORKS" ]]; then
    echo "FAIL: Docker network inventory changed after teardown" >&2
    diff -u <(printf '%s\n' "$PRE_NETWORKS") <(printf '%s\n' "$after_networks") >&2 || true
    cleanup_status=1
  else
    echo "  teardown: no rehearsal network remains"
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" || cleanup_status=1
  fi
  [[ ! -e "$TMP_DIR" ]] || cleanup_status=1
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}

[[ -z "$(docker ps -aq --filter "name=$PROJECT")" ]] \
  || blocked "disposable project name already exists"
[[ -z "$(docker network ls -q --filter "name=$PROJECT")" ]] \
  || blocked "disposable project network already exists"
PRE_CONTAINERS="$(container_inventory)"
PRE_NETWORKS="$(network_inventory)"
TMP_DIR="$(mktemp -d "$TMP_BASE/domum-sec09.XXXXXX")"
COMPOSE_FILE="$TMP_DIR/compose.yml"
trap cleanup EXIT

cat > "$COMPOSE_FILE" <<EOF
services:
  linuxserver-calibre:
    image: $CALIBRE_IMAGE
    container_name: ${PROJECT}-linuxserver-calibre
    network_mode: none
    security_opt: ["no-new-privileges:true"]
    environment:
      PUID: "$UID_VALUE"
      PGID: "$GID_VALUE"
      TZ: UTC
    tmpfs:
      - /config
      - /books

  navidrome:
    image: $NAVIDROME_IMAGE
    container_name: ${PROJECT}-navidrome
    network_mode: none
    security_opt: ["no-new-privileges:true"]
    user: "$UID_VALUE:$GID_VALUE"
    environment:
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /music
      ND_PORT: "4533"
      ND_LOGLEVEL: info
    tmpfs:
      - /data
      - /music

  kavita:
    image: $KAVITA_IMAGE
    container_name: ${PROJECT}-kavita
    network_mode: none
    security_opt: ["no-new-privileges:true"]
    tmpfs:
      - /kavita/config

  immich-redis:
    image: $IMMICH_REDIS_IMAGE
    container_name: ${PROJECT}-immich-redis
    security_opt: ["no-new-privileges:true"]
    networks:
      - immich-isolated
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping || exit 1"]
      interval: 3s
      timeout: 3s
      retries: 20

  immich-postgres:
    image: $IMMICH_POSTGRES_IMAGE
    container_name: ${PROJECT}-immich-postgres
    security_opt: ["no-new-privileges:true"]
    networks:
      - immich-isolated
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: sec09-disposable-only
      POSTGRES_DB: immich
      POSTGRES_INITDB_ARGS: --data-checksums
    command:
      - postgres
      - -c
      - shared_preload_libraries=vectors.so
      - -c
      - search_path="\$\$user", public, vectors
    tmpfs:
      - /var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-d", "immich"]
      interval: 3s
      timeout: 3s
      retries: 30
      start_period: 5s

  immich-server:
    image: $IMMICH_SERVER_IMAGE
    container_name: ${PROJECT}-immich-server
    security_opt: ["no-new-privileges:true"]
    networks:
      - immich-isolated
    depends_on:
      immich-redis:
        condition: service_healthy
      immich-postgres:
        condition: service_healthy
    environment:
      DB_HOSTNAME: immich-postgres
      DB_USERNAME: postgres
      DB_PASSWORD: sec09-disposable-only
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: immich-redis
      JWT_SECRET: sec09-disposable-jwt-secret-only
      UPLOAD_LOCATION: /usr/src/app/upload
    tmpfs:
      - /usr/src/app/upload

networks:
  immich-isolated:
    internal: true
EOF

echo "== assert the project is isolated before creating anything =="
[[ "$(container_inventory)" == "$PRE_CONTAINERS" ]] \
  || fail "container inventory changed before rehearsal startup"
[[ "$(network_inventory)" == "$PRE_NETWORKS" ]] \
  || fail "network inventory changed before rehearsal startup"

echo "== start the pinned images with no-new-privileges =="
COMPOSE_STARTED=1
compose up -d --pull never

assert_security_option() {  # $1=container name
  local security
  security="$(docker inspect "$1" --format '{{json .HostConfig.SecurityOpt}}')"
  [[ "$security" == *'no-new-privileges:true'* ]] \
    || fail "$1 did not receive no-new-privileges (got $security)"
  echo "  $1: no-new-privileges confirmed"
}

wait_for_log_pattern() {  # $1=container name, $2=readiness substring
  local container="$1" pattern="$2" logs state
  for _attempt in $(seq 1 90); do
    logs="$(docker logs "$container" 2>&1 || true)"
    if [[ "$logs" == *"$pattern"* ]]; then
      echo "  $container: readiness log observed: $pattern"
      return 0
    fi
    state="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || true)"
    [[ "$state" == running ]] || fail "$container exited before its readiness log"
    sleep 2
  done
  fail "$container did not emit its declared readiness log: $pattern"
}

wait_for_health() {  # $1=container name
  local container="$1" health state
  for _attempt in $(seq 1 90); do
    health="$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    [[ "$health" == healthy ]] && {
      echo "  $container: image healthcheck healthy"
      return 0
    }
    [[ "$health" != none ]] || fail "$container has no healthcheck to establish readiness"
    [[ "$health" != unhealthy ]] || fail "$container healthcheck reported unhealthy"
    state="$(docker inspect "$container" --format '{{.State.Status}}')"
    [[ "$state" == running ]] || fail "$container exited before becoming healthy"
    sleep 2
  done
  fail "$container did not become healthy (last health=$health)"
}

for service in linuxserver-calibre navidrome kavita immich-redis immich-postgres immich-server; do
  assert_security_option "${PROJECT}-${service}"
done

echo "== check the LinuxServer and Navidrome readiness lines =="
wait_for_log_pattern "${PROJECT}-linuxserver-calibre" 'port [tcp/*] succeeded!'
wait_for_log_pattern "${PROJECT}-navidrome" 'Navidrome server is ready!'

echo "== check Kavita and Immich healthchecks =="
wait_for_health "${PROJECT}-kavita"
wait_for_health "${PROJECT}-immich-redis"
wait_for_health "${PROJECT}-immich-postgres"
wait_for_health "${PROJECT}-immich-server"

echo "PASS: all rehearsed images started with no-new-privileges"
