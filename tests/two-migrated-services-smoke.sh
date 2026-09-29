#!/usr/bin/env bash
set -uo pipefail

# What changes when a SECOND service becomes a subvolume.
#
# Every defect this project has found around the migration has the same shape: an
# assumption that was harmless while nothing was a subvolume, and wrong the moment
# one is. The second migration arms a different set: assumptions that were
# harmless while exactly ONE service was a subvolume.
#
# Written BEFORE Kavita is migrated, deliberately. Discovering a two-service
# assumption afterwards means discovering it in production.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA="$TMP_DIR/data"
SNAPS="$TMP_DIR/snapshots"

# Both services are REAL directories and `find` is real. Only subvolume-ness is
# stubbed (inode 256 needs root and btrfs; there is none writable here or in CI),
# from an explicit list, so "jellyfin is a subvolume and kavita is not" and "both
# are" are both expressible.
harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$DATA"
DOMUM_SNAPSHOT_ROOT="$SNAPS"
DOMUM_STATE_ROOT="$TMP_DIR/state"
DOMUM_MEDIA_ROOT="$TMP_DIR/media"
need_root() { :; }
load_cfg() { :; }
domum_is_subvolume() { grep -qFx -- "\$(basename -- "\$1")" <<< "\$SUBVOLS"; }
is_btrfs_subvol()   { domum_is_subvolume "\$1"; }
path_is_subvolume() { domum_is_subvolume "\$1"; }
domum_subvolume_nested_children() { :; }
subvolume_nested_children() { :; }
EOF
}

run() {  # $1 = subvolume basenames, $2 = script
  bash -c "$(harness)
SUBVOLS='$1'
$2" 2>&1
}

seed() {  # $1 = base, $2 = count -- snapshots with real, increasing name stamps
  local base="$1" n="$2" i d
  mkdir -p "$SNAPS"
  for (( i = 1; i <= n; i++ )); do
    d="$SNAPS/$(printf '%s-2026%02d%02d-%02d0000-post-migration' "$base" \
        "$(( ((i - 1) / 28) + 1 ))" "$(( ((i - 1) % 28) + 1 ))" "$(( i % 24 ))")"
    mkdir -p "$d"
    # Identical mtimes, which is what real Btrfs produces: `btrfs subvolume
    # snapshot` copies the SOURCE subvolume root's mtime.
    touch -d "2026-01-01 00:00:00" "$d"
  done
}

BOTH='jellyfin
kavita'

mkdir -p "$DATA/jellyfin" "$DATA/kavita" "$DATA/plex" "$SNAPS"

# ---------------------------------------------------------------------------
# 1. The topology names both, and two identical captures still compare equal.
#    A deployment must not abort because a SECOND service was migrated, for the
#    same reason it must not abort because a first one was.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 1; seed kavita 1
cap="$TMP_DIR/cap"
run "$BOTH" "storage_topology" > "$cap"
[[ "$(grep -c '^subvolume ' "$cap")" == "2" ]] || fail "1: expected 2 subvolumes: $(cat "$cap")"
[[ "$(grep -c '^snapshot ' "$cap")" == "2" ]] || fail "1: expected 2 snapshots: $(cat "$cap")"
grep -q "^subvolume $DATA/kavita\$" "$cap" || fail "1: kavita is not listed: $(cat "$cap")"
grep -q "^subvolume $DATA/plex\$" "$cap" && fail "1: plex is not a subvolume but was listed"
out="$(run "$BOTH" "storage_topology_verify '$cap'")"; rc=$?
(( rc == 0 )) || fail "1: two migrated services reported a spurious change (rc=$rc): $out"
grep -q '2 subvolume(s), 2 snapshot(s)' <<< "$out" || fail "1: counts wrong: $out"

# ---------------------------------------------------------------------------
# 2. Retention is per service, in ONE prune run.
#
# jellyfin over the limit and kavita under it, pruned together: jellyfin comes
# down to the limit and kavita is not touched. A shared counter would have
# deleted from whichever list the loop reached first.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 20; seed kavita 3
out="$(run "$BOTH" "SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "2: prune failed: $out"
j="$(ls -1 "$SNAPS" | grep -c '^jellyfin-')"
k="$(ls -1 "$SNAPS" | grep -c '^kavita-')"
(( j == 14 )) || fail "2: jellyfin left $j snapshots, expected 14: $out"
(( k == 3 ))  || fail "2: kavita lost snapshots it was under the limit for ($k of 3): $out"
grep -q '6 deleted, 0 failed' <<< "$out" || fail "2: prune did not report 6 deletions: $out"

# ---------------------------------------------------------------------------
# 3. One service's snapshots cannot satisfy another's retention -- in both
#    directions, and with the GLOBAL count far over the limit.
#
# 30 jellyfin snapshots and 1 kavita snapshot is 31 in total, well past keep=14.
# A retention decision made on the global count would delete kavita's only
# recovery point while jellyfin kept fourteen.
# ---------------------------------------------------------------------------
for pair in "jellyfin:30 kavita:1" "kavita:30 jellyfin:1"; do
  many="${pair%%:*}"; rest="${pair#*:}"; few="$(cut -d' ' -f2 <<< "$rest" | cut -d: -f1)"
  rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed "$many" 30; seed "$few" 1
  out="$(run "$BOTH" "SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "3: prune failed: $out"
  n_few="$(ls -1 "$SNAPS" | grep -c "^$few-")"
  n_many="$(ls -1 "$SNAPS" | grep -c "^$many-")"
  (( n_few == 1 ))   || fail "3: $few's only recovery point was deleted because $many had many ($n_few left): $out"
  (( n_many == 14 )) || fail "3: $many left $n_many, expected 14: $out"
done

# ---------------------------------------------------------------------------
# 4. A service with NO snapshots must not be pruned into existence or error.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 20
out="$(run "$BOTH" "SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "4: prune failed with one service unsnapshotted: $out"
[[ "$(ls -1 "$SNAPS" | grep -c '^kavita-')" == "0" ]] || fail "4: kavita snapshots appeared from nowhere"
(( $(ls -1 "$SNAPS" | grep -c '^jellyfin-') == 14 )) || fail "4: jellyfin was not pruned: $out"

# ---------------------------------------------------------------------------
# 5. latest_snapshot_for_service answers per service, and never crosses over.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 3; seed kavita 2
lj="$(run "$BOTH" "latest_snapshot_for_service jellyfin")"
lk="$(run "$BOTH" "latest_snapshot_for_service kavita")"
[[ "$lj" == jellyfin-* ]] || fail "5: jellyfin's latest snapshot is '$lj'"
[[ "$lk" == kavita-* ]]   || fail "5: kavita's latest snapshot is '$lk'"
[[ "$lj" != "$lk" ]]      || fail "5: both services resolved to the same snapshot"

# ...and a service with none must answer with nothing, not with another's.
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 3
lk="$(run "$BOTH" "latest_snapshot_for_service kavita")"
[[ -z "$lk" ]] || fail "5: kavita, with no snapshots, was given '$lk'"

# ---------------------------------------------------------------------------
# 6. The report must classify the two INDEPENDENTLY.
#
# One subvolume with a snapshot and one without is the state right after a
# migration whose proof snapshot failed, and the state after a prune removed a
# service's last snapshot. Reporting them the same way is the CLAUDE.md section
# 14 defect: a report implying protection that does not exist.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"; seed jellyfin 1
# The report library carries its own byte-identical copy of domum_is_subvolume
# -- kept in step by tests/subvolume-detection-smoke.sh -- so sourcing it
# replaces the harness stub. Re-stub afterwards, or this would test the real
# inode check against a fixture that cannot have inode 256.
report_states() {  # $1 = services
  run "$BOTH" "
DOMUM_REPORT_LIB='$REPO_ROOT/bin/domum-media-report'
source '$REPO_ROOT/bin/domum-media-report'
domum_is_subvolume() { grep -qFx -- \"\$(basename -- \"\$1\")\" <<< \"\$SUBVOLS\"; }
for s in $1; do report_snapshot_protection \"\$s\" \"$DATA/\$s\"; done"
}
states="$(report_states 'jellyfin kavita plex')"
j_state="$(jq -r 'select(.service=="jellyfin")|.state' <<< "$states")"
k_state="$(jq -r 'select(.service=="kavita")|.state' <<< "$states")"
p_state="$(jq -r 'select(.service=="plex")|.state' <<< "$states")"
[[ "$j_state" == "protected" ]]     || fail "6: jellyfin is a subvolume with a snapshot but reads '$j_state'"
[[ "$k_state" == "snapshottable" ]] || fail "6: kavita is a subvolume with NO snapshot but reads '$k_state'"
[[ "$p_state" == "unprotected" ]]   || fail "6: plex is an ordinary directory but reads '$p_state'"
[[ "$(jq -r 'select(.service=="kavita")|.latest_snapshot' <<< "$states")" == "null" ]] \
  || fail "6: kavita was given a snapshot it does not have"

# Both snapshotted -> both protected, each naming its OWN snapshot.
seed kavita 1
states="$(report_states 'jellyfin kavita')"
[[ "$(jq -r 'select(.service=="jellyfin")|.state' <<< "$states")" == "protected" ]] || fail "6: jellyfin not protected"
[[ "$(jq -r 'select(.service=="kavita")|.state'   <<< "$states")" == "protected" ]] || fail "6: kavita not protected"
[[ "$(jq -r 'select(.service=="jellyfin")|.latest_snapshot' <<< "$states")" == jellyfin-* ]] \
  || fail "6: jellyfin names the wrong snapshot"
[[ "$(jq -r 'select(.service=="kavita")|.latest_snapshot' <<< "$states")" == kavita-* ]] \
  || fail "6: kavita names the wrong snapshot"

# ---------------------------------------------------------------------------
# 7. snapshot_create over TWO subvolumes: a failure on one is not excused by a
#    success on the other. "At least one created" is the right answer for a
#    fleet-wide job and the wrong answer for anything that gates on it.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"
out="$(run "$BOTH" "
snapshot_subvolumes() { printf '%s\n%s\n' '$DATA/jellyfin' '$DATA/kavita'; }
record_rollback_entry() { :; }
btrfs() { mkdir -p \"\${!#}\"; }
snapshot_create two-ok && echo RC=0 || echo RC=1")"
grep -q 'RC=0' <<< "$out" || fail "7: snapshotting two subvolumes failed: $out"
grep -q '2 created' <<< "$out" || fail "7: expected 2 created: $out"

out="$(run "$BOTH" "
snapshot_subvolumes() { printf '%s\n%s\n' '$DATA/jellyfin' '$DATA/kavita'; }
record_rollback_entry() { :; }
# kavita's snapshot fails; jellyfin's succeeds.
btrfs() { case \"\${!#}\" in *kavita*) return 1 ;; *) mkdir -p \"\${!#}\" ;; esac; }
snapshot_create one-fails && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" \
  || fail "7: one subvolume failing was excused by the other succeeding: $out"
grep -q '1 created' <<< "$out" || fail "7: expected 1 created: $out"
grep -q '1 failed' <<< "$out"  || fail "7: the failure was not counted: $out"

# ---------------------------------------------------------------------------
# 8. A snapshot of one service must never authorise destroying another's data.
#
# This is the gate that matters most once more than one service is a subvolume:
# with only jellyfin migrated, a global "does any snapshot exist" check passes
# and `immich reset-db` would rm -rf the Immich database with no Immich snapshot
# anywhere. The same reasoning applies to every pair.
# ---------------------------------------------------------------------------
rm -rf "$SNAPS"; mkdir -p "$SNAPS"
mkdir -p "$DATA/kavita/config"; printf 'x\n' > "$DATA/kavita/config/kavita.db"
out="$(run "$BOTH" "
service_data_path() { printf '%s' '$DATA'/\"\$1\"; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { :; }
btrfs() { mkdir -p \"\${!#}\"; }
# A snapshot of JELLYFIN, asked to cover KAVITA's data.
assert_service_snapshot_covers jellyfin probe '$DATA/kavita/config/kavita.db' && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" \
  || fail "8: a jellyfin snapshot authorised an operation on kavita's data: $out"
grep -q 'Not covered by any snapshot' <<< "$out" || fail "8: no explanation: $out"

# ...and the same service's own snapshot does cover its own path.
#
# The positive control is not optional. assert_service_snapshot_covers refuses
# when the snapshot NAME comes back empty as well as when the path is not
# covered, so a fixture whose service_data_path is subtly wrong makes the
# negative case above pass for entirely the wrong reason. This is what caught
# exactly that while writing this test.
out="$(run "$BOTH" "
service_data_path() { printf '%s' '$DATA'/\"\$1\"; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { :; }
btrfs() { mkdir -p \"\${!#}\"; }
path_covered_by_subvolume() { return 0; }
assert_service_snapshot_covers kavita probe '$DATA/kavita/config/kavita.db' && echo RC=0 || echo RC=1")"
grep -q 'RC=0' <<< "$out" || fail "8: kavita's own snapshot did not cover its own data: $out"

# ---------------------------------------------------------------------------
# 9. A restore must not accept another service's snapshot -- including one whose
#    name merely STARTS with this service's basename.
#
# This is the last check before `btrfs subvolume snapshot` writes over a service's
# data path, so a false accept overwrites live state rather than miscounting
# retention. With two migrated services it is no longer hypothetical.
#
# EVERY case starts from a clean fixture. The first version of this did not, and
# every negative case after the first passed for the wrong reason: a successful
# restore leaves `<path>.rollback-<YYYYMMDD-HHMMSS>` behind, the next restore in
# the same second collides with it, and the refusal that follows is
# "rollback directory already exists" -- not the ownership check under test. The
# unanchored-prefix mutant survived because of exactly that.
# ---------------------------------------------------------------------------
restore_case() {  # $1 = service, $2 = snapshot name, $3.. = snapshot dirs to create
  local svc="$1" snap="$2"; shift 2
  rm -rf "$DATA" "$SNAPS"; mkdir -p "$DATA/jellyfin" "$DATA/kavita" "$DATA/kavita-extra" "$SNAPS"
  local d
  for d in "$@"; do mkdir -p "$SNAPS/$d"; done
  run "$BOTH" "
service_data_path() { printf '%s' '$DATA'/\"\$1\"; }
service_compose_services() { printf 'x'; }
stop_compose_services_verified() { return 0; }
compose_cmd() { :; }
btrfs() { mkdir -p \"\${!#}\"; }
# A SUBSHELL: a refusal goes through die -> exit, which would otherwise terminate
# the harness before either echo runs and make every refusal look alike.
( restore_snapshot_for_service '$svc' '$snap' >/dev/null ) && echo RC=0 || echo RC=1"
}

K=kavita-20260929-001131-post-migration
J=jellyfin-20260925-153317-post-migration
X=kavita-extra-20260101-000000-tag

# Positive control first. Without it, a fixture mistake makes every negative case
# below pass for free.
out="$(restore_case kavita "$K" "$K")"
grep -q 'RC=0' <<< "$out" || fail "9: kavita's own snapshot was refused: $out"

# Another service's snapshot: refused, and named.
out="$(restore_case kavita "$J" "$J" "$K")"
grep -q 'RC=1' <<< "$out" || fail "9: a jellyfin snapshot was accepted for kavita: $out"
grep -q 'does not belong to kavita' <<< "$out" \
  || fail "9: refused for the wrong reason (not the ownership check): $out"

# THE PREFIX CASE. `kavita-extra-...` starts with "kavita-", so an unanchored
# prefix test accepts it and writes kavita-extra's state over kavita's path.
out="$(restore_case kavita "$X" "$X" "$K")"
grep -q 'RC=1' <<< "$out" \
  || fail "9: a DIFFERENT service's snapshot beginning 'kavita-' was accepted: $out"
grep -q 'does not belong to kavita' <<< "$out" \
  || fail "9: the prefix case was refused for the wrong reason: $out"

# ...and kavita-extra must still restore its own, or the fix is just a ban.
out="$(restore_case kavita-extra "$X" "$X")"
grep -q 'RC=0' <<< "$out" || fail "9: kavita-extra could not restore its own snapshot: $out"

# This service's prefix but no timestamp: not one of ours.
out="$(restore_case kavita kavita-handmade kavita-handmade)"
grep -q 'RC=1' <<< "$out" || fail "9: a hand-made directory was accepted as a snapshot: $out"
grep -q 'does not belong to kavita' <<< "$out" || fail "9: wrong reason: $out"

# Traversal. The first three do not even start with "kavita-", so the ownership
# check alone would catch them -- the last one DOES, and passes the ownership
# check, so only the path-component guard stands between it and a restore from
# outside the snapshot root.
for bad in "../$J" "." ".." "kavita-20260101-000000-../../../etc"; do
  out="$(restore_case kavita "$bad" "$K")"
  grep -q 'RC=1' <<< "$out" || fail "9: '$bad' was accepted as a snapshot name: $out"
  grep -q 'is not a valid snapshot name' <<< "$out" \
    || fail "9: '$bad' was refused, but not as an invalid name: $out"
done

# A second restore in the SAME SECOND must refuse rather than overwrite the
# preserved copy: `<path>.rollback-<YYYYMMDD-HHMMSS>` has one-second resolution.
# Refusing is correct -- the preserved copy is the only way back -- so this is
# pinned so nobody "fixes" it by overwriting.
rm -rf "$DATA" "$SNAPS"; mkdir -p "$DATA/kavita" "$SNAPS/$K"
twice="$(run "$BOTH" "
service_data_path() { printf '%s' '$DATA'/\"\$1\"; }
service_compose_services() { printf 'x'; }
stop_compose_services_verified() { return 0; }
compose_cmd() { :; }
btrfs() { mkdir -p \"\${!#}\"; }
( restore_snapshot_for_service kavita $K >/dev/null ) && echo FIRST=0 || echo FIRST=1
( restore_snapshot_for_service kavita $K >/dev/null ) && echo SECOND=0 || echo SECOND=1")"
grep -q 'FIRST=0' <<< "$twice" || fail "9: the first restore failed: $twice"
grep -q 'SECOND=1' <<< "$twice" \
  || fail "9: a second restore in the same second overwrote the preserved copy: $twice"
grep -q 'already exists' <<< "$twice" || fail "9: not explained: $twice"

# Restore the shared fixture the later cases expect.
rm -rf "$DATA" "$SNAPS"; mkdir -p "$DATA/jellyfin" "$DATA/kavita" "$DATA/plex" "$SNAPS"

# ---------------------------------------------------------------------------
# 10. restic must still traverse into BOTH subvolumes.
#
# `--one-file-system` means "do not cross filesystem boundaries AND SUBVOLUMES".
# Each migrated service is a nested subvolume under /srv/data, so that flag would
# silently drop them from the backup -- and with two migrated services it would
# drop two. Asserted over the whole file with comments stripped, because the flag
# would sit on a continuation line of its own.
# ---------------------------------------------------------------------------
backup_nocomments="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media-backup")"
if grep -qE -- '--one-file-system|(^|[[:space:]])-x([[:space:]]|$)' <<< "$backup_nocomments"; then
  fail "10: domum-media-backup passes --one-file-system; every migrated service would vanish from the backup"
fi

echo "PASS: two migrated services smoke test"
