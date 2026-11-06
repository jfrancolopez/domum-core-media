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

# ---------------------------------------------------------------------------
# The interactive selector offers a numbered menu and then APPLIES the choice,
# which restores a snapshot over live state. Two defects, both in the arithmetic
# rather than in the restore.
# ---------------------------------------------------------------------------
echo "== 0 is refused, because to bash it is the LAST entry and not out of range =="
# Measured: `${arr[-1]}` is the last element since bash 4.3, so $((0 - 1)) ==
# -1 selected the newest rollback point -- and the emptiness check passed,
# because the value is not empty. Only the LOW end was broken, which is why the
# guard looked sufficient.
setup
for i in 1 2 3; do
  cat > "$TMP_DIR/state/rollback/plex-2026010${i}-000000.env" <<EOF
ID='plex-2026010${i}-000000'
SERVICE='plex'
EVENT='upgrade'
SNAPSHOT='$TMP_DIR/snapshots/plex-20260101-000000-pre-test'
SNAPSHOT_NAME='plex-20260101-000000-pre-test'
STATUS='available'
EOF
done

select_probe() {  # $1 = what the operator types -> output of the selector
  {
    harness
    printf 'need_root() { :; }\n'
    printf 'load_cfg() { :; }\n'
    printf 'export_env_for_compose() { :; }\n'
    printf 'ensure_state_dirs() { :; }\n'
    # The applier is RECORDED, not run: this section is about which entry the
    # selector picks, and running a real restore would prove something else.
    printf 'rollback_apply_entry() { echo "APPLIED:$1"; }\n'
    printf 'rollback_cmd interactive <<< %q\n' "$1"
  } > "$TMP_DIR/sel.sh"
  bash "$TMP_DIR/sel.sh" 2>&1
}

out="$(select_probe 0)"
grep -q 'APPLIED:' <<< "$out" \
  && fail "typing 0 applied a rollback point: $out"
grep -q 'out of range' <<< "$out" \
  || fail "typing 0 was not refused with a range message: $out"
grep -qE 'choose 1 to 3' <<< "$out" \
  || fail "the refusal does not state the valid range: $out"
echo "  refused, and the range is stated"

echo "== a valid choice still selects the entry at that position =="
# The fix must not refuse legitimate input. 1 and the last are the boundaries.
out="$(select_probe 1)"
grep -q 'APPLIED:plex-20260101-000000' <<< "$out" \
  || fail "choice 1 did not select the first entry: $out"
out="$(select_probe 3)"
grep -q 'APPLIED:plex-20260103-000000' <<< "$out" \
  || fail "choice 3 did not select the third entry: $out"
out="$(select_probe 4)"
grep -q 'APPLIED:' <<< "$out" && fail "choice 4 applied something: $out"
echo "  1 and 3 select, 4 is refused"

echo "== an entry that names NO snapshot does not inherit the previous entry's =="
# Both rollback loops read SNAPSHOT_NAME and SNAPSHOT without unsetting them,
# so an entry lacking the keys was judged against whatever the PREVIOUS entry
# named -- and these loops exist precisely to keep an unusable entry out of the
# menu. Demonstrated directly, because the writer always emits the keys today:
# the live case is an older-format, hand-written or truncated entry.
leak_probe() {
  {
    printf 'set -uo pipefail\n'
    printf 'files=(%q %q)\n' "$TMP_DIR/leak-a.env" "$TMP_DIR/leak-b.env"
    # Exactly the loop body shape, with the CLI's own unset list.
    printf 'for f in "${files[@]}"; do\n'
    printf '  %s\n' "$1"
    printf '  . "$f"\n'
    printf '  printf "%%s SNAPSHOT_NAME=%%s\\n" "$ID" "${SNAPSHOT_NAME:-<none>}"\n'
    printf 'done\n'
  } > "$TMP_DIR/leak.sh"
  bash "$TMP_DIR/leak.sh" 2>&1
}
cat > "$TMP_DIR/leak-a.env" <<'EOF'
ID='entry-a'
SERVICE='plex'
STATUS='available'
SNAPSHOT_NAME='plex-snapshot-A'
EOF
cat > "$TMP_DIR/leak-b.env" <<'EOF'
ID='entry-b'
SERVICE='jellyfin'
STATUS='available'
EOF
# The old, incomplete list leaks; the shipped one must not.
old_out="$(leak_probe 'unset ID SERVICE EVENT STATUS')"
grep -q 'entry-b SNAPSHOT_NAME=plex-snapshot-A' <<< "$old_out" \
  || fail "the fixture does not reproduce the leak, so this section proves nothing: $old_out"
new_out="$(leak_probe 'unset ID SERVICE EVENT STATUS SNAPSHOT SNAPSHOT_NAME')"
grep -q 'entry-b SNAPSHOT_NAME=<none>' <<< "$new_out" \
  || fail "the complete unset still leaks: $new_out"
echo "  the incomplete list leaks and the shipped one does not"

echo "== both rollback loops unset every key their body reads =="
# Asserted on the CLI itself, so a future loop cannot reintroduce it.
for fn in rollback_cmd immich_cmd; do
  body="$(awk "/^${fn}\\(\\) \\{/,/^\\}/" "$REPO_ROOT/bin/domum-media")"
  [ -n "$body" ] || fail "$fn not found"
  code="$(grep -vE '^\s*#' <<< "$body" || true)"
  # Every `unset` that precedes a source of a rollback entry must cover the
  # snapshot keys, because the effective-status check reads both.
  while IFS= read -r line; do
    case "$line" in
      *"unset ID"*)
        grep -qF 'SNAPSHOT_NAME' <<< "$line" \
          || fail "$fn: '$line' does not unset SNAPSHOT_NAME, so an entry
lacking it inherits the previous entry's snapshot"
        grep -qF 'SNAPSHOT ' <<< "$line " \
          || fail "$fn: '$line' does not unset SNAPSHOT" ;;
    esac
  done <<< "$code"
done
echo "  both loops unset SNAPSHOT and SNAPSHOT_NAME"

echo "== MUTATION: without the range check, 0 applies the newest point again =="
# Neutralise the COMPARISON rather than deleting the line, and never `&& false`
# inside (( )) or [[ ]]. The observable is that typing 0 reaches the applier.
mut_cli="$TMP_DIR/cli-mut"
cp "$REPO_ROOT/bin/domum-media" "$mut_cli"
python3 - "$mut_cli" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '      (( choice >= 1 && choice <= ${#snapshots[@]} )) \\\n        || die "Selection out of range: choose 1 to ${#snapshots[@]}."\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PYMUT
grep -qF 'choose 1 to' "$mut_cli" \
  && fail "the range-check mutation did not apply"
mut_select() {  # $1 = typed input, using the MUTANT cli
  {
    harness | sed "s|source \"$REPO_ROOT/bin/domum-media\"|source \"$mut_cli\"|"
    printf 'need_root() { :; }\nload_cfg() { :; }\n'
    printf 'export_env_for_compose() { :; }\nensure_state_dirs() { :; }\n'
    printf 'rollback_apply_entry() { echo "APPLIED:$1"; }\n'
    printf 'rollback_cmd interactive <<< %q\n' "$1"
  } > "$TMP_DIR/sel-mut.sh"
  grep -qF "source \"$mut_cli\"" "$TMP_DIR/sel-mut.sh" \
    || fail "the harness was not repointed at the mutant"
  bash "$TMP_DIR/sel-mut.sh" 2>&1
}
out="$(mut_select 0)"
grep -q 'APPLIED:plex-20260103-000000' <<< "$out" \
  || fail "the mutation changed no ANSWER -- without the range check, typing 0
must select the LAST entry and reach the applier: $out"
echo "  killed: the mutant applies the newest point when 0 is typed"

echo "PASS: rollback entry integrity smoke test"
