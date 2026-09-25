#!/usr/bin/env bash
set -uo pipefail

# `domum-media snapshot prune` DELETES snapshots, and its timer is enabled and
# runs weekly (Sun 04:30 +20m).
#
# It has never actually deleted anything: while no service path was a subvolume
# the snapshot root stayed empty. The first migration turns it into a live
# deleting job -- which is exactly the moment its safety properties start to
# matter.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
DOMUM_STATE_ROOT="$TMP_DIR/state"
# Needed so latest_snapshot_for_service can resolve a service to its snapshot
# base name through the real service_data_path, rather than being stubbed.
DOMUM_DATA_ROOT="$TMP_DIR/data"
need_root() { :; }
load_cfg() { :; }
EOF
}

# Names carry a real, monotonically increasing -YYYYMMDD-HHMMSS- stamp, and the
# DIRECTORY MTIMES ARE DELIBERATELY IDENTICAL -- which is what real Btrfs
# produces, because `btrfs subvolume snapshot` copies the source subvolume root
# mtime into the snapshot. Measured on this host:
#
#   1790343086   s-20260101-000000-old
#   1790343087   s-20260601-000000-mid
#   1790343086   s-20261231-235959-newest     <- taken last, after a rollback
#
# The previous fixture used `touch -d "... +$i minutes"` to fabricate exactly the
# monotonic mtimes real Btrfs does not provide, so it validated -- and actively
# pinned -- an ordering key that cannot work.
seed_snapshots() {  # $1 = base, $2 = count
  local base="$1" n="$2" i d
  mkdir -p "$TMP_DIR/snapshots"
  for (( i = 1; i <= n; i++ )); do
    d="$TMP_DIR/snapshots/$(printf '%s-2026%02d%02d-%02d0000-tag' "$base" \
        "$(( ((i - 1) / 28) + 1 ))" "$(( ((i - 1) % 28) + 1 ))" "$(( i % 24 ))")"
    mkdir -p "$d"
    touch -d "2026-01-01 00:00:00" "$d"
  done
}

# ---------------------------------------------------------------------------
# 1. Prune deletes the OLDEST, never the newest.
#
# The newest snapshot is the one a rollback is most likely to want. Deleting
# from the wrong end would quietly destroy the freshest recovery point while
# reporting a clean run.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
# By NAME, not `ls -1t`: the mtimes are identical on purpose, so an mtime-ordered
# listing would pick an arbitrary entry and these assertions would be meaningless.
newest="$(ls -1 "$TMP_DIR/snapshots" | sort | tail -1)"
oldest="$(ls -1 "$TMP_DIR/snapshots" | sort | head -1)"
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "prune failed on a clean fixture: $out"

[[ -d "$TMP_DIR/snapshots/$newest" ]] || fail "prune deleted the NEWEST snapshot: $newest"
[[ ! -d "$TMP_DIR/snapshots/$oldest" ]] || fail "prune did not delete the oldest snapshot: $oldest"
remaining="$(ls -1 "$TMP_DIR/snapshots" | wc -l)"
(( remaining == 14 )) || fail "prune left $remaining snapshots, expected 14"
grep -q '6 deleted, 0 failed' <<< "$out" || fail "prune did not report what it did: $out"

# ---------------------------------------------------------------------------
# 1b. The rollback hazard, directly.
#
# After a rollback the live subvolume is recreated from an OLD snapshot and
# inherits its mtime, so the NEXT snapshot -- the newest recovery point there is
# -- carries an ancient mtime. Ordered by mtime it sorts near the front, and
# prune deletes `snaps[0..drop-1]`: it would delete the newest recovery point
# while keeping older ones. Measured on real Btrfs; see list_snapshots_for_base.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
rollback_newest="$TMP_DIR/snapshots/jellyfin-20261231-235959-post-rollback"
mkdir -p "$rollback_newest"
touch -d "2020-01-01 00:00:00" "$rollback_newest"     # inherited an ancient mtime
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "prune failed with a rollback-style snapshot present: $out"
[[ -d "$rollback_newest" ]] \
  || fail "prune deleted the NEWEST snapshot because its mtime was the oldest; ordering must key on the name timestamp, not mtime"

# ...and latest_snapshot_for_service must name it, not the one with the newest mtime.
latest="$(bash -c "$(harness)
latest_snapshot_for_service jellyfin" 2>/dev/null)"
[[ "$latest" == "jellyfin-20261231-235959-post-rollback" ]] \
  || fail "latest_snapshot_for_service named [$latest] instead of the genuinely newest snapshot"

# A snapshot whose name carries no timestamp must be excluded, not ordered
# arbitrarily: it would otherwise be pruned first (deleting something this code
# did not create) or reported as the latest snapshot.
mkdir -p "$TMP_DIR/snapshots/jellyfin-handmade"
out="$(bash -c "$(harness)
list_snapshots_for_base jellyfin" 2>&1)"
grep -q 'unrecognised name' <<< "$out" \
  || fail "a snapshot with an unparseable name was not announced: $out"
grep -q '^jellyfin-handmade$' <<< "$out" \
  && fail "a snapshot with an unparseable name was included in the ordered list"
rm -rf "$TMP_DIR/snapshots/jellyfin-handmade"

# ---------------------------------------------------------------------------
# 2. A failed delete must be reported and must fail the run.
#
# `|| true` meant the snapshot root silently never converged on the retention
# policy while the weekly unit reported success.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
# Warnings go to stderr, as they should -- capture both streams.
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { return 1; }
snapshot_prune" 2>&1)"
rc=$?
(( rc != 0 )) || fail "a prune whose deletes all failed reported success: $out"
grep -qi 'Could not delete snapshot' <<< "$out" || fail "the failed delete was not reported: $out"
grep -q '0 deleted, 6 failed' <<< "$out" || fail "the failure count was not reported: $out"
(( $(ls -1 "$TMP_DIR/snapshots" | wc -l) == 20 )) || fail "snapshots vanished despite delete failing"

# ---------------------------------------------------------------------------
# 3. Prune and snapshot-create take the operation lock.
#
# A rollback checks its snapshot exists and then creates from it. A prune
# landing between those two steps turns a routine restore into a failure.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "snapshot prune"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot prune does not take the operation lock"
grep -q 'domum_acquire_lock "snapshot create"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot create does not take the operation lock"

# Both must WAIT rather than fail: they run unattended from timers, and giving
# up would silently skip a week.
grep -q 'domum_acquire_lock "snapshot prune" "${SNAPSHOT_LOCK_WAIT_SECONDS:-900}"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot prune must wait for the lock, not fail immediately"

# And it must actually refuse while the lock is held.
mkdir -p "$TMP_DIR/lockstate" "$TMP_DIR/snapshots"
setsid bash -c 'exec 9>>"$1/operation.lock"; flock 9; echo $$ > "$1/holder.pid"; exec sleep 30' \
  _ "$TMP_DIR/lockstate" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [[ -s "$TMP_DIR/lockstate/holder.pid" ]] && break; sleep 0.05; done
holder="$(cat "$TMP_DIR/lockstate/holder.pid" 2>/dev/null || true)"
[[ -n "$holder" ]] || fail "could not start a competing lock holder"
out="$(bash -c "$(harness)
DOMUM_STATE_ROOT='$TMP_DIR/lockstate'
SNAPSHOT_LOCK_WAIT_SECONDS=1
btrfs() { return 0; }
snapshot_cmd prune" 2>&1)"
rc=$?
kill "$holder" 2>/dev/null; wait 2>/dev/null
(( rc != 0 )) || fail "prune ran while the operation lock was held: $out"
grep -qi 'Timed out waiting' <<< "$out" || fail "the lock refusal did not explain itself: $out"

# ---------------------------------------------------------------------------
# 4. `cleanup snapshots` is a SECOND snapshot deleter. It must take the lock and
#    share one retention policy.
#
#    It was the only snapshot deleter without the lock, and it defaulted to
#    CLEANUP_OLD_SNAPSHOTS_KEEP, which the shipped example config set to 7 while
#    SNAPSHOT_KEEP_PER_SUBVOL is 14 -- so it deleted seven more snapshots per
#    service than the retention policy, including ones the weekly prune had
#    deliberately kept.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "cleanup snapshots"' "$REPO_ROOT/bin/domum-media" \
  || fail "cleanup snapshots does not take the operation lock"

# Retention can only be raised, never lowered -- asserted through the real
# candidate selection, not by re-deriving the arithmetic in the test.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
candidates_for() {  # $1 = SNAPSHOT_KEEP_PER_SUBVOL, $2 = CLEANUP_OLD_SNAPSHOTS_KEEP
  bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=$1
CLEANUP_OLD_SNAPSHOTS_KEEP=$2
cleanup_snapshot_candidates" 2>/dev/null | grep -c . || true
}
got="$(candidates_for 14 7)"
[[ "$got" == "6" ]] \
  || fail "with policy 14 and cleanup 7, cleanup must still keep 14 of 20 (6 candidates), got $got"
got="$(candidates_for 14 30)"
[[ "$got" == "0" ]] \
  || fail "with cleanup 30, nothing may be a candidate out of 20, got $got"
got="$(candidates_for 5 5)"
[[ "$got" == "15" ]] \
  || fail "with both set to 5, 15 of 20 must be candidates, got $got"

# And the shipped example must not configure the two knobs to disagree.
pol="$(grep -E '^SNAPSHOT_KEEP_PER_SUBVOL=' "$REPO_ROOT/config/domum-media.conf.example" | cut -d= -f2)"
cln="$(grep -E '^CLEANUP_OLD_SNAPSHOTS_KEEP=' "$REPO_ROOT/config/domum-media.conf.example" | cut -d= -f2)"
[[ -n "$pol" && -n "$cln" && "$cln" -ge "$pol" ]] \
  || fail "the example config sets CLEANUP_OLD_SNAPSHOTS_KEEP=$cln below SNAPSHOT_KEEP_PER_SUBVOL=$pol"

echo "PASS: snapshot prune safety smoke test"
