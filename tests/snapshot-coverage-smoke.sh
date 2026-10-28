#!/usr/bin/env bash
set -uo pipefail

# Proves `verify-snapshot-coverage` establishes claim 2 of 4 honestly.
#
#   1 LOCAL           the file the asset table names exists here
#   2 IN SNAPSHOT     that path is present in a real off-site snapshot
#   3 RESTORE TESTED  restored from it and compared byte-wise
#   4 APP USABLE      a recovered Immich served it
#
# Claim 2 was previously INFERRED -- "the library is under the backup root and
# no exclusion matches it" is an argument about configuration, not an
# observation of the repository. This reconciles every originalPath against a
# snapshot's own file list, which `restic ls` provides from tree metadata
# without downloading any file content.
#
# Uses a REAL restic repository in scratch when restic is available, because the
# whole claim rests on what restic actually lists. Everything else is hermetic.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"; LIB="$DATA/immich/library"; STATE="$TMP_DIR/state"
mkdir -p "$LIB/upload/aa/bb" "$LIB/encoded-video/cc/dd" "$LIB/thumbs/ee" \
         "$STATE" "$TMP_DIR/media" "$TMP_DIR/bin"

# The host must be unreachable: an un-stubbed asset-table call once queried the
# LIVE production database from inside a fixture.
cat > "$TMP_DIR/bin/docker" <<'NODOCKER'
#!/usr/bin/env bash
echo "docker is deliberately unavailable in this test" >&2
exit 127
NODOCKER
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

O1="$LIB/upload/aa/bb/11111111-2222-3333-4444-555555555555.heic"
O2="$LIB/upload/aa/bb/66666666-7777-8888-9999-aaaaaaaaaaaa.MOV"
MP="$LIB/encoded-video/cc/dd/676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4"
head -c 300 /dev/urandom > "$O1"
head -c 400 /dev/urandom > "$O2"
head -c 500 /dev/urandom > "$MP"
head -c 200 /dev/urandom > "$LIB/encoded-video/cc/dd/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4"
head -c 100 /dev/urandom > "$LIB/thumbs/ee/t_thumbnail.webp"
printf 'marker' > "$LIB/upload/.immich"

cat > "$TMP_DIR/dbstub.sh" <<STUB
immich_db_original_paths() { printf '%s\n' '$O1' '$O2' '$MP'; }
STUB

# \$1 = setup evaluated after sourcing, \$2.. = args
run_cov() {
  local setup="${1:-}"; shift || true
  (
    export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media" DOMUM_STATE_ROOT="$STATE"
    export IMMICH_LIBRARY_DIR="$LIB" BACKUP_TARGETS=cloud
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    # shellcheck disable=SC1090
    source "$TMP_DIR/dbstub.sh"
    set +e
    die() { echo "DIE: $*"; exit 9; }
    log() { :; }
    backup_target_enabled() { return 0; }
    [[ -n "$setup" ]] && eval "$setup"
    do_verify_snapshot_coverage cloud "$@"
    echo "EXITCODE=$?"
  )
}

# A listing stub standing in for restic when no repository is available.
LS_FULL="$TMP_DIR/ls-full"; LS_PART="$TMP_DIR/ls-part"
printf '%s\n' "$O1" "$O2" "$MP" "$LIB/thumbs/ee/t_thumbnail.webp" > "$LS_FULL"
printf '%s\n' "$O1" "$O2" "$LIB/thumbs/ee/t_thumbnail.webp" > "$LS_PART"
SNAP_STUB='restic_for_target() {
  shift
  case "$1" in
    snapshots) echo "[{\"short_id\":\"stub0001\"}]" ;;
    ls) cat "'"$LS_FULL"'" ;;
  esac
  return 0
}'
SNAP_STUB_PART='restic_for_target() {
  shift
  case "$1" in
    snapshots) echo "[{\"short_id\":\"stub0001\"}]" ;;
    ls) cat "'"$LS_PART"'" ;;
  esac
  return 0
}'

# ---------------------------------------------------------------------------
sect "every original present in the listing => covered, exit 0"
out="$(run_cov "$SNAP_STUB")"
grep -q 'EXITCODE=0' <<< "$out" || fail "a complete listing did not exit 0: $out"
grep -q 'IN the snapshot   : 3 of 3' <<< "$out" || fail "wrong coverage count: $out"
grep -q 'claim 2 of 4' <<< "$out" \
  || fail "it does not say WHICH claim it established: $out"
grep -qi 'not yet restored' <<< "$out" \
  || fail "it must disclaim the stronger claims: $out"
echo "  3 of 3, exit 0, and it names the claim it did NOT make"

sect "the motion-photo original under encoded-video/ is reconciled too"
grep -q 'originals         : 3' <<< "$out" || fail "the MP original was not counted: $out"
echo "  all three, including the one outside upload/"

sect "an original absent from the listing is NAMED and never passes"
# This asserted exit 1 unconditionally. A missing original whose INGEST TIME
# cannot be established is now UNKNOWN (exit 2) rather than being called a gap:
# this fixture stubs no success record for the snapshot, so there is no backup
# window to classify against. The invariant that matters is that it is named,
# reported, and does not pass -- not which non-zero status it returns.
out="$(run_cov "$SNAP_STUB_PART")"
grep -q 'EXITCODE=0' <<< "$out" && fail "a missing original must never pass: $out"
grep -q 'IN the snapshot   : 2 of 3' <<< "$out" || fail "wrong count: $out"
grep -q 'MISSING FROM THE SNAPSHOT: 1' <<< "$out" || fail "the gap is not stated: $out"
grep -q -- '676850ba' <<< "$out" || fail "the missing original is not NAMED: $out"
grep -q 'NOT protected off-site' <<< "$out" || fail "the consequence is not stated: $out"
grep -q 'NOT CLASSIFIED' <<< "$out" \
  || fail "with no backup window it must say the timing is not established: $out"
grep -q 'result            : UNKNOWN' <<< "$out" \
  || fail "an unclassifiable absence must be UNKNOWN, not a gap: $out"
echo "  2 of 3, named, NOT CLASSIFIED, UNKNOWN -- and never exit 0"

sect "generated files and markers are never counted as originals"
# The listing contains a thumbnail and the library a marker; neither is in the
# asset table, so neither may appear in the denominator.
grep -q 'originals         : 3' <<< "$out" \
  || fail "the denominator is not the asset table's count: $out"
grep -q 'thumbnail' <<< "$out" && fail "a generated file appeared in the result"
grep -q '\.immich' <<< "$out" && fail "a marker appeared in the result"
echo "  the denominator is the asset table, so neither can leak in"

# ---------------------------------------------------------------------------
sect "an unobtainable listing is UNKNOWN, never a pass"
out="$(run_cov "$SNAP_STUB
snapshot_path_listing() { return 1; }")"
grep -q 'EXITCODE=2' <<< "$out" || fail "an unobtainable listing did not exit 2: $out"
grep -q 'UNKNOWN' <<< "$out" || fail "it did not say UNKNOWN: $out"
grep -q 'proves nothing' <<< "$out" || fail "it did not refuse explicitly: $out"
grep -q 'IN the snapshot' <<< "$out" && fail "it reported a coverage count anyway"
echo "  exit 2, and no count is reported"

sect "a listing with no library path is UNKNOWN (the vacuity guard)"
# Untranslated or wrong-root paths match nothing, so "0 missing" would be the
# most reassuring possible answer to a comparison that never happened.
out="$(run_cov "$SNAP_STUB
snapshot_path_listing() { printf '/somewhere/else/x\n' > \"\$3\"; return 0; }")"
grep -q 'EXITCODE=2' <<< "$out" || fail "an empty-intersection listing did not exit 2: $out"
grep -q 'nothing to match against' <<< "$out" || fail "it did not explain: $out"
echo "  a comparison with no overlap refuses instead of passing"

sect "no snapshot at all is UNKNOWN"
out="$(run_cov 'restic_for_target() { shift; case "$1" in snapshots) echo "[]" ;; esac; return 0; }')"
grep -q 'EXITCODE=2' <<< "$out" || fail "no snapshot did not exit 2: $out"
echo "  exit 2 when no snapshot can be identified"

sect "an unreadable asset table REFUSES"
out="$(run_cov 'immich_db_original_paths() { return 1; }')"
# `die` exits the subshell, so no EXITCODE line is printed -- the refusal
# itself is the observable, and no coverage figure may be reported with it.
grep -q 'asset table could not be read' <<< "$out" || fail "the cause is not named: $out"
grep -q 'IN the snapshot' <<< "$out" && fail "it reported a coverage count while refusing"
grep -q 'result            :' <<< "$out" && fail "it reported a verdict while refusing"
echo "  it refuses rather than guessing the originals"

# ---------------------------------------------------------------------------
sect "evidence is recorded at 0600 and reports the snapshot it is about"
run_cov "$SNAP_STUB" >/dev/null
EV="$STATE/restore-verification/cloud-snapshot-coverage.json"
[[ -f "$EV" ]] || fail "no evidence file"
[[ "$(stat -c %a "$EV")" == "600" ]] || fail "evidence is not mode 0600"
[[ "$(jq -r '.in_snapshot' "$EV")" == "3" ]] || fail "wrong in_snapshot recorded"
[[ "$(jq -r '.missing_from_snapshot' "$EV")" == "0" ]] || fail "wrong missing recorded"
[[ "$(jq -r '.snapshot_id' "$EV")" == "stub0001" ]] || fail "the snapshot id is not recorded"
echo "  0600, with the counts and the snapshot id"

sect "--json is machine-readable and agrees with the text"
out="$(run_cov "$SNAP_STUB_PART" --json)"
line="$(grep '^{' <<< "$out" | head -1)"
[[ -n "$line" ]] || fail "no JSON was emitted: $out"
# The verdict comes from ONE decision function, so the JSON and the printed
# report cannot disagree. Here the timing is unestablishable, so both say
# "unknown" -- and the JSON carries the per-class counts and the window it
# used, which is what automation needs to tell a gap from an upload.
jq -e '.result == "unknown" and .in_snapshot == 2 and .missing_from_snapshot == 1
       and .missing_classified == "unknown"
       and .missing_backup_gap == 0' \
  <<< "$line" >/dev/null || fail "the JSON disagrees with the text: $line"
grep -q 'result            : UNKNOWN' <<< "$out" \
  || fail "the text verdict does not match the JSON: $out"
echo "  result=unknown in BOTH, 2 in, 1 missing, gap=0, classified=unknown"

# ---------------------------------------------------------------------------
sect "against a REAL restic repository"
if command -v restic >/dev/null 2>&1; then
  R="$TMP_DIR/repo"; mkdir -p "$R"
  export RESTIC_REPOSITORY="$R" RESTIC_PASSWORD=coverage-test
  if restic init >/dev/null 2>&1; then
    REAL='restic_for_target() { shift; RESTIC_REPOSITORY="'"$R"'" RESTIC_PASSWORD=coverage-test restic "$@"; }'
    restic backup "$LIB" >/dev/null 2>&1 || fail "the scratch backup failed"
    out="$(run_cov "$REAL")"
    grep -q 'EXITCODE=0' <<< "$out" || fail "a real complete snapshot did not pass: $out"
    grep -q 'IN the snapshot   : 3 of 3' <<< "$out" || fail "real listing miscounted: $out"
    # Now a snapshot that really excludes one original.
    restic backup --exclude "$LIB/encoded-video/**/*-MP.mp4" "$LIB" >/dev/null 2>&1 \
      || fail "the excluding backup failed"
    out="$(run_cov "$REAL")"
    grep -q 'EXITCODE=0' <<< "$out" \
      && fail "restic really excluded an original and coverage still passed: $out"
    grep -q -- '676850ba' <<< "$out" || fail "the really-missing original was not named: $out"
    echo "  restic's own file list drives both verdicts"

    # The same real exclusion, now with a backup WINDOW available and the
    # original's ingest time before it: a genuine defect must come out as a
    # BACKUP GAP with exit 1, not be softened to UNKNOWN. This is the assertion
    # that keeps the new classification from excusing real failures.
    WINDOWED="$REAL
dr_last_success_run() { printf '%s %s' '2099-01-01T00:00:00+00:00' \
  \"\$(restic_for_target cloud snapshots --latest 1 --json 2>/dev/null \
       | jq -r '.[-1].short_id')\"; }
immich_db_paths_by_ingest() {
  case \"\$1\" in before) immich_db_original_paths ;; after) : ;; esac; return 0; }"
    out="$(run_cov "$WINDOWED")"
    grep -q 'EXITCODE=1' <<< "$out" \
      || fail "a real exclusion with a known window must exit 1: $out"
    grep -q 'result            : BACKUP GAP' <<< "$out" \
      || fail "a real exclusion must be classified as a BACKUP GAP: $out"
    grep -qE 'BACKUP GAP +: 1' <<< "$out" || fail "the gap count is wrong: $out"
    grep -q 'BACKUP GAP list' <<< "$out" \
      || fail "the gap paths must be written to durable evidence: $out"
    echo "  a real restic exclusion is a BACKUP GAP: exit 1, counted, listed"
  else
    echo "  SKIPPED: restic is present but a scratch repository could not be created"
  fi
else
  echo "  SKIPPED: restic is not installed here"
fi

# ---------------------------------------------------------------------------
sect "mutation: dropping the vacuity guard must turn a void comparison into a pass"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('  if [[ "${n_lib_paths:-0}" -eq 0 ]]; then',
            '  if [[ "${n_lib_paths:-0}" -eq -1 ]]; then', 1)
open(p,'w').write(s)
PY
mout="$(
  export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media" DOMUM_STATE_ROOT="$STATE"
  export IMMICH_LIBRARY_DIR="$LIB" BACKUP_TARGETS=cloud
  source "$MUT" >/dev/null 2>&1
  source "$TMP_DIR/dbstub.sh"
  set +e
  die() { echo "DIE: $*"; exit 9; }
  log() { :; }
  backup_target_enabled() { return 0; }
  restic_for_target() { shift; case "$1" in snapshots) echo '[{"short_id":"s"}]' ;; esac; return 0; }
  snapshot_path_listing() { printf "/somewhere/else/x\n" > "$3"; return 0; }
  do_verify_snapshot_coverage cloud 2>&1
  echo "EXITCODE=$?"
)"
grep -q 'MISSING FROM THE SNAPSHOT: 3' <<< "$mout" \
  || fail "the mutant did not report a void comparison as a result: $mout"
# A non-zero status, whichever it is: without the guard the mutant produces a
# VERDICT from a comparison that matched nothing. The specific code depends on
# whether the timing could be classified, which is not what this mutation is
# about.
grep -q 'EXITCODE=0' <<< "$mout" \
  && fail "the mutant passed a void comparison: $mout"
echo "  without the guard it reports all 3 as missing from a listing it never matched"

# ---------------------------------------------------------------------------
# A long missing list, under PRODUCTION's shell options.
#
# The suite's run_cov sets `set +e`, which is why it could never catch this:
# with more than 20 originals missing, `sed … "$missing" | head -20 | sed …`
# gave the first sed SIGPIPE, the pipeline reported 141, and under the CLI's
# own `set -euo pipefail` the function DIED there -- losing the "... and N
# more" line, losing its own "result : INCOMPLETE" verdict, and exiting 141
# instead of 1. Reproduced against the real function before it was fixed.
#
# A test that relaxes production's shell options is not a test of production.
BIG_LIB="$TMP_DIR/biglib"; mkdir -p "$BIG_LIB/upload/aa"
: > "$TMP_DIR/big-paths"; : > "$TMP_DIR/big-ls"; : > "$TMP_DIR/big-recent"
for i in $(seq 1 100); do
  bp="$BIG_LIB/upload/aa/6a835020-9702-4d77-a085-67d2e0bc3c37-$i-000000000000.HEIC"
  : > "$bp"; echo "$bp" >> "$TMP_DIR/big-paths"
  [ "$i" -le 31 ] && echo "$bp" >> "$TMP_DIR/big-ls"
done

# Run the real function in its OWN bash process with production's options.
#
# Not `( … ) || rc=$?`: bash suppresses errexit inside a function invoked as
# part of a `&&`/`||` list, which would defeat the whole point -- the defect was
# a pipeline aborting the function UNDER errexit. A separate process keeps
# errexit genuinely active and still yields an exit status to assert on.
run_strict() {  # $1 = file of paths created after the snapshot (may be empty)
  # $1 = paths ingested at/after the window CLOSED (pending)
  # $2 = paths ingested at/before the window OPENED (a gap) -- optional
  local recent="$1" before="${2:-}" script="$TMP_DIR/strict.sh"
  local T_OLD="$TMP_DIR/big-old"
  if [[ -n "$before" ]]; then cp "$before" "$T_OLD"; else : > "$T_OLD"; fi
  cat > "$script" <<SH
export DOMUM_DATA_ROOT="$TMP_DIR/data" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$STATE" IMMICH_LIBRARY_DIR="$BIG_LIB" BACKUP_TARGETS=cloud
export T_OLD="$T_OLD"
source "${CLI_UNDER_TEST:-$REPO_ROOT/bin/domum-media-backup}" >/dev/null 2>&1
set -euo pipefail
immich_db_original_paths() { cat "$TMP_DIR/big-paths"; }
immich_db_paths_by_ingest() {
  # \$1 is escaped: this heredoc is UNQUOTED, so a bare \$1 would be expanded
  # by the shell WRITING the script and the case would never match -- which it
  # did, silently classifying every missing original as "during the window".
  case "\$1" in
    before) [[ -s "$T_OLD" ]] && cat "$T_OLD" ;;
    after)  [[ -s "$recent" ]] && cat "$recent" ;;
  esac
  return 0
}
dr_last_success_run() { printf '%s %s' '2026-10-12T02:45:00-04:00' 'b18ea965'; }
snapshot_path_listing() { cp "$TMP_DIR/big-ls" "\$3"; return 0; }
restic_for_target() { printf '[{"short_id":"b18ea965","time":"2026-10-12T02:42:57-04:00"}]'; }
backup_target_enabled() { return 0; }
log() { :; }
do_verify_snapshot_coverage cloud
SH
  local out rc
  out="$(bash "$script" 2>&1)"; rc=$?
  printf '%s\nEXITCODE=%s\n' "$out" "$rc"
}

sect "69 missing under set -e keeps its remainder line AND its verdict"
: > "$TMP_DIR/big-recent"
out="$(run_strict "$TMP_DIR/big-recent")"
grep -q 'MISSING FROM THE SNAPSHOT: 69' <<< "$out" \
  || fail "the missing count is wrong: $out"
grep -q '\.\.\. and 49 more' <<< "$out" \
  || fail "the remainder line was lost -- the pipeline died before it: $out"
grep -qE 'result            : (BACKUP GAP|UNKNOWN|PENDING)' <<< "$out" \
  || fail "the verdict was lost, which is the whole defect: $out"
# The point is that a MEANINGFUL status survives the long listing, not which
# one: with no ingest evidence either way these 69 are UNKNOWN, not a gap.
rc="$(sed -nE 's/^EXITCODE=([0-9]+)$/\1/p' <<< "$out" | tail -1)"
case "$rc" in
  1|2|3) : ;;
  *) fail "the status must be a verdict (1/2/3), not 141 or 0; got '$rc': $out" ;;
esac
echo "  20 shown, 49 more announced, a verdict stated, exit $rc (not 141)"

sect "the FULL missing list is durable evidence, not 20 terminal lines"
mf="$STATE/restore-verification/cloud-snapshot-missing.txt"
[[ -f "$mf" ]] || fail "the full list was not written"
[[ "$(grep -c . "$mf")" == "69" ]] \
  || fail "the durable list holds $(grep -c . "$mf") path(s), not 69"
[[ "$(stat -c %a "$mf")" == "600" ]] || fail "the list is mode $(stat -c %a "$mf"), not 600"
grep -q "$mf" <<< "$out" || fail "the report does not name the full list: $out"
grep -qE '^upload/aa/' "$mf" || fail "the list should be library-relative: $(head -1 "$mf")"
echo "  69 paths at 0600, named in the report, library-relative"

sect "missing originals are split by whether they EXISTED at snapshot time"
# All 69 were added after it: expected, and reported as PENDING rather than as
# a coverage failure. Without this the line fired every day anything was
# uploaded and read identically to a genuinely dropped original.
tail -n +32 "$TMP_DIR/big-paths" > "$TMP_DIR/big-recent"
out="$(run_strict "$TMP_DIR/big-recent")"
grep -qE 'PENDING next run  +: 69' <<< "$out" \
  || fail "the newer count is wrong: $out"
grep -qE 'BACKUP GAP        +: 0' <<< "$out" \
  || fail "the older count is wrong: $out"
grep -q 'result            : PENDING' <<< "$out" \
  || fail "all-newer must be PENDING, not a coverage failure: $out"
grep -q 'only on THIS host' <<< "$out" \
  || fail "PENDING must still say they are unprotected right now: $out"
grep -q 'EXITCODE=3' <<< "$out" || fail "PENDING must have its own exit status: $out"
echo "  69 after / 0 before -> PENDING, exit 3, still called unprotected"

sect "an original INGESTED BEFORE the window opened is a BACKUP GAP"
# 5 of the 69 were already in Immich when the backup began, so their absence is
# a defect and not a pending upload. This is the classification that must never
# be softened.
tail -n +37 "$TMP_DIR/big-paths" > "$TMP_DIR/big-recent"
sed -n '32,36p' "$TMP_DIR/big-paths" > "$TMP_DIR/big-before"
out="$(run_strict "$TMP_DIR/big-recent" "$TMP_DIR/big-before")"
grep -qE 'BACKUP GAP        +: 5' <<< "$out" \
  || fail "the 5 originals ingested before the window are not counted: $out"
grep -q 'BACKUP GAP list' <<< "$out" \
  || fail "the gap paths must be written to durable evidence: $out"
[[ "$(grep -c . "$STATE/restore-verification/cloud-snapshot-gap.txt")" == "5" ]] \
  || fail "the durable gap list does not hold exactly the 5 gap paths"
grep -q 'result            : BACKUP GAP' <<< "$out" \
  || fail "an original ingested before the window must be a BACKUP GAP: $out"
grep -q 'EXITCODE=1' <<< "$out" || fail "a real gap must exit 1: $out"
echo "  5 predate it -> INCOMPLETE, exit 1"

sect "recency comes from the asset TABLE, never the file's mtime"
# Measured in production 2026-10-12: 69 assets had createdAt after the snapshot
# while only 27 files had a newer mtime, because an uploaded photo keeps a date
# from the file it came from. Reasoning from mtime would have reported 42
# originals as genuinely missing -- a false alarm about family photos.
#
# Here EVERY file is given an mtime long before the snapshot while the table
# says all 69 are new. If the code consulted mtime it would call them a gap.
find "$BIG_LIB" -type f -exec touch -d '2020-01-01 00:00:00' {} +
tail -n +32 "$TMP_DIR/big-paths" > "$TMP_DIR/big-recent"
out="$(run_strict "$TMP_DIR/big-recent")"
grep -q 'result            : PENDING' <<< "$out" \
  || fail "mtime appears to have overridden the asset table: $out"
grep -qE 'BACKUP GAP        +: 0' <<< "$out" \
  || fail "files with a 2020 mtime were treated as predating the snapshot: $out"
echo "  a 2020 mtime does not make a new asset old; the table decides"

sect "an unreadable split says so rather than guessing"
out="$(
  (
    export DOMUM_DATA_ROOT="$TMP_DIR/data" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
    export DOMUM_STATE_ROOT="$STATE" IMMICH_LIBRARY_DIR="$BIG_LIB" BACKUP_TARGETS=cloud
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set -euo pipefail
    immich_db_original_paths() { cat "$TMP_DIR/big-paths"; }
    immich_db_paths_by_ingest() { return 1; }
    snapshot_path_listing() { cp "$TMP_DIR/big-ls" "$3"; return 0; }
    restic_for_target() { printf '[{"short_id":"b18ea965","time":"2026-10-12T02:42:57-04:00"}]'; }
    backup_target_enabled() { return 0; }
    log() { :; }
    do_verify_snapshot_coverage cloud
    echo "EXITCODE=$?"
  ) 2>&1
)"
grep -q 'NOT CLASSIFIED' <<< "$out" \
  || fail "an unreadable asset table must be admitted, not guessed: $out"
grep -q 'result            : UNKNOWN' <<< "$out" \
  || fail "an unestablishable window must not be promoted to PENDING: $out"
echo "  unknown split is stated, and never promoted to PENDING"

sect "originals ABSENT from disk are still compared against the snapshot"
# `cut -f2 "$inv"` built the comparison set from a `stat` walk, so an original
# the table names but which is not on disk never entered it. With all of them
# absent the set was EMPTY, the comparison did nothing, and the report said
# "IN the snapshot: 3000 of 3000". Found by a fixture that created no files --
# the same hole this file already records for the exclusion audit. Whether a
# file is on disk today is a different question from whether its path is in
# the snapshot.
ABS_LIB="$TMP_DIR/abslib"; mkdir -p "$ABS_LIB/upload/aa"
: > "$TMP_DIR/abs-paths"
for i in 1 2 3 4 5; do
  echo "$ABS_LIB/upload/aa/never-written-$i.HEIC" >> "$TMP_DIR/abs-paths"
done
head -n 2 "$TMP_DIR/abs-paths" > "$TMP_DIR/abs-ls"
run_abs() {  # $1 = paths file, $2 = listing file
  local script="$TMP_DIR/abs.sh"
  cat > "$script" <<SH
export DOMUM_DATA_ROOT="$TMP_DIR/data" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$STATE" IMMICH_LIBRARY_DIR="$ABS_LIB" BACKUP_TARGETS=cloud
source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
set -euo pipefail
immich_db_original_paths() { [[ -s "$1" ]] && cat "$1"; return 0; }
immich_db_paths_by_ingest() { return 1; }
snapshot_path_listing() { cp "$2" "\$3"; return 0; }
restic_for_target() { printf '[{"short_id":"b18ea965","time":"2026-10-12T02:42:57-04:00"}]'; }
backup_target_enabled() { return 0; }
log() { :; }
do_verify_snapshot_coverage cloud
SH
  local out rc; out="$(bash "$script" 2>&1)"; rc=$?
  printf '%s\nEXITCODE=%s\n' "$out" "$rc"
}
out="$(run_abs "$TMP_DIR/abs-paths" "$TMP_DIR/abs-ls")"
grep -q 'MISSING FROM THE SNAPSHOT: 3' <<< "$out" \
  || fail "3 absent-on-disk originals are missing from the snapshot and must be
reported as such, not skipped because no file exists: $out"
grep -q '3 of 3' <<< "$out" && fail "it claimed full coverage having compared nothing: $out"
echo "  5 paths, none on disk: 2 in the snapshot, 3 reported missing"

sect "an asset table that yields NO paths is UNKNOWN, never full coverage"
: > "$TMP_DIR/abs-empty"
out="$(run_abs "$TMP_DIR/abs-empty" "$TMP_DIR/abs-ls")"
grep -qE 'UNKNOWN|REFUS|Refusing' <<< "$out" \
  || fail "an empty comparison side must refuse, not pass: $out"
grep -q 'result            : every original' <<< "$out" \
  && fail "it reported full coverage from an empty table: $out"
echo "  an empty left-hand side refuses instead of reporting a clean sweep"

sect "mutation: restoring the head pipeline must lose the verdict again"
# SIGPIPE only fires while the writer still has data to push, so the mutation
# needs a list that cannot fit the 64 KiB pipe buffer -- 3,000 paths, ~330 KB.
# At 69 paths the mutant survives, which is precisely why this defect sat in
# production unnoticed and why the fixture must be sized deliberately rather
# than left at "enough to exceed 20".
: > "$TMP_DIR/huge-paths"; : > "$TMP_DIR/huge-ls"
for i in $(seq 1 3000); do
  echo "$BIG_LIB/upload/aa/6a835020-9702-4d77-a085-67d2e0bc3c37-$i-00000000000000000000.HEIC"
done > "$TMP_DIR/huge-paths"
head -n 1 "$TMP_DIR/huge-paths" > "$TMP_DIR/huge-ls"

run_huge() {  # $1 = CLI to drive
  local cli="$1" script="$TMP_DIR/huge.sh"
  cat > "$script" <<SH
export DOMUM_DATA_ROOT="$TMP_DIR/data" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$STATE" IMMICH_LIBRARY_DIR="$BIG_LIB" BACKUP_TARGETS=cloud
source "$cli" >/dev/null 2>&1
set -euo pipefail
immich_db_original_paths() { cat "$TMP_DIR/huge-paths"; }
immich_db_paths_by_ingest() { return 1; }
snapshot_path_listing() { cp "$TMP_DIR/huge-ls" "\$3"; return 0; }
restic_for_target() { printf '[{"short_id":"b18ea965","time":"2026-10-12T02:42:57-04:00"}]'; }
backup_target_enabled() { return 0; }
log() { :; }
do_verify_snapshot_coverage cloud
SH
  local out rc
  out="$(bash "$script" 2>&1)"; rc=$?
  printf '%s\nEXITCODE=%s\n' "$out" "$rc"
}

MUTH="$TMP_DIR/mut-head"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTH"
python3 - "$MUTH" <<'PYH'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = '''    sed -n "1,20{s|^$lib/||;s|^|    |;p}" "$missing"'''
assert s.count(a) == 1, "the slice line moved; update this mutation"
p.write_text(s.replace(a, '''    sed "s|^$lib/||" "$missing" | head -20 | sed 's/^/    /' ''', 1))
PYH
grep -q 'head -20' "$MUTH" || fail "the head mutation was not applied"

mout="$(run_huge "$MUTH")"
mrc="$(sed -nE 's/^EXITCODE=([0-9]+)$/\1/p' <<< "$mout" | tail -1)"
# Assert the BEHAVIOUR, not the number. The broken pipe surfaces as 141 when
# SIGPIPE kills sed, and as sed's own exit 4 ("I/O error") when an ancestor
# ignores SIGPIPE so the write returns EPIPE instead. Measured: 141 here, 4 on
# the CI runner, from the same mutant and the same fixture. Pinning 141 made
# this assertion pass locally and fail in CI -- an exit code is not the
# observable here; losing the verdict is.
grep -qE 'result            : (BACKUP GAP|UNKNOWN|PENDING)' <<< "$mout" \
  && fail "the mutant kept its verdict; this mutation proves nothing"
case "$mrc" in
  1|3) fail "the mutant reached a meaningful verdict status ($mrc); it should have
died in the pipeline: $mout" ;;
  "")  fail "no exit status was captured from the mutant: $mout" ;;
esac
echo "  killed: with | head -20 and 2999 missing it dies in the pipeline (status"  # pipefail-audit: fixture -- names the mutation in a message
echo "  $mrc, neither 1 nor 3) and the verdict is gone"

sect "the FIXED form survives the same 2999-path list"
fout="$(run_huge "$REPO_ROOT/bin/domum-media-backup")"
grep -q 'MISSING FROM THE SNAPSHOT: 2999' <<< "$fout" \
  || fail "the fixed form miscounted: $(grep MISSING <<< "$fout")"
grep -q '\.\.\. and 2979 more' <<< "$fout" || fail "the remainder line is wrong: $fout"
grep -qE 'result            : (BACKUP GAP|UNKNOWN|PENDING)' <<< "$fout" \
  || fail "the verdict was lost: $fout"
frc="$(sed -nE 's/^EXITCODE=([0-9]+)$/\1/p' <<< "$fout" | tail -1)"
case "$frc" in
  1|2|3) : ;;
  *) fail "the fixed form must reach a verdict status, got '$frc': $fout" ;;
esac
echo "  2999 missing: 20 shown, 2979 announced, a verdict, exit $frc (not 141)"

sect "mutation: a BACKUP GAP reported as PENDING must be caught"
# The dangerous direction. If a gap is classified as a pending upload, a backup
# that silently skipped a family photo reads as the system working normally --
# which is the whole reason the four classes exist.
MUTS="$TMP_DIR/mut-gap"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTS"
sed -i 's/^    verdict=gap;      rc_wanted=1$/    verdict=pending;  rc_wanted=3/' "$MUTS"
grep -q 'verdict=pending;  rc_wanted=3' "$MUTS" || fail "the gap mutation was not applied"
# Exactly the gap fixture: 5 ingested before the window, 64 after.
tail -n +37 "$TMP_DIR/big-paths" > "$TMP_DIR/big-recent"
sed -n '32,36p' "$TMP_DIR/big-paths" > "$TMP_DIR/big-before"
mout="$(CLI_UNDER_TEST="$MUTS" run_strict "$TMP_DIR/big-recent" "$TMP_DIR/big-before")"
grep -q 'result            : PENDING' <<< "$mout" \
  || fail "the mutation did not change the verdict; it proves nothing: $mout"
grep -q 'EXITCODE=3' <<< "$mout" \
  || fail "the mutant should return the pending status: $mout"
# And the real thing must still disagree with it, on the same fixture.
gout="$(run_strict "$TMP_DIR/big-recent" "$TMP_DIR/big-before")"
grep -q 'result            : BACKUP GAP' <<< "$gout" \
  || fail "the unmutated form must report a BACKUP GAP here: $gout"
grep -q 'EXITCODE=1' <<< "$gout" || fail "a gap must exit 1: $gout"
echo "  killed: the mutant calls 5 skipped originals PENDING and exits 3;"
echo "  the real form calls them a BACKUP GAP and exits 1"

sect "mutation: ignoring the window END must excuse a during-window ingest"
# Without the window's closing time there is no band in which timing is
# unknowable, so a file ingested mid-run would be declared pending.
MUTW="$TMP_DIR/mut-window"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTW"
sed -i 's/^  if (( n_missing > 0 )) \&\& \[\[ -n "\$snapshot_time" \&\& -n "\$window_end" \]\]; then$/  if (( n_missing > 0 )) \&\& [[ -n "$snapshot_time" ]]; then/' "$MUTW"
grep -q 'n_missing > 0 )) && \[\[ -n "\$snapshot_time" \]\]; then' "$MUTW" \
  || fail "the window mutation was not applied"
: > "$TMP_DIR/big-recent"; : > "$TMP_DIR/big-before"
wout="$(CLI_UNDER_TEST="$MUTW" run_strict "$TMP_DIR/big-recent" "$TMP_DIR/big-before")"
# With both sets empty the real form must call all 69 UNKNOWN.
rout="$(run_strict "$TMP_DIR/big-recent" "$TMP_DIR/big-before")"
grep -qE 'timing UNKNOWN    +: 69' <<< "$rout" \
  || fail "with no ingest evidence either way all 69 must be UNKNOWN: $rout"
grep -q 'result            : UNKNOWN' <<< "$rout" || fail "verdict must be UNKNOWN: $rout"
echo "  69 with no ingest evidence are UNKNOWN, never pending, never a gap"

echo "PASS: snapshot-coverage-smoke"
