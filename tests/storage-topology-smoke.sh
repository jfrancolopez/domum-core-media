#!/usr/bin/env bash
set -uo pipefail

# A deployment must assert that the storage topology is UNCHANGED, not that it is
# EMPTY.
#
# The b762fe8 deployment aborted on the absolute form:
#
#   ABORT: a subvolume appeared under /srv/data: /srv/data/jellyfin
#
# after installing every file correctly. /srv/data/jellyfin is intentionally a
# subvolume; the assertion was written when none existed. A second assertion on
# the same lines ("/srv/snapshots is no longer empty") would have fired next.
#
# That invariant lived in a hand-written operator script CI never saw. It now
# lives here, as `storage_topology` + `storage_topology_verify`, and the operator
# script calls it. This pins both.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA="$TMP_DIR/data"
SNAPS="$TMP_DIR/snapshots"
mkdir -p "$DATA" "$SNAPS"

# REAL directories, REAL `find`. Only `domum_is_subvolume` is stubbed, because
# inode 256 cannot be arranged in a fixture without root and a btrfs filesystem
# (there is none writable on this host or in CI). It is the one thing that cannot
# be produced honestly here, it is a single well-defined predicate, and it is
# itself pinned by tests/subvolume-detection-smoke.sh. Real coverage of the
# predicate against real subvolumes lives in
# tests/integration/btrfs-migration-integration.sh.
#
# $1 = newline-separated basenames under the data root that ARE subvolumes.
harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$DATA"
DOMUM_SNAPSHOT_ROOT="$SNAPS"
need_root() { :; }
load_cfg() { :; }
domum_is_subvolume() {
  local n
  n="\$(basename -- "\$1")"
  grep -qFx -- "\$n" <<< "\$SUBVOL_NAMES"
}
EOF
}

topo() {  # $1 = subvolume basenames (newline separated)
  bash -c "$(harness)
SUBVOL_NAMES='${1:-}'
storage_topology" 2>/dev/null
}

verify() {  # $1 = capture file, $2 = subvolume basenames; echoes output, returns rc
  bash -c "$(harness)
SUBVOL_NAMES='${2:-}'
storage_topology_verify '$1'" 2>&1
}

body() { grep -v '^#' <<< "$1"; }

# ---------------------------------------------------------------------------
# A. zero migrated services -- the state before the pilot.
#
# An empty inventory is a legitimate topology, not an error, and it must still
# carry the header so it can be compared at all.
# ---------------------------------------------------------------------------
mkdir -p "$DATA/immich" "$DATA/kavita" "$DATA/plex"
a="$(topo '')"
[[ -n "$a" ]] || fail "A: even an empty topology must emit its header"
grep -q '^# topology-format 1 ' <<< "$a" || fail "A: no header: $a"
[[ -z "$(body "$a")" ]] || fail "A: ordinary directories were listed as subvolumes: $a"
[[ "$(topo '')" == "$a" ]] || fail "A: not deterministic"

cap_a="$TMP_DIR/cap_a"; topo '' > "$cap_a"
out="$(verify "$cap_a" '')"; rc=$?
(( rc == 0 )) || fail "A: an unchanged empty topology must verify clean (rc=$rc): $out"
grep -q '0 subvolume(s), 0 snapshot(s)' <<< "$out" || fail "A: counts not reported: $out"

# ---------------------------------------------------------------------------
# B. ONE expected migrated service -- the state the deployment aborted on.
#    Two identical captures must compare EQUAL. This is the whole bug.
# ---------------------------------------------------------------------------
mkdir -p "$DATA/jellyfin" "$SNAPS/jellyfin-20260925-153317-post-migration"
JF='jellyfin'
b="$(topo "$JF")"
grep -q "^subvolume $DATA/jellyfin\$" <<< "$b" || fail "B: the migrated subvolume is not listed: $b"
grep -q '^snapshot jellyfin-20260925-153317-post-migration$' <<< "$b" \
  || fail "B: the proof snapshot is not listed: $b"
[[ "$(topo "$JF")" == "$b" ]] || fail "B: two captures of the same topology differ"

cap_b="$TMP_DIR/cap_b"; topo "$JF" > "$cap_b"
out="$(verify "$cap_b" "$JF")"; rc=$?
(( rc == 0 )) || fail "B: THE BUG -- an unchanged migrated topology reported a change (rc=$rc): $out"
grep -q '1 subvolume(s), 1 snapshot(s)' <<< "$out" || fail "B: counts wrong: $out"

# The absolute form the deploy script used would have rejected exactly this.
[[ -n "$(body "$b")" ]] || fail "B: fixture is wrong; a migrated topology must not be empty"

# ---------------------------------------------------------------------------
# C. SEVERAL expected migrated services -- after Kavita, Calibre-Web and the rest.
#    The invariant has to keep working all the way to "everything migrated".
# ---------------------------------------------------------------------------
mkdir -p "$DATA/calibre-web" "$SNAPS/calibre-web-20261001-000000-post-migration" \
         "$SNAPS/kavita-20260930-000000-post-migration"
MULTI='calibre-web
jellyfin
kavita'
c="$(topo "$MULTI")"
[[ "$(grep -c '^subvolume ' <<< "$c")" == "3" ]] || fail "C: expected 3 subvolumes: $c"
[[ "$(grep -c '^snapshot ' <<< "$c")" == "3" ]] || fail "C: expected 3 snapshots: $c"

cap_c="$TMP_DIR/cap_c"; topo "$MULTI" > "$cap_c"
out="$(verify "$cap_c" "$MULTI")"; rc=$?
(( rc == 0 )) || fail "C: several migrated services reported a spurious change (rc=$rc): $out"

# Order-independence is a property in its own right: if the inventory reflected
# whatever order `find` returned, two captures of an UNCHANGED topology could
# compare unequal and abort a correct deployment.
SHUFFLED='kavita
calibre-web
jellyfin'
[[ "$(topo "$SHUFFLED")" == "$c" ]] \
  || fail "C: the inventory is order-dependent; equal topologies would compare unequal"

# And the listing itself must be sorted, not whatever order `find` walked the
# directory in. `storage_topology_verify` sorts both sides before diffing, so it is
# immune -- but a caller comparing the two captures as STRINGS (which is what the
# deploy script did) is not, and would abort a correct deployment. The fixture
# directories are deliberately created out of lexical order.
for kind in subvolume snapshot; do
  listed="$(grep "^$kind " <<< "$c")"
  [[ -n "$listed" ]] || fail "C: no $kind lines to check ordering on"
  [[ "$listed" == "$(LC_ALL=C sort <<< "$listed")" ]] \
    || fail "C: $kind lines are not sorted; a string comparison of two equal topologies would differ:
$listed"
done

# ---------------------------------------------------------------------------
# D. an UNEXPECTED new subvolume appears -> must be reported, and named
# ---------------------------------------------------------------------------
out="$(verify "$cap_c" "$MULTI
plex")"; rc=$?
(( rc == 1 )) || fail "D: a new subvolume was not reported as a change (rc=$rc): $out"
grep -q "^APPEARED    subvolume $DATA/plex\$" <<< "$out" || fail "D: the new subvolume is not named: $out"
grep -q 'CHANGED' <<< "$out" || fail "D: no warning: $out"

# A new SNAPSHOT is a change too. Nothing in a storage-neutral deployment creates
# one, and if one appears mid-deployment the operator needs to know before the
# weekly prune starts counting it.
mkdir -p "$SNAPS/plex-20261101-000000-post-migration"
out="$(verify "$cap_c" "$MULTI")"; rc=$?
(( rc == 1 )) || fail "D: a new snapshot was not reported (rc=$rc): $out"
grep -q '^APPEARED    snapshot plex-20261101-000000-post-migration$' <<< "$out" \
  || fail "D: the new snapshot is not named: $out"
rmdir "$SNAPS/plex-20261101-000000-post-migration"

# ---------------------------------------------------------------------------
# E. an EXPECTED subvolume disappears -> must be reported.
#    This is the direction that matters most: a service silently losing its
#    subvolume loses its rollback protection, and the report would then call it
#    "snapshottable" instead of "protected".
# ---------------------------------------------------------------------------
out="$(verify "$cap_c" 'calibre-web
kavita')"; rc=$?
(( rc == 1 )) || fail "E: a vanished subvolume was not reported (rc=$rc): $out"
grep -q "^DISAPPEARED subvolume $DATA/jellyfin\$" <<< "$out" || fail "E: not named: $out"

# ...and a vanished SNAPSHOT, which is the recovery point itself.
mv "$SNAPS/jellyfin-20260925-153317-post-migration" "$TMP_DIR/held"
out="$(verify "$cap_c" "$MULTI")"; rc=$?
(( rc == 1 )) || fail "E: a vanished snapshot was not reported (rc=$rc): $out"
grep -q '^DISAPPEARED snapshot jellyfin-20260925-153317-post-migration$' <<< "$out" \
  || fail "E: the vanished snapshot is not named: $out"
mv "$TMP_DIR/held" "$SNAPS/jellyfin-20260925-153317-post-migration"

# A rename nets to one appearance and one disappearance, not to "unchanged".
mv "$SNAPS/kavita-20260930-000000-post-migration" "$SNAPS/kavita-20260930-000000-renamed"
out="$(verify "$cap_c" "$MULTI")"; rc=$?
(( rc == 1 )) || fail "E: a renamed snapshot was not reported (rc=$rc): $out"
grep -q 'APPEARED    snapshot kavita-20260930-000000-renamed' <<< "$out" || fail "E: rename not named: $out"
grep -q 'DISAPPEARED snapshot kavita-20260930-000000-post-migration' <<< "$out" || fail "E: rename not named: $out"
mv "$SNAPS/kavita-20260930-000000-renamed" "$SNAPS/kavita-20260930-000000-post-migration"

# ---------------------------------------------------------------------------
# F. topology changes DURING a supposedly storage-neutral operation.
#    End to end, in the shape a deployment uses it: capture, do the work, verify.
# ---------------------------------------------------------------------------
deploy_like() {  # $1 = subvolumes before, $2 = subvolumes after
  local cap="$TMP_DIR/deploy_cap"
  topo "$1" > "$cap"
  # ... a deployment installs files and moves a git ref here. Neither can create,
  # remove or rename a subvolume or a snapshot.
  verify "$cap" "$2"
}
out="$(deploy_like "$MULTI" "$MULTI")"; rc=$?
(( rc == 0 )) || fail "F: a storage-neutral deployment aborted (rc=$rc): $out"
out="$(deploy_like "$MULTI" "$MULTI
plex")"; rc=$?
(( rc == 1 )) || fail "F: a deployment that changed the topology was accepted (rc=$rc): $out"

# ---------------------------------------------------------------------------
# G. "I cannot tell" must never be reported as "unchanged".
#
# rc=2 is a distinct outcome, so a caller that only tests for success still
# refuses. A capture from a different detector or a different root describes a
# different question; diffing it manufactures a change out of nothing.
# ---------------------------------------------------------------------------
out="$(verify "$TMP_DIR/no-such-capture" "$MULTI")"; rc=$?
(( rc == 2 )) || fail "G: a missing capture must be 'not comparable', got rc=$rc: $out"

printf 'subvolume %s/jellyfin\n' "$DATA" > "$TMP_DIR/cap_headerless"
out="$(verify "$TMP_DIR/cap_headerless" "$MULTI")"; rc=$?
(( rc == 2 )) || fail "G: a headerless capture must be 'not comparable', got rc=$rc: $out"

sed 's/detector=[^ ]*/detector=btrfs-tool/' "$cap_c" > "$TMP_DIR/cap_other_detector"
sed -n '2,$p' "$cap_c" >> /dev/null
out="$(verify "$TMP_DIR/cap_other_detector" "$MULTI")"; rc=$?
if [[ "$(bash -c "$(harness)
storage_topology_detector")" == "btrfs-tool" ]]; then
  (( rc == 0 )) || fail "G: same detector should compare (rc=$rc): $out"
else
  (( rc == 2 )) || fail "G: a capture from a different detector must not be diffed, got rc=$rc: $out"
  grep -q 'not comparable' <<< "$out" || fail "G: no explanation: $out"
fi

sed 's#data-root=[^ ]*#data-root=/somewhere/else#' "$cap_c" > "$TMP_DIR/cap_other_root"
out="$(verify "$TMP_DIR/cap_other_root" "$MULTI")"; rc=$?
(( rc == 2 )) || fail "G: a capture of a different data root must not be diffed, got rc=$rc: $out"

# ---------------------------------------------------------------------------
# H. What this deliberately does NOT detect, stated so nobody assumes otherwise:
#    a path that stays while its CONTENTS change. This is a topology guard.
#    Content integrity is proven by the migration's own verification and by
#    .premigration == proof snapshot.
# ---------------------------------------------------------------------------
echo "new content" > "$DATA/jellyfin/appeared.txt"
out="$(verify "$cap_c" "$MULTI")"; rc=$?
(( rc == 0 )) || fail "H: content changes must not be reported as topology changes: $out"
rm -f "$DATA/jellyfin/appeared.txt"

# ---------------------------------------------------------------------------
# I. Surface contract.
# ---------------------------------------------------------------------------
storage_block="$(awk '/^storage_cmd\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
[[ -n "$storage_block" ]] || fail "storage_cmd not found"
grep -q 'topology)' <<< "$storage_block" || fail "storage topology is not dispatched"
grep -q -- '--verify' <<< "$storage_block" || fail "storage topology --verify is not dispatched"
# Isolate just the topology arm, so migrate-subvolume's need_root is not read as
# topology's.
topo_block="$(awk '/^    topology\)/,/^    \*\)/' <<< "$storage_block")"
grep -q 'need_root' <<< "$topo_block" \
  && fail "storage topology must not require root; a pre-capture could then differ from the post-capture"

# The inventory must not reimplement subvolume detection. There is one answer to
# "is this a subvolume?" and three used to be two too many.
topo_fn="$(awk '/^storage_topology\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'domum_is_subvolume' <<< "$topo_fn" \
  || fail "storage_topology must decide subvolume-ness through domum_is_subvolume"
grep -q 'inum 256' <<< "$topo_fn" \
  && fail "storage_topology reimplements subvolume detection with an inline inode test"

echo "PASS: storage topology smoke test"
