#!/usr/bin/env bash
set -uo pipefail

# "Is this a subvolume?" decides whether risky operations are refused, whether a
# migration is a no-op, and what the report tells the operator. There used to be
# three different answers to it. This pins the single one.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

extract() {
  awk '/^# BEGIN SHARED SUBVOLUME HELPER$/,/^# END SHARED SUBVOLUME HELPER$/' "$1"
}

# ---------------------------------------------------------------------------
# 1. One implementation, byte-identical in both scripts.
#
# A detector that answers differently in the CLI and in the report is worse than
# either answer alone: the report would say "protected" while the gate refused,
# or the reverse.
# ---------------------------------------------------------------------------
a="$(extract "$REPO_ROOT/bin/domum-media")"
b="$(extract "$REPO_ROOT/bin/domum-media-report")"
[[ -n "$a" ]] || fail "bin/domum-media has no shared subvolume helper"
[[ -n "$b" ]] || fail "bin/domum-media-report has no shared subvolume helper"
[[ "$a" == "$b" ]] && : || {
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") >&2
  fail "the subvolume helper has drifted between the two scripts"
}

# The old names must resolve to the shared one, not to private copies.
grep -qE '^is_btrfs_subvol\(\)\s+\{ domum_is_subvolume' "$REPO_ROOT/bin/domum-media" \
  || fail "is_btrfs_subvol is not delegating to the shared helper"
grep -qE '^path_is_subvolume\(\)\s+\{ domum_is_subvolume' "$REPO_ROOT/bin/domum-media" \
  || fail "path_is_subvolume is not delegating to the shared helper"
# The report must not test subvolume-ness anywhere OUTSIDE the shared helper.
# (The helper itself calls `btrfs subvolume show` -- that is the whole point.)
if awk '/^# BEGIN SHARED SUBVOLUME HELPER$/,/^# END SHARED SUBVOLUME HELPER$/ {next} {print}' \
     "$REPO_ROOT/bin/domum-media-report" | grep -q 'btrfs subvolume show'; then
  fail "the report still has its own inline subvolume test outside the shared helper"
fi

run() { bash -c "set -uo pipefail
$a
$1"; }

# ---------------------------------------------------------------------------
# 2. A missing path is never a subvolume.
# ---------------------------------------------------------------------------
run "domum_is_subvolume '$TMP_DIR/nope'" && fail "a missing path was called a subvolume"
run "domum_is_subvolume ''" && fail "an empty path was called a subvolume"

# A plain file is not a subvolume either.
printf 'x\n' > "$TMP_DIR/afile"
run "domum_is_subvolume '$TMP_DIR/afile'" && fail "a regular file was called a subvolume"

# ---------------------------------------------------------------------------
# 3. inode 256 alone must NOT be enough.
#
# Inode 256 is a necessary condition for a btrfs subvolume root, not a
# sufficient one -- it is perfectly ordinary on ext4, and /srv/media on this
# host IS ext4. The old inode-only test would have said "already a subvolume"
# there and refused a migration that should have run, or worse, reported
# protection that does not exist.
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR/dir"
out="$(run "
stat() {
  case \"\$1\" in
    -f) printf 'ext2/ext3' ;;   # NOT btrfs
    *)  printf '256' ;;          # but inode 256
  esac
}
command() { return 1; }          # no btrfs tool, so the fallback is used
if domum_is_subvolume '$TMP_DIR/dir'; then echo YES; else echo NO; fi")"
[[ "$out" == "NO" ]] || fail "inode 256 on a non-btrfs filesystem was called a subvolume"

# ...and inode 256 ON btrfs must be accepted by the fallback.
out="$(run "
stat() {
  case \"\$1\" in
    -f) printf 'btrfs' ;;
    *)  printf '256' ;;
  esac
}
command() { return 1; }
if domum_is_subvolume '$TMP_DIR/dir'; then echo YES; else echo NO; fi")"
[[ "$out" == "YES" ]] || fail "inode 256 on btrfs was not accepted by the fallback"

# A non-256 inode on btrfs is an ordinary directory.
out="$(run "
stat() {
  case \"\$1\" in
    -f) printf 'btrfs' ;;
    *)  printf '4373' ;;
  esac
}
command() { return 1; }
if domum_is_subvolume '$TMP_DIR/dir'; then echo YES; else echo NO; fi")"
[[ "$out" == "NO" ]] || fail "an ordinary btrfs directory was called a subvolume"

# ---------------------------------------------------------------------------
# 4. Against the real host, the answer must match `btrfs subvolume show`.
#
# /srv/data and /srv/snapshots are subvolumes; /srv/media is a plain directory
# on ext4. Skipped when those paths are absent, so the suite stays portable.
# ---------------------------------------------------------------------------
if [[ -d /srv/data && -d /srv/media ]]; then
  # Unprivileged here, so the fallback path is what runs -- which is exactly the
  # case the ext4 false positive would have broken.
  run "domum_is_subvolume /srv/data" || fail "/srv/data was not detected as a subvolume"
  run "domum_is_subvolume /srv/media" && fail "/srv/media (ext4) was detected as a subvolume"
  # Do NOT assert that a particular service is or is not a subvolume: migrating
  # one is a legitimate operation, and this assertion failed the moment the
  # Jellyfin pilot succeeded. Assert the INVARIANT instead -- that the detector
  # agrees with the independent evidence (inode 256 on a btrfs filesystem) for
  # whatever state each service happens to be in.
  for d in /srv/data/*/; do
    [[ -d "$d" ]] || continue
    expect=no
    [[ "$(stat -c %i "$d")" == "256" && "$(stat -f -c %T "$d")" == "btrfs" ]] && expect=yes
    if run "domum_is_subvolume '$d'"; then got=yes; else got=no; fi
    [[ "$got" == "$expect" ]] \
      || fail "domum_is_subvolume said $got for $d but inode/fstype evidence says $expect"
  done
fi

# ---------------------------------------------------------------------------
# 5. The nested-subvolume detector must be regression-proof in CI.
#
# It had ZERO hermetic coverage: tests/snapshot-safety-gate-smoke.sh stubs
# domum_subvolume_nested_children outright (correctly testing the CALLERS), and
# the only test of the real thing is the Btrfs integration test -- which CI runs
# knowing it SKIPS with exit 0 on a runner without Btrfs. So `-xdev`, `-inum 256`
# or `-type d` could all be dropped and nothing in CI would fail.
#
# An inode number cannot be chosen, so the query SHAPE is pinned instead: that is
# precisely what those mutations change.
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR/probe"
args="$(bash -c "set -uo pipefail
$a
find() { printf '%s\n' \"\$*\"; }
domum_subvolume_nested_children '$TMP_DIR/probe'")"

[[ -n "$args" ]] || fail "the nested-subvolume detector did not run find at all"
grep -q -- '-xdev' <<< "$args" \
  || fail "the detector lost -xdev; it would descend into every nested subvolume and scan the whole 213 GB tree: [$args]"
grep -q -- '-inum 256' <<< "$args" \
  || fail "the detector lost -inum 256, the only thing that identifies a subvolume root: [$args]"
grep -q -- '-type d' <<< "$args" \
  || fail "the detector lost -type d; a regular file with inode 256 would be reported: [$args]"
grep -q -- '-mindepth 1' <<< "$args" \
  || fail "the detector lost -mindepth 1; the root itself is inode 256 and would always self-report: [$args]"
grep -q "$TMP_DIR/probe" <<< "$args" \
  || fail "the detector did not search the path it was given: [$args]"

# A tree with nothing nested must report nothing.
[[ -z "$(bash -c "set -uo pipefail
$a
domum_subvolume_nested_children '$TMP_DIR/probe'")" ]] \
  || fail "an ordinary directory tree reported a nested subvolume"

# A missing path must be quiet, not an error -- it is called on paths that may
# not exist yet.
bash -c "set -uo pipefail
$a
domum_subvolume_nested_children '$TMP_DIR/definitely-absent'" >/dev/null 2>&1 \
  || fail "the detector failed on a missing path instead of reporting nothing"

echo "PASS: subvolume detection smoke test"
