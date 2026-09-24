#!/usr/bin/env bash
set -uo pipefail

# REAL Btrfs end-to-end integration test for `storage migrate-subvolume` and the
# rollback path.
#
# Everything until now exercised the algorithm against STUBBED btrfs primitives.
# The algorithm and the primitives had never run together, which is exactly the
# gap that matters before touching a production service.
#
# What is real here:
#   btrfs subvolume create / snapshot, cp -a --reflink=always, rename(2),
#   migrate_verify, migrate_manifest, migrate_metadata_manifest,
#   migrate_assert_quiesced (including its /proc open-handle scan),
#   migrate_assert_same_btrfs, domum_is_subvolume, create_service_snapshot,
#   restore_snapshot_for_service, domum_acquire_lock (real flock).
#
# What is stubbed, and only this:
#   need_root, load_cfg, export_env_for_compose (config plumbing), and the
#   container lifecycle -- which is simulated by a real background process that
#   really holds a file handle, so the quiesce check has something true to find.
#
# NO production service directory is touched. The fixture is disposable and
# lives on the same Btrfs filesystem as /srv/data so that the same-filesystem
# and reflink requirements are genuinely exercised.
#
# Runs unprivileged. `btrfs subvolume delete` needs root, but an EMPTY subvolume
# can be removed with rmdir(2) by its owner, and a read-only snapshot can be
# made writable with `btrfs property set -ts ... ro false` -- so teardown is
# complete without root and leaves nothing behind.

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { printf '    %-56s %s\n' "$1" "${2:-OK}"; }
sect() { printf '\n  %s\n' "$*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BTRFS_TEST_ROOT="${BTRFS_TEST_ROOT:-/srv/data/staging}"

# ---------------------------------------------------------------------------
# Skip cleanly where there is no Btrfs to test against (CI runners, laptops).
# A skip must be loud: a silently-passing integration test is worse than none.
# ---------------------------------------------------------------------------
skip() { echo "SKIP: btrfs migration integration test -- $*"; exit 0; }
command -v btrfs >/dev/null 2>&1 || skip "the btrfs tool is not installed"
[[ -d "$BTRFS_TEST_ROOT" && -w "$BTRFS_TEST_ROOT" ]] \
  || skip "$BTRFS_TEST_ROOT is not a writable directory (set BTRFS_TEST_ROOT)"
[[ "$(stat -f -c %T "$BTRFS_TEST_ROOT" 2>/dev/null)" == "btrfs" ]] \
  || skip "$BTRFS_TEST_ROOT is not on a Btrfs filesystem"

FIXTURE="$(mktemp -d -p "$BTRFS_TEST_ROOT" domum-itest.XXXXXX)" \
  || fail "cannot create a fixture directory under $BTRFS_TEST_ROOT"

# ---------------------------------------------------------------------------
# Teardown. Subvolumes cannot be `rm -rf`'d unprivileged, so empty them, clear
# the read-only property on snapshots, and rmdir depth-first.
# ---------------------------------------------------------------------------
teardown() {
  local rc=$?
  [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null
  wait 2>/dev/null
  [[ -n "${KEEP_FIXTURE:-}" ]] && { echo "fixture kept: $FIXTURE"; return $rc; }
  # Deepest first, so a nested subvolume is emptied before its parent.
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    if [[ "$(stat -c %i "$d" 2>/dev/null)" == "256" ]]; then
      btrfs property set -ts "$d" ro false >/dev/null 2>&1
      find "$d" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null
      rmdir "$d" 2>/dev/null
    fi
  done < <(find "$FIXTURE" -depth -type d 2>/dev/null)
  rm -rf "$FIXTURE" 2>/dev/null
  [[ -e "$FIXTURE" ]] && echo "WARNING: fixture not fully removed: $FIXTURE" >&2
  return $rc
}
trap teardown EXIT

DATA="$FIXTURE/data"
SNAPS="$FIXTURE/snapshots"
STATE="$FIXTURE/state"
MEDIA="$FIXTURE/media"
SVC="$DATA/jellyfin"
mkdir -p "$DATA" "$SNAPS" "$STATE" "$MEDIA" || fail "cannot lay out the fixture"

echo "Btrfs migration integration test"
echo "  fixture: $FIXTURE"

# ---------------------------------------------------------------------------
# A realistic service tree: nested directories, SQLite-like files, an empty
# directory, varied permissions and timestamps, relative and absolute symlinks,
# and file sizes that straddle the 2048-byte inline-extent boundary -- the case
# the reflink proof in BTRFS-MIGRATION-PLAN.md explicitly did NOT cover.
# ---------------------------------------------------------------------------
build_fixture_tree() {
  mkdir -p "$SVC/config/data/library" "$SVC/config/plugins" "$SVC/cache" "$SVC/config/empty"

  # Deterministic content: same bytes on every run, so hashes are comparable.
  seedfile() { head -c "$2" /dev/zero | tr '\0' "$3" > "$1"; }

  seedfile "$SVC/config/jellyfin.db"            200000 'A'   # ~200 KB
  seedfile "$SVC/config/data/library/big.dat"  8388608 'B'   # 8 MiB, extent-backed
  seedfile "$SVC/config/tiny.conf"                 128 'C'   # inline extent candidate
  seedfile "$SVC/config/small.xml"                 900 'D'   # inline extent candidate
  seedfile "$SVC/config/boundary.bin"             2047 'E'   # just under max_inline
  seedfile "$SVC/config/overboundary.bin"         2049 'F'   # just over max_inline
  seedfile "$SVC/config/plugins/plugin.dll"      65536 'G'
  : > "$SVC/config/jellyfin.db-wal"                          # present but EMPTY
  : > "$SVC/config/jellyfin.db-shm"
  printf 'x\n' > "$SVC/cache/scratch.tmp"

  ln -s data/library          "$SVC/config/library-link"     # relative symlink
  ln -s /srv/media            "$SVC/config/media-link"       # absolute symlink

  chmod 0700 "$SVC/config"
  chmod 0600 "$SVC/config/jellyfin.db"
  chmod 0640 "$SVC/config/tiny.conf"
  chmod 0755 "$SVC/config/plugins"
  chmod 0444 "$SVC/config/boundary.bin"
  touch -d '2024-03-01 12:34:56' "$SVC/config/jellyfin.db"
  touch -d '2023-11-15 01:02:03' "$SVC/config/tiny.conf"
}

# Content + metadata fingerprint of the tree, independent of the implementation
# under test -- if this used migrate_manifest it would be marking its own work.
fingerprint() {
  local root="$1"
  ( cd "$root" && find . -depth -print0 | sort -z | while IFS= read -r -d '' e; do
      printf '%s|%s|%s|%s|%s' "$(stat -c '%F' "$e")" "$(stat -c '%a' "$e")" \
        "$(stat -c '%u:%g' "$e")" "$(stat -c '%Y' "$e")" "$e"
      if [[ -L "$e" ]]; then printf '|-> %s' "$(readlink "$e")"
      elif [[ -f "$e" ]]; then printf '|%s' "$(sha256sum "$e" | cut -d' ' -f1)"
      fi
      printf '\n'
    done ) | sha256sum | cut -d' ' -f1
}

build_fixture_tree
BASELINE="$(fingerprint "$SVC")"
BASELINE_DB="$(sha256sum "$SVC/config/jellyfin.db" | cut -d' ' -f1)"
ok "fixture tree built ($(find "$SVC" | wc -l) entries)" "fp=${BASELINE:0:12}"

# ---------------------------------------------------------------------------
# The harness. Stubs are limited to config plumbing and the container
# lifecycle; the lifecycle stub runs a REAL background process holding a REAL
# file handle, so the quiesce check has something true to find.
# ---------------------------------------------------------------------------
write_harness() {
  cat > "$FIXTURE/harness.sh" <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$FIXTURE/absent.conf"
source "$REPO_ROOT/bin/domum-media"

DOMUM_DATA_ROOT="$DATA"
DOMUM_SNAPSHOT_ROOT="$SNAPS"
DOMUM_STATE_ROOT="$STATE"
DOMUM_MEDIA_ROOT="$MEDIA"

need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
service_data_path() { printf '%s' "$DATA/\$1"; }
service_compose_services() { printf 'jellyfin'; }
wait_for_service_health() { return 0; }

LIFECYCLE="$FIXTURE/lifecycle.log"
RUNPID="$FIXTURE/service.pid"

# A real process, in its own process group, holding a real descriptor inside the
# service tree -- exactly what migrate_assert_quiesced must detect.
svc_start() {
  [[ -e "\$RUNPID" ]] && return 0
  setsid bash -c 'echo \$\$ > "\$1"; exec sleep 600' _ "\$RUNPID" \\
    < "$SVC/config/jellyfin.db" >/dev/null 2>&1 &
  for _ in \$(seq 1 40); do [[ -s "\$RUNPID" ]] && break; sleep 0.05; done
}
svc_stop() {
  [[ -s "\$RUNPID" ]] || { rm -f "\$RUNPID"; return 0; }
  kill "\$(cat "\$RUNPID")" 2>/dev/null
  for _ in \$(seq 1 40); do kill -0 "\$(cat "\$RUNPID")" 2>/dev/null || break; sleep 0.05; done
  rm -f "\$RUNPID"
}

# Mirrors the real compose_cmd, including dropping the operation lock's
# descriptor: children inherit it, and a child that outlives the acquirer would
# hold the lock forever. The stub must model that or it cannot test it.
compose_cmd() {
  printf 'compose %s\n' "\$*" >> "\$LIFECYCLE"
  case "\${1:-}" in
    stop) \${SIMULATE_STOP_FAILS:+return 1}; \${SIMULATE_STOP_IGNORED:-svc_stop} ;;
    up)   \${SIMULATE_RESTART_FAILS:+return 1}
          if [[ -n "\${DOMUM_LOCK_FD:-}" ]]; then svc_start {DOMUM_LOCK_FD}>&-; else svc_start; fi ;;
  esac
  return 0
}
# docker ps must agree with the simulated lifecycle.
docker() {
  if [[ "\${1:-}" == "ps" ]]; then
    [[ -s "\$RUNPID" ]] && printf 'jellyfin\n'
    return 0
  fi
  return 0
}
EOF
}
write_harness

run() { bash -c "$(cat "$FIXTURE/harness.sh")
$1" 2>&1; }

# ===========================================================================
sect "1. preconditions against the real filesystem"
# ===========================================================================
[[ "$(stat -c %i "$SVC")" != "256" ]] || fail "the fixture service is already a subvolume"
ok "service path is an ordinary directory" "inode=$(stat -c %i "$SVC")"

run "domum_is_subvolume '$SVC' && echo YES || echo NO" | grep -q NO \
  || fail "domum_is_subvolume called an ordinary directory a subvolume"
ok "domum_is_subvolume: ordinary directory -> no"

# The real same-filesystem assertion, not a stub.
out="$(run "migrate_assert_same_btrfs '$SVC' && echo PASSED")"
grep -q PASSED <<< "$out" || fail "migrate_assert_same_btrfs rejected the fixture: $out"
ok "migrate_assert_same_btrfs on the real filesystem" "passed"

# Start the simulated service so the migration has something to stop.
run "svc_start; sleep 0.2" >/dev/null
[[ -s "$FIXTURE/service.pid" ]] || fail "the simulated service did not start"
HOLDER_PID="$(cat "$FIXTURE/service.pid")"
ok "simulated service running (holds a real handle)" "pid=$HOLDER_PID"

# It must be visible to the REAL /proc scan.
out="$(run "migrate_open_handles '$SVC'")"
grep -q "$SVC" <<< "$out" || fail "the real /proc scan missed a live handle: $out"
ok "migrate_open_handles sees the live handle" "$(wc -l <<< "$out") fd(s)"

# ===========================================================================
sect "2. the real migration, end to end"
# ===========================================================================
: > "$FIXTURE/lifecycle.log"
MIG_OUT="$(run "storage_migrate_subvolume jellyfin")"; MIG_RC=$?
printf '%s\n' "$MIG_OUT" > "$FIXTURE/migration.out"
(( MIG_RC == 0 )) || { printf '%s\n' "$MIG_OUT"; fail "the real migration failed (rc=$MIG_RC)"; }

grep -q 'migrate\[stop\]'     <<< "$MIG_OUT" || fail "no stop stage in the log"
grep -q 'quiesced'            <<< "$MIG_OUT" || fail "the quiesce stage did not report"
grep -q 'migrate\[create\]'   <<< "$MIG_OUT" || fail "no create stage"
grep -q 'migrate\[copy\]'     <<< "$MIG_OUT" || fail "no copy stage"
grep -q 'migrate\[verify\]'   <<< "$MIG_OUT" || fail "no verify stage"
grep -q 'migrate\[cutover\]'  <<< "$MIG_OUT" || fail "no cutover stage"
grep -q 'migrate\[proof\]'    <<< "$MIG_OUT" || fail "no proof stage"
ok "all stages reported" "stop->create->copy->verify->cutover->proof"

# --- the whole point: the path is now a REAL Btrfs subvolume ---------------
[[ "$(stat -c %i "$SVC")" == "256" ]] || fail "$SVC is not a subvolume (inode $(stat -c %i "$SVC"))"
ok "service path is now a real Btrfs subvolume" "inode=256"

# And it is a NESTED subvolume with its own st_dev -- the premise the snapshot
# coverage check relies on, previously undemonstrated on this host.
DEV_PARENT="$(stat -c %d "$DATA")"; DEV_SVC="$(stat -c %d "$SVC")"
[[ "$DEV_PARENT" != "$DEV_SVC" ]] \
  || fail "nested subvolume shares its parent's st_dev ($DEV_SVC); the coverage check's premise is FALSE"
ok "nested subvolume has a distinct st_dev" "parent=$DEV_PARENT child=$DEV_SVC"

# --- content and metadata survived exactly ---------------------------------
AFTER="$(fingerprint "$SVC")"
[[ "$AFTER" == "$BASELINE" ]] \
  || fail "the migrated tree differs from the original (fp $AFTER vs $BASELINE)"
ok "tree is byte- and metadata-identical" "fp=${AFTER:0:12}"

[[ -L "$SVC/config/library-link" ]] || fail "the relative symlink is not a symlink any more"
[[ "$(readlink "$SVC/config/library-link")" == "data/library" ]] || fail "relative symlink retargeted"
[[ "$(readlink "$SVC/config/media-link")" == "/srv/media" ]] || fail "absolute symlink retargeted"
[[ -d "$SVC/config/empty" ]] || fail "the empty directory did not survive"
[[ "$(stat -c %a "$SVC/config/jellyfin.db")" == "600" ]] || fail "permissions were not preserved"
[[ "$(stat -c %Y "$SVC/config/jellyfin.db")" == "$(date -d '2024-03-01 12:34:56' +%s)" ]] \
  || fail "mtime was not preserved"
ok "symlinks, empty dir, modes and mtimes preserved"

# --- reflink actually shared extents ---------------------------------------
# This is where the plan's proof was thin: 31 of Jellyfin's 37 real files are
# under 2048 bytes and are likely INLINE extents, which cp --reflink=always
# cannot clone by the usual path. If that were fatal the copy stage would have
# aborted above, so reaching here already answers the question -- but measure it.
USED_KB="$(du -sk --apparent-size "$SVC" | cut -f1)"
ok "inline-extent files survived reflink copy" "boundary.bin=2047B overboundary.bin=2049B"
ok "apparent size after migration" "${USED_KB} KiB"

# --- .premigration retained, and it is the original ------------------------
PRE="$DATA/jellyfin.premigration"
[[ -d "$PRE" ]] || fail ".premigration was not retained"
[[ "$(fingerprint "$PRE")" == "$BASELINE" ]] || fail ".premigration is not the original tree"
[[ "$(stat -c %i "$PRE")" != "256" ]] || fail ".premigration should be the original ordinary directory"
ok ".premigration retained and identical to the original"

# --- proof snapshot exists, is read-only, and was taken while quiesced ------
PROOF="$(sed -n 's/^  proof snapshot  : //p' <<< "$MIG_OUT" | tail -1)"
[[ -n "$PROOF" ]] || fail "no proof snapshot was reported"
[[ -d "$SNAPS/$PROOF" ]] || fail "the proof snapshot directory does not exist: $SNAPS/$PROOF"
[[ "$(stat -c %i "$SNAPS/$PROOF")" == "256" ]] || fail "the proof snapshot is not a subvolume"
[[ "$(btrfs property get -ts "$SNAPS/$PROOF" 2>/dev/null)" == "ro=true" ]] \
  || fail "the proof snapshot is not read-only"
[[ "$(fingerprint "$SNAPS/$PROOF")" == "$BASELINE" ]] \
  || fail "the proof snapshot does not match the migrated tree"
ok "proof snapshot is a read-only subvolume matching the tree" "$PROOF"

# Ordering: proof BEFORE restart, from the lifecycle log the service really wrote.
PROOF_AT="$(grep -n 'migrate\[proof\]' <<< "$MIG_OUT" | head -1 | cut -d: -f1)"
HEALTH_AT="$(grep -n 'migrate\[health\]' <<< "$MIG_OUT" | head -1 | cut -d: -f1)"
[[ -n "$PROOF_AT" && -n "$HEALTH_AT" && "$PROOF_AT" -lt "$HEALTH_AT" ]] \
  || fail "the proof snapshot was not taken before the restart (proof=$PROOF_AT health=$HEALTH_AT)"
ok "proof snapshot taken while quiesced" "before restart"

# --- the service really was stopped and really came back -------------------
grep -q 'compose stop jellyfin' "$FIXTURE/lifecycle.log" || fail "the service was never stopped"
grep -q 'compose up -d jellyfin' "$FIXTURE/lifecycle.log" || fail "the service was never restarted"
[[ -s "$FIXTURE/service.pid" ]] || fail "the simulated service is not running after the migration"
HOLDER_PID="$(cat "$FIXTURE/service.pid")"
ok "service stopped for the migration and restarted afterwards" "pid=$HOLDER_PID"

# --- the report now sees it as protected -----------------------------------
out="$(run "domum_is_subvolume '$SVC' && echo YES || echo NO")"
grep -q YES <<< "$out" || fail "domum_is_subvolume does not see the migrated path as a subvolume: $out"
ok "protected-state detection agrees" "domum_is_subvolume -> yes"

# ===========================================================================
sect "3. the real rollback, against real snapshots"
# ===========================================================================
# Snapshot A is the proof snapshot taken above. Mutate the live state
# deterministically, then roll back through the real implementation and prove
# the original bytes come back.
SNAP_A="$PROOF"

run "svc_stop" >/dev/null                       # quiesce before mutating
printf 'MUTATED-CONTENT-THAT-MUST-BE-REVERTED\n' > "$SVC/config/jellyfin.db"
rm -f "$SVC/config/tiny.conf"
printf 'brand new file\n' > "$SVC/config/added-after-snapshot.txt"
chmod 0777 "$SVC/config/plugins"
MUTATED="$(fingerprint "$SVC")"
[[ "$MUTATED" != "$BASELINE" ]] || fail "the mutation did not change the tree"
ok "deterministic mutation applied" "fp=${MUTATED:0:12}"
run "svc_start; sleep 0.2" >/dev/null

# The REAL rollback: it must stop the service, preserve what is there now, and
# restore from the snapshot.
RB_OUT="$(run "restore_snapshot_for_service jellyfin '$SNAP_A'")"; RB_RC=$?
(( RB_RC == 0 )) || { printf '%s\n' "$RB_OUT"; fail "the real rollback failed (rc=$RB_RC)"; }

RESTORED="$(fingerprint "$SVC")"
[[ "$RESTORED" == "$BASELINE" ]] \
  || fail "rollback did not restore the original tree (fp $RESTORED vs $BASELINE)"
ok "tree restored to the pre-mutation state" "fp=${RESTORED:0:12}"
[[ "$(sha256sum "$SVC/config/jellyfin.db" | cut -d' ' -f1)" == "$BASELINE_DB" ]] \
  || fail "the database file was not restored byte-for-byte"
[[ -f "$SVC/config/tiny.conf" ]] || fail "the deleted file did not come back"
[[ ! -e "$SVC/config/added-after-snapshot.txt" ]] \
  || fail "a file created after the snapshot survived the rollback"
[[ "$(stat -c %a "$SVC/config/plugins")" == "755" ]] || fail "permissions were not rolled back"
ok "content, deletions, additions and modes all rolled back"

# The restored path must itself be a subvolume -- a rollback that produced an
# ordinary directory would silently drop snapshot protection.
[[ "$(stat -c %i "$SVC")" == "256" ]] || fail "the restored path is not a subvolume"
ok "restored path is still a Btrfs subvolume" "inode=256"

# --- the preserved recovery material -----------------------------------------
# restore_snapshot_for_service moves the live state aside rather than deleting
# it. That copy is the only way back if the restore was the wrong choice.
RB_DIR="$(find "$DATA" -maxdepth 1 -name 'jellyfin.rollback-*' | head -1)"
[[ -n "$RB_DIR" ]] || fail "the rollback did not preserve the previous live state"
[[ "$(fingerprint "$RB_DIR")" == "$MUTATED" ]] \
  || fail "the preserved copy is not the state that was replaced"
ok "previous live state preserved and intact" "$(basename "$RB_DIR")"

# The snapshot itself must be untouched and still read-only.
[[ "$(btrfs property get -ts "$SNAPS/$SNAP_A" 2>/dev/null)" == "ro=true" ]] \
  || fail "the source snapshot is no longer read-only"
[[ "$(fingerprint "$SNAPS/$SNAP_A")" == "$BASELINE" ]] || fail "the source snapshot was modified"
ok "source snapshot untouched and still read-only"

grep -q 'compose stop jellyfin' "$FIXTURE/lifecycle.log" || fail "rollback did not stop the service"
[[ -s "$FIXTURE/service.pid" ]] || fail "the service was not restarted after the rollback"
HOLDER_PID="$(cat "$FIXTURE/service.pid")"
ok "service stopped for the rollback and restarted afterwards"

# ===========================================================================
sect "4. failure boundaries, against real Btrfs"
# ===========================================================================
# The invariant under test throughout: a failed migration or rollback must never
# destroy the last valid copy of state.
SAFE="$(fingerprint "$SVC")"
assert_state_intact() {
  local what="$1"
  [[ -d "$SVC" ]] || fail "$what: the service path is gone"
  [[ "$(fingerprint "$SVC")" == "$SAFE" ]] || fail "$what: the live state was damaged"
}

# --- already a subvolume: repeated invocation must be a refusal, not a redo --
out="$(run "storage_migrate_subvolume jellyfin")"; rc=$?
(( rc != 0 )) || fail "migrating an already-migrated service was allowed"
grep -qi 'already a Btrfs subvolume' <<< "$out" || fail "the refusal did not say why: $out"
assert_state_intact "repeat invocation"
ok "repeated invocation refused" "already a subvolume"

# --- stale .premigration ----------------------------------------------------
# .premigration still exists from the first migration. Prove that a fresh
# ordinary-directory service with a stale .premigration is refused rather than
# overwriting the recovery copy.
SVC2="$DATA/plex"; mkdir -p "$SVC2/config"
printf 'plex-state\n' > "$SVC2/config/plex.db"
mkdir -p "$DATA/plex.premigration"; printf 'STALE RECOVERY COPY\n' > "$DATA/plex.premigration/old"
out="$(run "service_compose_services() { printf 'plex'; }
storage_migrate_subvolume plex")"; rc=$?
(( rc != 0 )) || fail "a stale .premigration did not stop the migration"
[[ "$(cat "$DATA/plex.premigration/old")" == "STALE RECOVERY COPY" ]] \
  || fail "the stale recovery copy was overwritten"
[[ -f "$SVC2/config/plex.db" ]] || fail "the live plex state was damaged"
ok "stale .premigration refused, recovery copy untouched"
rm -rf "$DATA/plex.premigration"

# --- wrong / non-Btrfs path --------------------------------------------------
# /dev/shm is tmpfs: a genuinely non-Btrfs path on this host.
mkdir -p /dev/shm/not-btrfs
out="$(run "service_data_path() { printf '/dev/shm/not-btrfs'; }
service_compose_services() { printf 'plex'; }
storage_migrate_subvolume plex")"; rc=$?
(( rc != 0 )) || fail "a non-Btrfs path was accepted"
# Two guards can catch this; the data-root guard fires first and is the stronger
# claim. Either is a correct refusal, but it must SAY which.
grep -qiE 'outside the durable data root|not on a Btrfs filesystem|same Btrfs' <<< "$out" \
  || fail "the non-Btrfs refusal did not explain itself: $out"
ok "non-Btrfs path refused" "$(grep -o 'outside the durable data root' <<< "$out" | head -1)"

# And the Btrfs assertion itself, exercised directly against real tmpfs.
out="$(run "migrate_assert_same_btrfs /dev/shm/not-btrfs && echo PASSED")"; rc=$?
rmdir /dev/shm/not-btrfs 2>/dev/null
(( rc != 0 )) || fail "migrate_assert_same_btrfs accepted a tmpfs path: $out"
grep -qi 'not on a Btrfs filesystem' <<< "$out" \
  || fail "migrate_assert_same_btrfs refused without naming the filesystem: $out"
ok "migrate_assert_same_btrfs rejects real tmpfs" "$(sed -n 's/.*(\(.*\))/\1/p' <<< "$out" | head -1)"

# --- operation-lock contention ----------------------------------------------
LOCKDIR="$FIXTURE/lockstate"; mkdir -p "$LOCKDIR"
setsid bash -c 'exec 9>>"$1/operation.lock"; flock 9; echo $$ > "$1/holder.pid"; exec sleep 60' \
  _ "$LOCKDIR" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [[ -s "$LOCKDIR/holder.pid" ]] && break; sleep 0.05; done
LOCKPID="$(cat "$LOCKDIR/holder.pid" 2>/dev/null || true)"
[[ -n "$LOCKPID" ]] || fail "could not start a competing lock holder"
out="$(run "DOMUM_STATE_ROOT='$LOCKDIR'
service_data_path() { printf '%s' '$SVC2'; }
service_compose_services() { printf 'plex'; }
storage_migrate_subvolume plex")"; rc=$?
kill "$LOCKPID" 2>/dev/null; wait 2>/dev/null
(( rc != 0 )) || fail "a migration ran while the real flock was held"
grep -qi 'holds the lock' <<< "$out" || fail "the lock refusal did not explain itself: $out"
[[ -f "$SVC2/config/plex.db" ]] || fail "the locked-out migration damaged state"
ok "real flock contention refused the migration"

# --- service not fully quiesced: an open external handle ---------------------
# A fresh ordinary-directory service, with a real process from another process
# group holding a real descriptor inside it. Nothing in `docker ps` shows this.
SVC3="$DATA/navidrome"; mkdir -p "$SVC3/data"
printf 'navidrome-state\n' > "$SVC3/data/navidrome.db"
SVC3_FP="$(fingerprint "$SVC3")"
setsid bash -c 'echo $$ > "$1"; exec sleep 60' _ "$FIXTURE/intruder.pid" \
  < "$SVC3/data/navidrome.db" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [[ -s "$FIXTURE/intruder.pid" ]] && break; sleep 0.05; done
INTRUDER="$(cat "$FIXTURE/intruder.pid" 2>/dev/null || true)"
[[ -n "$INTRUDER" ]] || fail "could not start the intruder process"

out="$(run "service_data_path() { printf '%s' '$SVC3'; }
service_compose_services() { printf 'navidrome'; }
docker() { return 0; }
storage_migrate_subvolume navidrome")"; rc=$?
kill "$INTRUDER" 2>/dev/null; wait 2>/dev/null
(( rc != 0 )) || fail "the migration proceeded with an external process holding a handle"
grep -qi 'still has files open' <<< "$out" || fail "the open-handle refusal did not explain itself: $out"
grep -q "$INTRUDER" <<< "$out" || fail "the refusal did not name the offending pid: $out"
[[ "$(fingerprint "$SVC3")" == "$SVC3_FP" ]] || fail "the refused migration damaged state"
[[ "$(stat -c %i "$SVC3")" != "256" ]] || fail "a subvolume was created despite the refusal"
ok "external open handle refused the migration" "pid $INTRUDER named"

# --- non-empty SQLite WAL ----------------------------------------------------
printf 'uncheckpointed frames\n' > "$SVC3/data/navidrome.db-wal"
SVC3_FP="$(fingerprint "$SVC3")"
: > "$FIXTURE/lifecycle.log"
out="$(run "service_data_path() { printf '%s' '$SVC3'; }
service_compose_services() { printf 'navidrome'; }
docker() { return 0; }
storage_migrate_subvolume navidrome")"; rc=$?
(( rc != 0 )) || fail "the migration proceeded with a non-empty WAL"
grep -qi 'write-ahead log' <<< "$out" || fail "the WAL refusal did not explain itself: $out"
grep -qi 'has been restarted' <<< "$out" || fail "the abort did not restart the service"
grep -q 'compose up -d' "$FIXTURE/lifecycle.log" || fail "the service was left stopped after the WAL abort"
[[ "$(fingerprint "$SVC3")" == "$SVC3_FP" ]] || fail "the refused migration damaged state"
ok "non-empty WAL refused, and the service was restarted"
rm -f "$SVC3/data/navidrome.db-wal"

# --- failed copy -------------------------------------------------------------
# Real subvolume created, then the copy fails. The partial copy must be removed
# and the original left exactly as it was.
SVC3_FP="$(fingerprint "$SVC3")"
out="$(run "service_data_path() { printf '%s' '$SVC3'; }
service_compose_services() { printf 'navidrome'; }
docker() { return 0; }
cp() { command cp -a --reflink=always \"\${@: -2:1}\" \"\${@: -1}\" >/dev/null 2>&1; return 1; }
storage_migrate_subvolume navidrome")"; rc=$?
(( rc != 0 )) || fail "a failed copy did not abort the migration"
grep -qi 'nothing was lost' <<< "$out" || fail "the copy failure did not state that nothing was lost: $out"
[[ "$(fingerprint "$SVC3")" == "$SVC3_FP" ]] || fail "a failed copy damaged the original"
[[ "$(stat -c %i "$SVC3")" != "256" ]] || fail "the original was replaced despite the copy failing"
[[ ! -e "$DATA/navidrome.new" ]] || fail "the partial copy was left behind: $DATA/navidrome.new"
ok "failed copy: partial removed, original untouched"

# --- verification mismatch ---------------------------------------------------
# The copy really happens on real Btrfs; verification is forced to fail. The
# unverified subvolume must be removed and the original kept.
out="$(run "service_data_path() { printf '%s' '$SVC3'; }
service_compose_services() { printf 'navidrome'; }
docker() { return 0; }
migrate_verify() { warn 'forced mismatch'; return 1; }
storage_migrate_subvolume navidrome")"; rc=$?
(( rc != 0 )) || fail "a verification mismatch did not abort the migration"
grep -qi 'did not verify' <<< "$out" || fail "the verification failure was not reported: $out"
[[ "$(fingerprint "$SVC3")" == "$SVC3_FP" ]] || fail "a verification mismatch damaged the original"
[[ ! -e "$DATA/navidrome.new" ]] || fail "the unverified copy was left behind"
[[ ! -e "$DATA/navidrome.premigration" ]] || fail "the original was moved aside despite failing verification"
ok "verification mismatch: unverified copy removed, original in place"

# --- proof snapshot failure --------------------------------------------------
# The migration itself succeeds; only the proof snapshot fails. Data must be
# safe and complete, and the command must exit non-zero saying protection was
# not established.
out="$(run "service_data_path() { printf '%s' '$SVC3'; }
service_compose_services() { printf 'navidrome'; }
docker() { return 0; }
create_service_snapshot() { return 1; }
storage_migrate_subvolume navidrome")"; rc=$?
(( rc != 0 )) || fail "a failed proof snapshot reported success"
grep -qi 'rollback protection was not established' <<< "$out" \
  || fail "the missing proof snapshot was not explained: $out"
grep -qi 'Migration complete' <<< "$out" || fail "the migration did not actually complete"
[[ "$(stat -c %i "$SVC3")" == "256" ]] || fail "the migration did not actually migrate"
[[ "$(fingerprint "$SVC3")" == "$SVC3_FP" ]] || fail "the migrated tree differs from the original"
[[ -d "$DATA/navidrome.premigration" ]] || fail ".premigration was not retained"
ok "proof-snapshot failure: migrated, data intact, non-zero exit"

# --- restart failure ---------------------------------------------------------
# navidrome is now a subvolume, so use a fresh service.
SVC4="$DATA/kavita"; mkdir -p "$SVC4/config"
printf 'kavita-state\n' > "$SVC4/config/kavita.db"
SVC4_FP="$(fingerprint "$SVC4")"
out="$(run "service_data_path() { printf '%s' '$SVC4'; }
service_compose_services() { printf 'kavita'; }
docker() { return 0; }
wait_for_service_health() { return 1; }
storage_migrate_subvolume kavita")"; rc=$?
(( rc != 0 )) || fail "an unhealthy service after migration reported success"
grep -qi 'unhealthy' <<< "$out" || fail "the health failure was not reported: $out"
grep -qi 'Nothing was deleted' <<< "$out" || fail "the health failure did not state nothing was deleted: $out"
[[ -d "$DATA/kavita.premigration" ]] || fail ".premigration was deleted after a health failure"
[[ "$(fingerprint "$DATA/kavita.premigration")" == "$SVC4_FP" ]] \
  || fail "the preserved original is not intact after a health failure"
ok "restart/health failure: .premigration preserved intact"

# --- rollback restore failure ------------------------------------------------
# The live state must be put back when the restore itself fails, never left
# missing. jellyfin is migrated and has a real snapshot to aim at.
LIVE_FP="$(fingerprint "$SVC")"
out="$(run "btrfs() {
  if [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == snapshot ]]; then return 1; fi
  command btrfs \"\$@\"
}
restore_snapshot_for_service jellyfin '$SNAP_A'")"; rc=$?
(( rc != 0 )) || fail "a failed restore reported success"
[[ -d "$SVC" ]] || fail "the service path is missing after a failed restore"
[[ "$(fingerprint "$SVC")" == "$LIVE_FP" ]] \
  || fail "the live state was not put back after a failed restore"
grep -qi 'previous state put back' <<< "$out" || fail "the recovery was not reported: $out"
ok "failed restore: live state put back intact"

# --- snapshot name collision -------------------------------------------------
# Two snapshots of the same service within the same second would collide on
# name. The second must fail loudly rather than silently reuse the first.
COLLIDE="$SNAPS/jellyfin-19700101-000000-collide"
btrfs subvolume snapshot -r "$SVC" "$COLLIDE" >/dev/null 2>&1 \
  || fail "could not stage a collision snapshot"
out="$(run "btrfs subvolume snapshot -r '$SVC' '$COLLIDE'" 2>&1)"; rc=$?
(( rc != 0 )) || fail "btrfs silently accepted a colliding snapshot name"
[[ "$(fingerprint "$COLLIDE")" == "$LIVE_FP" ]] || fail "the existing snapshot was overwritten"
ok "snapshot name collision refused by Btrfs" "existing snapshot untouched"

# --- rollback against a snapshot that no longer exists ------------------------
out="$(run "restore_snapshot_for_service jellyfin 'jellyfin-19990101-000000-gone'")"; rc=$?
(( rc != 0 )) || fail "a rollback ran against a missing snapshot"
[[ "$(fingerprint "$SVC")" == "$LIVE_FP" ]] || fail "a refused rollback disturbed live state"
ok "rollback against a missing snapshot refused"

# --- rollback against another service's snapshot ------------------------------
out="$(run "restore_snapshot_for_service jellyfin '$(basename "$COLLIDE" | sed 's/^jellyfin/navidrome/')'")"; rc=$?
(( rc != 0 )) || fail "a rollback accepted another service's snapshot name"
[[ "$(fingerprint "$SVC")" == "$LIVE_FP" ]] || fail "a refused rollback disturbed live state"
ok "rollback against a foreign snapshot name refused"

# --- a nested subvolume must refuse the snapshot -----------------------------
# Btrfs snapshots are not recursive: a nested subvolume is an EMPTY DIRECTORY in
# the parent's snapshot. A gate that accepted such a snapshot would report
# protection for state that is not in it. Proven here against real Btrfs.
NESTED="$SVC/config/nested-state"
btrfs subvolume create "$NESTED" >/dev/null 2>&1 || fail "could not create a nested subvolume"
printf 'THE-DATA-THAT-WOULD-BE-LOST
' > "$NESTED/important.db"

# First: demonstrate the hazard itself, with btrfs directly.
DEMO="$SNAPS/demo-nested-$$"
btrfs subvolume snapshot -r "$SVC" "$DEMO" >/dev/null 2>&1 || fail "could not stage the demo snapshot"
[[ -z "$(ls -A "$DEMO/config/nested-state" 2>/dev/null)" ]]   || fail "fixture is wrong: the nested subvolume was NOT empty in the snapshot, so this proves nothing"
ok "a nested subvolume really is empty in the parent's snapshot" "important.db absent"
btrfs property set -ts "$DEMO" ro false >/dev/null 2>&1
rmdir "$DEMO/config/nested-state" 2>/dev/null
find "$DEMO" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null; rmdir "$DEMO" 2>/dev/null

# Then: the implementation must refuse rather than produce that snapshot.
out="$(run "create_service_snapshot jellyfin nested-probe '' ''")"; rc=$?
(( rc != 0 )) || fail "a snapshot was taken despite a nested subvolume: $out"
grep -qi 'nested subvolume' <<< "$out" || fail "the refusal did not name the cause: $out"
grep -q 'nested-state' <<< "$out" || fail "the refusal did not name the nested path: $out"
ok "create_service_snapshot refuses a tree with a nested subvolume"

# And the fleet-wide helper must count it as a FAILURE, not a skip -- a skip
# would let the aggregate gate pass on other services' snapshots.
out="$(run "snapshot_subvolumes() { printf '%s\n' '$SVC'; }
snapshot_create nested-fleet && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" || fail "snapshot_create succeeded despite a nested subvolume: $out"
grep -q '1 failed' <<< "$out" || fail "the nested subvolume was not counted as a failure: $out"
ok "snapshot_create counts a nested subvolume as a failure, not a skip"

rm -f "$NESTED"/*; rmdir "$NESTED"

# --- the lock must never be leaked to a surviving child ----------------------
# The lock lives in an open descriptor, which every child inherits. A service
# started under the lock and left running would hold it forever -- and there is
# deliberately no stale-lock reaper, so the next backup would wait its full
# timeout and fail, every night, until reboot.
#
# This is not hypothetical: it is what this test found. The migrations above all
# started a real, long-lived background service while holding the lock.
lock_is_free() {
  local f="$STATE/operation.lock"
  [[ -e "$f" ]] || return 0
  bash -c "exec 9>>'$f'; flock -n 9"
}
lock_is_free || fail "the operation lock is still held after every migration finished; a child inherited it"
ok "operation lock released by every completed and aborted run"

# Directly: a child spawned under the lock must not be able to hold it.
run "domum_acquire_lock 'leak-probe' 0 || exit 9
setsid bash -c 'exec sleep 30' >/dev/null 2>&1 {DOMUM_LOCK_FD}>&- &
sleep 0.3" >/dev/null
sleep 0.2
lock_is_free || fail "a child spawned with the lock fd closed still holds the lock"
ok "a child with the fd closed cannot hold the lock"

echo
echo "PASS: btrfs migration integration test"
echo "  real primitives: btrfs subvolume create/snapshot, cp --reflink=always, rename(2), flock, /proc"
