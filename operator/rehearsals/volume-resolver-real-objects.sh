#!/usr/bin/env bash
#
# The volume recovery-point chain has three steps:
#
#   1. service_named_volumes <service>    docker inspect of the container
#   2. docker_volume_mountpoint <volume>  docker volume inspect
#   3. dump_volume_to_file                tar -C <mountpoint>        <- ROOT
#
# `tests/volume-recovery-point-smoke.sh` drives 1-3 with real tar, real
# checksums, real xattrs and ACLs -- against a directory, with
# docker_volume_mountpoint as its ONE stubbed seam. That stub is what this
# rehearsal removes: steps 1 and 2 are exercised against REAL Docker objects,
# which needs no privilege.
#
# Step 3 genuinely does need root, and the reason is narrower than
# "/var/lib/docker needs root" -- measured 2026-11-11:
#
#     /var/lib/docker        drwx--x--- root:root
#
# The group is ROOT, not `docker`. Being in the `docker` group gives nothing
# here, so `other` (---) applies and `statx` is denied at
# /var/lib/docker/volumes itself. A bind-type volume does not help: docker
# reports the /var/lib/docker Mountpoint regardless of where the bytes live,
# and docker_volume_mountpoint returns the Mountpoint.
#
# What this rehearsal therefore proves, and what it does not:
#
#   PROVES    the two resolution steps against real containers and real named
#             volumes, including that docker_volume_mountpoint agrees with
#             docker volume inspect
#   PROVES    the production read-only case: both declared docker-volume
#             services resolve to exactly one named rw volume each
#   DOES NOT  prove the tar read, the dump, the restore, or any upgrade or
#             rollback. Those need root and are covered against a directory by
#             the smoke suite.
#
# It is NOT hermetic and CI does not run it: it needs a Docker daemon. It
# creates a disposable compose project, asserts the project is free first, and
# tears it down.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
PROJECT="domum-volres"
TMP="$(mktemp -d)"

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; exit 1; }
sect() { printf '\n== %s ==\n' "$*"; }

cleanup() {
  docker compose -p "$PROJECT" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || { echo "SKIP: no docker"; exit 0; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker daemon unreachable"; exit 0; }

# ---------------------------------------------------------------------------
sect "0. the disposable project and its names are FREE before anything is made"
# Asserted BEFORE any mutation, which is what makes the isolation claim mean
# something rather than being a description of intent.
existing="$(docker ps -a --format '{{.Names}}' | grep -E "^${PROJECT}[-_]" || true)"
[[ -z "$existing" ]] || bad "a container of project $PROJECT already exists: $existing"
existing="$(docker volume ls --format '{{.Name}}' | grep -E "^${PROJECT}[-_]" || true)"
[[ -z "$existing" ]] || bad "a volume of project $PROJECT already exists: $existing"
prod_before="$(docker ps -q | wc -l)"
ok "project $PROJECT is free; production has $prod_before running containers"

# The production container ids, so the teardown check can prove none was touched.
prod_ids_before="$(docker ps -q | sort)"

sect "1. a disposable container with a REAL named rw volume"
cat > "$TMP/compose.yml" <<'YML'
services:
  volres:
    image: busybox:latest
    command: ["sh", "-c", "sleep 600"]
    volumes:
      - volres-data:/app/data
      - volres-ro:/ro:ro
volumes:
  volres-data:
  volres-ro:
YML
docker compose -p "$PROJECT" -f "$TMP/compose.yml" up -d >/dev/null 2>&1 \
  || bad "could not start the disposable project"
cid="$(docker compose -p "$PROJECT" -f "$TMP/compose.yml" ps -q volres)"
[[ -n "$cid" ]] || bad "the disposable container did not start"
cname="$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')"
ok "container $cname ($(printf '%.12s' "$cid"))"

sect "2. service_named_volumes against a REAL docker inspect"
# Only the compose-service lookup is redirected; the inspect is real. The
# service name is deliberately NOT a production one, so nothing can collide.
out="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  service_compose_services() { printf '%s\n' "$cname"; }
  service_named_volumes volres
)"
[[ -n "$out" ]] || bad "no named volume was resolved from a real container"
n="$(grep -c . <<< "$out")"
printf '%s\n' "$out" | sed 's/^/        /'
grep -q "${PROJECT}_volres-data /app/data" <<< "$out" \
  || bad "the rw named volume was not resolved: $out"
# A READ-ONLY mount must be excluded: a recovery point cannot be built from a
# volume the service cannot write, and including it would dump bytes the
# service does not own.
grep -q 'volres-ro' <<< "$out" \
  && bad "a READ-ONLY volume was included; the filter is {{if and (eq .Type \"volume\") .RW}}"
[[ "$n" == 1 ]] || bad "expected exactly one rw named volume, got $n: $out"
ok "one rw named volume resolved, the ro mount excluded"

sect "3. docker_volume_mountpoint against a REAL volume -- the stub removed"
vol="${PROJECT}_volres-data"
mp="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  docker_volume_mountpoint "$vol"
)"
direct="$(docker volume inspect "$vol" --format '{{.Mountpoint}}')"
[[ -n "$mp" ]] || bad "the resolver returned nothing for a real volume"
[[ "$mp" == "$direct" ]] || bad "resolver disagrees with docker: $mp vs $direct"
ok "resolves to $mp and agrees with docker volume inspect"

sect "4. an ABSENT volume resolves to nothing, not to a plausible path"
mp_absent="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  docker_volume_mountpoint "${PROJECT}_does-not-exist" || true
)"
[[ -z "${mp_absent//[[:space:]]/}" ]] \
  || bad "an absent volume returned a path: $mp_absent -- a dump would then tar
the wrong directory or create one"
ok "absent -> empty"

sect "5. step 3 is where privilege starts, and the chain says exactly where"
chain_stop=""
p=""
for part in $(echo "$mp" | tr '/' ' '); do
  p="$p/$part"
  if ! stat -c '%A' "$p" >/dev/null 2>&1; then chain_stop="$p"; break; fi
done
if [[ -n "$chain_stop" ]]; then
  printf '        first unreadable component: %s\n' "$chain_stop"
  printf '        /var/lib/docker is %s\n' "$(stat -c '%A %U:%G' /var/lib/docker)"
  tar -cf /dev/null -C "$mp" . >/dev/null 2>&1 \
    && bad "tar -C succeeded on a volume mountpoint -- the root claim in this
script's header is then wrong and P3.4's blocker must be re-measured"
  ok "tar -C is denied, and the chain stops at $chain_stop (group is root, not docker)"
else
  echo "        NOTE: the whole chain is readable on THIS host."
  tar -cf /dev/null -C "$mp" . >/dev/null 2>&1 \
    && ok "tar -C SUCCEEDS here -- step 3 can be rehearsed on this host after all" \
    || ok "the chain is readable but tar still failed; inspect manually"
fi

sect "6. PRODUCTION, read-only: both declared docker-volume services resolve"
# Read-only inspection of production is permitted. This is the measurement the
# fixtures cannot make: that the real services resolve to exactly the volumes
# the design names.
prod_out="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  for svc in traefik uptime-kuma; do
    while read -r name dest; do
      [[ -n "$name" ]] || continue
      printf '%s %s %s\n' "$svc" "$name" "$dest"
    done <<< "$(service_named_volumes "$svc")"
  done
)"
printf '%s\n' "$prod_out" | sed 's/^/        /'
grep -q '^traefik .*traefik-letsencrypt /letsencrypt$' <<< "$prod_out" \
  || bad "traefik did not resolve its ACME volume: $prod_out"
grep -q '^uptime-kuma .*uptime-kuma-data /app/data$' <<< "$prod_out" \
  || bad "uptime-kuma did not resolve its data volume: $prod_out"
[[ "$(grep -c . <<< "$prod_out")" == 2 ]] \
  || bad "expected exactly two volumes across both services: $prod_out"
ok "traefik -> /letsencrypt (the ACME account key), uptime-kuma -> /app/data (kuma.db)"

sect "7. teardown, asserted rather than assumed"
docker compose -p "$PROJECT" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
left_c="$(docker ps -a --format '{{.Names}}' | grep -E "^${PROJECT}[-_]" || true)"
left_v="$(docker volume ls --format '{{.Name}}' | grep -E "^${PROJECT}[-_]" || true)"
[[ -z "$left_c" ]] || bad "a container of $PROJECT survived: $left_c"
[[ -z "$left_v" ]] || bad "a volume of $PROJECT survived: $left_v"
prod_after="$(docker ps -q | wc -l)"
[[ "$prod_before" == "$prod_after" ]] \
  || bad "production container count changed: $prod_before -> $prod_after"
[[ "$prod_ids_before" == "$(docker ps -q | sort)" ]] \
  || bad "a production container id changed -- something was recreated"
ok "nothing of $PROJECT remains; production still $prod_after containers, same ids"

printf '\nPROVEN: the two resolution steps, against real Docker objects.\n'
printf 'NOT PROVEN: the tar read, the dump, the restore, or any upgrade or\n'
printf 'rollback -- step 3 needs root. The smoke suite covers those against a\n'
printf 'directory; what this removes is the docker_volume_mountpoint stub.\n'
