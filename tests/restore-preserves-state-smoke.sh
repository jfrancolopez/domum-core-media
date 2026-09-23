#!/usr/bin/env bash
set -uo pipefail

# Proves that restoring a snapshot never destroys live state before the
# replacement exists, and puts it back if the restore fails.
#
# Exercises the real restore_snapshot_for_service with btrfs stubbed, so the
# ordinary-directory case (the current production condition) is covered.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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
service_data_path() { printf '%s' "$TMP_DIR/data/\$1"; }
service_compose_services() { printf 'plex'; }
compose_cmd() { :; }
is_btrfs_subvol() { return 1; }
EOF
}

setup() {
  rm -rf "$TMP_DIR/data" "$TMP_DIR/snapshots"
  mkdir -p "$TMP_DIR/data/plex" "$TMP_DIR/snapshots/plex-snap"
  printf 'LIVE DATA THAT MUST NOT BE LOST\n' > "$TMP_DIR/data/plex/important.db"
  printf 'RESTORED\n' > "$TMP_DIR/snapshots/plex-snap/important.db"
}

# ---------------------------------------------------------------------------
# 1. A successful restore must preserve the previous state, not delete it.
# ---------------------------------------------------------------------------
setup
out="$(bash -c "$(harness)
# btrfs subvolume snapshot [-r] SRC DST -- take the last two arguments so the
# stub works whether or not -r is present.
btrfs() { cp -a \"\${@: -2:1}\" \"\${!#}\"; }
restore_snapshot_for_service plex plex-snap" 2>&1)" || fail "1: a working restore should succeed: $out"

[ -f "$TMP_DIR/data/plex/important.db" ] || fail "1: nothing was restored"
grep -q RESTORED "$TMP_DIR/data/plex/important.db" || fail "1: the snapshot content was not restored"
preserved="$(find "$TMP_DIR/data" -maxdepth 1 -name 'plex.rollback-*' | head -1)"
[ -n "$preserved" ] || fail "1: the previous state was not preserved"
grep -q 'LIVE DATA' "$preserved/important.db" \
  || fail "1: the preserved copy does not contain the original live data"
grep -q 'Preserved current state' <<< "$out" || fail "1: the preserved location was not reported"
grep -q 'remove it once satisfied' <<< "$out" \
  || fail "1: the operator was not told the previous state is being kept"

# ---------------------------------------------------------------------------
# 2. A FAILED restore must put the live state back, not leave the service empty.
# ---------------------------------------------------------------------------
setup
out="$(bash -c "$(harness)
btrfs() { return 1; }
restore_snapshot_for_service plex plex-snap" 2>&1)"
[ -n "$out" ] || fail "2: a failed restore produced no output"

[ -d "$TMP_DIR/data/plex" ] || fail "2: the live state was not put back after a failed restore"
grep -q 'LIVE DATA' "$TMP_DIR/data/plex/important.db" \
  || fail "2: the data put back is not the original live data"
[ -z "$(find "$TMP_DIR/data" -maxdepth 1 -name 'plex.rollback-*')" ] \
  || fail "2: the preserved copy should have been moved back, not left behind"
grep -qi 'previous state put back' <<< "$out" || fail "2: the recovery was not reported"

# ---------------------------------------------------------------------------
# 3. Live state must never be deleted outright.
# ---------------------------------------------------------------------------
fn="$(awk '/^restore_snapshot_for_service\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
[ -n "$fn" ] || fail "3: could not extract restore_snapshot_for_service"

# The only rm may be the one that clears a partial restore during recovery, and
# it must be guarded by holding a preserved copy.
# Ignore comments: the code is commented with the very construct being counted.
code_only="$(grep -vE '^[[:space:]]*#' <<< "$fn")"
rm_lines="$(grep -c 'rm -rf' <<< "$code_only" || true)"
[ "$rm_lines" -le 1 ] || fail "3: more than one rm -rf in the restore path ($rm_lines)"
if [ "$rm_lines" -eq 1 ]; then
  grep -q 'current_backup' <<< "$(grep -B4 'rm -rf' <<< "$code_only")" \
    || fail "3: the rm -rf is not guarded by holding a preserved copy"
fi

# The old asymmetric branch must not come back.
grep -qE 'elif \[\[ -e "\$data_path" \]\]; then' <<< "$fn" \
  && fail "3: the branch that deleted an ordinary directory has returned"

grep -q 'mv -- "$data_path" "$current_backup"' <<< "$fn" \
  || fail "3: live state must be moved aside rather than deleted"

echo "PASS: restore preserves state smoke test"
