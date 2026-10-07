#!/usr/bin/env bash
set -uo pipefail

# A pre-upgrade recovery point is the complete rollback artifact for an
# application upgrade: application-consistent state + the exact old image +
# metadata tying the two together. It deploys nothing.
#
# WHY IT EXISTS. Measured in refresh_images, the path `updates apply` uses:
#
#   * create_service_snapshot is called while the service is RUNNING. There is no
#     stop, no open-handle check and no WAL gate in that function -- so the
#     snapshot is CRASH-consistent, not application-consistent. Plex holds a live
#     non-empty WAL (93,304 bytes measured), and the migration path stops and
#     proves quiescence before snapshotting. The update path would use a weaker
#     model for the same data.
#   * create_service_snapshot writes NO recovery metadata (zero references), so a
#     pre-update snapshot records nothing about WHICH application wrote the state.
#   * and because `cleanup images` protection keys off .recovery files, the old
#     image such a point depends on would NOT be protected from deletion.
#   * refresh_images rejects any positional argument, so it cannot target one
#     service at all.
#
# These assertions pin the properties that make the new point trustworthy, and
# the refresh_images facts above, so the justification cannot silently rot.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

echo "== 1. the facts that justify this command are still true of refresh_images =="
ri="$(awk '/^refresh_images\(\) \{/,/^\}/' "$CLI")"
[ -n "$ri" ] || fail "could not isolate refresh_images"
grep -q 'create_service_snapshot' <<< "$ri" || fail "refresh_images no longer snapshots; re-audit"
grep -qE 'compose_cmd stop|migrate_assert_quiesced' <<< "$ri" \
  && fail "refresh_images now stops or quiesces before snapshotting. If the update
path became application-consistent, this command's justification changed -- re-audit
rather than leaving both."
csn="$(awk '/^create_service_snapshot\(\) \{/,/^\}/' "$CLI")"
grep -q 'recovery' <<< "$csn" \
  && fail "create_service_snapshot now touches recovery metadata; re-audit whether a
separate pre-upgrade point is still needed"
grep -qE 'die "Usage: domum-media refresh-images' <<< "$ri" \
  || fail "refresh_images may now accept a service argument; re-audit the scope claim"
echo "  refresh_images still: snapshots while running, no metadata, no service arg"

echo "== 2. the new command exists, is dispatched, and is documented =="
grep -q 'pre-upgrade-point)' "$CLI" || fail "the subcommand is not dispatched"
grep -q 'storage_pre_upgrade_point "\${1:-}" "\${2:-}"' "$CLI" \
  || fail "the dispatcher does not forward the service and the flag"
grep -q 'domum-media storage pre-upgrade-point <service> \[--archive-image\]' "$CLI" \
  || fail "it is absent from the usage text"
echo "  dispatched and documented"

echo "== 3. it uses the STOP-then-quiesce model, not the update path's =="
fn="$(awk '/^storage_pre_upgrade_point\(\) \{/,/^\}/' "$CLI")"
[ -n "$fn" ] || fail "could not isolate storage_pre_upgrade_point"
for want in 'compose_cmd stop' 'migrate_assert_quiesced' 'create_service_snapshot' \
            'stage_recovery_point_metadata' 'bind_recovery_point_metadata' 'domum_acquire_lock'; do
  grep -qF "$want" <<< "$fn" || fail "missing: $want"
done
# Ordering is the whole claim: stage before stop, quiesce before snapshot,
# bind before restart.
l_stage="$(grep -n 'stage_recovery_point_metadata' <<< "$fn" | head -1 | cut -d: -f1)"
l_stop="$(grep -n 'compose_cmd stop' <<< "$fn" | head -1 | cut -d: -f1)"
l_qui="$(grep -n 'migrate_assert_quiesced' <<< "$fn" | head -1 | cut -d: -f1)"
l_snap="$(grep -n 'create_service_snapshot' <<< "$fn" | head -1 | cut -d: -f1)"
l_bind="$(grep -n 'bind_recovery_point_metadata' <<< "$fn" | head -1 | cut -d: -f1)"
l_restart="$(grep -n 'migrate_restart || restart_ok=0' <<< "$fn" | head -1 | cut -d: -f1)"
[ "$l_stage" -lt "$l_stop" ] || fail "metadata is staged AFTER the stop ($l_stage vs $l_stop):
the running image must be recorded while it is still observably running"
[ "$l_stop" -lt "$l_qui" ] || fail "quiescence is asserted before the stop ($l_qui vs $l_stop)"
[ "$l_qui" -lt "$l_snap" ] || fail "the snapshot is taken before quiescence is proven ($l_snap vs $l_qui)"
[ "$l_bind" -lt "$l_restart" ] || fail "metadata is bound AFTER the restart ($l_bind vs $l_restart):
once the application runs again it can mutate the state the point describes"
echo "  stage($l_stage) < stop($l_stop) < quiesce($l_qui) < snapshot($l_snap) < bind($l_bind) < restart($l_restart)"

echo "== 4. it restarts with 'start' and never reconciles =="
grep -q 'compose_cmd start' <<< "$fn" || fail "it does not restart with 'compose start'"
exec_lines="$(grep -v '^ *#' <<< "$fn" | grep -v '^ *warn ' | grep -v '^ *echo ')"
grep -qE 'compose_cmd up -d' <<< "$exec_lines" \
  && fail "it contains an executable 'up -d'; that resolves the image tag and could
deploy the staged image this point exists to protect against"
echo "  'compose start' only, no executable 'up -d'"

echo "== 5. it refuses on a path that is not a subvolume =="
# The check lives in assert_pre_upgrade_possible, shared with service_upgrade so
# the two cannot disagree about what counts as protectable. Assert the routing
# plus the check, not the inlined text -- this test failed the extraction once
# while the behaviour was intact.
grep -q 'assert_pre_upgrade_possible' <<< "$fn" \
  || fail "it does not assert that a pre-upgrade point is possible"
helper="$(awk '/^assert_pre_upgrade_possible\(\) \{/,/^\}$/' "$CLI")"
[ -n "$helper" ] || fail "assert_pre_upgrade_possible is not defined"
grep -q 'domum_is_subvolume "$path"' <<< "$helper" \
  || fail "the assertion does not check that the path can be snapshotted"
grep -q 'migrate-subvolume' <<< "$helper" \
  || fail "the refusal does not tell the operator how to fix it"
echo "  refuses via the shared assertion, and names the fix"

echo "== 6. every failure path restarts the service and leaves nothing behind =="
# A half-finished pre-upgrade point must not leave the service down or publish a
# snapshot with no metadata.
n_restart="$(grep -c 'migrate_restart' <<< "$fn")"
[ "$n_restart" -ge 5 ] || fail "only $n_restart migrate_restart call(s); the stop, quiesce,
snapshot, archive and bind failures must each bring the service back"
grep -q 'rm -f "$staged"' <<< "$fn" || fail "a failed run leaves the staged metadata behind"
grep -q 'DATA-only point' <<< "$fn" \
  || fail "a bind failure must say the snapshot is a data-only point, not imply success"
echo "  $n_restart restart paths; staged metadata cleaned; bind failure stated honestly"

echo "== 7. the archive is published atomically and never overwritten =="
af="$(awk '/^archive_image_to_file\(\) \{/,/^\}/' "$CLI")"
[ -n "$af" ] || fail "archive_image_to_file is missing"
grep -q 'refusing to overwrite an existing archive' <<< "$af" \
  || fail "it would overwrite an existing archive, destroying another point's copy"
grep -q '\.partial' <<< "$af" || fail "it does not stage to a .partial name"
p_save="$(grep -n 'docker save' <<< "$af" | head -1 | cut -d: -f1)"
p_mv="$(grep -n 'mv -- "$dest.partial" "$dest"' <<< "$af" | head -1 | cut -d: -f1)"
[ -n "$p_save" ] && [ -n "$p_mv" ] || fail "could not locate the save and the publish"
[ "$p_save" -lt "$p_mv" ] || fail "the archive is published before it is written"
grep -q 'sha256sum' <<< "$af" || fail "no checksum is written beside the archive"
grep -q 'sync' <<< "$af" || fail "the archive is renamed without being flushed first"
echo "  .partial -> checksum -> sync -> atomic publish; refuses to overwrite"

echo "== 8. a failed archive is fatal BEFORE the restart =="
l_arch="$(grep -n 'archive_image_to_file' <<< "$fn" | head -1 | cut -d: -f1)"
[ "$l_arch" -lt "$l_restart" ] || fail "the archive is attempted after the restart"
# Anchor the end pattern. `/fi/` also matches the START line, because
# `archive_image_to_file` contains "fi" -- so the range closed immediately and
# the assertion inspected one line.
arch_block="$(awk '/if ! archive_image_to_file/,/^ *fi$/' <<< "$fn")"
grep -q 'die ' <<< "$arch_block" \
  || fail "a failed archive does not abort. A recovery point that claims an archive
it does not have is worse than one that admits it has none."
echo "  archive failure aborts before the restart"

echo "== 9. the archive destination is the protected, backed-up tier =="
ad="$(awk '/^image_archive_dir\(\) \{/,/^\}/' "$CLI")"
grep -q 'backups/images' <<< "$ad" || fail "the archive does not live under backups/"
grep -q 'DOMUM_DATA_ROOT' <<< "$ad" \
  || fail "the archive is not on the protected data tier, so it would not be in the
restic backup set"
grep -qE 'DOMUM_MEDIA_ROOT|/tmp|/var/tmp' <<< "$ad" \
  && fail "the archive is on a replaceable or unbacked tier"
# And it must not be inside a service subvolume, or it would duplicate into every
# per-service snapshot.
grep -q 'service_data_path' <<< "$ad" \
  && fail "the archive path is derived from a service's state dir, so it would sit
inside that service's subvolume and be copied into each of its snapshots"
echo "  \$DOMUM_DATA_ROOT/backups/images: protected, in restic, outside every subvolume"

echo "== 10. the metadata ties the archive to the image and the point =="
for k in IMAGE_ARCHIVE IMAGE_ARCHIVE_SHA256 IMAGE_ARCHIVE_BYTES POINT_KIND; do
  grep -q "$k=" <<< "$fn" || fail "the recovery evidence does not record $k"
done
grep -q "POINT_KIND='pre-upgrade'" <<< "$fn" \
  || fail "the point does not record what kind of point it is"
echo "  records IMAGE_ARCHIVE, its sha256 and size, and POINT_KIND"

echo "== 11. cleanup protection reaches a pre-upgrade point automatically =="
# The point writes a .recovery file with CONTAINER_n_IMAGE_ID, which is exactly
# what recovery_point_image_ids reads -- so the old image is protected with no
# further wiring. Assert the two halves still agree on the key.
grep -q "CONTAINER_%s_IMAGE_ID='%s'" "$CLI" \
  || fail "the metadata writer no longer emits CONTAINER_n_IMAGE_ID"
grep -qF "CONTAINER_[0-9]+_IMAGE_ID='" "$CLI" \
  || fail "the cleanup selector no longer reads CONTAINER_n_IMAGE_ID; a pre-upgrade
point's image would stop being protected"
echo "  writer and cleanup selector agree on CONTAINER_n_IMAGE_ID"

echo "== 12. it deploys nothing, and says so =="
grep -q 'Deploys' "$CLI" || fail "the usage text does not say it deploys nothing"
grep -q 'nothing was deployed' <<< "$fn" \
  || fail "the summary does not state that nothing was deployed"
echo "  stated in both the usage text and the result"

echo "== 13. the archive inventory answers the lifecycle questions =="
ar="$(awk '/^storage_archives\(\) \{/,/^\}/' "$CLI")"
[ -n "$ar" ] || fail "storage_archives is missing"
# The questions the operator has to be able to answer without reading two
# directories by hand.
for want in 'needed by' 'image id' 'checksum' 'local object' 'safe to delete' 'orphan'; do
  grep -qi -- "$want" <<< "$ar" || fail "the inventory does not report: $want"
done
# It must decide "needed" from the METADATA, not from the filename, which is
# only a convenience.
grep -q "IMAGE_ARCHIVE='" <<< "$ar" \
  || fail "the inventory does not match archives against IMAGE_ARCHIVE in the metadata"
# And it must never delete.
grep -qE '^\s*(rm|btrfs subvolume delete|docker image rm)' <<< "$ar" \
  && fail "storage_archives deletes something; it is an inventory"
grep -q 'Nothing was deleted' <<< "$ar" || fail "it does not state that it deleted nothing"
echo "  reports need, id, checksum, local object, orphans; deletes nothing"

echo "== 14. an archive whose only copy is the file is called out =="
grep -q 'this archive is the only copy' <<< "$ar" \
  || fail "when the local Docker object is gone, the inventory must say the archive
is the only remaining copy of the application"
grep -q 'a rollback would not need this archive' <<< "$ar" \
  || fail "when the local object is present it should say so, or the operator cannot
tell which archives are load-bearing today"
echo "  distinguishes 'only copy' from 'local object also present'"

echo "== 15. every metadata key the new code reads is one the writer emits =="
# A reader using a key the writer never produces does not fail -- sed matches
# nothing and the value is silently empty. That happened: the inventory read
# ..._IMAGE_VERSION while the writer emits ..._IMAGE_LABEL_VERSION.
python3 "$REPO_ROOT/tests/recovery-metadata-keys-audit.py" >/dev/null \
  || fail "the recovery-metadata key audit fails; a key is read but never written"
grep -q 'IMAGE_LABEL_VERSION' <<< "$ar" \
  || fail "the inventory no longer reads the version key the writer actually emits"
echo "  key audit passes; the inventory reads IMAGE_LABEL_VERSION"

echo "PASS: pre-upgrade point smoke test"
