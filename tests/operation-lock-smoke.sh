#!/usr/bin/env bash
set -uo pipefail

# Proves that state-mutating operations cannot run concurrently, and that the
# lock cannot silently stop working.
#
# The hazard: the nightly backup fires at 02:30 (+15m jitter) and reads all of
# /srv/data with no exclude for .new / .premigration / .rollback-*. A migration
# renaming directories underneath restic makes the backup fail for a reason
# nobody can see the next morning.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v flock >/dev/null 2>&1 || fail "flock is required for this test"

# ---------------------------------------------------------------------------
# 1. The helper is byte-identical in both scripts.
#
# It is deliberately duplicated rather than sourced from a new file. That trade
# is only safe while the two copies agree: if they ever computed different lock
# paths the scripts would take different locks, exclude nothing, and fail
# silently -- the worst possible failure for a lock. This repository has already
# shipped one bug of exactly that shape (two `backup_target_names` with
# divergent defaults), so it is pinned here.
# ---------------------------------------------------------------------------
extract_helper() {
  awk '/^# BEGIN SHARED LOCK HELPER$/,/^# END SHARED LOCK HELPER$/' "$1"
}
a="$(extract_helper "$REPO_ROOT/bin/domum-media")"
b="$(extract_helper "$REPO_ROOT/bin/domum-media-backup")"
[[ -n "$a" ]] || fail "bin/domum-media has no shared lock helper"
[[ -n "$b" ]] || fail "bin/domum-media-backup has no shared lock helper"
[[ "$a" == "$b" ]] || {
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") >&2
  fail "the lock helper has drifted between the two scripts"
}

# Both must resolve the same lock path for the same state root.
for script in domum-media domum-media-backup; do
  got="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$(extract_helper "$REPO_ROOT/bin/$script")
domum_lock_file")"
  [[ "$got" == "$TMP_DIR/state/operation.lock" ]] \
    || fail "$script resolved an unexpected lock path: $got"
done

# ---------------------------------------------------------------------------
# 2. The lock actually excludes.
# ---------------------------------------------------------------------------
lock_helper="$(extract_helper "$REPO_ROOT/bin/domum-media")"

# Holder: takes the lock, then waits for a file to appear before exiting.
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'holder-op' 0 || exit 9
touch '$TMP_DIR/held'
while [[ ! -e '$TMP_DIR/release' ]]; do sleep 0.05; done
" &
holder_pid=$!
for _ in $(seq 1 100); do [[ -e "$TMP_DIR/held" ]] && break; sleep 0.05; done
[[ -e "$TMP_DIR/held" ]] || fail "the holder never acquired the lock"

# A second attempt with no wait must fail immediately.
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'second-op' 0
" && fail "a second operation acquired the lock while it was held"

# ...and must be able to say who holds it.
holder="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_lock_holder")"
grep -q 'holder-op' <<< "$holder" || fail "the holder was not reported: $holder"

# A bounded wait that expires must also fail, rather than proceeding.
start=$(date +%s)
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'waiter-op' 1
" && fail "a waiting operation acquired a lock that was never released"
(( $(date +%s) - start >= 1 )) || fail "the bounded wait did not actually wait"

# ---------------------------------------------------------------------------
# 3. Releasing is automatic. The lock lives in a file descriptor, so a process
#    that is SIGKILLed -- leaving no chance to clean up -- must not wedge the
#    system. A lock scheme that needs a stale-lock reaper becomes the outage.
# ---------------------------------------------------------------------------
kill -9 "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
touch "$TMP_DIR/release"

ok=0
for _ in $(seq 1 100); do
  if bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'after-kill' 0"; then ok=1; break; fi
  sleep 0.05
done
(( ok == 1 )) || fail "the lock was not released when the holder was SIGKILLed"

# ---------------------------------------------------------------------------
# 4. The operations that need the lock actually take it.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "storage migrate-subvolume' "$REPO_ROOT/bin/domum-media" \
  || fail "storage migrate-subvolume does not take the operation lock"
grep -q 'domum_acquire_lock "rollback apply' "$REPO_ROOT/bin/domum-media" \
  || fail "rollback apply does not take the operation lock"
grep -q 'domum_acquire_lock "daily backup"' "$REPO_ROOT/bin/domum-media-backup" \
  || fail "the daily backup does not take the operation lock"

# The unattended backup must WAIT; the attended operations must not. A backup
# that gave up would silently skip a night, which is what the lock exists to
# prevent.
grep -q 'domum_acquire_lock "daily backup" "${BACKUP_LOCK_WAIT_SECONDS:-1800}"' \
  "$REPO_ROOT/bin/domum-media-backup" \
  || fail "the daily backup must wait for the lock, not fail immediately"

echo "PASS: operation lock smoke test"
