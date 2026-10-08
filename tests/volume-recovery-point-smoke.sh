#!/usr/bin/env bash
set -uo pipefail

# A pre-upgrade recovery point for a service whose durable state lives in a
# Docker volume.
#
# WHY IT EXISTS. traefik and uptime-kuma are blocked from upgrading because no
# Btrfs snapshot can reach a Docker volume. Blocking is honest but it is a dead
# end, so this builds the point that works for volume-backed state, to the same
# contract as the Btrfs one: application-consistent state + the exact image that
# wrote it + metadata binding the two.
#
# What makes it tractable: a Docker volume HAS a host path, so
# migrate_assert_quiesced -- open handles, hot journals, non-empty WALs --
# applies unchanged. uptime-kuma's kuma.db runs in WAL mode with a live -wal
# (8,272 bytes measured), so that is not a formality: a dump taken without
# quiescing is a torn database.
#
# WHAT THIS DOES NOT COVER. docker_volume_mountpoint is stubbed to a temp
# directory, because /var/lib/docker/volumes is 0700 root-owned and these tests
# run unprivileged. That one function is the entire seam between "docker owns
# this path" and "we tar a directory": everything else here is real -- real tar,
# real checksums, real quiescence checks, real metadata binding, real restore,
# and real file modes.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

OLD_IMG=sha256:aaaa1111000000000000000000000000000000000000000000000000000000aa

# A fixture volume holding what traefik and uptime-kuma actually hold: a
# 0600 secret and a WAL-mode SQLite database.
setup() {  # $1.. = options: dirty-wal, no-volume, open-handle
  rm -rf "${TMP_DIR:?}/f"
  ENV_DIR="$TMP_DIR/f"
  mkdir -p "$ENV_DIR"/{data,state/snapshots,log,vol,bin}
  local opts=" $* "

  printf '{"cf":{"Account":{"PrivateKey":"SECRET"}}}\n' > "$ENV_DIR/vol/acme.json"
  chmod 0600 "$ENV_DIR/vol/acme.json"
  printf 'SQLite format 3\n' > "$ENV_DIR/vol/kuma.db"
  mkdir -p "$ENV_DIR/vol/screenshots"
  printf 'x\n' > "$ENV_DIR/vol/screenshots/a.png"
  # A non-empty WAL means the application did not shut down cleanly.
  if [[ "$opts" == *" dirty-wal "* ]]; then
    printf 'uncheckpointed frames\n' > "$ENV_DIR/vol/kuma.db-wal"
  else
    : > "$ENV_DIR/vol/kuma.db-wal"
  fi
  : > "$ENV_DIR/calls.log"
  [[ "$opts" == *" no-volume "* ]] && NO_VOLUME=1 || NO_VOLUME=0
}

probe() {  # $1 = command to run with the CLI sourced
  local vols='fixture-vol /letsencrypt'
  (( NO_VOLUME == 1 )) && vols=''
  rm -f "$ENV_DIR/probe.sh.stubs"
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    printf 'need_root() { :; }\n'
    printf 'load_cfg() { :; }\n'
    printf 'export_env_for_compose() { :; }\n'
    printf 'ensure_dirs() { :; }\n'
    printf 'DOMUM_DATA_ROOT=%q\n' "$ENV_DIR/data"
    printf 'DOMUM_STATE_ROOT=%q\n' "$ENV_DIR/state"
    printf 'DOMUM_LOG_DIR=%q\n' "$ENV_DIR/log"
    printf 'snapshot_metadata_dir() { printf %q; }\n' "$ENV_DIR/state/snapshots"
    # The ONE stubbed seam: docker owns the real path, and it is 0700 root.
    printf 'docker_volume_mountpoint() { printf %q; }\n' "$ENV_DIR/vol"
    printf 'service_state_model() { printf "docker-volume durable state in a Docker volume (/letsencrypt)"; }\n'
    printf 'service_named_volumes() { printf %q; }\n' "$vols"
    printf 'service_compose_services() { printf traefik; }\n'
    printf 'service_runtime_state() { printf running; }\n'
    printf 'service_running_images() { printf "traefik %s"; }\n' "$OLD_IMG"
    printf 'migrate_allowed_service() { return 0; }\n'
    printf 'domum_acquire_lock() { return 0; }\n'
    cat >> "$ENV_DIR/probe.sh.stubs" <<STUBS
stage_recovery_point_metadata() {
  local f="$ENV_DIR/staged.\$\$"
  {
    printf "FORMAT='%s'\\n" 1
    printf "SERVICE='%s'\\n" traefik
    printf "CAPTURED_AT='%s'\\n" now
    printf "RUNTIME_BEFORE='%s'\\n" running
    printf "CONTAINER_1_SERVICE='%s'\\n" traefik
    printf "CONTAINER_1_IMAGE_IDENTITY='%s'\\n" known
    printf "CONTAINER_1_IMAGE_ID='%s'\\n" "$OLD_IMG"
  } > "\$f"
  printf '%s' "\$f"
}
recovery_metadata_required_keys() { printf 'FORMAT\\nSERVICE\\nCAPTURED_AT\\n'; }
archive_image_to_file() {
  install -d -m 0750 "\$(dirname "\$2")" || return 1
  printf 'ARCHIVE' > "\$2" || return 1
  sha256sum "\$2" | awk '{print \$1}' > "\$2.sha256"
}
STUBS
    cat "$ENV_DIR/probe.sh.stubs"

    printf 'image_archive_dir() { printf %q; }\n' "$ENV_DIR/data/backups/images"
    printf 'compose_cmd() { printf "compose %%s\\n" "$*" >> %q; return 0; }\n' "$ENV_DIR/calls.log"
    printf 'docker() { return 1; }\n'
    printf '%s\n' "$1"
  } > "$ENV_DIR/probe.sh"
  bash "$ENV_DIR/probe.sh" >"$ENV_DIR/out" 2>"$ENV_DIR/err"
  echo $?
}
out() { cat "$ENV_DIR/out" "$ENV_DIR/err"; }
calls() { cat "$ENV_DIR/calls.log"; }
meta_file() { find "$ENV_DIR/state/snapshots" -name '*.recovery' | head -1; }
dump_file() { find "$ENV_DIR/data/backups/volumes" -name '*-fixture-vol.tar' ! -name '*.failed-*' 2>/dev/null | head -1; }

echo "== 1. the point is created, and it deploys NOTHING =="
setup
rc="$(probe 'storage_volume_pre_upgrade_point traefik --archive-image')"
[ "$rc" = "0" ] || { out; fail "the volume point failed (rc=$rc)"; }
grep -q 'COMPLETE' "$ENV_DIR/out" || { out; fail "it did not report COMPLETE"; }
# compose start, never up -d: a restart must resolve no image reference.
grep -q 'compose stop traefik' <<< "$(calls)" || fail "the service was never stopped"
grep -q 'compose start traefik' <<< "$(calls)" || fail "it did not restart with 'compose start'"
grep -q 'compose up' <<< "$(calls)" \
  && fail "it used 'up -d', which RECONCILES and could deploy a staged image"
echo "  stopped, dumped, restarted with 'compose start'; no reconcile"

echo "== 2. the ordering the safety argument rests on =="
log="$(cat "$ENV_DIR/out")"
n_stop="$(grep -n 'migrate\[stop\] stopping' <<< "$log" | head -1 | cut -d: -f1)"
n_quiesce="$(grep -n 'quiesced:' <<< "$log" | head -1 | cut -d: -f1)"
n_dump="$(grep -n 'dumping' <<< "$log" | head -1 | cut -d: -f1)"
for v in n_stop n_quiesce n_dump; do
  [ -n "${!v}" ] || fail "stage $v never reported: $log"
done
[ "$n_stop" -lt "$n_quiesce" ] || fail "quiescence was proven before the stop"
[ "$n_quiesce" -lt "$n_dump" ] || fail "the dump was taken before quiescence was proven"
echo "  stop($n_stop) < quiesce($n_quiesce) < dump($n_dump)"

echo "== 3. the dump is complete, checksummed, and preserves FILE MODES =="
d="$(dump_file)"
[ -n "$d" ] || fail "no dump was produced: $(ls -R "$ENV_DIR/data" 2>&1)"
[ -r "$d.sha256" ] || fail "the dump has no checksum beside it"
[ "$(sha256sum "$d" | awk '{print $1}')" = "$(cat "$d.sha256")" ] \
  || fail "the recorded checksum does not match the dump"
# A 0600 secret restored world-readable would turn a recovery into a disclosure.
modes="$(tar -tvf "$d" 2>/dev/null | grep 'acme.json')"
grep -qE '^-rw-------' <<< "$modes" \
  || fail "the dump did not preserve acme.json's 0600 mode: $modes"
tar -tf "$d" | grep -q 'screenshots/a.png' || fail "the dump is missing a subdirectory file"
echo "  checksummed; acme.json kept 0600; subdirectories included"

echo "== 4. the metadata records every volume AND the image =="
m="$(meta_file)"
[ -n "$m" ] || fail "no recovery metadata was bound"
for key in VOLUME_1_NAME VOLUME_1_DEST VOLUME_1_DUMP VOLUME_1_DUMP_SHA256 VOLUME_COUNT \
           POINT_KIND CONTAINER_1_IMAGE_ID IMAGE_ARCHIVE; do
  grep -q "^$key=" "$m" || fail "the metadata records no $key: $(cat "$m")"
done
grep -q "^POINT_KIND='pre-upgrade-volume'" "$m" || fail "wrong POINT_KIND"
grep -q "^CONTAINER_1_IMAGE_ID='$OLD_IMG'" "$m" \
  || fail "the metadata does not record the OLD image id; a rollback could not pair"
grep -qE "^RECOVERY_POINT='traefik-[0-9]{8}-[0-9]{6}-pre-upgrade-volume'" "$m" \
  || fail "the point name does not identify it as a volume point: $(grep RECOVERY_POINT "$m")"
echo "  volume, destination, dump, checksum, image id and archive all recorded"

echo "== 5. a NON-EMPTY WAL refuses, and publishes nothing =="
# The case that matters: uptime-kuma's database is WAL-mode and live.
setup dirty-wal
rc="$(probe 'storage_volume_pre_upgrade_point traefik --archive-image')"
[ "$rc" != "0" ] || fail "a non-empty WAL did not refuse"
grep -q 'write-ahead log' "$ENV_DIR/err" || { out; fail "the WAL refusal did not explain itself"; }
[ -z "$(dump_file)" ] || fail "a dump was published despite the refusal: $(dump_file)"
[ -z "$(meta_file)" ] || fail "recovery metadata was bound despite the refusal"
grep -q 'compose start traefik' <<< "$(calls)" \
  || fail "the service was left stopped after the refusal"
echo "  refused, nothing published, service restarted"

echo "== 6. an open handle refuses =="
setup
# A real process holding a real descriptor inside the fixture volume, from
# another process group, as the migration suite does it.
setsid bash -c 'echo $$ > "$1"; exec sleep 60' _ "$ENV_DIR/intruder.pid" \
  < "$ENV_DIR/vol/kuma.db" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [ -s "$ENV_DIR/intruder.pid" ] && break; sleep 0.05; done
INTRUDER="$(cat "$ENV_DIR/intruder.pid" 2>/dev/null || true)"
[ -n "$INTRUDER" ] || fail "could not start the intruder process"
rc="$(probe 'storage_volume_pre_upgrade_point traefik --archive-image')"
kill "$INTRUDER" 2>/dev/null; wait 2>/dev/null
[ "$rc" != "0" ] || fail "an open handle inside the volume did not refuse"
grep -q 'still has files open' "$ENV_DIR/err" || { out; fail "the handle refusal did not explain itself"; }
[ -z "$(dump_file)" ] || fail "a dump was published despite an open handle"
echo "  refused, naming the open handle"

echo "== 7. a service with no NAMED volume refuses =="
# An anonymous volume cannot be a recovery point: its name changes when the
# container is recreated, so a dump could not be restored to the same place.
setup no-volume
rc="$(probe 'storage_volume_pre_upgrade_point traefik --archive-image')"
[ "$rc" != "0" ] || fail "a service with no named volume did not refuse"
grep -q 'anonymous volume cannot be a recovery point' "$ENV_DIR/err" \
  || { out; fail "the refusal does not explain why an anonymous volume is unusable"; }
grep -q 'compose stop' <<< "$(calls)" && fail "it stopped the service before refusing"
echo "  refused before stopping anything"

echo "== 8. the wrong state model refuses =="
setup
rc="$(probe 'service_state_model() { printf "protected-tier declared"; }
storage_volume_pre_upgrade_point traefik --archive-image')"
[ "$rc" != "0" ] || fail "a protected-tier service was accepted by the volume path"
grep -q 'not docker-volume' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
echo "  a protected-tier service is sent to the snapshot path"

echo "== 9. verify-volume-dumps reports intact, missing and mismatched =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
rc="$(probe "storage_verify_volume_dumps $point")"
[ "$rc" = "0" ] || { out; fail "verification failed on an intact dump"; }
grep -q 'matches the record' "$ENV_DIR/out" || { out; fail "it did not confirm the checksum"; }
grep -q 'not the same claim' "$ENV_DIR/out" \
  || fail "it does not distinguish file integrity from the state being usable"
# Corrupt it.
printf 'CORRUPT\n' >> "$(dump_file)"
rc="$(probe "storage_verify_volume_dumps $point")"
[ "$rc" != "0" ] || fail "a corrupted dump verified clean"
grep -q 'MISMATCH' "$ENV_DIR/out" || { out; fail "the mismatch was not named"; }
# Remove it.
rm -f "$(dump_file)"
rc="$(probe "storage_verify_volume_dumps $point")"
[ "$rc" != "0" ] || fail "a missing dump verified clean"
grep -q 'MISSING' "$ENV_DIR/out" || { out; fail "the missing dump was not named"; }
echo "  intact / mismatched / missing each reported distinctly"

echo "== 10. restore preserves what was there, then restores, keeping modes =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
d="$(dump_file)"
[ -n "$d" ] || fail "no dump to restore from"
# Mutate the live volume as an upgrade would.
printf '{"cf":{"Account":{"PrivateKey":"ROTATED"}}}\n' > "$ENV_DIR/vol/acme.json"
chmod 0644 "$ENV_DIR/vol/acme.json"
printf 'NEW\n' > "$ENV_DIR/vol/added-by-upgrade"
rc="$(probe "restore_volume_from_file fixture-vol $d 20261008-120000")"
[ "$rc" = "0" ] || { out; fail "the restore failed (rc=$rc)"; }
grep -q 'SECRET' "$ENV_DIR/vol/acme.json" \
  || fail "the original secret was not restored: $(cat "$ENV_DIR/vol/acme.json")"
[ "$(stat -c %a "$ENV_DIR/vol/acme.json")" = "600" ] \
  || fail "the restored acme.json is mode $(stat -c %a "$ENV_DIR/vol/acme.json"), not 600.
Restoring a private key world-readable turns a recovery into a disclosure."
[ ! -e "$ENV_DIR/vol/added-by-upgrade" ] \
  || fail "a file the upgrade added survived the restore; the volume was not cleared"
# And the replaced contents were PRESERVED, not deleted.
aside="$(find "$ENV_DIR/data/backups/volumes" -name '*.failed-20261008-120000.tar' | head -1)"
[ -n "$aside" ] || fail "the replaced contents were not preserved"
tar -xOf "$aside" ./acme.json 2>/dev/null | grep -q 'ROTATED' \
  || fail "the preserved copy does not hold what was replaced"
echo "  restored with modes intact; replaced contents preserved at $(basename "$aside")"

echo "== 11. restore REFUSES on a bad checksum, before touching the volume =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
d="$(dump_file)"
printf 'TAMPERED\n' >> "$d"
before="$(sha256sum "$ENV_DIR/vol/acme.json" | awk '{print $1}')"
rc="$(probe "restore_volume_from_file fixture-vol $d 20261008-130000")"
[ "$rc" != "0" ] || fail "a dump that does not match its checksum was restored"
grep -q 'checksum mismatch' "$ENV_DIR/err" || { out; fail "the mismatch was not named"; }
[ "$(sha256sum "$ENV_DIR/vol/acme.json" | awk '{print $1}')" = "$before" ] \
  || fail "the volume was modified despite the refusal"
[ -z "$(find "$ENV_DIR/data/backups/volumes" -name '*.failed-20261008-130000.tar')" ] \
  || fail "it preserved a copy before validating the dump; the refusal must come first"
echo "  refused before touching the volume, and before preserving anything"

echo "== 12. a dump is never silently overwritten =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
d="$(dump_file)"
rc="$(probe "dump_volume_to_file fixture-vol $d")"
[ "$rc" != "0" ] || fail "an existing dump was overwritten"
grep -q 'refusing to overwrite' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
echo "  refused"

# ===========================================================================
# ROLLBACK for a volume point. A point whose restore cannot be reached from the
# CLI is not a recovery point.
# ===========================================================================

rb_probe() {  # $1 = extra stubs, $2 = command
  probe "$1
service_running_images() { printf 'traefik %s' \"\$(cat $ENV_DIR/running-image)\"; }
uppercase_token() { printf TRAEFIK; }
managed_image_specs() { printf 'traefik|ENABLE_TRAEFIK|TRAEFIK_IMAGE|A|B|traefik\n'; }
compose_cmd() {
  printf 'compose %s\n' \"\$*\" >> $ENV_DIR/calls.log
  case \"\$1\" in
    up) printf '%s' \"\${TRAEFIK_IMAGE:-unpinned}\" > $ENV_DIR/running-image ;;
  esac
  return 0
}
docker() {
  case \"\$*\" in
    'image inspect '*) return 1 ;;   # the old image has been pruned
    'load -i '*) printf 'Loaded image ID: %s\n' '$OLD_IMG' ;;
  esac
  return 0
}
$2"
}

echo "== 13. the volume rollback restores BOTH halves =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
# An upgrade happened: the volume was mutated and the image moved on.
printf '{"cf":{"Account":{"PrivateKey":"ROTATED"}}}\n' > "$ENV_DIR/vol/acme.json"
printf 'sha256:bbbb2222\n' > "$ENV_DIR/running-image"
: > "$ENV_DIR/calls.log"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
[ "$rc" = "0" ] || { out; fail "the volume rollback failed (rc=$rc)"; }
grep -q 'SECRET' "$ENV_DIR/vol/acme.json" \
  || fail "the volume was not restored: $(cat "$ENV_DIR/vol/acme.json")"
[ "$(cat "$ENV_DIR/running-image")" = "$OLD_IMG" ] \
  || fail "the image was not pinned to the record; got $(cat "$ENV_DIR/running-image")"
grep -q 'compose stop traefik' <<< "$(calls)" || fail "it did not stop the service"
grep -q 'compose up -d traefik' <<< "$(calls)" \
  || fail "it did not recreate; a volume rollback must deploy the recorded image"
grep -q 'Rollback COMPLETE' "$ENV_DIR/out" || { out; fail "it did not report COMPLETE"; }
echo "  volumes restored and the image pinned to the record"

echo "== 14. it loaded the image FROM THE ARCHIVE and confirmed the identity =="
grep -q 'loading .* from ' "$ENV_DIR/out" \
  || { out; fail "it did not load from the archive, although the local object was pruned"; }
grep -q 'identity CONFIRMED equal to the record' "$ENV_DIR/out" \
  || { out; fail "the loaded identity was not compared against the record"; }
echo "  loaded and identity confirmed"

echo "== 15. every dump is verified BEFORE anything is stopped =="
# A rollback that gets half way and finds a corrupt dump has already taken the
# service down. This is the ordering that matters most in the whole function.
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
printf 'TAMPERED\n' >> "$(dump_file)"
printf 'sha256:bbbb2222\n' > "$ENV_DIR/running-image"
: > "$ENV_DIR/calls.log"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
[ "$rc" != "0" ] || fail "a corrupted dump was restored"
grep -q 'does not match its recorded sha256' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
grep -q 'compose stop' <<< "$(calls)" \
  && fail "it STOPPED the service before discovering the dump was corrupt"
echo "  refused with the service still running"

echo "== 16. a missing dump refuses, also before stopping =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
rm -f "$(dump_file)"
: > "$ENV_DIR/calls.log"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
[ "$rc" != "0" ] || fail "a missing dump was accepted"
grep -q 'is missing at' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
grep -q 'compose stop' <<< "$(calls)" && fail "it stopped the service before refusing"
echo "  refused with the service still running"

echo "== 17. no recorded image identity refuses =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
sed -i "/^CONTAINER_1_IMAGE_ID=/d" "$(meta_file)"
: > "$ENV_DIR/calls.log"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
[ "$rc" != "0" ] || fail "a point with no image identity was rolled back"
grep -q 'records no image identity' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
grep -q 'compose stop' <<< "$(calls)" && fail "it stopped the service before refusing"
echo "  refused -- restoring volumes under an unknown application is the pairing failure"

echo "== 18. the two rollbacks refuse each other's points, ACCURATELY =="
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
# The snapshot rollback must REDIRECT, not say "the snapshot is missing" -- a
# volume point has none by design, and that message would send the operator
# looking for a deleted snapshot.
rc="$(rb_probe 'service_data_path() { printf %s "'"$ENV_DIR"'/vol"; }
DOMUM_SNAPSHOT_ROOT='"$ENV_DIR"'/snaps' "rollback_upgrade traefik $point")"
[ "$rc" != "0" ] || fail "the snapshot rollback accepted a volume point"
grep -q 'DOCKER-VOLUME recovery point' "$ENV_DIR/err" \
  || { out; fail "it did not identify the point as volume-backed"; }
grep -q 'rollback-volume-upgrade' "$ENV_DIR/err" \
  || fail "it did not name the command that CAN restore it"
grep -q 'snapshot .* is missing' "$ENV_DIR/err" \
  && fail "it blamed a missing snapshot. A volume point has none by design."
# And the reverse.
sed -i "s/^POINT_KIND='pre-upgrade-volume'/POINT_KIND='pre-upgrade'/" "$(meta_file)"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
[ "$rc" != "0" ] || fail "the volume rollback accepted a snapshot point"
grep -q 'not pre-upgrade-volume' "$ENV_DIR/err" || { out; fail "wrong refusal"; }
echo "  each redirects to the other by name, with the real reason"

echo "== 19. mutation: the pre-stop dump verification is load-bearing =="
mut="$TMP_DIR/mut"; rm -rf "$mut"; mkdir -p "$mut"
cp "$CLI" "$mut/domum-media"
# Remove the pre-stop checksum loop's refusal.
sed -i 's@|| die "Refusing: the dump for \$vname does not match its recorded sha256.@|| warn "ignored@' \
  "$mut/domum-media"
cmp -s "$CLI" "$mut/domum-media" && fail "19: the mutation changed nothing"
setup
probe 'storage_volume_pre_upgrade_point traefik --archive-image' >/dev/null
point="$(basename "$(meta_file)" .recovery)"
printf 'TAMPERED\n' >> "$(dump_file)"
printf 'sha256:bbbb2222\n' > "$ENV_DIR/running-image"
: > "$ENV_DIR/calls.log"
saved="$CLI"; CLI="$mut/domum-media"
rc="$(rb_probe '' "rollback_volume_upgrade traefik $point")"
CLI="$saved"
grep -q 'compose stop' <<< "$(calls)" \
  || fail "19: removing the pre-stop verification did NOT let it reach the stop, so
section 15 is not proving the ordering"
echo "  without it the service IS stopped before the corruption is found"

echo
echo "PASS: volume recovery point smoke"
