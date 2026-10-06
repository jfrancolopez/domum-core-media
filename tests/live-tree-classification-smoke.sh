#!/usr/bin/env bash
set -uo pipefail

# What has the restarted service done to its state since the proof snapshot?
#
# Stage 9 compares two STATIC trees (.premigration == proof snapshot) and is the
# integrity claim. This is the other question, and until now it existed ONLY in
# the operator wrapper -- while docs/MIGRATION-LIFECYCLE.md and CLAUDE.md both
# described the live tree as "classified, not compared" as though the CLI did it.
# It did not. One canonical implementation, tested here, invoked by the wrapper.
#
# The fixture is PLEX-SHAPED on purpose, because Plex breaks two assumptions that
# held for jellyfin, kavita and navidrome:
#
#   1. PATHS CONTAIN SPACES. `config/Library/Application Support/Plex Media
#      Server/...`. The wrapper iterated `for f in $CHANGED $ADDED`, which
#      word-splits: measured, two real Plex paths became ELEVEN fragments, and
#      since `Server.2.log` matches `*.log` while `Support/Plex` matches nothing,
#      pieces of a single path were classified differently from each other.
#
#   2. FILES LEGITIMATELY DISAPPEAR. Plex rotates `Plex Media Server.N.log` and
#      prunes its own dated database backups (four kept). The wrapper aborted
#      unconditionally on any snapshotted file missing from the live tree, so
#      ordinary log rotation would have failed a correct migration -- the same
#      shape as the stale topology invariant.
#
# Every removal below uses ${VAR:?} so an unset fixture path is an error, never a
# top-level delete.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

PMS='config/Library/Application Support/Plex Media Server'
DBS="$PMS/Plug-in Support/Databases"

build_tree() {
  local root="${1:?}"
  mkdir -p "$root/$DBS" "$root/$PMS/Logs/PMS Plugin Logs" \
           "$root/$PMS/Drivers/icr-x-linux-x86_64" \
           "$root/$PMS/Cache/va-dri-linux-x86_64" \
           "$root/$PMS/Codecs" "$root/$PMS/Crash Reports"
  printf 'SQLite format 3\000library-main' > "$root/$DBS/com.plexapp.plugins.library.db"
  printf 'SQLite format 3\000blobs-main'   > "$root/$DBS/com.plexapp.plugins.library.blobs.db"
  local day
  for day in 2026-09-25 2026-09-28 2026-10-01 2026-10-04; do
    printf 'SQLite format 3\000backup-%s' "$day" > "$root/$DBS/com.plexapp.plugins.library.db-$day"
  done
  printf 'wal-bytes'  > "$root/$DBS/com.plexapp.plugins.library.db-wal"
  printf 'shm-bytes'  > "$root/$DBS/com.plexapp.plugins.library.db-shm"
  printf 'token-shaped-but-not-a-real-secret' > "$root/$PMS/Preferences.xml"
  printf '1234'       > "$root/$PMS/plexmediaserver.pid"
  local n
  for n in 1 2 3 4 5; do printf 'log %s' "$n" > "$root/$PMS/Logs/Plex Media Server.$n.log"; done
  for n in 1 2 3; do printf 'plugin log %s' "$n" > "$root/$PMS/Logs/PMS Plugin Logs/com.plexapp.system.log.$n"; done
  printf 'driver blob' > "$root/$PMS/Drivers/icr-x-linux-x86_64/libigc.so.2.16.0+0"
  ln -sf 'libigc.so.2.16.0+0' "$root/$PMS/Drivers/icr-x-linux-x86_64/libigc.so.2"
  # Absolute symlink in the CONTAINER's namespace: /config is the bind-mount
  # destination for <root>/config, so it resolves in the container and dangles on
  # the host. Measured on production: Plex has exactly one of these.
  ln -sf "/config/Library/Application Support/Plex Media Server/Drivers/icr-x-linux-x86_64/libigc.so.2.16.0+0" \
         "$root/$PMS/Cache/va-dri-linux-x86_64/iHD_drv_video.so"
  ln -sf 'gone-forever.so' "$root/$PMS/Drivers/icr-x-linux-x86_64/dangling.so"
}

probe() {
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$REPO_ROOT/bin/domum-media"
    # Sourcing the CLI re-enables its own `set -e`, so a function returning
    # non-zero would kill the probe before it could report the status. This has
    # cost a debugging session before.
    printf 'set +e\n'
    printf '%s\n' "$1"
  } > "$TMP_DIR/probe.sh"
  bash "$TMP_DIR/probe.sh" 2>&1
}

SNAP="$TMP_DIR/snap"; LIVE="$TMP_DIR/live"
reset_trees() {
  rm -rf "${SNAP:?}" "${LIVE:?}"
  build_tree "$SNAP"; build_tree "$LIVE"
}
classify() {
  probe "migrate_classify_live_tree $(printf '%q' "$SNAP") $(printf '%q' "$LIVE") | tr '\\0' '\\n'"
}
nrec() { grep -c . <<< "$1" || true; }

echo "== 1. identical trees: no differences at all =="
reset_trees
out="$(classify)"
[ "$(nrec "$out")" = 0 ] || fail "identical trees produced records:
$out"
echo "  no records"

echo "== 2. SPACED PATHS are one record each, not fragments =="
reset_trees
printf 'log 2 ROTATED' > "$LIVE/$PMS/Logs/Plex Media Server.2.log"
printf 'SQLite format 3\000library-CHANGED' > "$LIVE/$DBS/com.plexapp.plugins.library.db"
out="$(classify)"
[ "$(nrec "$out")" = 2 ] || fail "expected 2 records from 2 changed spaced paths, got $(nrec "$out"):
$out"
grep -qF "CHURN $PMS/Logs/Plex Media Server.2.log" <<< "$out" \
  || fail "the rotated log was not expected churn:
$out"
grep -qF "CHANGED $DBS/com.plexapp.plugins.library.db" <<< "$out" \
  || fail "the changed database was not CHANGED:
$out"
grep -qE '^(CHURN|CHANGED|ADDED|LOST|PRUNED) (Support/Plex|Media|Server\.2\.log)$' <<< "$out" \
  && fail "a path fragment appeared -- word splitting is back:
$out"
echo "  2 spaced paths -> 2 records; database CHANGED, log CHURN"

echo "== 3. the DATABASE is never treated as expected churn =="
reset_trees
printf 'SQLite format 3\000blobs-CHANGED' > "$LIVE/$DBS/com.plexapp.plugins.library.blobs.db"
out="$(classify)"
grep -qF "CHANGED $DBS/com.plexapp.plugins.library.blobs.db" <<< "$out" \
  || fail "a changed .db must be CHANGED, never CHURN:
$out"
reset_trees
printf 'SQLite format 3\000backup-TAMPERED' > "$LIVE/$DBS/com.plexapp.plugins.library.db-2026-10-01"
out="$(classify)"
grep -qF "CHANGED $DBS/com.plexapp.plugins.library.db-2026-10-01" <<< "$out" \
  || fail "a dated backup database must not be swallowed as a sidecar:
$out"
echo "  live and dated-backup databases both CHANGED"

echo "== 4. SIDECARS are expected churn =="
reset_trees
printf 'wal-GREW-a-lot' > "$LIVE/$DBS/com.plexapp.plugins.library.db-wal"
printf 'shm-changed'    > "$LIVE/$DBS/com.plexapp.plugins.library.db-shm"
printf '9999'           > "$LIVE/$PMS/plexmediaserver.pid"
out="$(classify)"
for f in "com.plexapp.plugins.library.db-wal" "com.plexapp.plugins.library.db-shm"; do
  grep -qF "CHURN $DBS/$f" <<< "$out" || fail "$f should be CHURN:
$out"
done
grep -qF "CHURN $PMS/plexmediaserver.pid" <<< "$out" || fail "the pid file should be CHURN:
$out"
grep -q '^CHANGED ' <<< "$out" && fail "sidecars must not produce CHANGED:
$out"
echo "  -wal, -shm and .pid all CHURN"

echo "== 5. LOG ROTATION (a file disappearing) must not be a failure =="
reset_trees
rm -f "${LIVE:?}/${PMS:?}/Logs/Plex Media Server.5.log"
rm -f "${LIVE:?}/${PMS:?}/Logs/PMS Plugin Logs/com.plexapp.system.log.3"
out="$(classify)"
grep -qF "PRUNED $PMS/Logs/Plex Media Server.5.log" <<< "$out" \
  || fail "a rotated log must be PRUNED, not LOST:
$out"
grep -qF "PRUNED $PMS/Logs/PMS Plugin Logs/com.plexapp.system.log.3" <<< "$out" \
  || fail "a rotated plugin log (.log.N) must be PRUNED:
$out"
grep -q '^LOST ' <<< "$out" && fail "log rotation produced a LOST record:
$out"
echo "  rotated logs -> PRUNED, no LOST"

echo "== 6. a DATABASE disappearing IS a failure =="
reset_trees
rm -f "${LIVE:?}/${DBS:?}/com.plexapp.plugins.library.db"
out="$(classify)"
grep -qF "LOST $DBS/com.plexapp.plugins.library.db" <<< "$out" \
  || fail "a vanished database must be LOST:
$out"
rc_out="$(probe "migrate_report_live_tree $(printf '%q' "$SNAP") $(printf '%q' "$LIVE"); echo RC=\$?")"
grep -q 'RC=1' <<< "$rc_out" || fail "migrate_report_live_tree must return 1 on LOST:
$rc_out"
echo "  vanished database -> LOST, reporter returns 1"

echo "== 7. a pruned dated DB BACKUP is surfaced, not silently accepted =="
reset_trees
rm -f "${LIVE:?}/${DBS:?}/com.plexapp.plugins.library.db-2026-09-25"
out="$(classify)"
grep -qF "LOST $DBS/com.plexapp.plugins.library.db-2026-09-25" <<< "$out" \
  || fail "a removed dated backup must be surfaced, not filed as PRUNED:
$out"
echo "  removed dated backup -> LOST (surfaced)"

echo "== 8. SYMLINKS are never followed and never hashed through =="
reset_trees
ln -sfn 'libigc.so.OTHER' "$LIVE/$PMS/Drivers/icr-x-linux-x86_64/libigc.so.2"
out="$(classify)"
grep -q 'libigc.so.2$' <<< "$out" \
  && fail "the classifier reported a symlink; it compares regular files only:
$out"
[ "$(nrec "$out")" = 0 ] || fail "dangling/absolute symlinks produced records:
$out"
probe "migrate_classify_live_tree $(printf '%q' "$SNAP") $(printf '%q' "$LIVE") >/dev/null; echo RC=\$?" \
  | grep -q 'RC=0' || fail "classification failed with a dangling absolute symlink present"
echo "  symlinks produce no records; exit 0 with a dangling /config link"

echo "== 9. an UNEXPECTED new file is surfaced =="
reset_trees
printf 'what is this' > "$LIVE/$PMS/mystery.bin"
printf 'regenerable' > "$LIVE/$PMS/Codecs/libsomething.so"
out="$(classify)"
grep -qF "ADDED $PMS/mystery.bin" <<< "$out" || fail "a new unexplained file must be ADDED:
$out"
grep -qF "CHURN $PMS/Codecs/libsomething.so" <<< "$out" \
  || fail "a downloaded codec should be CHURN:
$out"
echo "  mystery.bin ADDED; new codec CHURN"

echo "== 10. an UNREADABLE file never reads as identical =="
reset_trees
chmod 000 "$LIVE/$DBS/com.plexapp.plugins.library.blobs.db" 2>/dev/null || true
if [ -r "$LIVE/$DBS/com.plexapp.plugins.library.blobs.db" ]; then
  echo "  skipped: this user can read mode-000 files (root)"
else
  out="$(classify)"
  grep -qF "LOST $DBS/com.plexapp.plugins.library.blobs.db" <<< "$out" \
    || fail "an unreadable file must not compare equal; expected LOST:
$out"
  echo "  unreadable -> LOST, never 'identical'"
fi
chmod 644 "$LIVE/$DBS/com.plexapp.plugins.library.blobs.db" 2>/dev/null || true

echo "== 11. the predicate itself, path by path =="
check() {
  local got
  got="$(probe "if migrate_runtime_expected $(printf '%q' "$1"); then echo yes; else echo no; fi")"
  [ "$got" = "$2" ] || fail "migrate_runtime_expected '$1' = $got, expected $2"
}
check "$PMS/Logs/Plex Media Server.2.log"                  yes
check "$PMS/Logs/PMS Plugin Logs/com.plexapp.system.log.3" yes
check "$PMS/plexmediaserver.pid"                           yes
check "$DBS/com.plexapp.plugins.library.db-wal"            yes
check "$DBS/com.plexapp.plugins.library.db-shm"            yes
check "$PMS/Cache/va-dri-linux-x86_64/x.so"                yes
check "$PMS/Codecs/libx.so"                                yes
check "$PMS/Crash Reports/abc.dmp"                         yes
check "$DBS/com.plexapp.plugins.library.db"                no
check "$DBS/com.plexapp.plugins.library.blobs.db"          no
check "$DBS/com.plexapp.plugins.library.db-2026-10-04"     no
check "$PMS/Preferences.xml"                               no
check "$PMS/Drivers/icr-x-linux-x86_64/libigc.so.2.16.0+0" no
echo "  13 paths classified as intended"

echo "== 12. the migration actually CALLS it (call site, not just the function) =="
# Without this, deleting stage 10 from storage_migrate_subvolume leaves every
# test above passing -- measured: that mutant survived until this case existed.
CLI="$REPO_ROOT/bin/domum-media"
mig="$(awk '/^storage_migrate_subvolume\(\) \{/,/^\}/' "$CLI")"
[ -n "$mig" ] || fail "could not isolate storage_migrate_subvolume"
grep -q 'migrate_report_live_tree' <<< "$mig" \
  || fail "storage_migrate_subvolume no longer calls migrate_report_live_tree; stage 10 is gone"
# And it must run AFTER the recovery-point proof, which compares static trees:
# classifying the live tree first would describe a state the proof had not yet
# validated.
rp="$(grep -n 'migrate_verify_recovery_point' <<< "$mig" | tail -1 | cut -d: -f1)"
lt="$(grep -n 'migrate_report_live_tree' <<< "$mig" | head -1 | cut -d: -f1)"
[ -n "$rp" ] && [ -n "$lt" ] || fail "could not locate both stages inside the migration"
[ "$lt" -gt "$rp" ] \
  || fail "stage 10 (relative line $lt) runs BEFORE the recovery-point proof (line $rp)"
echo "  called at relative line $lt, after the recovery-point proof at $rp"
# A LOST file must not be silently swallowed by the summary.
grep -q 'live_ok' <<< "$mig" || fail "the migration does not track the live-tree outcome"
echo "  outcome tracked in live_ok and surfaced in the summary"

echo "PASS: live tree classification smoke test"
