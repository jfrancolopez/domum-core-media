#!/usr/bin/env bash
set -uo pipefail

# A rollback entry decides what gets overwritten. It is root-owned, but it is
# still DATA -- hand-editable, corruptible, and routinely out of date, because
# `snapshot_prune` deletes snapshots on Sundays at 04:30 without touching the
# index. These assertions cover both: what the entry is allowed to name, and
# whether what it names still exists.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CANARY='live-state-that-must-not-be-overwritten'

setup() {
  rm -rf "$TMP_DIR/data" "$TMP_DIR/snapshots" "$TMP_DIR/state"
  mkdir -p "$TMP_DIR/data/plex" "$TMP_DIR/data/immich" \
           "$TMP_DIR/snapshots/plex-20260101-000000-pre-test" \
           "$TMP_DIR/snapshots/immich-20260101-000000-pre-test" \
           "$TMP_DIR/state/rollback"
  printf '%s\n' "$CANARY" > "$TMP_DIR/data/plex/live.db"
  printf 'immich-snapshot-content\n' > "$TMP_DIR/snapshots/immich-20260101-000000-pre-test/x"
}

harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$TMP_DIR/data"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
DOMUM_STATE_ROOT="$TMP_DIR/state"
service_data_path() { printf '%s' "$TMP_DIR/data/\$1"; }
service_compose_services() { printf 'plex'; }
compose_cmd() { :; }
docker() { :; }
EOF
}

# ---------------------------------------------------------------------------
# 1. A snapshot name must be a single path component.
#
# "../data/immich" satisfies a bare [[ -d "$SNAPSHOT_ROOT/$name" ]] test and
# would restore a completely different tree over this service's path.
# ---------------------------------------------------------------------------
setup
out="$( { bash -c "$(harness); restore_snapshot_for_service plex '../data/immich'" ; } 2>&1 )"
rc=$?
(( rc != 0 )) || fail "a traversing snapshot name was accepted: $out"
grep -qi 'not a valid snapshot name' <<< "$out" || fail "the refusal did not explain itself: $out"
[[ "$(cat "$TMP_DIR/data/plex/live.db")" == "$CANARY" ]] \
  || fail "live state was touched by a refused restore"

# ---------------------------------------------------------------------------
# 2. A snapshot must belong to the service being restored.
#
# Restoring immich's snapshot onto plex's path is an operation that would
# otherwise SUCCEED -- both exist, both are directories, nothing complains.
# ---------------------------------------------------------------------------
setup
out="$( { bash -c "$(harness); restore_snapshot_for_service plex 'immich-20260101-000000-pre-test'" ; } 2>&1 )"
rc=$?
(( rc != 0 )) || fail "one service's snapshot was restored onto another's path: $out"
grep -qi 'does not belong to plex' <<< "$out" || fail "the refusal did not name the mismatch: $out"
[[ "$(cat "$TMP_DIR/data/plex/live.db")" == "$CANARY" ]] \
  || fail "live state was touched by a refused restore"

# A correctly-named snapshot must still be accepted, so this is not always-refuse.
setup
out="$( { bash -c "$(harness); restore_snapshot_for_service plex 'plex-20260101-000000-pre-test'" ; } 2>&1 )"
grep -qi 'not a valid snapshot name\|does not belong' <<< "$out" \
  && fail "a correctly named snapshot was rejected by the name guards: $out"

# ---------------------------------------------------------------------------
# 3. `rollback list` must reflect the snapshot store, not a stale field.
#
# snapshot_prune deletes snapshots without updating the index, so entries go on
# advertising "available" while pointing at nothing. The operator picks one and
# finds out at restore time.
# ---------------------------------------------------------------------------
setup
status_of() {
  bash -c "$(harness); rollback_entry_effective_status '$1' '$2'"
}
[[ "$(status_of available plex-20260101-000000-pre-test)" == "available" ]] \
  || fail "an entry whose snapshot exists must read as available"
[[ "$(status_of available plex-19990101-000000-gone)" == "missing" ]] \
  || fail "an entry whose snapshot was pruned must read as missing, not available"
[[ "$(status_of available '../data/immich')" == "invalid" ]] \
  || fail "an entry naming a traversing path must read as invalid"
[[ "$(status_of consumed plex-19990101-000000-gone)" == "consumed" ]] \
  || fail "a non-available status must be reported unchanged"

# ---------------------------------------------------------------------------
# 4. `rollback apply` must enforce exactly what `rollback list` displayed.
# ---------------------------------------------------------------------------
setup
cat > "$TMP_DIR/state/rollback/test-entry.env" <<ENT
ID='test-entry'
SERVICE='plex'
EVENT='test'
SNAPSHOT_NAME='plex-19990101-000000-gone'
TS='1700000000'
STATUS='available'
ENT
out="$( { bash -c "$(harness); rollback_index_dir() { printf '%s' '$TMP_DIR/state/rollback'; }
rollback_apply_entry test-entry" ; } 2>&1 )"
rc=$?
(( rc != 0 )) || fail "a rollback ran against a snapshot that no longer exists: $out"
grep -qi 'not available: missing' <<< "$out" \
  || fail "apply did not refuse for the same reason list would have shown: $out"
[[ "$(cat "$TMP_DIR/data/plex/live.db")" == "$CANARY" ]] \
  || fail "live state was touched by a refused rollback"

# ---------------------------------------------------------------------------
# 5. EVERY reader of the rollback index must use the effective status.
#
# `rollback_entry_effective_status` exists because prune deletes snapshots
# without touching the index. Two of the four readers ignored it:
#
#   - the interactive selector offered pruned entries as menu choices;
#   - `immich rollback` does `| tail -n 1`, so one pruned-but-recorded entry made
#     it pick that entry every time and die "not available: missing" -- permanently
#     unusable, even with older genuinely restorable snapshots present.
#
# Fail-closed, so no data risk -- but a rollback command that cannot be used is
# not a rollback command.
# ---------------------------------------------------------------------------
if grep -nE '\[\[ "\$\{STATUS:-available\}" == "available" \]\]' "$REPO_ROOT/bin/domum-media"; then
  fail "a rollback index reader still tests the RECORDED status instead of the effective one"
fi

# All four readers must go through the helper.
readers="$(grep -c 'rollback_entry_effective_status' "$REPO_ROOT/bin/domum-media")"
(( readers >= 4 )) \
  || fail "expected at least 4 uses of rollback_entry_effective_status (definition + 3 readers), found $readers"

echo "PASS: rollback entry integrity smoke test"
