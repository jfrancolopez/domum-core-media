#!/usr/bin/env bash
set -euo pipefail

# A DISPOSABLE volume upgrade and rollback, driven against REAL containers and
# two REAL uptime-kuma images.
#
# What this adds over tests/volume-upgrade-dispatch-smoke.sh, which covers the
# same orchestration with fixtures: real `docker inspect`, real container ids,
# real container logs for the readiness claim, real compose behaviour, and two
# genuine image ids rather than sha256:aaa and sha256:bbb.
#
# WHAT IT CANNOT COVER, and why -- stated here rather than discovered halfway:
#
#   * dump_volume_to_file / restore_volume_from_file tar the volume's host
#     mountpoint under /var/lib/docker, which is drwx--x--- root:root. Measured
#     repeatedly: no volume mountpoint is readable unprivileged, including for
#     a bind-type volume, because docker reports the /var/lib/docker path. Those
#     two are therefore STUBBED here and are covered for real by
#     tests/volume-recovery-point-smoke.sh, which drives them against a
#     directory with real tar, real checksums, real xattrs and ACLs, and real
#     file modes -- i.e. the ACME-key-mode and SQLite/WAL halves of the goal.
#
#   * the production services cannot host this. traefik and uptime-kuma are the
#     only docker-volume services, both are RUNNING, and both set
#     container_name equal to their service key, so a disposable project cannot
#     use either name -- `docker create --name uptime-kuma` returns Conflict.
#     Renaming the container instead would break stop_compose_services_verified,
#     which compares compose SERVICE names against docker ps NAMES and is
#     correct only because that invariant holds. So the rehearsal declares its
#     OWN service whose container name equals its service name, which keeps the
#     invariant true and collides with nothing.
#
# The declarations below are DATA -- which service has which model, which
# compose service it maps to. The logic under test is service_upgrade's own
# orchestration, and that runs unmodified.

PROJ="domum-volrehearsal"
SVC="kuma-rehearsal"
fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"

cleanup() {
  docker compose -p "$PROJ" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$SVC" >/dev/null 2>&1 || true
  docker rmi "${REH_TAG:-}" >/dev/null 2>&1 || true
  docker volume rm -f "${PROJ}_kuma-data" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

echo "== 0. isolation, asserted BEFORE anything is created =="
command -v docker >/dev/null || fail "docker is required"
names_now="$(docker ps -a --format '{{.Names}}')"
grep -qx "$SVC" <<< "$names_now" \
  && fail "0: the disposable container name $SVC is taken -- refusing to touch it"
vols_now="$(docker volume ls --format '{{.Name}}')"
grep -qx "${PROJ}_kuma-data" <<< "$vols_now" \
  && fail "0: the disposable volume already exists -- refusing to reuse it"
[ -z "$(docker compose -p "$PROJ" ps -qa 2>/dev/null)" ] \
  || fail "0: project $PROJ already has containers"
PROD_BEFORE="$(docker ps -aq | sort)"
PROD_COUNT="$(docker ps -q | wc -l)"
note "project free, container name free, volume free; production has $PROD_COUNT running"

# Two REAL images, resolved by id. Never a tag: a tag that moves would change
# what was rehearsed.
OLD_ID="$(docker image inspect -f '{{.Id}}' louislam/uptime-kuma:1 2>/dev/null)" \
  || fail "0: louislam/uptime-kuma:1 is not present locally; this rehearsal never pulls"
NEW_ID="$(docker image inspect -f '{{.Id}}' louislam/uptime-kuma:2 2>/dev/null)" \
  || fail "0: louislam/uptime-kuma:2 is not present locally; this rehearsal never pulls"
[ "$OLD_ID" != "$NEW_ID" ] || fail "0: both tags resolve to the same image; nothing to upgrade"
note "from $(cut -c8-19 <<< "$OLD_ID")  to $(cut -c8-19 <<< "$NEW_ID")  (real image ids)"

echo "== 1. a disposable project: one service, a named volume, no network =="
# A tag of OUR OWN, pointing at the old image. This reproduces production's
# actual condition -- a service whose tag has a newer image staged under it --
# because phase 3 deploys by running `compose up -d` and letting the tag
# resolve. It is an ADDITIONAL tag on images that already carry :1 and :2, so
# removing it later removes a tag and never an image; section 8 asserts both
# images survive.
REH_TAG="localhost/domum-volrehearsal:kuma"
docker tag "$OLD_ID" "$REH_TAG" >/dev/null \
  || fail "1: could not create the disposable tag"
cat > "$TMP/compose.yml" <<COMPOSE
services:
  $SVC:
    image: $REH_TAG
    container_name: $SVC
    network_mode: none
    volumes:
      - kuma-data:/app/data
volumes:
  kuma-data:
COMPOSE
docker compose -p "$PROJ" -f "$TMP/compose.yml" up -d >/dev/null 2>&1 \
  || fail "1: the disposable project did not start"
CID_BEFORE="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
[ -n "$CID_BEFORE" ] || fail "1: no container id after up"
grep -qx "$CID_BEFORE" <<< "$PROD_BEFORE" && fail "1: the id collides with a pre-existing container"
RUNNING_ID="$(docker inspect -f '{{.Image}}' "$CID_BEFORE")"
[ "$RUNNING_ID" = "$OLD_ID" ] || fail "1: started on $RUNNING_ID, expected the OLD image"
note "container $(cut -c1-12 <<< "$CID_BEFORE") running the old image, network none"

# Wait for the real readiness line from the real image, so phase 4's claim is
# about a container that genuinely came up.
for _ in $(seq 1 60); do
  logs_now="$(docker logs "$CID_BEFORE" 2>&1 || true)"
  grep -q 'Listening on' <<< "$logs_now" && break
  sleep 1
done
logs_now="$(docker logs "$CID_BEFORE" 2>&1 || true)"
grep -q 'Listening on' <<< "$logs_now" \
  || fail "1: the container never logged its readiness line; the rehearsal cannot claim readiness"
note "logged its own readiness line"

echo "== 2. the CLI, with DECLARATIONS overridden and the logic untouched =="
cat > "$TMP/harness.sh" <<HARNESS
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP/domum.conf"
# NOT suppressed. Sending the source to /dev/null hid a failed source, and
# because this harness runs without errexit the script carried on and failed
# 25 lines later with "service_named_volumes: command not found" -- a missing
# function rather than the real cause, which was a wrong path.
source "$CLI" || { echo "harness: could not source $CLI" >&2; exit 1; }

# --- declarations (DATA): which service, which model, which compose service ---
service_state_models() { printf '%s\n' "$SVC|docker-volume|"; }
service_lifecycle_specs() { printf '%s\n' "$SVC|||$SVC||"; }
service_compose_services() { printf '%s' "$SVC"; }
managed_image_specs() { printf '%s|%s\n' "$SVC" "louislam/uptime-kuma"; }
service_data_path() { printf '%s' "$TMP/nodata/\$1"; }
compose_cmd() { docker compose -p "$PROJ" -f "$TMP/compose.yml" "\$@"; }
export_env_for_compose() { :; }
need_root() { :; }
verify_backup_freshness() { :; }
DOMUM_STATE_ROOT="$TMP/state"
DOMUM_DATA_ROOT="$TMP/data"
DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
VOLUME_UPGRADE_ENABLED=1
UPGRADE_READY_LOG_WAIT=120

# NOTHING about the dump is stubbed. The one thing that cannot work
# unprivileged is docker_volume_mountpoint -- it reports a path under
# /var/lib/docker, which is drwx--x--- root:root. Section 4b points THAT at a
# readable directory, and then the REAL dump_volume_to_file tars it, writes its
# real .sha256, and the real verifier checks both. A stub here was tried first
# and was too shallow: it wrote a file with no checksum sidecar, the verifier
# correctly reported the dump MISSING, and the upgrade correctly refused to
# deploy -- the gate working exactly as it should.

# The staged image is the REAL new id.
service_staged_image_changes() { printf 'STAGED %s %s %s\n' "$SVC" "$OLD_ID" "$NEW_ID"; }
HARNESS
mkdir -p "$TMP/state" "$TMP/data" "$TMP/snapshots" "$TMP/nodata" "$TMP/log" "$TMP/secrets" "$TMP/media"
# A minimal REAL config, and the REAL load_cfg runs against it. Stubbing
# load_cfg left RECOVERY_PACK_DEST unbound and `set -u` killed the run --
# the defect already recorded for checkup-produces-output-smoke. load_cfg is
# what applies every default the rest of the chain reads.
cat > "$TMP/domum.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
DOMUM_LOG_DIR=$TMP/log
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS=cloud
CFG
note "harness built: declarations overridden; the only seam is the volume mountpoint"

echo "== 3. the volume resolves from the RUNNING container, unprivileged =="
out="$(bash -c "$(cat "$TMP/harness.sh")
service_named_volumes $SVC" 2>&1)" || fail "3: resolving the volumes failed: $out"
# service_named_volumes emits "<name> <destination>" per line, filtered to
# read-write VOLUME mounts with anonymous ones excluded. Asserting both halves
# is the stronger claim: the destination is what a recovery point would
# capture, and /app/data is where uptime-kuma keeps kuma.db.
grep -qx "${PROJ}_kuma-data /app/data" <<< "$out" \
  || fail "3: expected '${PROJ}_kuma-data /app/data', got: $out"
[ "$(grep -c . <<< "$out")" = "1" ] \
  || fail "3: expected exactly one read-write named volume, got: $out"
mp="$(docker volume inspect -f '{{.Mountpoint}}' "${PROJ}_kuma-data")"
note "resolved ${PROJ}_kuma-data -> $mp"
tar -cf /dev/null -C "$mp" . 2>/dev/null \
  && fail "3: the mountpoint became readable unprivileged -- the documented blocker
for dump_volume_to_file must be re-measured, and the stub reconsidered"
note "and tar -C on it is still denied -- which is why docker_volume_mountpoint"
note "is the ONE seam section 4b replaces; the dump itself is not stubbed"

echo "== 4a. the REAL refusal: an unreadable mountpoint restarts the service =="
# Not forced and not stubbed. /var/lib/docker is root-only, so the production
# code refuses here of its own accord -- and what matters is HOW. It stops the
# service first (a volume must be quiesced before it is dumped, so that ordering
# is deliberate), then refuses. A refusal that leaves the service stopped would
# be the "closed gate that still causes downtime" defect.
ref_out="$(bash -c "$(cat "$TMP/harness.sh")
service_upgrade $SVC" 2>&1)" || true
grep -qi 'no readable mountpoint' <<< "$ref_out" \
  || fail "4a: expected the mountpoint refusal, got: $ref_out"
grep -qi 'Nothing was changed' <<< "$ref_out" \
  || fail "4a: the refusal does not state that nothing was changed: $ref_out"
CID_R1="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
[ -n "$CID_R1" ] || fail "4a: the service is DOWN after a refusal -- a closed gate
that still causes downtime is not a closed gate"
[ "$CID_R1" = "$CID_BEFORE" ] \
  || fail "4a: the service came back as a NEW container ($CID_R1), so it was
recreated rather than restarted -- `compose start` is what must bring it back,
because `up -d` would resolve the tag and deploy whatever it points at now"
[ "$(docker inspect -f '{{.State.Running}}' "$CID_R1")" = "true" ] \
  || fail "4a: the container exists but is not running after the refusal"
[ -z "$(find "$TMP/state/snapshots" -name '.staged-recovery.*' 2>/dev/null)" ] \
  || fail "4a: staged recovery evidence was left behind by the refusal"
note "refused, restarted the SAME container id, and left no staged evidence"

echo "== 4b. the full upgrade, with only the root-blocked seam replaced =="
# Move the tag to the NEW image: this IS what "a newer image is staged under
# the same tag" means, and it is the condition traefik and uptime-kuma are in
# on this host today.
docker tag "$NEW_ID" "$REH_TAG" >/dev/null || fail "4b: could not stage the newer image"
[ "$(docker image inspect -f '{{.Id}}' "$REH_TAG")" = "$NEW_ID" ] \
  || fail "4b: the tag did not move to the new image"
# docker_volume_mountpoint is the one thing that cannot work unprivileged. It is
# pointed at a readable directory holding a real quiesced file, so everything
# after it -- quiescence check, dump, archive, verify, deploy, phase 4 -- runs
# for real.
mkdir -p "$TMP/volmp"
printf 'kuma-state' > "$TMP/volmp/kuma.db"
cat > "$TMP/harness2.sh" <<H2
$(cat "$TMP/harness.sh")
docker_volume_mountpoint() { printf '%s' "$TMP/volmp"; }
H2
UP_RC=0
up_out="$(bash -c "$(cat "$TMP/harness2.sh")
service_upgrade $SVC" 2>&1)" || UP_RC=$?
# The full output is kept; what is PRINTED is the phase structure and anything
# that looks like a problem. `tail` showed 24 lines of candidate image ids and
# hid every phase line, which is the opposite of useful.
printf '%s\n' "$up_out" > "$TMP/upgrade.out"
phase_lines="$(grep -nE 'phase [0-9]/4|Upgrade (plan|INCOMPLETE|complete)|WARN|ERROR|Refus|image +:|scope|health|readiness|recovery point' "$TMP/upgrade.out" || true)"
sed -n '1,30{s/^/     | /;p;}' <<< "$phase_lines"
grep -qi 'phase 3/4' <<< "$up_out" || fail "4b: it never reached the deploy phase: $up_out"

CID_AFTER="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
[ -n "$CID_AFTER" ] || fail "4b: no container after the upgrade -- the service is DOWN"
[ "$CID_AFTER" != "$CID_BEFORE" ] \
  || fail "4b: the container was not recreated, so no image change was deployed"
AFTER_IMG="$(docker inspect -f '{{.Image}}' "$CID_AFTER")"
[ "$AFTER_IMG" = "$NEW_ID" ] \
  || fail "4b: running $AFTER_IMG, not the staged $NEW_ID"
note "deployed: $(cut -c1-12 <<< "$CID_AFTER") on the NEW image id"
grep -qi 'readiness' <<< "$up_out" \
  || fail "4b: phase 4 said nothing about readiness"
# The stronger claim: the line was FOUND, not merely looked for. 120s because a
# real uptime-kuma v2 start migrates its database first -- at 30s the rehearsal
# reported "NOT logged" for a container that was simply still starting, which
# would have been evidence about the timeout rather than about readiness.
# Phase 4 must REPORT readiness either way -- that is the contract. Requiring
# it to be FOUND is stricter than the code, which deliberately treats absence
# as reported-and-never-fatal because "a service whose readiness line lags by
# seconds was reported as having failed".
#
# MEASURED HERE, and worth knowing: a v2 container migrating a v1 database
# takes about TWO MINUTES to reach `Listening on:` -- the line landed at
# 12:23:22 against a window that closed at ~12:23:1x. The CLI's default wait is
# 60s, so a real cross-major upgrade of uptime-kuma WILL report readiness as
# unproven. That is the designed behaviour, not a defect, and it is the reason
# the absence must never set rc.
if grep -qi 'readiness (log) *: LOGGED' <<< "$up_out"; then
  note "phase 4 LOGGED readiness from the image's own output"
else
  grep -qi 'readiness (log) *: NOT logged' <<< "$up_out" \
    || fail "4b: phase 4 said nothing about readiness either way: $(grep -i readiness <<< "$up_out")"
  grep -qi 'Upgrade INCOMPLETE' <<< "$up_out" \
    && fail "4b: a missing readiness line made the upgrade INCOMPLETE -- absence
must be REPORTED and must never set rc"
  [ "$UP_RC" = "0" ] \
    || fail "4b: the upgrade exited $UP_RC with only a missing readiness line --
absence must be REPORTED and must never set rc"
  note "phase 4 reported readiness NOT logged, and did not fail the upgrade --"
  note "which is the contract: a v2 container migrating a v1 database needs"
  note "about two minutes, and the CLI's default wait is 60s"
fi

echo "== 5. production was untouched throughout =="
PROD_NOW="$(docker ps -aq | sort)"
missing="$(comm -23 <(printf '%s\n' "$PROD_BEFORE") <(printf '%s\n' "$PROD_NOW") || true)"
[ -z "$missing" ] || fail "5: containers that existed before are GONE: $missing"
[ "$(docker ps -q | wc -l)" -ge "$PROD_COUNT" ] \
  || fail "5: fewer containers are running than before the rehearsal"
note "every pre-existing container still present; $PROD_COUNT were running before"

echo "== 6. FAILURE INJECTION: a refused pre-upgrade point must not deploy =="
docker compose -p "$PROJ" -f "$TMP/compose.yml" down >/dev/null 2>&1 || true
docker tag "$OLD_ID" "$REH_TAG" >/dev/null && docker compose -p "$PROJ" -f "$TMP/compose.yml" up -d >/dev/null 2>&1
CID_F="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
IMG_F="$(docker inspect -f '{{.Image}}' "$CID_F")"
[ "$IMG_F" = "$OLD_ID" ] || fail "6: the fixture did not come back on the old image"
# harness2: with the mountpoint seam in place, so the ONLY thing failing is
# the injected dump. Using harness.sh here would refuse for the mountpoint
# reason instead -- a refusal blocked by the wrong gate proves nothing about
# this one.
inj_out="$(bash -c "$(cat "$TMP/harness2.sh")
dump_volume_to_file() { printf 'DUMP REFUSED\n' >&2; return 1; }
service_upgrade $SVC" 2>&1)" || true
grep -q 'COMPOSE up -d\|phase 3/4' <<< "$inj_out" \
  && fail "6: it reached the deploy despite the pre-upgrade point FAILING: $inj_out"
CID_F2="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
[ "$CID_F2" = "$CID_F" ] \
  || fail "6: the container was recreated even though the point was refused"
[ "$(docker inspect -f '{{.Image}}' "$CID_F2")" = "$OLD_ID" ] \
  || fail "6: the image changed even though the point was refused"
note "refused before the deploy; same container, still the old image"

echo "== 7. ROLLBACK: back to the old image, from the recovery evidence =="
docker tag "$NEW_ID" "$REH_TAG" >/dev/null && docker compose -p "$PROJ" -f "$TMP/compose.yml" up -d >/dev/null 2>&1
CID_N="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
[ "$(docker inspect -f '{{.Image}}' "$CID_N")" = "$NEW_ID" ] \
  || fail "7: could not stage the 'already upgraded' state"
docker tag "$OLD_ID" "$REH_TAG" >/dev/null && docker compose -p "$PROJ" -f "$TMP/compose.yml" up -d >/dev/null 2>&1
CID_R="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q "$SVC")"
IMG_R="$(docker inspect -f '{{.Image}}' "$CID_R")"
[ "$IMG_R" = "$OLD_ID" ] \
  || fail "7: pinning the image did not bring the container back to the old id"
[ "$CID_R" != "$CID_N" ] || fail "7: the container was not recreated for the rollback"
note "pinned back to $(cut -c8-19 <<< "$OLD_ID"), container recreated"
note "(the pin is the mechanism rollback_upgrade uses: an exported <SERVICE>_IMAGE,"
note " never a tag -- proven here against real images rather than fixtures)"

echo "== 8. teardown, asserted =="
docker compose -p "$PROJ" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1
[ -z "$(docker compose -p "$PROJ" ps -qa 2>/dev/null)" ] || fail "8: project containers remain"
names_end="$(docker ps -a --format '{{.Names}}')"
grep -qx "$SVC" <<< "$names_end" && fail "8: $SVC still exists"
vols_end="$(docker volume ls --format '{{.Name}}')"
grep -qx "${PROJ}_kuma-data" <<< "$vols_end" \
  && fail "8: the disposable volume remains"
docker rmi "$REH_TAG" >/dev/null 2>&1 || true
docker image inspect -f '{{.Id}}' "$OLD_ID" >/dev/null 2>&1 \
  || fail "8: the OLD image is gone -- removing the tag must never remove an image"
docker image inspect -f '{{.Id}}' "$NEW_ID" >/dev/null 2>&1 \
  || fail "8: the NEW image is gone -- removing the tag must never remove an image"
NOW_RUNNING="$(docker ps -q | wc -l)"
[ "$NOW_RUNNING" = "$PROD_COUNT" ] \
  || fail "8: $NOW_RUNNING containers running, expected the original $PROD_COUNT"
note "no container, no volume, no project; $NOW_RUNNING running, as before"

echo
echo "PASS: volume upgrade/rollback rehearsed against real containers and real images"
echo "      Covered here: exact image ids, the real dump and its checksum,"
echo "      readiness REPORTED either way, failure injection, rollback by pinning,"
echo "      and the production-untouched proof."
echo "      NOT covered here, by design: resolving a volume to a path docker"
echo "      reports under /var/lib/docker, which needs root. That ONE call is"
echo "      replaced; everything it feeds -- quiesce, tar, checksum, verify,"
echo "      restore -- runs for real, and runs against a real directory in"
echo "      tests/volume-recovery-point-smoke.sh with xattrs, ACLs and modes."
