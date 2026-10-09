#!/usr/bin/env bash
set -uo pipefail

# Proves `dr-status` reports what is PROVEN about recovery, not what is
# configured, and that each of the five levels is earned by evidence:
#
#   UNKNOWN < CONFIGURED < BACKED UP < RESTORE TESTED < FULL RECOVERY VERIFIED
#
# The load-bearing assertions are the ones that must NOT happen: a sample
# manifest with no recorded population must not become RESTORE TESTED, and
# nothing must ever reach FULL RECOVERY VERIFIED without a run that has never
# been performed. Those are the two ways this report could start lying in the
# reassuring direction.
#
# Hermetic: every root is redirected into the fixture, no restic, no network,
# no production paths.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"
LIB="$DATA/immich/library"
STATE="$TMP_DIR/state"
META="$STATE/backups"
VDIR="$STATE/restore-verification"
mkdir -p "$LIB/upload" "$META" "$VDIR" "$TMP_DIR/media"

# Every root the command touches is redirected into the fixture, and asserted
# to be: a test that reads a host path is not a test.
export DOMUM_DATA_ROOT="$DATA"
export DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$STATE"
export REPO_META_DIR="$META"
export SECRETS_DIR="$TMP_DIR/secrets"
export BACKUP_INCLUDE_PATHS="$DATA"
export BACKUP_TARGETS="cloud"
mkdir -p "$SECRETS_DIR"

# The summary blocks read the asset table. Stub it, and keep the host
# unreachable so an un-stubbed path cannot silently query production.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<'NODOCKER'
#!/usr/bin/env bash
echo "docker is deliberately unavailable in this test" >&2
exit 127
NODOCKER
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$LIB/upload/aa" "$LIB/encoded-video/bb" "$LIB/thumbs/cc"
head -c 400 /dev/urandom > "$LIB/upload/aa/one.heic"
head -c 500 /dev/urandom > "$LIB/upload/aa/two.mov"
head -c 600 /dev/urandom > "$LIB/encoded-video/bb/three-MP.mp4"
head -c 900 /dev/urandom > "$LIB/encoded-video/bb/0000000000000000000000000000000a.mp4"
head -c 300 /dev/urandom > "$LIB/thumbs/cc/t_thumbnail.webp"
cat > "$TMP_DIR/dbstub.sh" <<STUB
immich_db_original_paths() {
  printf '%s\n' '$LIB/upload/aa/one.heic' '$LIB/upload/aa/two.mov' \
                 '$LIB/encoded-video/bb/three-MP.mp4'
}
STUB

run_dr() {
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    # shellcheck disable=SC1090
    source "$TMP_DIR/dbstub.sh"
    set +e
    die() { echo "DIE: $*"; exit 9; }
    do_dr_status 2>&1
    echo "EXITCODE=$?"
  )
}

# The legend line names all five levels, so a negative assertion must be
# scoped to a RESULT ROW or it matches the legend and passes vacuously.
row_level() {  # $1 = output, $2 = tier -> the level in that row
  grep -E "^  $2 +" <<< "$1" | head -1 | sed -E "s/^  $2 +//; s/  .*//"
}
no_row_claims() {  # $1 = output, $2 = level
  grep -qE "^  (immich originals|immich database) +$2" <<< "$1"
}

assert_no_host_paths() {  # $1 = output
  grep -qE '(^|[^-])/var/lib/domum-media|/srv/data|/srv/media' <<< "$1" \
    && fail "the output referenced a production path: a fixture leak"
  return 0
}

mk_run_record() {  # $1 = result
  cat > "$META/cloud-run.env" <<EOF
SCHEMA_VERSION=1
TARGET=cloud
RESULT=$1
STARTED_TS=2026-10-09T02:31:00-04:00
FINISHED_TS=2026-10-09T02:31:26-04:00
SNAPSHOT_ID=abc123de
EOF
}

mk_sample_manifest() {
  printf '{"path":"a.heic","ok":true}\n' > "$VDIR/cloud-sample.jsonl"
}

mk_coverage() {  # $1 = sampled, $2 = population
  cat > "$VDIR/cloud-coverage.json" <<EOF
{"population_files":$2,"population_bytes":1000,"oversize_files":3,
 "oversize_bytes":500,"per_file_cap_bytes":268435456,
 "total_cap_bytes":1073741824,"sampled_files":$1}
EOF
}

mk_dbimport() {  # $1 = assets imported
  cat > "$VDIR/cloud-dbimport.env" <<EOF
SCHEMA_VERSION=1
TARGET=cloud
RESULT=success
VERIFIED_TS=2026-10-09T16:23:41-04:00
LAST_SUCCESS_TS=2026-10-09T16:23:41-04:00
LAST_SUCCESS_SNAPSHOT_ID=abc123de
SNAPSHOT_ID=abc123de
DUMP_BYTES=28066699
PG_IMAGE=tensorchord/pgvecto-rs:pg14-v0.2.0
ASSETS_IMPORTED=$1
REASON=
EOF
}

mk_dump_verification() {
  cat > "$VDIR/cloud.env" <<'EOF'
SCHEMA_VERSION=2
TARGET=cloud
RESULT=success
VERIFIED_TS=2026-10-09T03:00:00-04:00
LAST_SUCCESS_TS=2026-10-09T03:00:00-04:00
LAST_SUCCESS_SNAPSHOT_ID=abc123de
SNAPSHOT_ID=abc123de
EOF
}

# ---------------------------------------------------------------------------
sect "no evidence at all: CONFIGURED at best, never a pass"
out="$(run_dr)"
assert_no_host_paths "$out"
grep -q 'EXITCODE=2' <<< "$out" || fail "no evidence did not exit 2: $out"
grep -q 'NO successful run is recorded' <<< "$out" || fail "did not say the run is missing"
no_row_claims "$out" "RESTORE TESTED" && fail "claimed RESTORE TESTED with no evidence"
echo "  exit 2, the missing run is named, nothing stronger is claimed"

# ---------------------------------------------------------------------------
sect "a failed run record is not a backup"
mk_run_record failure
out="$(run_dr)"
grep -q 'NO successful run is recorded' <<< "$out" \
  || fail "a FAILED run was read as a success: $out"
grep -q 'EXITCODE=2' <<< "$out" || fail "failed run did not exit 2"
echo "  RESULT=failure does not satisfy BACKED UP"

# ---------------------------------------------------------------------------
sect "a successful run earns BACKED UP, and no more"
mk_run_record success
out="$(run_dr)"
grep -q 'EXITCODE=1' <<< "$out" || fail "successful run did not exit 1: $out"
grep -q 'immich originals *BACKED UP' <<< "$out" || fail "originals not BACKED UP: $out"
grep -q 'abc123de' <<< "$out" || fail "the snapshot id is not cited"
grep -q 'NO sample restore proof' <<< "$out" || fail "did not say the proof is missing"
no_row_claims "$out" "RESTORE TESTED" && fail "claimed RESTORE TESTED from a run alone"
echo "  BACKED UP with the snapshot cited; the absent restore proof is named"

# ---------------------------------------------------------------------------
sect "a sample manifest WITHOUT a recorded population is NOT restore tested"
# This is the defect the coverage artefact exists to prevent. A proof with no
# denominator is exactly what used to read as a clean green result.
mk_sample_manifest
out="$(run_dr)"
grep -q 'immich originals *BACKED UP' <<< "$out" \
  || fail "a manifest with no coverage was promoted: $out"
grep -q 'NO sample restore proof with a stated population' <<< "$out" \
  || fail "did not explain why the manifest was not enough: $out"
echo "  a manifest alone does not promote the level, and the report says why"

# ---------------------------------------------------------------------------
sect "manifest + coverage earns RESTORE TESTED, WITH the denominator"
mk_coverage 12 22976
out="$(run_dr)"
grep -q 'immich originals *RESTORE TESTED' <<< "$out" || fail "not promoted: $out"
# The verdict is governed by the WEAKEST tier, so promoting the originals must
# not promote the overall result while the database is still only BACKED UP.
grep -q 'EXITCODE=1' <<< "$out" \
  || fail "promoting one tier changed the overall verdict: $out"
grep -q 'WEAKEST TIER: BACKED UP' <<< "$out" || fail "the weakest tier is misreported: $out"
grep -q '12 of 22976 original' <<< "$out" || fail "the denominator is missing: $out"
grep -q '22964 never restore-tested' <<< "$out" || fail "the untested remainder is missing: $out"
echo "  12 of 22976 stated, and 22964 reported as never restore-tested"

# ---------------------------------------------------------------------------
sect "ARCHIVE VALIDATED is not DATABASE IMPORT RESTORE TESTED"
# The archive checks prove gzip, size and footer -- that the FILE is intact.
# They say nothing about whether PostgreSQL can read it, so they must not
# promote the level. This test previously required the opposite.
out="$(run_dr)"
grep -q 'immich database *BACKED UP' <<< "$out" \
  || fail "the database should still be only BACKED UP: $out"
grep -q 'NEVER imported' <<< "$out" \
  || fail "did not say the dump was never imported: $out"

mk_dump_verification
out="$(run_dr)"
grep -q 'immich database *BACKED UP' <<< "$out" \
  || fail "archive validation wrongly PROMOTED the database: $out"
grep -q 'archive validated' <<< "$out" || fail "archive validation not reported: $out"
grep -q 'NEVER imported' <<< "$out" \
  || fail "with only archive checks it must still say NEVER imported: $out"
echo "  archive checks are reported and do NOT promote the level"

mk_dbimport 23033
out="$(run_dr)"
grep -q 'immich database *RESTORE TESTED' <<< "$out" \
  || fail "a successful import did not promote the database: $out"
grep -q 'IMPORTED into a disposable PostgreSQL' <<< "$out" \
  || fail "the import evidence is not cited: $out"
grep -q '23033 asset' <<< "$out" || fail "the imported asset count is missing: $out"
# Only once BOTH tiers are restore-tested does the overall verdict move.
grep -q 'EXITCODE=0' <<< "$out" || fail "both tiers tested but verdict not 0: $out"
grep -q 'WEAKEST TIER: RESTORE TESTED' <<< "$out" || fail "weakest tier wrong: $out"
echo "  an actual import promotes it, cites the count, and moves the verdict"
echo "  a sample proof for originals does not vouch for the database, or vice versa"

sect "nothing is ever FULL RECOVERY VERIFIED"
out="$(run_dr)"
grep -q 'Nothing above is FULL RECOVERY VERIFIED' <<< "$out" \
  || fail "the standing caveat is missing: $out"
no_row_claims "$out" "FULL RECOVERY VERIFIED" && fail "a tier claimed FULL RECOVERY VERIFIED"
echo "  the strongest level is stated as unreached, and no tier claims it"

# ---------------------------------------------------------------------------
sect "a disabled target reports that nothing is backed up there"
out="$(BACKUP_TARGETS="cloud nas" BACKUP_TARGET_NAS_ENABLED=0 run_dr)"
grep -q 'target: nas  (NOT ENABLED' <<< "$out" \
  || fail "a disabled target was not reported as such: $out"
# The nas section must contain no result row at all.
nas_rows="$(sed -n '/^target: nas/,/^$/p' <<< "$out" | grep -cE '^  immich ' || true)"
[[ "$nas_rows" -eq 0 ]] || fail "the disabled target emitted $nas_rows result row(s)"
echo "  the disabled target is named and claims nothing"

# ---------------------------------------------------------------------------
sect "the scope block states what goes off-site, in both directions"
out="$(run_dr)"
grep -q 'BACKUP SCOPE' <<< "$out" || fail "no scope block: $out"
grep -qE 'included +'"$DATA" <<< "$out" || fail "the include root is not stated: $out"
grep -q 'replaceable media tier' <<< "$out" || fail "the media tier is not addressed: $out"
grep -q 'not in the backup set' <<< "$out" \
  || fail "the media tier is outside the include set and that was not stated: $out"
echo "  include roots, exclusions and the replaceable tier are all named"

sect "an UNSET include path is UNKNOWN, not 'not backed up'"
# A claim about configuration that was never read is worthless, and saying
# "NOT in the backup set" for it is the same conflation this report prevents.
out="$(BACKUP_INCLUDE_PATHS= run_dr)"
grep -q 'BACKUP_INCLUDE_PATHS is not set' <<< "$out" \
  || fail "an unset include set was not reported as UNKNOWN: $out"
no_row_claims "$out" "BACKED UP" && fail "it claimed BACKED UP with no include set"
echo "  unset configuration reports UNKNOWN and claims no level"

sect "the media tier being INSIDE the include set is reported as a finding"
out="$(BACKUP_INCLUDE_PATHS="$DATA $TMP_DIR/media" run_dr)"
grep -q 'IN the backup set' <<< "$out" \
  || fail "a reacquirable tier inside the backup set was not flagged: $out"
echo "  reacquirable data stored off-site is called out"

sect "the summary counts originals by LOCATION and names what is untested"
out="$(run_dr)"
grep -qE 'originals \(asset table\) +3' <<< "$out" || fail "wrong original count: $out"
grep -qE 'under upload/ +2' <<< "$out" || fail "upload/ count missing: $out"
grep -qE 'under encoded-video/ +1' <<< "$out" \
  || fail "the encoded-video original is not counted: $out"
grep -q 'NEVER restore-tested' <<< "$out" || fail "the untested count is missing: $out"
echo "  3 originals: 2 upload/, 1 encoded-video/, and the untested count is stated"

sect "the regenerable block separates derivatives from the originals beside them"
grep -q 'REGENERABLE DATA' <<< "$out" || fail "no regenerable block: $out"
grep -q 'of which ORIGINALS (kept)' <<< "$out" \
  || fail "it does not distinguish the originals inside encoded-video/: $out"
grep -q 'potential saving if excluded' <<< "$out" || fail "no saving figure: $out"
grep -q 'BACKUP_EXCLUDE_IMMICH_DERIVATIVES=0' <<< "$out" \
  || fail "it does not say the exclusion is unapplied: $out"
echo "  derivatives, the originals among them, the saving, and that it is not applied"

sect "remaining risks are numbered and name the command that would clear them"
grep -q 'REMAINING RISKS' <<< "$out" || fail "no risk block: $out"
grep -q 'verify-large' <<< "$out" || fail "the large-file risk does not name its remedy: $out"
grep -q 'FULL RECOVERY VERIFIED' <<< "$out" || fail "the standing risk is missing: $out"
# By this point the fixture HAS import evidence, so that risk is correctly
# absent -- a risk list that keeps naming a resolved risk is noise. Prove both
# directions by taking the evidence away.
grep -q 'verify-db-restore' <<< "$out" \
  && fail "the import risk is still listed although an import is recorded: $out"
mv "$VDIR/cloud-dbimport.env" "$TMP_DIR/dbimport.saved"
noimp="$(run_dr)"
grep -q 'verify-db-restore' <<< "$noimp" \
  || fail "with no import recorded the risk must be listed: $noimp"
mv "$TMP_DIR/dbimport.saved" "$VDIR/cloud-dbimport.env"
echo "  each risk names its remedy, and a resolved risk stops being listed"

sect "mutation: ignoring the coverage file must produce an undenominated claim"
# The coverage requirement is enforced twice -- the file must exist AND carry
# both fields -- so the mutation has to remove both to reproduce the pre-fix
# behaviour of promoting on a manifest alone.
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# Make the proof accept a manifest with no coverage, the pre-fix behaviour.
s=s.replace('  [[ -f "$man" && -f "$cov" ]] || return 1',
            '  [[ -f "$man" ]] || return 1',1)
s=s.replace('  [[ -n "$sampled" && -n "$pop" ]] || return 1',
            '  sampled="${sampled:-0}"; pop="${pop:-0}"',1)
open(p,'w').write(s)
PY
rm -f "$VDIR/cloud-coverage.json"
mout="$(
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  do_dr_status 2>&1
)"
no_row_claims "$mout" "RESTORE TESTED" \
  || fail "the mutant did not promote without coverage; the check is not load-bearing"
grep -q '0 of 0 original' <<< "$mout" \
  || fail "the mutant did not show the undenominated claim: $mout"
echo "  without the coverage requirement it reports 'RESTORE TESTED, 0 of 0'"

echo "PASS: dr-status-smoke"
