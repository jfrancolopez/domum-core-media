#!/usr/bin/env bash
set -uo pipefail

# `domum-media snapshot prune` DELETES snapshots, and its timer is enabled and
# runs weekly (Sun 04:30 +20m).
#
# It has never actually deleted anything: while no service path was a subvolume
# the snapshot root stayed empty. The first migration turns it into a live
# deleting job -- which is exactly the moment its safety properties start to
# matter.

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
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
DOMUM_STATE_ROOT="$TMP_DIR/state"
# Needed so latest_snapshot_for_service can resolve a service to its snapshot
# base name through the real service_data_path, rather than being stubbed.
DOMUM_DATA_ROOT="$TMP_DIR/data"
need_root() { :; }
load_cfg() { :; }
EOF
}

# Names carry a real, monotonically increasing -YYYYMMDD-HHMMSS- stamp, and the
# DIRECTORY MTIMES ARE DELIBERATELY IDENTICAL -- which is what real Btrfs
# produces, because `btrfs subvolume snapshot` copies the source subvolume root
# mtime into the snapshot. Measured on this host:
#
#   1790343086   s-20260101-000000-old
#   1790343087   s-20260601-000000-mid
#   1790343086   s-20261231-235959-newest     <- taken last, after a rollback
#
# The previous fixture used `touch -d "... +$i minutes"` to fabricate exactly the
# monotonic mtimes real Btrfs does not provide, so it validated -- and actively
# pinned -- an ordering key that cannot work.
seed_snapshots() {  # $1 = base, $2 = count
  local base="$1" n="$2" i d
  mkdir -p "$TMP_DIR/snapshots"
  for (( i = 1; i <= n; i++ )); do
    d="$TMP_DIR/snapshots/$(printf '%s-2026%02d%02d-%02d0000-tag' "$base" \
        "$(( ((i - 1) / 28) + 1 ))" "$(( ((i - 1) % 28) + 1 ))" "$(( i % 24 ))")"
    mkdir -p "$d"
    touch -d "2026-01-01 00:00:00" "$d"
  done
}

# ---------------------------------------------------------------------------
# 1. Prune deletes the OLDEST, never the newest.
#
# The newest snapshot is the one a rollback is most likely to want. Deleting
# from the wrong end would quietly destroy the freshest recovery point while
# reporting a clean run.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
# By NAME, not `ls -1t`: the mtimes are identical on purpose, so an mtime-ordered
# listing would pick an arbitrary entry and these assertions would be meaningless.
newest="$(ls -1 "$TMP_DIR/snapshots" | sort | tail -1)"
oldest="$(ls -1 "$TMP_DIR/snapshots" | sort | head -1)"
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "prune failed on a clean fixture: $out"

[[ -d "$TMP_DIR/snapshots/$newest" ]] || fail "prune deleted the NEWEST snapshot: $newest"
[[ ! -d "$TMP_DIR/snapshots/$oldest" ]] || fail "prune did not delete the oldest snapshot: $oldest"
remaining="$(ls -1 "$TMP_DIR/snapshots" | wc -l)"
(( remaining == 14 )) || fail "prune left $remaining snapshots, expected 14"
grep -q '6 deleted, 0 failed' <<< "$out" || fail "prune did not report what it did: $out"

# ---------------------------------------------------------------------------
# 1b. The rollback hazard, directly.
#
# After a rollback the live subvolume is recreated from an OLD snapshot and
# inherits its mtime, so the NEXT snapshot -- the newest recovery point there is
# -- carries an ancient mtime. Ordered by mtime it sorts near the front, and
# prune deletes `snaps[0..drop-1]`: it would delete the newest recovery point
# while keeping older ones. Measured on real Btrfs; see list_snapshots_for_base.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
rollback_newest="$TMP_DIR/snapshots/jellyfin-20261231-235959-post-rollback"
mkdir -p "$rollback_newest"
touch -d "2020-01-01 00:00:00" "$rollback_newest"     # inherited an ancient mtime
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune")" || fail "prune failed with a rollback-style snapshot present: $out"
[[ -d "$rollback_newest" ]] \
  || fail "prune deleted the NEWEST snapshot because its mtime was the oldest; ordering must key on the name timestamp, not mtime"

# ...and latest_snapshot_for_service must name it, not the one with the newest mtime.
latest="$(bash -c "$(harness)
latest_snapshot_for_service jellyfin" 2>/dev/null)"
[[ "$latest" == "jellyfin-20261231-235959-post-rollback" ]] \
  || fail "latest_snapshot_for_service named [$latest] instead of the genuinely newest snapshot"

# A snapshot whose name carries no timestamp must be excluded, not ordered
# arbitrarily: it would otherwise be pruned first (deleting something this code
# did not create) or reported as the latest snapshot.
mkdir -p "$TMP_DIR/snapshots/jellyfin-handmade"
out="$(bash -c "$(harness)
list_snapshots_for_base jellyfin" 2>&1)"
grep -q 'unrecognised name' <<< "$out" \
  || fail "a snapshot with an unparseable name was not announced: $out"
grep -q '^jellyfin-handmade$' <<< "$out" \
  && fail "a snapshot with an unparseable name was included in the ordered list"
rm -rf "$TMP_DIR/snapshots/jellyfin-handmade"

# ---------------------------------------------------------------------------
# 2. A failed delete must be reported and must fail the run.
#
# `|| true` meant the snapshot root silently never converged on the retention
# policy while the weekly unit reported success.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
# Warnings go to stderr, as they should -- capture both streams.
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { return 1; }
snapshot_prune" 2>&1)"
rc=$?
(( rc != 0 )) || fail "a prune whose deletes all failed reported success: $out"
grep -qi 'Could not delete snapshot' <<< "$out" || fail "the failed delete was not reported: $out"
grep -q '0 deleted, 6 failed' <<< "$out" || fail "the failure count was not reported: $out"
(( $(ls -1 "$TMP_DIR/snapshots" | wc -l) == 20 )) || fail "snapshots vanished despite delete failing"

# ---------------------------------------------------------------------------
# 3. Prune and snapshot-create take the operation lock.
#
# A rollback checks its snapshot exists and then creates from it. A prune
# landing between those two steps turns a routine restore into a failure.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "snapshot prune"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot prune does not take the operation lock"
grep -q 'domum_acquire_lock "snapshot create"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot create does not take the operation lock"

# Both must WAIT rather than fail: they run unattended from timers, and giving
# up would silently skip a week.
grep -q 'domum_acquire_lock "snapshot prune" "${SNAPSHOT_LOCK_WAIT_SECONDS:-900}"' "$REPO_ROOT/bin/domum-media" \
  || fail "snapshot prune must wait for the lock, not fail immediately"

# And it must actually refuse while the lock is held.
mkdir -p "$TMP_DIR/lockstate" "$TMP_DIR/snapshots"
setsid bash -c 'exec 9>>"$1/operation.lock"; flock 9; echo $$ > "$1/holder.pid"; exec sleep 30' \
  _ "$TMP_DIR/lockstate" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [[ -s "$TMP_DIR/lockstate/holder.pid" ]] && break; sleep 0.05; done
holder="$(cat "$TMP_DIR/lockstate/holder.pid" 2>/dev/null || true)"
[[ -n "$holder" ]] || fail "could not start a competing lock holder"
out="$(bash -c "$(harness)
DOMUM_STATE_ROOT='$TMP_DIR/lockstate'
SNAPSHOT_LOCK_WAIT_SECONDS=1
btrfs() { return 0; }
snapshot_cmd prune" 2>&1)"
rc=$?
kill "$holder" 2>/dev/null; wait 2>/dev/null
(( rc != 0 )) || fail "prune ran while the operation lock was held: $out"
grep -qi 'Timed out waiting' <<< "$out" || fail "the lock refusal did not explain itself: $out"

# ---------------------------------------------------------------------------
# 4. `cleanup snapshots` is a SECOND snapshot deleter. It must take the lock and
#    share one retention policy.
#
#    It was the only snapshot deleter without the lock, and it defaulted to
#    CLEANUP_OLD_SNAPSHOTS_KEEP, which the shipped example config set to 7 while
#    SNAPSHOT_KEEP_PER_SUBVOL is 14 -- so it deleted seven more snapshots per
#    service than the retention policy, including ones the weekly prune had
#    deliberately kept.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "cleanup snapshots"' "$REPO_ROOT/bin/domum-media" \
  || fail "cleanup snapshots does not take the operation lock"

# Retention can only be raised, never lowered -- asserted through the real
# candidate selection, not by re-deriving the arithmetic in the test.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
candidates_for() {  # $1 = SNAPSHOT_KEEP_PER_SUBVOL, $2 = CLEANUP_OLD_SNAPSHOTS_KEEP
  bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=$1
CLEANUP_OLD_SNAPSHOTS_KEEP=$2
cleanup_snapshot_candidates" 2>/dev/null | grep -c . || true
}
got="$(candidates_for 14 7)"
[[ "$got" == "6" ]] \
  || fail "with policy 14 and cleanup 7, cleanup must still keep 14 of 20 (6 candidates), got $got"
got="$(candidates_for 14 30)"
[[ "$got" == "0" ]] \
  || fail "with cleanup 30, nothing may be a candidate out of 20, got $got"
got="$(candidates_for 5 5)"
[[ "$got" == "15" ]] \
  || fail "with both set to 5, 15 of 20 must be candidates, got $got"

# And the shipped example must not configure the two knobs to disagree.
pol="$(grep -E '^SNAPSHOT_KEEP_PER_SUBVOL=' "$REPO_ROOT/config/domum-media.conf.example" | cut -d= -f2)"
cln="$(grep -E '^CLEANUP_OLD_SNAPSHOTS_KEEP=' "$REPO_ROOT/config/domum-media.conf.example" | cut -d= -f2)"
[[ -n "$pol" && -n "$cln" && "$cln" -ge "$pol" ]] \
  || fail "the example config sets CLEANUP_OLD_SNAPSHOTS_KEEP=$cln below SNAPSHOT_KEEP_PER_SUBVOL=$pol"

# ---------------------------------------------------------------------------
# 5. Retention can never leave a service with ZERO recovery points.
#
# `drop=$(( total - keep ))` is honest arithmetic, and that is the hazard. With
# the first real service migrated, /srv/snapshots holds exactly ONE Jellyfin
# snapshot -- so a keep of 0, or a negative or non-numeric value, would have had
# the Sunday timer delete the only recovery point that service has. Measured
# against the real snapshot_prune before the fix:
#
#   keep=14   start=1  left=1     the default and the shipped example: safe
#   keep=0    start=1  left=0     the only recovery point, gone
#   keep=-5   start=1  left=0     gone, and rc=1
#
# A RETENTION job must never zero a service. Deliberate wholesale removal is
# `cleanup snapshots --confirm`, which is attended and asks.
# ---------------------------------------------------------------------------
keep_probe() {  # $1 = configured value, $2 = snapshots to seed -> prints survivors
  rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin "$2"
  bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL='$1'
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune" >/dev/null 2>&1
  ls -1 "$TMP_DIR/snapshots" 2>/dev/null | wc -l
}

for bad in 0 -5 fourteen " "; do
  got="$(keep_probe "$bad" 1)"
  (( got >= 1 )) \
    || fail "SNAPSHOT_KEEP_PER_SUBVOL='$bad' left $got snapshots; retention must never zero a service"
done
# A malformed value must not make the weekly timer fail forever: it must warn,
# fall back to the default, and still prune correctly. The floor alone cannot do
# this -- bash arithmetic on "14abc" is an error, which under `set -e` aborts the
# run and leaves retention unapplied every single week.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL='14abc'
btrfs() { [[ \"\${1:-}\" == subvolume && \"\${2:-}\" == delete ]] && { rm -rf -- \"\${!#}\"; return 0; }; return 0; }
snapshot_prune" 2>&1)"
rc=$?
(( rc == 0 )) || fail "a malformed SNAPSHOT_KEEP_PER_SUBVOL made the prune fail outright: $out"
grep -qi 'not a non-negative integer' <<< "$out" \
  || fail "a malformed retention value was not reported: $out"
[[ "$(ls -1 "$TMP_DIR/snapshots" | wc -l)" == "14" ]] \
  || fail "a malformed value did not fall back to the default retention of 14"

# The cleanup path must go through the same validation, not its own arithmetic.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots jellyfin 20
n="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=0
CLEANUP_OLD_SNAPSHOTS_KEEP=0
cleanup_snapshot_candidates" 2>/dev/null | grep -c . || true)"
(( n <= 19 )) \
  || fail "cleanup proposed deleting all $n snapshots; it must leave at least one recovery point"
# Both knobs are validated, and the effective value is the larger of the two, so
# a bad value in either alone is absorbed. That redundancy is deliberate -- but it
# means neither is independently killable, so the assertion here is that with BOTH
# at zero the floor still holds.
(( n >= 1 )) || fail "cleanup proposed nothing to delete from 20 snapshots; the fixture is wrong"

# ...and a sane value is honoured exactly, so the floor did not become a ceiling.
[[ "$(keep_probe 14 20)" == "14" ]] || fail "keep=14 of 20 should leave 14, got $(keep_probe 14 20)"
[[ "$(keep_probe 3 20)"  == "3"  ]] || fail "keep=3 of 20 should leave 3, got $(keep_probe 3 20)"
[[ "$(keep_probe 14 1)"  == "1"  ]] || fail "keep=14 of 1 should leave 1 untouched"

# ---------------------------------------------------------------------------
# 6. One service's snapshots must never count toward another's retention.
#
# The stamp extraction was unanchored, so the glob "jellyfin-*" also matched
# "jellyfin-extra-20260301-000000-c". With a tight keep, prune would have deleted
# jellyfin's REAL snapshots while preserving the other service's. Not reachable
# with today's names -- none is a "-"-prefix of another -- but adding plex-hd or
# immich-ml would arm it silently.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"; mkdir -p "$TMP_DIR/snapshots"
for n in jellyfin-20260101-000000-a jellyfin-20260201-000000-b \
         jellyfin-extra-20260301-000000-c jellyfin-extra-20260401-000000-d \
         calibre-web-20260501-000000-e; do
  mkdir -p "$TMP_DIR/snapshots/$n"
done
listed() { bash -c "$(harness)
list_snapshots_for_base '$1'" 2>/dev/null | tr '\n' ' '; }

got="$(listed jellyfin)"
[[ "$got" == *jellyfin-20260101* && "$got" == *jellyfin-20260201* ]] \
  || fail "base 'jellyfin' lost its own snapshots: $got"
[[ "$got" != *jellyfin-extra* ]] \
  || fail "base 'jellyfin' claimed another service's snapshots: $got"
[[ "$got" != *calibre-web* ]] || fail "base 'jellyfin' claimed calibre-web snapshots: $got"

got="$(listed jellyfin-extra)"
[[ "$got" == *jellyfin-extra-20260301* ]] || fail "base 'jellyfin-extra' lost its own snapshots: $got"
[[ "$got" != *"jellyfin-20260101"* ]] || fail "base 'jellyfin-extra' claimed jellyfin snapshots: $got"

# A name with no timestamp at all is announced; a name belonging to another base
# is silently skipped. Conflating those two produced noise on every listing.
mkdir -p "$TMP_DIR/snapshots/jellyfin-handmade"
err="$(bash -c "$(harness)
list_snapshots_for_base jellyfin" 2>&1 >/dev/null)"
grep -q 'jellyfin-handmade' <<< "$err" \
  || fail "a name with no timestamp was not announced: $err"
grep -q 'jellyfin-extra' <<< "$err" \
  && fail "another base's snapshot was reported as unrecognised; that is noise: $err"

# ---------------------------------------------------------------------------
# The real production inventory, as of the first weekly run that had something to
# prune (2026-09-27). Pinned by its ACTUAL name, because the retention arithmetic
# and the name parser both have to accept it and a change to either would be
# invisible against synthetic `-tag` fixtures.
#
# The suffix is what makes it worth pinning: `-post-migration` contains a hyphen,
# so it exercises the `(-.*)?$` tail rather than a single trailing word. A name
# this code cannot parse is EXCLUDED from the listing -- which sounds safe, and is
# not: the report would then name no latest snapshot for a service that has one.
#
# docs/SNAPSHOT-PRUNE-FORENSICS.md records what the run actually did.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots"
mkdir -p "$TMP_DIR/snapshots/jellyfin-20260925-153317-post-migration"
# The mtime real Btrfs produces: the SOURCE subvolume root's, not a creation time.
touch -d "2026-06-05 15:13:09" "$TMP_DIR/snapshots/jellyfin-20260925-153317-post-migration"

got="$(bash -c "$(harness)
list_snapshots_for_base jellyfin" 2>/dev/null)"
[[ "$got" == "jellyfin-20260925-153317-post-migration" ]] \
  || fail "the real production snapshot name does not parse: [$got]"

out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
btrfs() { echo \"DELETE \${!#}\"; return 0; }
snapshot_prune" 2>&1)" || fail "prune failed against the real inventory: $out"
# Captured with 2>&1 BECAUSE the stub's output lands on stderr: snapshot_prune
# runs `btrfs subvolume delete "$victim" >&2`, so a stub that echoes is writing
# to stderr and `$(...)` takes only stdout. Without the redirect this assertion
# can never fire -- it was vacuous, in the suite that guards the live weekly
# deleting job. The directory check below it is what has actually been holding
# this section up.
grep -q 'DELETE' <<< "$out" && fail "the weekly prune would delete the only recovery point: $out"
# The PROPERTY, not the exact summary line: nothing deleted, nothing failed,
# and the keep figure stated. Pinning the whole sentence broke when the summary
# grew a recovery-point count, while what it exists to protect was untouched --
# and this project has three production aborts caused by assertions that were
# too specific.
grep -qE '0 deleted, 0 failed' <<< "$out" \
  || fail "prune did not report a clean no-op: $out"
grep -qE 'keeping 14( prunable)? per subvolume' <<< "$out" \
  || fail "prune did not state the keep figure it applied: $out"
[[ -d "$TMP_DIR/snapshots/jellyfin-20260925-153317-post-migration" ]] \
  || fail "the only snapshot is gone"

# One snapshot must survive every retention value, including the ones that used to
# delete it. This is the invariant, stated against the real inventory: a RETENTION
# job never leaves a protected service with zero recovery points.
for keep in 0 -1 "" fourteen 1 14 999; do
  out="$(bash -c "$(harness)
${keep:+SNAPSHOT_KEEP_PER_SUBVOL='$keep'}
btrfs() { echo \"DELETE \${!#}\"; return 0; }
snapshot_prune" 2>&1)"
  grep -q 'DELETE' <<< "$out" \
    && fail "SNAPSHOT_KEEP_PER_SUBVOL='$keep' would delete the only recovery point: $out"
done

# ---------------------------------------------------------------------------
# 7. A SNAPSHOT A RECOVERY POINT NAMES IS NEVER DELETED BY EITHER DELETER.
#
# `cleanup images` carefully protects the IMAGE a recovery point names, because
# a recovery point is service + snapshot + the application that wrote it. Both
# snapshot deleters selected purely by age and count and consulted no recovery
# evidence at all -- so the DATA half was unprotected while the application
# half was protected: the pairing failure from the other side.
#
# Measured on this host 2026-11-11: all seven snapshots in /srv/snapshots carry
# the recovery-point naming shape (-post-migration, -pre-upgrade), and the
# OLDEST snapshot of every migrated service IS its migration proof snapshot --
# the first thing an age-ordered retention policy deletes. Latent only because
# keep is 14 and no service has more than two.
#
# The stub DELETES FOR REAL, as section 1's does, so the assertions are about
# the filesystem rather than about a message. Output is captured with 2>&1
# because snapshot_prune redirects the delete to stderr and `warn` writes there
# too.
# ---------------------------------------------------------------------------
seed_rp() {  # $1.. = point names that have .recovery evidence
  mkdir -p "$TMP_DIR/state/snapshots"
  local n
  for n in "$@"; do
    printf "SERVICE='x'\nIMAGE_ID='sha256:aaa'\n" > "$TMP_DIR/state/snapshots/$n.recovery"
  done
}
REAL_DELETE='btrfs() { [[ "${1:-}" == subvolume && "${2:-}" == delete ]] && { rm -rf -- "${!#}"; return 0; }; return 0; }'

rm -rf "$TMP_DIR/snapshots" "$TMP_DIR/state/snapshots"
seed_snapshots plex 16
oldest="$(ls -1 "$TMP_DIR/snapshots" | sort | head -1)"
second="$(ls -1 "$TMP_DIR/snapshots" | sort | sed -n '2p')"
seed_rp "$oldest"

out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
$REAL_DELETE
snapshot_prune" 2>&1)" || fail "7: prune failed: $out"
[[ -d "$TMP_DIR/snapshots/$oldest" ]] \
  || fail "7: the weekly prune DELETED the snapshot half of a recovery point ($oldest): $out"
[[ ! -d "$TMP_DIR/snapshots/$second" ]] \
  || fail "7: protecting a recovery point must not stop retention converging --
the next oldest ($second) should have gone instead: $out"
remaining="$(ls -1 "$TMP_DIR/snapshots" | wc -l)"
(( remaining == 15 )) \
  || fail "7: expected 14 prunable + 1 protected = 15, got $remaining: $out"
grep -q '1 kept as recovery points' <<< "$out" \
  || fail "7: the prune did not STATE what it protected -- a deletion tool that
silently omits things gives no way to notice the protection broke: $out"
echo "  7: the weekly prune keeps recovery points, states the count, still converges"

# The same protection, through the same implementation, in the second deleter.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots plex 16
seed_rp "$oldest"
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
CLEANUP_OLD_SNAPSHOTS_KEEP=14
cleanup_snapshot_candidates" 2>&1)" || fail "7: candidates failed: $out"
grep -qx "$oldest" <<< "$out" \
  && fail "7: \`cleanup snapshots\` offered a recovery point for deletion: $out"
grep -qx "$second" <<< "$out" \
  || fail "7: the cleanup selector must still offer the next oldest: $out"
[ "$(grep -c . <<< "$out")" = "1" ] \
  || fail "7: the cleanup selector offered more than the one eligible snapshot: $out"
echo "  7: cleanup snapshots never offers a recovery point either"

# ---------------------------------------------------------------------------
# 8. UNREADABLE EVIDENCE IS NOT "NOTHING IS PROTECTED".
#
# "There are no recovery points" and "I could not look" are different facts and
# only one of them is safe to prune on. An ABSENT metadata directory is the
# honest former -- it is created by ensure_state_dirs and is empty before the
# first migration -- so it must NOT refuse, or a pre-migration host could never
# prune at all.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/snapshots" "$TMP_DIR/state/snapshots"; seed_snapshots plex 16
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
$REAL_DELETE
snapshot_prune" 2>&1)" || fail "8: an absent metadata directory must not refuse: $out"
grep -q '0 kept as recovery points' <<< "$out" \
  || fail "8: with no evidence directory nothing is protected, and that is correct: $out"
[[ ! -d "$TMP_DIR/snapshots/$oldest" ]] \
  || fail "8: with no recovery evidence the oldest is an ordinary snapshot: $out"

# Present and UNREADABLE: refuse, delete nothing, and fail so the unit records it.
rm -rf "$TMP_DIR/snapshots"; seed_snapshots plex 16
seed_rp "$oldest"
chmod 000 "$TMP_DIR/state/snapshots"
rc=0
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
$REAL_DELETE
snapshot_prune" 2>&1)" || rc=$?
chmod 755 "$TMP_DIR/state/snapshots"
(( rc != 0 )) \
  || fail "8: unreadable recovery evidence must FAIL the prune, not read as
'nothing is protected' (rc=$rc): $out"
[ "$(ls -1 "$TMP_DIR/snapshots" | wc -l)" = "16" ] \
  || fail "8: it pruned blind: $out"
grep -qi 'could not be read' <<< "$out" \
  || fail "8: the refusal does not say why: $out"

# ...and the destructive cleanup refuses rather than offering them.
chmod 000 "$TMP_DIR/state/snapshots"
rc=0
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
$REAL_DELETE
cleanup_snapshots_execute 0 1" 2>&1)" || rc=$?
chmod 755 "$TMP_DIR/state/snapshots"
(( rc != 0 )) || fail "8: cleanup proceeded with unreadable evidence: $out"
[ "$(ls -1 "$TMP_DIR/snapshots" | wc -l)" = "16" ] \
  || fail "8: cleanup deleted blind: $out"
grep -qi 'Refusing destructive cleanup' <<< "$out" \
  || fail "8: cleanup's refusal does not name the cause: $out"

# cleanup_summary must not ABORT on it. The report prints only after every line
# is built, so an aborted summary is a blank screen -- indistinguishable from a
# healthy one, which is the defect that once blanked `checkup` in production.
chmod 000 "$TMP_DIR/state/snapshots"
rc=0
out="$(bash -c "$(harness)
SNAPSHOT_KEEP_PER_SUBVOL=14
# Returns 0 and prints nothing: the CLI sources with \`set -euo pipefail\`, so a
# docker stub that FAILS kills the shell at the first assignment and the section
# would then be measuring that instead of the snapshot branch.
docker() { return 0; }
cleanup_summary" 2>&1)" || rc=$?
chmod 755 "$TMP_DIR/state/snapshots"
grep -q 'Cleanup summary:' <<< "$out" \
  || fail "8: cleanup_summary produced no report at all (rc=$rc): $out"
grep -qi 'Snapshots beyond retention: unknown' <<< "$out" \
  || fail "8: cleanup_summary must say the figure is unknown rather than print a
guess or abort: $out"
echo "  8: unreadable evidence refuses in both deleters, absent evidence does not"

# ---------------------------------------------------------------------------
# 9. MUTATION: removing the protection must delete the recovery point.
#
# Against a COPY, so a run stopped mid-way cannot leave the mutant in the tree.
# ---------------------------------------------------------------------------
cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/mut-cli"
cat > "$TMP_DIR/mut9.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''      if [[ -n "${rp_protected[$s_name]:-}" ]]; then
        protected_seen=$(( protected_seen + 1 ))
        continue
      fi
'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
print("applied")
PY
python3 -I "$TMP_DIR/mut9.py" "$TMP_DIR/mut-cli" >/dev/null \
  || fail "9: the protection mutation did not apply"
rm -rf "$TMP_DIR/snapshots"; seed_snapshots plex 16
seed_rp "$oldest"
out="$(bash -c "set -uo pipefail
DOMUM_DIR=\"$REPO_ROOT\"
CFG_FILE=\"$TMP_DIR/absent.conf\"
source \"$TMP_DIR/mut-cli\"
DOMUM_SNAPSHOT_ROOT=\"$TMP_DIR/snapshots\"
DOMUM_STATE_ROOT=\"$TMP_DIR/state\"
DOMUM_DATA_ROOT=\"$TMP_DIR/data\"
need_root() { :; }
load_cfg() { :; }
SNAPSHOT_KEEP_PER_SUBVOL=14
$REAL_DELETE
snapshot_prune" 2>&1)" || fail "9: the mutant failed for an unrelated reason: $out"
[[ ! -d "$TMP_DIR/snapshots/$oldest" ]] \
  || fail "9: the mutation applied but the recovery point survived, so section 7
would pass without the protection: $out"
echo "  9: without the protection the proof snapshot is deleted"
rm -rf "$TMP_DIR/snapshots" "$TMP_DIR/state/snapshots"

echo "PASS: snapshot prune safety smoke test"
