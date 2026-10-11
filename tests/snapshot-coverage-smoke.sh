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

sect "an original absent from the listing => INCOMPLETE, exit 1, named"
out="$(run_cov "$SNAP_STUB_PART")"
grep -q 'EXITCODE=1' <<< "$out" || fail "a missing original did not exit 1: $out"
grep -q 'IN the snapshot   : 2 of 3' <<< "$out" || fail "wrong count: $out"
grep -q 'MISSING FROM THE SNAPSHOT: 1' <<< "$out" || fail "the gap is not stated: $out"
grep -q -- '676850ba' <<< "$out" || fail "the missing original is not NAMED: $out"
grep -q 'NOT protected off-site' <<< "$out" || fail "the consequence is not stated: $out"
echo "  2 of 3, exit 1, and the unprotected original is named"

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
jq -e '.result == "incomplete" and .in_snapshot == 2 and .missing_from_snapshot == 1' \
  <<< "$line" >/dev/null || fail "the JSON disagrees with the text: $line"
echo "  result=incomplete, 2 in, 1 missing -- same as the report"

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
    grep -q 'EXITCODE=1' <<< "$out" \
      || fail "restic really excluded an original and coverage still passed: $out"
    grep -q -- '676850ba' <<< "$out" || fail "the really-missing original was not named: $out"
    echo "  restic's own file list drives both verdicts"
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
grep -q 'EXITCODE=1' <<< "$mout" \
  || fail "the mutant did not produce a verdict from nothing: $mout"
echo "  without the guard it reports all 3 as missing from a listing it never matched"

echo "PASS: snapshot-coverage-smoke"
