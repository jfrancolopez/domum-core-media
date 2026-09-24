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
need_root() { :; }
load_cfg() { :; }
EOF
}

seed_snapshots() {  # $1 = base, $2 = count
  local base="$1" n="$2" i
  mkdir -p "$TMP_DIR/snapshots"
  for (( i = 1; i <= n; i++ )); do
    local d
    d="$TMP_DIR/snapshots/$(printf '%s-2026%02d01-000000-tag' "$base" "$(( (i % 12) + 1 ))")-$i"
    mkdir -p "$d"
    touch -d "2026-01-01 00:00:00 +$i minutes" "$d"
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
newest="$(ls -1t "$TMP_DIR/snapshots" | head -1)"
oldest="$(ls -1t "$TMP_DIR/snapshots" | tail -1)"
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

echo "PASS: snapshot prune safety smoke test"
