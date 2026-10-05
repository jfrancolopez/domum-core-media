#!/usr/bin/env bash
set -uo pipefail

# Two fail-open paths, found by reading the merged implementation rather than the
# summary of it.
#
#   1. The rollback's restart fell back to `compose up -d` when `compose start`
#      failed. It warned that recreation resolves the image tag -- and then did
#      it. After a rollback has already restored an OLD database, that sequence is
#         old data -> mutable tag -> newer application -> automatic migration
#      which is the Kavita failure mode, reached during the operation meant to
#      undo it. A documented fail-open is the worst shape available: the warning
#      proves the author knew.
#
#   2. Recovery-point metadata failure warned and continued, and the command still
#      printed "Migration complete" and exited 0. If the application identity is
#      part of a recovery point, a migration that cannot record it has not made
#      one.
#
# Both now fail closed. A service that is down is visible and fixable in one
# command; a service silently running a different application than its recovery
# point pairs with is neither.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Part 1: the ROLLBACK must not reconcile after a failed start.
# ---------------------------------------------------------------------------
rollback_run() {  # $1 = scenario, $2 = extra stubs
  local dir="$TMP_DIR/$1" stubs="${2:-}"
  rm -rf "$dir"; mkdir -p "$dir/data/kavita" "$dir/snapshots/kavita-20260101-000000-tag" "$dir/state"
  printf 'restored-old-state\n' > "$dir/snapshots/kavita-20260101-000000-tag/app.db"
  printf 'current-state\n' > "$dir/data/kavita/app.db"
  cat > "$dir/harness.sh" <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$dir/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$dir/data"
DOMUM_SNAPSHOT_ROOT="$dir/snapshots"
DOMUM_STATE_ROOT="$dir/state"
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
service_data_path() { printf '%s' "$dir/data"/"\$1"; }
service_compose_services() { printf 'kavita'; }
stop_compose_services_verified() { return 0; }
btrfs() { command cp -a "$dir/snapshots/kavita-20260101-000000-tag" "\${!#}" 2>/dev/null; }
COMPOSE_LOG="$dir/compose.log"
: > "\$COMPOSE_LOG"
compose_cmd() { printf '%s\\n' "\$*" >> "\$COMPOSE_LOG"; return 0; }
$stubs
restore_snapshot_for_service kavita kavita-20260101-000000-tag
EOF
  bash "$dir/harness.sh" > "$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
  printf '%s' "$dir"
}

# Baseline: a working rollback uses `start` and never reconciles.
d="$(rollback_run ok)"
[ "$(cat "$d/rc")" = "0" ] || fail "1: a working rollback failed: $(cat "$d/out.txt")"
grep -q '^start kavita$' "$d/compose.log" || fail "1: the rollback did not use 'start': $(cat "$d/compose.log")"
grep -q 'up -d' "$d/compose.log" && fail "1: a working rollback reconciled: $(cat "$d/compose.log")"

# THE BUG: `start` fails. Nothing may reconcile.
d="$(rollback_run start_fails 'compose_cmd() {
  printf "%s\n" "$*" >> "$COMPOSE_LOG"
  [[ "${1:-}" == start ]] && return 1
  return 0
}')"
[ "$(cat "$d/rc")" != "0" ] || fail "1: a failed restart was reported as a successful rollback: $(cat "$d/out.txt")"
grep -q '^start kavita$' "$d/compose.log" || fail "1: 'start' was not attempted: $(cat "$d/compose.log")"
# The whole point: NO reconcile/recreate command of any kind.
grep -qE 'up( |$)|up -d|--force-recreate|create' "$d/compose.log" \
  && fail "1: THE FAIL-OPEN -- something reconciled after a failed start: $(cat "$d/compose.log")"
grep -q 'NOT recreating' "$d/out.txt" || fail "1: the refusal was not explained: $(cat "$d/out.txt")"
grep -q 'destroying the pairing' "$d/out.txt" || fail "1: the reason was not stated: $(cat "$d/out.txt")"
# The restored data and the state it replaced must both still be there.
grep -q 'restored-old-state' "$d/data/kavita/app.db" \
  || fail "1: the restored state was lost when the restart failed"
ls -d "$d"/data/kavita.rollback-* >/dev/null 2>&1 \
  || fail "1: the state the rollback replaced was not preserved"
grep -q 'restored state is in place' "$d/out.txt" || fail "1: the operator was not told where the data is"
grep -q 'recovery' "$d/out.txt" || fail "1: no recovery instructions: $(cat "$d/out.txt")"

# ---------------------------------------------------------------------------
# Part 2: recovery metadata is REQUIRED.
# ---------------------------------------------------------------------------
migrate_run() {  # $1 = scenario, $2 = extra stubs
  local dir="$TMP_DIR/$1" stubs="${2:-}"
  rm -rf "$dir"; mkdir -p "$dir/data/kavita/config" "$dir/snapshots" "$dir/state"
  printf 'original\n' > "$dir/data/kavita/config/app.conf"
  cat > "$dir/harness.sh" <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$dir/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$dir/data"
DOMUM_MEDIA_ROOT="$dir/media"
DOMUM_SNAPSHOT_ROOT="$dir/snapshots"
DOMUM_STATE_ROOT="$dir/state"
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
service_data_path() { printf '%s' "$dir/data"/"\$1"; }
service_compose_services() { printf 'kavita'; }
migrate_assert_same_btrfs() { :; }
wait_for_service_health() { return 0; }
tracked_service_container_id()     { printf 'cid-kavita'; }
tracked_service_container_id_any() { printf 'cid-kavita'; }
docker() {
  case "\$*" in
    *"{{.State.Status}}"*) printf 'running\\n' ;;
    *"{{.Image}}"*)        printf 'sha256:pinned\\n' ;;
    *"{{.Config.Image}}"*) printf 'example/kavita:latest\\n' ;;
    *"{{.Id}}"*)           printf 'sha256:pinned\\n' ;;
    *RepoDigests*)         printf 'example/kavita@sha256:manifestdigest\\n' ;;
    *) : ;;
  esac
}
SUBVOL_REG="$dir/.subvols"
path_is_subvolume() { grep -qxF "\$1" "\$SUBVOL_REG" 2>/dev/null; }
btrfs() {
  case "\$1" in
    subvolume) mkdir -p "\${!#}" && printf '%s\\n' "\${!#}" >> "\$SUBVOL_REG" ;;
    property)  printf 'ro=true\\n' ;;
  esac
}
mv() {
  local src="\${@: -2:1}" dst="\${@: -1}"
  command mv "\$@" || return 1
  grep -qxF "\$src" "\$SUBVOL_REG" 2>/dev/null && printf '%s\\n' "\$dst" >> "\$SUBVOL_REG"
  true
}
cp() { command cp -a "\${@: -2:1}" "\${@: -1}"; }
create_service_snapshot() {
  local name="kavita-20260101-000000-post-migration"
  command cp -a "$dir/data/kavita" "$dir/snapshots/\$name" 2>/dev/null || return 1
  printf '%s\\n' "$dir/snapshots/\$name" >> "\$SUBVOL_REG"
  printf '%s' "\$name"
}
COMPOSE_LOG="$dir/compose.log"
: > "\$COMPOSE_LOG"
compose_cmd() { printf '%s\\n' "\$*" >> "\$COMPOSE_LOG"; return 0; }
$stubs
storage_migrate_subvolume kavita
EOF
  bash "$dir/harness.sh" > "$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
  printf '%s' "$dir"
}

# Baseline: complete recovery point, exit 0, and the four claims are separate.
d="$(migrate_run complete)"
[ "$(cat "$d/rc")" = "0" ] || fail "2: a complete migration failed: $(cat "$d/out.txt")"
grep -q 'Migration COMPLETE' "$d/out.txt" || fail "2: completion not reported: $(cat "$d/out.txt")"
grep -q 'recovery point  : complete' "$d/out.txt" || fail "2: the recovery point was not called complete: $(cat "$d/out.txt")"
grep -q 'data migrated   : yes' "$d/out.txt" || fail "2: the data claim is missing: $(cat "$d/out.txt")"
meta="$(ls "$d"/state/snapshots/*.recovery 2>/dev/null | head -1)"
[ -n "$meta" ] || fail "2: no evidence file: $(ls -R "$d/state" 2>&1)"
grep -q "RECOVERY_POINT='kavita-20260101-000000-post-migration'" "$meta" \
  || fail "2: the evidence is not bound to the snapshot: $(cat "$meta")"
# Staged file must not be left behind.
ls "$d"/state/snapshots/.staged-recovery.* >/dev/null 2>&1 \
  && fail "2: a staged evidence file was left behind: $(ls -a "$d/state/snapshots")"

# Identity is not availability. The stub gives a RepoDigest that DIFFERS from the
# image id, so that is a real registry reference.
grep -q "CONTAINER_1_IMAGE_AVAILABILITY='identity,registry-digest'" "$meta" \
  || grep -q "CONTAINER_1_IMAGE_AVAILABILITY='identity,local,registry-digest'" "$meta" \
  || fail "2: availability was not classified: $(grep AVAILABILITY "$meta")"

# --- the metadata failure modes ------------------------------------------
# a. the directory cannot be created -> refuse BEFORE touching anything
d="$(migrate_run meta_dir_fails 'snapshot_metadata_dir() { printf "%s" "/proc/nonexistent-dir/snapshots"; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "2a: an unwritable evidence directory did not refuse: $(cat "$d/out.txt")"
grep -q 'could not record which application image' "$d/out.txt" \
  || fail "2a: refused for the wrong reason: $(cat "$d/out.txt")"
[ ! -e "$d/data/kavita.premigration" ] || fail "2a: refused AFTER the cutover; nothing should have moved"
grep -q 'migrate\[stop\]' "$d/out.txt" && fail "2a: the service was stopped before the refusal"

# b. staging succeeds, binding fails -> data migrated, NOT complete, nothing deleted
d="$(migrate_run bind_fails 'bind_recovery_point_metadata() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "2b: THE FAIL-OPEN -- metadata failure still reported success: $(cat "$d/out.txt")"
grep -q 'Migration INCOMPLETE' "$d/out.txt" || fail "2b: not reported as incomplete: $(cat "$d/out.txt")"
grep -q 'recovery point  : DATA ONLY' "$d/out.txt" || fail "2b: the recovery point was not downgraded: $(cat "$d/out.txt")"
grep -q 'Migration COMPLETE' "$d/out.txt" && fail "2b: it claimed completion anyway"
# No failure may delete the recovery point.
[ -d "$d/data/kavita.premigration" ] || fail "2b: .premigration was deleted"
[ -d "$d/snapshots/kavita-20260101-000000-post-migration" ] || fail "2b: the proof snapshot was deleted"
grep -q 'original' "$d/data/kavita.premigration/config/app.conf" || fail "2b: the preserved data is wrong"

# c. truncated evidence -> the verifier must reject it, not accept a short file
for trunc in "FORMAT='1'" "FORMAT='1'
SERVICE='kavita'"; do
  f="$TMP_DIR/trunc"; printf '%s\n' "$trunc" > "$f"
  out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
verify_recovery_point_metadata '$f' kavita some-point && echo ACCEPTED || echo REJECTED" 2>&1)"
  grep -q REJECTED <<< "$out" || fail "2c: truncated evidence was accepted: [$trunc] -> $out"
done

# d. a container claiming known identity with no image id
f="$TMP_DIR/noimg"
cat > "$f" <<'EV'
FORMAT='1'
SERVICE='kavita'
RECOVERY_POINT='p'
CAPTURED_AT='now'
DATA_PATH='/srv/data/kavita'
RUNTIME_STATE_BEFORE='running'
CONTAINER_1_SERVICE='kavita'
CONTAINER_1_IMAGE_IDENTITY='known'
CONTAINER_1_IMAGE_ID=''
EV
out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
verify_recovery_point_metadata '$f' kavita p && echo ACCEPTED || echo REJECTED" 2>&1)"
grep -q REJECTED <<< "$out" || fail "2d: known identity with no image id was accepted: $out"
grep -q 'claims known identity with no image id' <<< "$out" || fail "2d: not explained: $out"

# e. evidence naming the WRONG snapshot, or the wrong service
for pair in "p:kavita:otherpoint" "p:othersvc:p"; do
  point="${pair%%:*}"; rest="${pair#*:}"; svc="${rest%%:*}"; want="${rest##*:}"
  f="$TMP_DIR/wrong"
  sed "s/RECOVERY_POINT='p'/RECOVERY_POINT='$point'/; s/CONTAINER_1_IMAGE_ID=''/CONTAINER_1_IMAGE_ID='sha256:x'/" "$TMP_DIR/noimg" > "$f"
  out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
verify_recovery_point_metadata '$f' '$svc' '$want' && echo ACCEPTED || echo REJECTED" 2>&1)"
  grep -q REJECTED <<< "$out" || fail "2e: evidence for the wrong $( [[ "$svc" == othersvc ]] && echo service || echo snapshot) was accepted: $out"
done

# f. an UNKNOWN identity is recorded honestly rather than as known
f="$TMP_DIR/unknown"
sed "s/CONTAINER_1_IMAGE_IDENTITY='known'/CONTAINER_1_IMAGE_IDENTITY='unknown'/" "$TMP_DIR/noimg" > "$f"
out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
verify_recovery_point_metadata '$f' kavita p && echo ACCEPTED || echo REJECTED" 2>&1)"
grep -q ACCEPTED <<< "$out" \
  || fail "2f: honestly-unknown identity was rejected; that is the correct record for a service with no container: $out"

# g. the write succeeds but the final rename fails -> not complete, nothing lost
d="$(migrate_run rename_fails 'bind_recovery_point_metadata() {
  local staged="$1"
  printf "RECOVERY_POINT=%s\n" "$3" >> "$staged"
  warn "recovery evidence: could not move it into place"
  return 1
}')"
[ "$(cat "$d/rc")" != "0" ] || fail "2g: a failed rename still reported success: $(cat "$d/out.txt")"
grep -q 'Migration INCOMPLETE' "$d/out.txt" || fail "2g: not reported as incomplete"
[ -d "$d/data/kavita.premigration" ] || fail "2g: .premigration was deleted"
[ -d "$d/snapshots/kavita-20260101-000000-post-migration" ] || fail "2g: the proof snapshot was deleted"

# ---------------------------------------------------------------------------
# Part 3: the migration's restart must fail closed too, for the same reason.
# ---------------------------------------------------------------------------
d="$(migrate_run mig_start_fails 'compose_cmd() {
  printf "%s\n" "$*" >> "$COMPOSE_LOG"
  [[ "${1:-}" == start ]] && return 1
  return 0
}')"
grep -q '^start kavita$' "$d/compose.log" || fail "3: 'start' was not attempted: $(cat "$d/compose.log")"
grep -qE 'up( |$)|up -d|--force-recreate' "$d/compose.log" \
  && fail "3: THE FAIL-OPEN -- the migration reconciled after a failed start: $(cat "$d/compose.log")"
[ "$(cat "$d/rc")" != "0" ] || fail "3: a down service was reported as a successful migration: $(cat "$d/out.txt")"
grep -q 'service         : DOWN' "$d/out.txt" || fail "3: the service state was not reported: $(cat "$d/out.txt")"
grep -q 'NOT recreating' "$d/out.txt" || fail "3: the refusal was not explained: $(cat "$d/out.txt")"
[ -d "$d/data/kavita.premigration" ] || fail "3: .premigration was deleted"

# ---------------------------------------------------------------------------
# Part 4: image identity is not image recoverability.
# ---------------------------------------------------------------------------
avail() {
  bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
docker() { [[ \"\$1\" == image && \"\$2\" == inspect ]] && return ${3:-1}; return 1; }
recovery_image_availability '$1' '$2'"
}
[[ "$(avail '' '')" == "unknown" ]] || fail "4: no image id is not 'unknown': $(avail '' '')"
[[ "$(avail 'sha256:aaa' '')" == "identity" ]] \
  || fail "4: an id with no digest and no local object is not plain 'identity': $(avail 'sha256:aaa' '')"
# A RepoDigest equal to the image id is NOT an independent registry reference.
# Measured on this host: docker reports exactly that for kavita and jellyfin.
[[ "$(avail 'sha256:aaa' 'repo@sha256:aaa')" == "identity" ]] \
  || fail "4: a RepoDigest equal to the image id was counted as a registry reference: $(avail 'sha256:aaa' 'repo@sha256:aaa')"
[[ "$(avail 'sha256:aaa' 'repo@sha256:bbb')" == "identity,registry-digest" ]] \
  || fail "4: a real manifest digest was not counted: $(avail 'sha256:aaa' 'repo@sha256:bbb')"
[[ "$(avail 'sha256:aaa' '' 0)" == "identity,local" ]] \
  || fail "4: a locally present image was not recorded as local: $(avail 'sha256:aaa' '' 0)"

# ---------------------------------------------------------------------------
# Part 5: application readiness from the application's own log.
#
# navidrome has no Docker healthcheck and no host-published port, so "the
# container is running" was the whole claim. It does log, after opening and
# migrating its database and binding its listener:
#
#   ----> Navidrome server is ready! address="0.0.0.0:4533" startupTime=128.3ms
#
# Strictly stronger than a process check, and it needs no networking, credentials
# or production change.
# ---------------------------------------------------------------------------
ready() {  # $1 = service, $2 = what `docker logs -t` returns, $3 = restart boundary
  cat > "$TMP_DIR/ready.sh" <<PROBE
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
compose_cmd() { :; }
service_compose_services() { printf '%s' "\$1"; }
tracked_service_container_id_any() { printf 'cid-x'; }
docker() { [[ "\$1" == logs ]] && printf '%s\n' '$2'; return 0; }
# Guarded: sourcing bin/domum-media re-enables `set -e` in this shell, so a
# non-zero return would kill the probe before it could report the code.
rc=0
service_logged_ready_since '$1' '${3:-2026-01-01T00:00:00}' || rc=\$?
printf 'RC=%s' "\$rc"
PROBE
  bash "$TMP_DIR/ready.sh" 2>/dev/null
}

# The real line as `docker logs -t` emits it, with its RFC3339Nano UTC prefix.
FRESH='2026-09-29T17:56:58.386777720Z time="2026-09-29T17:56:58Z" level=info msg="----> Navidrome server is ready!" address="0.0.0.0:4533"'
STALE='2026-09-21T10:20:05.594409942Z time="2026-09-21T10:20:05Z" level=info msg="----> Navidrome server is ready!" address="0.0.0.0:4533"'
[[ "$(ready navidrome "$FRESH" 2026-09-29T17:56:58)" == "RC=0" ]] \
  || fail "5: the real navidrome readiness line was not recognised"
[[ "$(ready navidrome 'time=... msg="Closing Database"')" == "RC=1" ]] \
  || fail "5: absence of readiness was not reported"

# THE FALSE POSITIVE. A readiness line from a PREVIOUS start must not satisfy the
# check. `docker logs --since` alone cannot exclude it: a bare timestamp is parsed
# in the CALLER'S timezone, so east of UTC the window opens hours early and an old
# line lands inside it. Measured on this host against a line at 17:56:58Z:
#
#   TZ=UTC               --since 2026-09-29T17:56:00   -> 1 match
#   TZ=America/New_York  --since 2026-09-29T17:56:00   -> 0 matches
#   any TZ               --since 2026-09-29T17:56:00Z  -> 1 match
#
# West of UTC that aborts a correct migration; east of UTC it accepts a stale
# line. So the line's OWN timestamp is compared, which does not depend on it.
[[ "$(ready navidrome "$STALE" 2026-09-29T17:56:58)" == "RC=1" ]] \
  || fail "5: a readiness line from a PREVIOUS start satisfied the check"
[[ "$(ready navidrome "$STALE
$FRESH" 2026-09-29T17:56:58)" == "RC=0" ]] \
  || fail "5: a fresh readiness line was missed when an older one was also present"
# Same second, nanosecond stamp: '.' sorts before 'Z', so comparing against a
# boundary ending in 'Z' would read this as earlier and reject it.
[[ "$(ready navidrome '2026-09-29T17:56:58.386777720Z msg="----> Navidrome server is ready!"' 2026-09-29T17:56:58)" == "RC=0" ]] \
  || fail "5: a readiness line in the same second as the restart was rejected"
[[ "$(ready navidrome '2026-09-29T17:56:57.999999999Z msg="----> Navidrome server is ready!"' 2026-09-29T17:56:58)" == "RC=1" ]] \
  || fail "5: a readiness line from BEFORE the restart was accepted"

# THE MATRIX. The comparison is on the line's own UTC stamp, so the answer must
# not change with the host's timezone, and must be right across midnight and for
# both whole and fractional seconds.
for tz in UTC America/New_York Asia/Tokyo; do
  # fresh: accepted in every zone
  [[ "$(TZ="$tz" ready navidrome "$FRESH" 2026-09-29T17:56:58)" == "RC=0" ]] \
    || fail "5: TZ=$tz rejected a fresh readiness line"
  # stale: refused in every zone -- east of UTC is where a --since-only check
  # would have let it through
  [[ "$(TZ="$tz" ready navidrome "$STALE" 2026-09-29T17:56:58)" == "RC=1" ]] \
    || fail "5: TZ=$tz accepted a readiness line from a PREVIOUS start"
done

# Across midnight: a restart at 23:59:59Z and a readiness line at 00:00:01Z the
# next day. Lexicographic comparison of the full stamps handles the date rollover;
# comparing times alone would read 00:00:01 as earlier than 23:59:59.
MIDNIGHT_AFTER='2026-09-30T00:00:01.100000000Z msg="----> Navidrome server is ready!"'
MIDNIGHT_BEFORE='2026-09-29T23:59:58.900000000Z msg="----> Navidrome server is ready!"'
[[ "$(ready navidrome "$MIDNIGHT_AFTER" 2026-09-29T23:59:59)" == "RC=0" ]] \
  || fail "5: a readiness line just after midnight was rejected for a restart just before it"
[[ "$(ready navidrome "$MIDNIGHT_BEFORE" 2026-09-29T23:59:59)" == "RC=1" ]] \
  || fail "5: a readiness line BEFORE the restart was accepted across a midnight boundary"
# ...and the same, one whole day earlier, which a time-only comparison would accept.
[[ "$(ready navidrome '2026-09-28T23:59:59.999999999Z msg="----> Navidrome server is ready!"' 2026-09-29T23:59:59)" == "RC=1" ]] \
  || fail "5: a readiness line from the previous DAY at the same clock time was accepted"

# Whole seconds, no fractional part -- docker emits these for some runtimes.
[[ "$(ready navidrome '2026-09-29T17:56:58Z msg="----> Navidrome server is ready!"' 2026-09-29T17:56:58)" == "RC=0" ]] \
  || fail "5: a whole-second stamp equal to the restart was rejected"
[[ "$(ready navidrome '2026-09-29T17:56:57Z msg="----> Navidrome server is ready!"' 2026-09-29T17:56:58)" == "RC=1" ]] \
  || fail "5: a whole-second stamp one second early was accepted"

# Plex's pattern, from the line this host actually emits. Pinned for the same
# reason as navidrome's: an upstream wording change must break CI, not a migration.
PLEX_FRESH='2026-10-05T10:10:26.559725948Z Connection to localhost (::1) 32400 port [tcp/*] succeeded!'
[[ "$(ready plex "$PLEX_FRESH" 2026-10-05T10:10:24)" == "RC=0" ]] \
  || fail "5: plex's real readiness line was not recognised"
[[ "$(ready plex '2026-10-05T10:10:25.511545597Z Starting Plex Media Server. . .' 2026-10-05T10:10:24)" == "RC=1" ]] \
  || fail "5: 'Starting Plex Media Server' was treated as readiness; it precedes the listener"
# The benign error the image tells you to ignore must not be mistaken either way.
[[ "$(ready plex '2026-10-05T10:10:38.328027003Z Critical: libusb_init failed' 2026-10-05T10:10:24)" == "RC=1" ]] \
  || fail "5: a benign post-readiness error line was read as readiness"
plexpat="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
service_ready_log_pattern plex")"
[[ "$plexpat" == "port [tcp/*] succeeded!" ]] || fail "5: the plex readiness pattern changed to [$plexpat]"
# Services with no known pattern must still say so rather than claim readiness.
for svc in jellyfin calibre-web immich traefik; do
  [[ "$(ready "$svc" 'anything')" == "RC=2" ]] \
    || fail "5: $svc has no readiness pattern but did not report 'nothing to look for'"
done

# The --since value handed to docker must carry an explicit zone.
fnsrc="$(awk '/^service_logged_ready_since\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q -- '--since "${boundary}Z"' <<< "$fnsrc" \
  || fail "5: --since is passed without a timezone, which docker reads in local time"
grep -q -- 'docker logs -t' <<< "$fnsrc" \
  || fail "5: readiness does not request timestamps, so it cannot check the line's own time"
# A service with no known pattern must say so (rc=2), never claim readiness.
[[ "$(ready jellyfin 'anything at all')" == "RC=2" ]] \
  || fail "5: a service with no readiness pattern did not report 'nothing to look for': $(ready jellyfin x)"
# The pattern itself is pinned: an upstream wording change must break a test, not
# a migration silently.
pat="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
service_ready_log_pattern navidrome")"
[[ "$pat" == "Navidrome server is ready!" ]] || fail "5: the navidrome readiness pattern changed to [$pat]"

# And it must not be a `cmd | grep -q` pipeline: under pipefail that inverts,
# so a match would read as no-match. CLAUDE.md section 8.
fn="$(awk '/^service_logged_ready_since\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -qE 'docker logs[^|]*\| *grep' <<< "$fn" \
  && fail "5: readiness uses 'docker logs | grep', which pipefail inverts on a match"
grep -q 'logs="\$(docker logs' <<< "$fn" \
  || fail "5: readiness does not capture the logs before matching"

# ---------------------------------------------------------------------------
# Part 6: `storage verify-recovery` -- reading a recovery point without grepping
# the CLI's prose.
#
# The migration wrapper used to assert on the literal string
# "recovery point  : verified". That wording changed when the summary was split
# into four claims, and the wrapper aborted a migration that had completed
# perfectly -- the same shape as the stale topology invariant that aborted a
# correct deployment. Prose is not a contract; a subcommand is.
# ---------------------------------------------------------------------------
vr() {  # $1 = state root, $2 = service, $3 = point
  bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
DOMUM_STATE_ROOT='$1'
need_root() { :; }
load_cfg() { :; }
docker() { return 1; }
rc=0
storage_verify_recovery '$2' '$3' || rc=\$?
printf 'RC=%s' \"\$rc\"" 2>&1
}

SR="$TMP_DIR/state6"; mkdir -p "$SR/snapshots"
cat > "$SR/snapshots/navidrome-20260929-175657-post-migration.recovery" <<'EV'
FORMAT='1'
SERVICE='navidrome'
RECOVERY_POINT='navidrome-20260929-175657-post-migration'
CAPTURED_AT='2026-09-29T13:56:57-04:00'
DATA_PATH='/srv/data/navidrome'
RUNTIME_STATE_BEFORE='running'
CONTAINER_1_SERVICE='navidrome'
CONTAINER_1_IMAGE_IDENTITY='known'
CONTAINER_1_IMAGE_AVAILABILITY='identity,local'
CONTAINER_1_ID='ef44ae505efc'
CONTAINER_1_IMAGE_ID='sha256:9012939114fb'
CONTAINER_1_IMAGE_REF='deluan/navidrome:latest'
CONTAINER_1_IMAGE_LABEL_VERSION='0.63.2'
EV
out="$(vr "$SR" navidrome navidrome-20260929-175657-post-migration)"
grep -q 'RC=0' <<< "$out" || fail "6: valid evidence was rejected: $out"
grep -q 'identity,local' <<< "$out" || fail "6: availability was not shown: $out"
grep -q 'no immutable reference for later' <<< "$out" \
  || fail "6: 'identity,local' was not explained as recoverable-today-only: $out"
grep -q 'MUTABLE' <<< "$out" || fail "6: the image ref was not labelled mutable: $out"
grep -q 'present now   : NO' <<< "$out" \
  || fail "6: an image absent from the host was not reported as absent now: $out"

# Missing evidence is a failure, and says what that costs.
out="$(vr "$SR" navidrome no-such-point)"
grep -q 'RC=1' <<< "$out" || fail "6: a missing recovery point did not fail: $out"
grep -q 'DATA recovery point only' <<< "$out" || fail "6: the consequence was not stated: $out"

# Evidence for a different service must not satisfy a query for this one.
out="$(vr "$SR" kavita navidrome-20260929-175657-post-migration)"
grep -q 'RC=1' <<< "$out" || fail "6: evidence for another service was accepted: $out"

# ---------------------------------------------------------------------------
# Part 7: the result summary is an operator contract.
#
# Not because anything greps it now -- the wrapper was moved onto the exit status
# and the evidence file precisely so it would not -- but because these six lines
# are what a person reads at 2am, and a rewording should be a decision rather than
# a side effect.
# ---------------------------------------------------------------------------
fn="$(awk '/^storage_migrate_subvolume\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
for line in \
  'Migration result for' \
  'data migrated   :' \
  'proof snapshot  :' \
  'recovery point  :' \
  'service         :' \
  'Migration COMPLETE for' \
  'Migration INCOMPLETE for'; do
  grep -qF -- "$line" <<< "$fn" || fail "7: the result summary no longer prints '$line'"
done
# And the two outcomes must be mutually exclusive in the code, not just in prose.
grep -qF 'if (( complete == 1 )); then' <<< "$fn" \
  || fail "7: completion is not decided by a single flag"

# ---------------------------------------------------------------------------
# Part 8: `storage protection` -- protection as a VALUE, not a sentence.
#
# The migration wrapper decided this by grepping `domum-media report` for
# ": protected" / ": snapshottable" / ": degraded" and ABORTING on the English.
# Same dependency that aborted a completed migration over a reworded summary
# line, except here it gated a safety decision.
#
# Exit status is the contract: 0 only for `protected`.
# ---------------------------------------------------------------------------
prot() {  # $1 = service, $2 = subvolume? yes/no, $3 = snapshot name or "", $4 = nested? yes/no
  cat > "$TMP_DIR/prot.sh" <<PROBE
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$TMP_DIR/protdata"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/protsnaps"
need_root() { :; }
load_cfg() { :; }
load_report_lib() { source "$REPO_ROOT/bin/domum-media-report"; }
cmd_exists() { return 0; }
service_data_path() { printf '%s' "\$DOMUM_DATA_ROOT/\$1"; }
# After the report library is sourced it redefines these, so they are overridden
# inside storage_protection's call path by wrapping load_report_lib.
_orig_load_report_lib() { source "$REPO_ROOT/bin/domum-media-report"; }
load_report_lib() {
  _orig_load_report_lib
  domum_is_subvolume() { [[ "$2" == yes ]]; }
  domum_subvolume_nested_children() { [[ "$4" == yes ]] && printf '%s/nested\n' "\$1"; return 0; }
  latest_snapshot_for_service() { [[ -n "$3" ]] && printf '%s' "$3"; return 0; }
  snapshot_path_mtime() { printf '1790000000'; }
}
rc=0
storage_protection '$1' || rc=\$?
printf 'RC=%s' "\$rc"
PROBE
  mkdir -p "$TMP_DIR/protdata/$1" "$TMP_DIR/protsnaps"
  bash "$TMP_DIR/prot.sh" 2>/dev/null
}

out="$(prot kavita yes kavita-20260101-000000-tag no)"
grep -q '^protected' <<< "$out" || fail "8: a subvolume with a snapshot is not 'protected': $out"
grep -q 'RC=0'       <<< "$out" || fail "8: 'protected' did not exit 0: $out"

out="$(prot kavita yes "" no)"
grep -q '^snapshottable' <<< "$out" || fail "8: a subvolume with NO snapshot is not 'snapshottable': $out"
grep -q 'RC=1'           <<< "$out" || fail "8: 'snapshottable' exited 0 -- the whole point is that it must not: $out"

out="$(prot kavita yes kavita-20260101-000000-tag yes)"
grep -q '^degraded' <<< "$out" || fail "8: a nested subvolume is not 'degraded': $out"
grep -q 'RC=1'      <<< "$out" || fail "8: 'degraded' exited 0: $out"

out="$(prot kavita no "" no)"
grep -q '^unprotected' <<< "$out" || fail "8: an ordinary directory is not 'unprotected': $out"
grep -q 'RC=1'         <<< "$out" || fail "8: 'unprotected' exited 0: $out"

# The state must be computed, not asserted. A hardcoded answer passes the three
# positive cases above and fails these.
[[ "$(prot kavita yes "" no | head -1)" != "$(prot kavita yes snap no | head -1)" ]] \
  || fail "8: the same state is returned whether or not a snapshot exists"

# And the dispatcher must expose it, exit status intact.
storage_block="$(awk '/^storage_cmd\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'protection)' <<< "$storage_block" || fail "8: 'storage protection' is not dispatched"
grep -q 'storage_protection' <<< "$storage_block" || fail "8: the arm does not call storage_protection"

echo "PASS: fail-closed recovery smoke test"
