#!/usr/bin/env bash
set -uo pipefail

# A deployment must assert that the storage topology is UNCHANGED, not that it is
# EMPTY.
#
# The Jellyfin deployment aborted on the absolute form:
#
#   ABORT: a subvolume appeared under /srv/data: /srv/data/jellyfin
#
# after installing every file correctly. /srv/data/jellyfin is intentionally a
# subvolume; the assertion was written when none existed. A second assertion on
# the same lines ("/srv/snapshots is no longer empty") would have fired next.
#
# This pins the inventory those comparisons rest on.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Subvolume-ness is identified by inode 256, which cannot be arranged in a
# fixture on demand, so `find` is stubbed to describe a chosen topology. What is
# under test is the inventory's shape, ordering and comparison semantics.
topo() {  # $1 = newline-separated subvolume paths, $2 = newline-separated snapshot names
  bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_SNAPSHOT_ROOT='$TMP_DIR/snapshots'
find() {
  case \"\$*\" in
    *inum\ 256*) printf '%s' \"\$SUBVOLS\" ;;
    *printf*)    printf '%s' \"\$SNAPS\" ;;
  esac
}
SUBVOLS='$1'
SNAPS='$2'
storage_topology" 2>/dev/null
}
mkdir -p "$TMP_DIR/data" "$TMP_DIR/snapshots"

# ---------------------------------------------------------------------------
# A. zero migrated services -- the state before the pilot
# ---------------------------------------------------------------------------
a="$(topo '' '')"
[[ -z "$a" ]] || fail "A: an empty topology must produce no output, got: $a"
[[ "$(topo '' '')" == "$a" ]] || fail "A: not deterministic"

# ---------------------------------------------------------------------------
# B. Jellyfin already migrated -- the state the deployment aborted on.
#    Two identical captures must compare EQUAL. This is the whole bug.
# ---------------------------------------------------------------------------
jf_sub='/srv/data/jellyfin
'
jf_snap='jellyfin-20260925-153317-post-migration
'
b1="$(topo "$jf_sub" "$jf_snap")"
b2="$(topo "$jf_sub" "$jf_snap")"
[[ "$b1" == "$b2" ]] || fail "B: two captures of the same topology differ: [$b1] vs [$b2]"
grep -q '^subvolume /srv/data/jellyfin$' <<< "$b1" || fail "B: the migrated subvolume is not listed: $b1"
grep -q '^snapshot jellyfin-20260925-153317-post-migration$' <<< "$b1" \
  || fail "B: the proof snapshot is not listed: $b1"
# And the absolute form would have rejected it -- that is what went wrong.
[[ -n "$b1" ]] || fail "B: fixture is wrong; a migrated topology must not be empty"

# ---------------------------------------------------------------------------
# C. several services already migrated -- the state after Kavita, Calibre-Web...
# ---------------------------------------------------------------------------
multi_sub='/srv/data/calibre-web
/srv/data/jellyfin
/srv/data/kavita
'
multi_snap='calibre-web-20261001-000000-post-migration
jellyfin-20260925-153317-post-migration
kavita-20260930-000000-post-migration
'
c1="$(topo "$multi_sub" "$multi_snap")"
c2="$(topo "$multi_sub" "$multi_snap")"
[[ "$c1" == "$c2" ]] || fail "C: not stable with several migrated services"
[[ "$(grep -c '^subvolume ' <<< "$c1")" == "3" ]] || fail "C: expected 3 subvolumes: $c1"
[[ "$(grep -c '^snapshot ' <<< "$c1")" == "3" ]] || fail "C: expected 3 snapshots: $c1"

# Order must not depend on the order `find` happened to return them in, or two
# captures of the same topology could compare unequal for no reason.
shuffled_sub='/srv/data/kavita
/srv/data/calibre-web
/srv/data/jellyfin
'
[[ "$(topo "$shuffled_sub" "$multi_snap")" == "$c1" ]] \
  || fail "C: the inventory is order-dependent; equal topologies would compare unequal"

# ---------------------------------------------------------------------------
# D. an unexpected NEW subvolume appears during the operation -> must differ
# ---------------------------------------------------------------------------
d="$(topo "$jf_sub/srv/data/kavita
" "$jf_snap")"
[[ "$d" != "$b1" ]] || fail "D: a new subvolume did not change the topology"
grep -q 'kavita' <<< "$d" || fail "D: the new subvolume is not named: $d"

# ---------------------------------------------------------------------------
# E. an expected subvolume DISAPPEARS -> must differ
# ---------------------------------------------------------------------------
e="$(topo '' "$jf_snap")"
[[ "$e" != "$b1" ]] || fail "E: a vanished subvolume did not change the topology"

# ...and a vanished SNAPSHOT must differ too -- that is the recovery point.
f="$(topo "$jf_sub" '')"
[[ "$f" != "$b1" ]] || fail "F: a vanished snapshot did not change the topology"

# ---------------------------------------------------------------------------
# G. What the comparison deliberately does NOT detect, stated so nobody assumes
#    otherwise: a path that stays while its CONTENTS change. This is a topology
#    guard. Content integrity is proven by the migration's own verification and by
#    .premigration == proof snapshot.
# ---------------------------------------------------------------------------
[[ "$(topo "$jf_sub" "$jf_snap")" == "$b1" ]] \
  || fail "G: identical topology compared unequal"

# The subcommand must exist and must not require root: a deployment captures this
# before and after, and both captures have to run the same code path.
grep -q 'topology)' "$REPO_ROOT/bin/domum-media" || fail "storage topology is not dispatched"
topo_block="$(awk '/^    topology\)/,/;;/' "$REPO_ROOT/bin/domum-media")"
grep -q 'need_root' <<< "$topo_block" \
  && fail "storage topology must not require root; a pre-capture could then differ from the post-capture"

echo "PASS: storage topology smoke test"
