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

# ---------------------------------------------------------------------------
# 5. Retention can never leave a service with ZERO recovery points.
#
# `drop=$(( total - keep ))` is honest arithmetic, and that is the hazard. With
# the first real service migrated, /srv/snapshots holds exactly ONE Jellyfin
# snapshot -- so a keep of 0, or a negative or non-numeric value, would have had
# the Sunday timer delete the only recovery point that service has. Measured
# against the real snapshot_prune before the fix:
#
#   keep=14   start=1  left=1     the default and the shipped example: safe
#   keep=0    start=1  left=0     the only recovery point, gone
#   keep=-5   start=1  left=0     gone, and rc=1
#
# A RETENTION job must never zero a service. Deliberate wholesale removal is
# `cleanup snapshots --confirm`, which is attended and asks.
# ---------------------------------------------------------------------------
keep_probe() {  # $1 = configured value, $2 = snapshots to seed -> prints survivors
  rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin "$2"
  bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL='$1'
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune" >/dev/null 2>&1
  ls -1 "$TMP_DIR/snapshots" 2>/dev/null | wc -l
}

for bad in 0 -5 fourteen " "; do
  got="$(keep_probe "$bad" 1)"
  (( got >= 1 )) \
    || fail "SNAPSHOT_KEEP_PER_SUBVOL='$bad' left $got snapshots; retention must never zero a service"
done
# A malformed value must not make the weekly timer fail forever: it must warn,
# fall back to the default, and still prune correctly. The floor alone cannot do
# this -- bash arithmetic on "14abc" is an error, which under `set -e` aborts the
# run and leaves retention unapplied every single week.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL='14abc'
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune" 2>&1)"
rc=$?
(( rc == 0 )) || fail "a malformed SNAPSHOT_KEEP_PER_SUBVOL made the prune fail outright: $out"
grep -qi 'not a non-negative integer' <<< "$out" \
  || fail "a malformed retention value was not reported: $out"
[[ "$(ls -1 "$TMP_DIR/snapshots" | wc -l)" == "14" ]] \
  || fail "a malformed value did not fall back to the default retention of 14"

# The cleanup path must go through the same validation, not its own arithmetic.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
n="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=0
CLEANUP_OLD_SNAPSHOTS_KEEP=0
cleanup_snapshot_candidates" 2>/dev/null | grep -c . || true)"
(( n <= 19 )) \
  || fail "cleanup proposed deleting all $n snapshots; it must leave at least one recovery point"
# Both knobs are validated, and the effective value is the larger of the two, so
# a bad value in either alone is absorbed. That redundancy is deliberate -- but it
# means neither is independently killable, so the assertion here is that with BOTH
# at zero the floor still holds.
(( n >= 1 )) || fail "cleanup proposed nothing to delete from 20 snapshots; the fixture is wrong"

# ...and a sane value is honoured exactly, so the floor did not become a ceiling.
[[ "$(keep_probe 14 20)" == "14" ]] || fail "keep=14 of 20 should leave 14, got $(keep_probe 14 20)"
[[ "$(keep_probe 3 20)"  == "3"  ]] || fail "keep=3 of 20 should leave 3, got $(keep_probe 3 20)"
[[ "$(keep_probe 14 1)"  == "1"  ]] || fail "keep=14 of 1 should leave 1 untouched"

# ---------------------------------------------------------------------------
# 6. One service's snapshots must never count toward another's retention.
#
# The stamp extraction was unanchored, so the glob "jellyfin-*" also matched
# "jellyfin-extra-20260301-000000-c". With a tight keep, prune would have deleted
# jellyfin's REAL snapshots while preserving the other service's. Not reachable
# with today's names -- none is a "-"-prefix of another -- but adding plex-hd or
# immich-ml would arm it silently.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; mkdir -p "$TMP_DIR/snapshots"
for n in jellyfin-20260101-000000-a jellyfin-20260201-000000-b \
         jellyfin-extra-20260301-000000-c jellyfin-extra-20260401-000000-d \
         calibre-web-20260501-000000-e; do
  mkdir -p "$TMP_DIR/snapshots/$n"
done
listed() { bash -c "$(harness)
list_snapshots_for_base '$1'" 2>/dev/null | tr '\n' ' '; }

got="$(listed jellyfin)"
[[ "$got" == *jellyfin-20260101* && "$got" == *jellyfin-20260201* ]] \
  || fail "base 'jellyfin' lost its own snapshots: $got"
[[ "$got" != *jellyfin-extra* ]] \
  || fail "base 'jellyfin' claimed another service's snapshots: $got"
[[ "$got" != *calibre-web* ]] || fail "base 'jellyfin' claimed calibre-web snapshots: $got"

got="$(listed jellyfin-extra)"
[[ "$got" == *jellyfin-extra-20260301* ]] || fail "base 'jellyfin-extra' lost its own snapshots: $got"
[[ "$got" != *"jellyfin-20260101"* ]] || fail "base 'jellyfin-extra' claimed jellyfin snapshots: $got"

# A name with no timestamp at all is announced; a name belonging to another base
# is silently skipped. Conflating those two produced noise on every listing.
mkdir -p "$TMP_DIR/snapshots/jellyfin-handmade"
err="$(bash -c "$(harness)
list_snapshots_for_base jellyfin" 2>&1 >/dev/null)"
grep -q 'jellyfin-handmade' <<< "$err" \
  || fail "a name with no timestamp was not announced: $err"
grep -q 'jellyfin-extra' <<< "$err" \
  && fail "another base's snapshot was reported as unrecognised; that is noise: $err"

echo "PASS: snapshot prune safety smoke test"
