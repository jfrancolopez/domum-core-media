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
# 20 originals: 19 under upload/ and the motion-photo one under
# encoded-video/. Enough that "never restore-tested" is a real number rather
# than clamping to zero, which would make the agreement assertion vacuous.
for i in $(seq 4 20); do head -c 100 /dev/urandom > "$LIB/upload/aa/f$i.heic"; done
{
  printf 'immich_db_original_paths() {\n  printf '"'"'%%s\\n'"'"' \\\n'
  printf "    '%s' \\\\\n" "$LIB/upload/aa/one.heic" "$LIB/upload/aa/two.mov"
  for i in $(seq 4 20); do printf "    '%s' \\\\\n" "$LIB/upload/aa/f$i.heic"; done
  printf "    '%s'\n}\n" "$LIB/encoded-video/bb/three-MP.mp4"
} > "$TMP_DIR/dbstub.sh"
bash -n "$TMP_DIR/dbstub.sh" || fail "the generated asset-table stub is not valid shell"

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

mk_phase_a() {  # $1 = assets
  cat > "$VDIR/cloud-phase-a.env" <<EOF
SCHEMA_VERSION=1
TARGET=cloud
RESULT=success
VERIFIED_TS=2026-10-11T14:45:00-04:00
LAST_SUCCESS_TS=2026-10-11T14:45:00-04:00
LAST_SUCCESS_SNAPSHOT_ID=abc123de
SNAPSHOT_ID=abc123de
SERVER_IMAGE_ID=sha256:serverimgid0
ASSETS=$1
USERS=2
REASON=
EOF
}

mk_snapshot_coverage() {  # $1 = in_snapshot, $2 = originals, $3 = missing, $4 = snapshot
  cat > "$VDIR/cloud-snapshot-coverage.json" <<EOF
{"target":"cloud","snapshot_id":"$4","recorded_at":"2026-10-11T10:00:00-04:00",
 "originals":$2,"in_snapshot":$1,"missing_from_snapshot":$3,"snapshot_paths":64500}
EOF
}

mk_large_history() {  # $1 = how many proven large originals
  # The files must REALLY exist with the recorded size: a proof is about the
  # bytes that were there when it was taken, so large_verified_paths drops a
  # record whose file is gone or has changed size. A fixture of invented paths
  # would be invalidated on sight -- which is the correct behaviour, and makes
  # it useless as a fixture for "these are proven".
  local i dir="$TMP_DIR/bigfiles"
  mkdir -p "$dir"
  : > "$VDIR/cloud-large-verified.jsonl"
  for ((i=1; i<=$1; i++)); do
    head -c $(( 300 + i )) /dev/zero > "$dir/video-$i.mov"
    jq -cn --arg p "$dir/video-$i.mov" --argjson b "$(stat -c %s "$dir/video-$i.mov")" \
      '{target:"cloud",snapshot_id:"abc123de",path:$p,media_type:"mov",
        size_bytes:$b,result:"match",verified_at:"2026-10-11T08:25:58-04:00"}' \
      >> "$VDIR/cloud-large-verified.jsonl"
  done
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
# This asserted "22964 never restore-tested" -- 22976 recorded minus 12 proven
# -- and so REQUIRED the defect production showed on 2026-10-12: the recorded
# population as the denominator for a claim about the library NOW. The fixture's
# live library has 20 originals, so 8 of them have never been tested. Before
# adapting a test to a change, ask which of the two is wrong; here it was the
# test.
grep -q '8 of 20 never restore-tested' <<< "$out" \
  || fail "the untested remainder must count the LIVE library: $out"
echo "  the fraction cites the recorded 22976; the remainder is 8 of the live 20"

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

sect "the tier row and the summary report the SAME untested count"
# They did not, twice. In 2026-10-09 the row said "23021 never restore-tested"
# while the summary said 23019, because only the summary knew about two large
# originals. In 2026-10-12 the row said 23013 and the summary 23082 -- 69 apart
# -- because the row subtracted the proven count from the population RECORDED
# when the sample ran while the summary subtracted it from the LIVE library.
#
# The previous version of this very section could not catch the second one: its
# own comment said "the fixture must make them the same population for the two
# untested figures to be comparable at all", and it set recorded == live. An
# assertion that first establishes the precondition for agreement cannot detect
# disagreement. So both cases are driven here.
row_un() { sed -nE 's/.*immich originals.*; ([0-9]+) of [0-9]+ never restore-tested.*/\1/p' <<< "$1" | head -1; }
sum_un() { sed -nE 's/^ +NEVER restore-tested +([0-9]+) of [0-9]+$/\1/p' <<< "$1" | head -1; }
row_den() { sed -nE 's/.*immich originals.*; [0-9]+ of ([0-9]+) never restore-tested.*/\1/p' <<< "$1" | head -1; }

mk_large_history 2
mk_coverage 12 20          # recorded == live: the case the old fixture allowed
out="$(run_dr)"
r="$(row_un "$out")"; u="$(sum_un "$out")"
[[ -n "$r" ]] || fail "could not read the tier row's untested count: $out"
[[ -n "$u" ]] || fail "could not read the summary's untested count: $out"
[[ "$r" == "$u" ]] || fail "the two counts disagree: tier row $r vs summary $u"
[[ "$r" == "6" ]] || fail "20 originals less 12 sampled and 2 large is 6, got $r"
echo "  equal populations: both report $r, from one count"

mk_coverage 12 15          # the library has GROWN since the proof: production's case
out="$(run_dr)"
r="$(row_un "$out")"; u="$(sum_un "$out")"
[[ "$r" == "$u" ]] \
  || fail "they disagree once the library has grown: tier row $r vs summary $u"
[[ "$r" == "6" ]] \
  || fail "never-restore-tested must count the LIVE library (20 - 14 = 6), got $r"
[[ "$(row_den "$out")" == "20" ]] \
  || fail "the tier row must state the LIVE denominator, got $(row_den "$out")"
grep -q 'of the 15 present when sampled' <<< "$out" \
  || fail "the proof's own fraction must still quote the recorded population: $out"
echo "  grown library: both report $r of 20, and the fraction still cites 15"

sect "mutation: the recorded denominator must bring the contradiction back"
MUTD="$TMP_DIR/mut-dr"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTD"
sed -i 's/^          nevtxt="\$nev of \$dr_live_pop never restore-tested"$/          nevtxt="$u never restore-tested"/' "$MUTD"
grep -q 'nevtxt="\$u never restore-tested"' "$MUTD" \
  || fail "the dr-status mutation was not applied"
mout="$(
  (
    # shellcheck disable=SC1090
    source "$MUTD" >/dev/null 2>&1
    # shellcheck disable=SC1090
    source "$TMP_DIR/dbstub.sh"
    set +e
    die() { echo "DIE: $*"; exit 9; }
    do_dr_status 2>&1
  )
)"
mr="$(sed -nE 's/.*immich originals.*; ([0-9]+) never restore-tested.*/\1/p' <<< "$mout" | head -1)"
[[ "$mr" == "1" ]] \
  || fail "the mutant should subtract from the recorded 15 and report 1, got '$mr'"
echo "  killed: the recorded denominator reports 1 where the live one reports 6"
mk_coverage 12 20

sect "the tier row cites BOTH numerators when large files are proven"
out="$(run_dr)"
grep -q 'sampled + 2 large' <<< "$out" \
  || fail "the row does not show the sample and large contributions separately: $out"
grep -qE 'immich originals +RESTORE TESTED +14 proven \(12 sampled \+ 2 large\) of the 20 present when sampled' <<< "$out" \
  || fail "the row does not total the two proofs against the sampled population: $out"
echo "  14 proven = 12 sampled + 2 large, both numerators stated"

sect "removing the large history moves BOTH figures together"
rm -f "$VDIR/cloud-large-verified.jsonl"
out="$(run_dr)"
r="$(row_un "$out")"; u="$(sum_un "$out")"
[[ "$r" == "$u" ]] || fail "they disagree with no large history: $r vs $u"
[[ "$r" == "8" ]] || fail "without the 2 large proofs it must be 8, got $r"
echo "  both still agree once the large proofs are gone"

sect "a population that has GROWN since the proof is reported as drift"
# The tier row quotes the recorded denominator and the summary the live one.
# They diverge as photos are added, and that must be stated rather than left
# looking like a contradiction.
mk_coverage 12 22976
out="$(run_dr)"
grep -q 'population drift' <<< "$out" || fail "drift was not reported: $out"
grep -q '20 now vs 22976 when last sampled' <<< "$out" \
  || fail "the drift line does not give both populations: $out"
grep -q 'the proof covers the older set' <<< "$out" \
  || fail "the drift line does not say which set the proof covers: $out"
mk_coverage 12 20
out="$(run_dr)"
grep -q 'population drift' <<< "$out" \
  && fail "drift was reported although the populations match"
echo "  drift is stated when it exists and silent when it does not"

sect "each database claim cites the snapshot it is ABOUT"
mk_dbimport 23033
out="$(run_dr)"
grep -q 'snapshot abc123de' <<< "$out" || fail "the import does not cite its snapshot: $out"
grep -q 'not the current snapshot' <<< "$out" \
  && fail "the evidence matches the current snapshot but was flagged as stale"
# Now make the recorded proof refer to an OLDER snapshot than the current run.
sed -i 's/^LAST_SUCCESS_SNAPSHOT_ID=.*/LAST_SUCCESS_SNAPSHOT_ID=0ldsnap1/' \
  "$VDIR/cloud-dbimport.env"
out="$(run_dr)"
grep -q 'snapshot 0ldsnap1' <<< "$out" || fail "the older snapshot is not cited: $out"
grep -q 'not the current snapshot' <<< "$out" \
  || fail "a proof of an EARLIER snapshot was not flagged: $out"
grep -q 'immich database *RESTORE TESTED' <<< "$out" \
  || fail "an earlier-snapshot proof is still a proof and must keep the level: $out"
echo "  the snapshot is cited, and a stale one is flagged without losing the level"
mk_dbimport 23033

sect "the CONFIG claim and the OBSERVED claim are reported separately"
# "The library is under the backup root and no exclusion matches it" is an
# argument about configuration. "This path is in snapshot X" is an observation.
# Presenting the first as the second is what made off-site coverage look proven
# when nothing had ever been reconciled.
rm -f "$VDIR/cloud-snapshot-coverage.json"
out="$(run_dr)"
grep -qE 'in the backup set \(config\) +all 20' <<< "$out" \
  || fail "the configuration claim is not reported: $out"
grep -qE 'IN a snapshot \(observed\) +NOT CHECKED' <<< "$out" \
  || fail "an unreconciled library must say NOT CHECKED: $out"
grep -q 'verify-snapshot-coverage' <<< "$out" \
  || fail "it does not name the command that would check it: $out"
echo "  config says all 20; observed says NOT CHECKED, and names the remedy"

sect "an unreconciled library is a named RISK"
grep -q 'RECONCILED against a real snapshot' <<< "$out" \
  || fail "the missing reconciliation is not listed as a risk: $out"
grep -q 'downloads nothing' <<< "$out" \
  || fail "the risk does not say the check is cheap: $out"
echo "  listed as a risk, with the cost of clearing it stated"

sect "recorded full coverage is reported as an observation"
mk_snapshot_coverage 20 20 0 abc123de
out="$(run_dr)"
grep -qE 'IN a snapshot \(observed\) +all 20, snapshot abc123de' <<< "$out" \
  || fail "full coverage is not reported with its snapshot: $out"
grep -q 'RECONCILED against a real snapshot' <<< "$out" \
  && fail "the risk is still listed although reconciliation happened"
grep -q 'reconciled against an earlier snapshot' <<< "$out" \
  && fail "the current snapshot was flagged as earlier"
echo "  all 20 in abc123de, the risk clears, and it is not flagged stale"

sect "a MISSING original is reported and becomes a risk"
mk_snapshot_coverage 17 20 3 abc123de
out="$(run_dr)"
grep -q '3 MISSING from snapshot abc123de' <<< "$out" \
  || fail "the missing originals are not reported: $out"
grep -q '3 original(s) are NOT in the snapshot' <<< "$out" \
  || fail "the gap is not raised as a risk: $out"
grep -q 'not protected off-site' <<< "$out" \
  || fail "the consequence is not stated: $out"
echo "  3 missing, stated in the summary and raised as a risk"

sect "a reconciliation against an EARLIER snapshot is flagged, not hidden"
mk_snapshot_coverage 20 20 0 0ldsnap1
out="$(run_dr)"
grep -q 'snapshot 0ldsnap1' <<< "$out" || fail "the older snapshot is not cited: $out"
grep -q 'reconciled against an earlier snapshot' <<< "$out" \
  || fail "an older reconciliation was not flagged: $out"
echo "  the older snapshot is named and flagged"

sect "a library that has GROWN since reconciliation says so"
mk_snapshot_coverage 15 15 0 abc123de
out="$(run_dr)"
grep -q 'originals now vs 15 when reconciled' <<< "$out" \
  || fail "growth since the reconciliation is not reported: $out"
echo "  20 now vs 15 when reconciled, stated plainly"
mk_snapshot_coverage 20 20 0 abc123de

sect "originals added since the reconciliation are a NAMED RISK"
# The summary already printed "[the library has 23102 originals now vs 23033
# when reconciled]" in production. That is honest but not actionable, and the
# REMAINING RISKS block -- the part an operator acts on -- said nothing, so 69
# originals that had never been observed in ANY snapshot were invisible there.
# A missing risk line reads as "nothing to report", which is this function's
# own stated reason for existing. They are also the NEWEST photos.
mk_snapshot_coverage 15 15 0 abc123de
out="$(run_dr)"
grep -qE '5 original\(s\) have been added since the last' <<< "$out" \
  || fail "the unreconciled additions are not named as a risk: $out"
grep -q 'NEVER been observed in a snapshot' <<< "$out" \
  || fail "the risk does not say what is unproven about them: $out"
grep -q 'They are the newest photos' <<< "$out" \
  || fail "the risk does not say which originals these are: $out"
grep -q 're-run verify-snapshot-coverage\|Re-run verify-snapshot-coverage' <<< "$out" \
  || fail "the risk does not name its remedy: $out"
grep -q 'downloads nothing' <<< "$out" \
  || fail "the remedy must say it costs no egress, or it reads as expensive: $out"
echo "  5 unreconciled additions named, with the remedy and its cost"

# And silent when the library has not grown -- a risk that is always listed is
# noise, and this block is read by someone deciding what to do next.
mk_snapshot_coverage 20 20 0 abc123de
out="$(run_dr)"
grep -q 'have been added since the last' <<< "$out" \
  && fail "the risk was listed although the library has not grown: $out"
echo "  silent when the reconciled population matches the live one"

sect "mutation: dropping the growth comparison must hide those originals"
MUTG="$TMP_DIR/mut-growth"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTG"
sed -i 's/^      if \[\[ -n "\$sc_orig" \]\] \&\& (( live_now > sc_orig )); then$/      if [[ -n "$sc_orig" ]] \&\& false; then/' "$MUTG"
grep -q 'sc_orig" \]\] && false; then' "$MUTG" || fail "the growth mutation was not applied"
mk_snapshot_coverage 15 15 0 abc123de
mg="$(
  (
    # shellcheck disable=SC1090
    source "$MUTG" >/dev/null 2>&1
    # shellcheck disable=SC1090
    source "$TMP_DIR/dbstub.sh"
    set +e
    die() { echo "DIE: $*"; exit 9; }
    do_dr_status 2>&1
  )
)"
grep -q 'have been added since the last' <<< "$mg" \
  && fail "the risk still appeared without the comparison; it is not load-bearing"
echo "  killed: without the comparison the 5 unreconciled originals go unmentioned"
mk_snapshot_coverage 20 20 0 abc123de

sect "Phase A is reported as its own claim, and NOT TESTED until it runs"
rm -f "$VDIR/cloud-phase-a.env"
out="$(run_dr)"
grep -qE 'application startup \(Phase A\) +NOT TESTED' <<< "$out" \
  || fail "an untested Phase A must say NOT TESTED: $out"
grep -q 'immich-phase-a' <<< "$out" || fail "it does not name the command: $out"
grep -q 'ever been started against a recovered database' <<< "$out" \
  || fail "the untested application is not raised as a risk: $out"
grep -q 'not the library' <<< "$out" || fail "the risk does not state the cost: $out"
echo "  NOT TESTED, named as a risk, with the remedy and its cost"

sect "a passing Phase A is reported WITHOUT promoting any tier"
mk_phase_a 23033
out="$(run_dr)"
grep -q 'application startup (Phase A)' <<< "$out" || fail "Phase A is not reported: $out"
grep -q 'VERIFIED 2026-10-11' <<< "$out" || fail "the timestamp is not cited: $out"
grep -q 'no file was served' <<< "$out" \
  || fail "it does not say what Phase A did NOT prove: $out"
grep -q 'ever been started against a recovered database' <<< "$out" \
  && fail "the risk is still listed although Phase A passed"
# The crucial one: it must not elevate the overall verdict.
no_row_claims "$out" "FULL RECOVERY VERIFIED" \
  && fail "a passing Phase A promoted a tier to FULL RECOVERY VERIFIED"
grep -q 'Nothing above is FULL RECOVERY VERIFIED' <<< "$out" \
  || fail "the standing caveat disappeared after Phase A passed: $out"
echo "  reported, the risk clears, and no tier is promoted"

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
grep -qE 'originals \(asset table\) +20' <<< "$out" || fail "wrong original count: $out"
grep -qE 'under upload/ +19' <<< "$out" || fail "upload/ count missing: $out"
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

sect "mutation: the shared count ignoring large proofs must move BOTH figures"
# The production defect of 2026-10-09 was the ROW counting only the sample while
# the summary counted sample + large: 23021 against 23019. Both figures now come
# from dr_never_restore_tested, so that particular divergence is no longer
# EXPRESSIBLE -- which is the improvement, and also why the old form of this
# mutation (breaking dr_sample_proof's `uns`) no longer changes anything
# observable. The shared count is still load-bearing, and this proves it the way
# that now applies: drop the large term and both figures must move together and
# both must be wrong.
mk_coverage 12 20
mk_large_history 2
MUT0="$TMP_DIR/mutant0"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT0"
sed -i 's/^  never=\$(( live - \${samp:-0} - \${largeok:-0} ))$/  never=$(( live - ${samp:-0} ))/' "$MUT0"
grep -q 'never=\$(( live - \${samp:-0} ))' "$MUT0" \
  || fail "the shared-count mutation was not applied"
m0="$(
  (
    # shellcheck disable=SC1090
    source "$MUT0" >/dev/null 2>&1
    # shellcheck disable=SC1090
    source "$TMP_DIR/dbstub.sh"
    set +e
    die() { echo "DIE: $*"; exit 9; }
    do_dr_status 2>&1
  )
)"
m_row="$(row_un "$m0")"; m_sum="$(sum_un "$m0")"
[[ "$m_row" == "$m_sum" ]] \
  || fail "the two figures diverged; they must come from ONE count: $m_row vs $m_sum"
[[ "$m_row" == "8" ]] \
  || fail "ignoring the 2 large proofs must report 8, not $m_row -- the mutation did nothing"
echo "  without the large term both say $m_row instead of 6, still agreeing"

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
# This section is about the missing DENOMINATOR, so clear the large history too:
# otherwise the mutant reports "2 of 0" and the point is obscured.
rm -f "$VDIR/cloud-large-verified.jsonl"
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
