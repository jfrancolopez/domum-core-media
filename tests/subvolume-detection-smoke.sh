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
  if [[ -d /srv/data/jellyfin ]]; then
    run "domum_is_subvolume /srv/data/jellyfin" \
      && fail "/srv/data/jellyfin is an ordinary directory but was detected as a subvolume"
  fi
fi

echo "PASS: subvolume detection smoke test"
