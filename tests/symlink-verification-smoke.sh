#!/usr/bin/env bash
set -uo pipefail

# Symlinks, end to end, before Plex.
#
# Plex is the only remaining routine candidate whose state contains symlinks --
# 7 of them, and one is ABSOLUTE and points at a container-internal path:
#
#   .../Cache/va-dri-linux-x86_64/iHD_drv_video.so
#     -> /config/Library/Application Support/Plex Media Server/Drivers/imd-…/dri/iHD_drv_video.so
#
# On the host that target does not exist, so it is a BROKEN symlink from the
# migration's point of view. The existing suites cover a relative symlink, an
# absolute one, and a retarget to a name of the same length. They do not cover the
# two failures that matter for this shape:
#
#   * dereferencing -- hashing or traversing what a symlink POINTS AT, which for
#     an absolute link into /srv/media would pull an unrelated tree into the
#     comparison, and for a link to a huge file would make a migration appear to
#     verify data it never copied
#   * a dangling target, which `sha256sum` cannot read at all

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
need_root() { :; }
load_cfg() { :; }
EOF
}

verify() {  # $1 = src, $2 = dst
  bash -c "$(harness)
migrate_verify '$1' '$2'" 2>&1
}
manifest() {  # $1 = tree
  bash -c "$(harness)
migrate_manifest '$1'" 2>/dev/null
}
metadata() {  # $1 = tree
  bash -c "$(harness)
migrate_metadata_manifest '$1'" 2>/dev/null
}

# A tree outside the migration, with content that must never be read through a
# link. Distinctive and large enough that counting bytes catches it.
OUT="$TMP_DIR/outside"
mkdir -p "$OUT/dir"
head -c 1048576 /dev/zero | tr '\0' 'X' > "$OUT/secret.bin"     # 1 MiB
printf 'must-not-be-hashed\n' > "$OUT/dir/a.txt"
printf 'must-not-be-hashed\n' > "$OUT/dir/b.txt"

build() {  # $1 = scenario -> echoes the pair's directory
  local d="$TMP_DIR/$1"
  rm -rf "$d"; mkdir -p "$d/src/config"
  printf 'real content\n' > "$d/src/config/real.txt"
  mkdir -p "$d/src/config/data"
  printf 'nested\n' > "$d/src/config/data/nested.txt"
  # relative, inside the tree
  ln -s data/nested.txt      "$d/src/config/rel-inside"
  # absolute, to a FILE outside the tree
  ln -s "$OUT/secret.bin"    "$d/src/config/abs-outside-file"
  # absolute, to a DIRECTORY outside the tree
  ln -s "$OUT/dir"           "$d/src/config/abs-outside-dir"
  # absolute and BROKEN -- the shape plex actually has
  ln -s "/config/Library/Application Support/Plex Media Server/Drivers/x/dri/iHD.so" \
                             "$d/src/config/abs-broken"
  # relative and broken
  ln -s ./gone               "$d/src/config/rel-broken"
  cp -a "$d/src" "$d/dst"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# 1. A faithful copy of a tree containing every symlink shape verifies.
# ---------------------------------------------------------------------------
d="$(build ok)"
out="$(verify "$d/src" "$d/dst")"
rc=$?
(( rc == 0 )) || fail "1: a faithful copy with symlinks did not verify (rc=$rc): $out"
grep -q 'symlink targets identical' <<< "$out" || fail "1: symlink targets were not compared: $out"

# ---------------------------------------------------------------------------
# 2. NO DEREFERENCING. Symlinks must not be hashed, and what they point at must
#    not be read -- not the 1 MiB file, not the directory's contents.
# ---------------------------------------------------------------------------
m="$(manifest "$d/src")"
lines="$(grep -c . <<< "$m")"
files_in_tree="$(find "$d/src" -xdev -type f | wc -l)"
(( lines == files_in_tree )) \
  || fail "2: the content manifest has $lines lines for $files_in_tree regular files; something was followed:
$m"
grep -q 'rel-inside\|abs-outside\|abs-broken\|rel-broken' <<< "$m" \
  && fail "2: a symlink appears in the CONTENT manifest, so it was hashed: $m"
# The outside tree's files must not appear by any name.
grep -q 'secret.bin\|a\.txt\|b\.txt' <<< "$m" \
  && fail "2: content from OUTSIDE the tree was hashed through a symlink: $m"
# And the byte count must not include the target.
read -r _ bytes <<< "$(bash -c "$(harness)
migrate_measure '$d/src'")"
tree_bytes="$(find "$d/src" -xdev -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
(( bytes < 1048576 )) \
  || fail "2: measured $bytes bytes, which includes the 1 MiB file the symlink points at (tree holds $tree_bytes)"

# ---------------------------------------------------------------------------
# 3. Every symlink IS in the metadata manifest, with its target.
# ---------------------------------------------------------------------------
md="$(metadata "$d/src")"
for link in rel-inside abs-outside-file abs-outside-dir abs-broken rel-broken; do
  grep -q "l .* ./config/$link -> " <<< "$md" \
    || fail "3: $link is missing from the metadata manifest, or not recorded as a link:
$(grep "$link" <<< "$md")"
done
grep -q "config/abs-broken -> /config/Library" <<< "$md" \
  || fail "3: the broken absolute target was not recorded verbatim: $(grep abs-broken <<< "$md")"

# ---------------------------------------------------------------------------
# 4. A retargeted symlink is caught -- including a target of the SAME LENGTH,
#    which leaves file count and byte count identical.
# ---------------------------------------------------------------------------
d="$(build retarget)"
rm "$d/dst/config/rel-inside"; ln -s data/nested.TXT "$d/dst/config/rel-inside"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc != 0 )) || fail "4: a symlink retargeted to a same-length name verified clean: $out"
grep -q 'metadata mismatch' <<< "$out" || fail "4: not reported as a metadata mismatch: $out"

# A broken link retargeted to a DIFFERENT broken path is still a difference.
d="$(build retarget_broken)"
rm "$d/dst/config/abs-broken"; ln -s "/config/Library/Application Support/Plex Media Server/Drivers/y/dri/iHD.so" "$d/dst/config/abs-broken"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc != 0 )) || fail "4: a retargeted BROKEN symlink verified clean: $out"

# ---------------------------------------------------------------------------
# 5. A symlink REPLACED BY A REGULAR FILE must be caught, even when that file's
#    content equals the target's. The content manifest alone cannot see this:
#    the symlink was never hashed, so only the entry TYPE differs.
# ---------------------------------------------------------------------------
d="$(build typeswap)"
rm "$d/dst/config/rel-inside"; printf 'nested\n' > "$d/dst/config/rel-inside"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc != 0 )) || fail "5: a symlink replaced by a regular file verified clean: $out"
# Caught by the file count, because a symlink is not a regular file and the
# replacement is: 2 -> 3. That is the earliest possible point, which is fine.
grep -q 'file count mismatch' <<< "$out" \
  || fail "5: expected the count check to catch this first: $out"

# 5b. THE CASE ONLY METADATA CAN CATCH. Swap a symlink for a regular file AND a
# regular file for a symlink, so the regular-file COUNT is unchanged -- and give
# the new file exactly the bytes that keep the total equal too. Then the content
# manifest compares a different SET of files with no size clue, and only the
# entry types differ.
d="$(build typeswap_balanced)"
#   src: real.txt (regular, 13 B)   rel-inside (link -> data/nested.txt)
#   dst: real.txt (link -> data/nested.txt)   rel-inside (regular, 13 B)
rm "$d/dst/config/rel-inside";  printf 'real content\n' > "$d/dst/config/rel-inside"
rm "$d/dst/config/real.txt";    ln -s data/nested.txt "$d/dst/config/real.txt"
src_n="$(find "$d/src" -xdev -type f | wc -l)"; dst_n="$(find "$d/dst" -xdev -type f | wc -l)"
(( src_n == dst_n )) || fail "5b: fixture is wrong; counts differ ($src_n vs $dst_n) so this proves nothing"
src_b="$(find "$d/src" -xdev -type f -printf '%s\n' | awk '{s+=$1}END{print s+0}')"
dst_b="$(find "$d/dst" -xdev -type f -printf '%s\n' | awk '{s+=$1}END{print s+0}')"
(( src_b == dst_b )) || fail "5b: fixture is wrong; byte totals differ ($src_b vs $dst_b)"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc != 0 )) || fail "5b: a count- and byte-preserving symlink/file type swap verified CLEAN: $out"
grep -qE 'content manifest mismatch|metadata mismatch' <<< "$out" \
  || fail "5b: caught, but not by a manifest comparison: $out"

# ---------------------------------------------------------------------------
# 6. A dangling symlink must not make the manifest silently shorter.
#
# migrate_verify refuses when the manifest covers fewer files than `find`
# counted, which is how an unreadable file is stopped from dropping out of both
# sides and passing. A symlink is not a regular file, so it must not be counted
# as one -- otherwise every tree with a symlink would fail that check.
# ---------------------------------------------------------------------------
d="$(build dangling)"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc == 0 )) || fail "6: a tree with dangling symlinks could not verify at all: $out"
grep -q 'content manifest identical' <<< "$out" \
  || fail "6: the content manifest was not compared: $out"
hashed="$(grep -oE '\(([0-9]+) of ([0-9]+) file' <<< "$out" | head -1)"
[[ -n "$hashed" ]] || fail "6: the hashed count was not reported: $out"
[[ "$(grep -oE '[0-9]+' <<< "$hashed" | head -1)" == "$(grep -oE '[0-9]+' <<< "$hashed" | tail -1)" ]] \
  || fail "6: hashed count does not equal the file count: $hashed"

# ---------------------------------------------------------------------------
# 7. The real plex shape, as measured on this host: 7 symlinks, 6 relative and
#    1 absolute into a container path that does not exist here.
# ---------------------------------------------------------------------------
d="$TMP_DIR/plexshape"
rm -rf "$d"; mkdir -p "$d/src/Drivers/icr-0256789a2fae28b8b94d7939-linux-x86_64" "$d/src/Cache/va-dri-linux-x86_64"
cd "$d/src/Drivers/icr-0256789a2fae28b8b94d7939-linux-x86_64"
# Exactly the real layout measured on this host: three regular .so.2.16.0+0 files
# and six links, two of which are CHAINS (libiga64.so -> .so.2 -> .so.2.16.0+0).
printf 'lib\n' > libigdfcl.so.2.16.0+0
printf 'lib\n' > libigc.so.2.16.0+0
printf 'lib\n' > libiga64.so.2.16.0+0
ln -s libigdfcl.so.2.16.0+0 libigdfcl.so.2
ln -s libigdfcl.so.2         libigdfcl.so
ln -s libigc.so.2.16.0+0     libigc.so.2
ln -s libigc.so.2            libigc.so
ln -s libiga64.so.2.16.0+0   libiga64.so.2
ln -s libiga64.so.2          libiga64.so
cd "$d/src/Cache/va-dri-linux-x86_64"
ln -s "/config/Library/Application Support/Plex Media Server/Drivers/imd-a5431fbbff9ce9568f94ae21-linux-x86_64/dri/iHD_drv_video.so" iHD_drv_video.so
cd "$REPO_ROOT"
cp -a "$d/src" "$d/dst"
links="$(find "$d/src" -type l | wc -l)"
(( links >= 7 )) || fail "7: the fixture has $links symlinks, expected at least 7"
out="$(verify "$d/src" "$d/dst")"; rc=$?
(( rc == 0 )) || fail "7: the plex-shaped tree did not verify (rc=$rc): $out"
grep -q 'symlink targets identical' <<< "$out" || fail "7: targets not compared: $out"
# A symlink CHAIN (libiga64.so -> libiga64.so.2 -> libiga64.so.2.16.0+0) must not
# be resolved to its eventual file and hashed.
mp="$(manifest "$d/src")"
# The chain's links must not appear in the CONTENT manifest; only the three real
# .so.2.16.0+0 files may.
grep -qE '  \./Drivers/[^/]+/libiga64\.so$|  \./Drivers/[^/]+/libiga64\.so\.2$' <<< "$mp" \
  && fail "7: a link in a symlink CHAIN was hashed: $mp"
hashed_n="$(grep -c . <<< "$mp")"
real_n="$(find "$d/src" -xdev -type f | wc -l)"
(( hashed_n == real_n )) \
  || fail "7: hashed $hashed_n entries for $real_n regular files; a chain was followed:
$mp"

echo "PASS: symlink verification smoke test"
