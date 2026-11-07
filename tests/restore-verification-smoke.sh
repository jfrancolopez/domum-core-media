#!/usr/bin/env bash
set -uo pipefail

# Proves the restore-verification record means what it claims: only an actual
# isolated restore that revalidated the artefact may be recorded as verified.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

STATE="$TMP_DIR/state"
VDIR="$STATE/restore-verification"
mkdir -p "$VDIR"

report_rv() {
  bash -c "
set -uo pipefail
cmd_exists() { command -v \"\$1\" >/dev/null 2>&1; }
DOMUM_STATE_ROOT='$STATE'
REPORT_NOW_EPOCH=\$(date +%s)
source '$REPO_ROOT/bin/domum-media-report'
report_restore_verification
"
}

# ---------------------------------------------------------------------------
# 1. No record at all -> unknown, never "verified".
# ---------------------------------------------------------------------------
out="$(report_rv)" || fail "report_restore_verification failed with no records"
jq -e '.state == "unknown"' <<< "$out" >/dev/null \
  || fail "with no record the state must be unknown: $out"
jq -e '.reason != null' <<< "$out" >/dev/null || fail "unknown state must explain itself"

# ---------------------------------------------------------------------------
# 2. A successful BACKUP record must never be read as a restore verification.
#    (A run record lives in a different directory and must not be consulted.)
# ---------------------------------------------------------------------------
mkdir -p "$STATE/backups"
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=success\nFINISHED_TS=%s\n' "$(date -Iseconds)" \
  > "$STATE/backups/cloud-run.env"
out="$(report_rv)" || fail "report_restore_verification failed"
jq -e '.state == "unknown"' <<< "$out" >/dev/null \
  || fail "a successful backup must not count as a restore verification: $out"

# ---------------------------------------------------------------------------
# 3. A FAILED verification must not read as verified.
# ---------------------------------------------------------------------------
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=failure\nVERIFIED_TS=%s\nREASON=gzip failed\n' \
  "$(date -Iseconds)" > "$VDIR/cloud.env"
out="$(report_rv)" || fail "report_restore_verification failed on a failure record"
jq -e '.state == "failed"' <<< "$out" >/dev/null \
  || fail "a failed verification must report failed: $out"

# ---------------------------------------------------------------------------
# 4. A successful verification is reported with its evidence.
# ---------------------------------------------------------------------------
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=success\nVERIFIED_TS=%s\nSNAPSHOT_ID=abcdef12\nBYTES=4096\nCHECKS=gzip,size,footer\n' \
  "$(date -Iseconds)" > "$VDIR/cloud.env"
out="$(report_rv)" || fail "report_restore_verification failed on a success record"
jq -e '.state == "verified"' <<< "$out" >/dev/null || fail "a successful verification must report verified: $out"
jq -e '.target == "cloud"' <<< "$out" >/dev/null || fail "the verified target must be reported"
jq -e '.snapshot_id == "abcdef12"' <<< "$out" >/dev/null || fail "the verified snapshot must be reported"
jq -e '.checks == "gzip,size,footer"' <<< "$out" >/dev/null || fail "the checks performed must be reported"
jq -e '.age_seconds != null' <<< "$out" >/dev/null || fail "a verification must have a computable age"

# ---------------------------------------------------------------------------
# 4b. A failed verification must not erase when verification last PASSED, and
#     must not let the failure masquerade as that success.
# ---------------------------------------------------------------------------
record_rv() {
  bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$STATE'
die() { echo \"ERR \$*\" >&2; exit 1; }
eval \"\$(awk '/^restore_verification_dir\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media-backup')\"
eval \"\$(awk '/^record_restore_verification\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media-backup')\"
record_restore_verification $1
"
}

rm -f "$VDIR"/*.env
record_rv "cloud success snapok11 /a/b 4096 gzip,size,footer ''" \
  || fail "recording a success failed"
grep -q '^RESULT=success$' "$VDIR/cloud.env" || fail "success not recorded"
ok_ts="$(grep '^LAST_SUCCESS_TS=' "$VDIR/cloud.env" | cut -d= -f2-)"
[ -n "$ok_ts" ] || fail "a success must record LAST_SUCCESS_TS"
[ "$(grep '^LAST_SUCCESS_SNAPSHOT_ID=' "$VDIR/cloud.env" | cut -d= -f2-)" = "snapok11" ] \
  || fail "a success must record the snapshot it verified as the last success"

# Now a failure over the top of it.
record_rv "cloud failure snapbad2 /a/b 0 gzip 'gzip integrity failed'" \
  || fail "recording a failure failed"
grep -q '^RESULT=failure$' "$VDIR/cloud.env" || fail "failure not recorded"
[ "$(grep '^LAST_SUCCESS_TS=' "$VDIR/cloud.env" | cut -d= -f2-)" = "$ok_ts" ] \
  || fail "a failure erased the record of when verification last passed"
[ "$(grep '^LAST_SUCCESS_SNAPSHOT_ID=' "$VDIR/cloud.env" | cut -d= -f2-)" = "snapok11" ] \
  || fail "a failure overwrote the last successfully verified snapshot"

out="$(report_rv)" || fail "report_restore_verification failed after a failure"
jq -e '.state == "failed"' <<< "$out" >/dev/null \
  || fail "the current state must be failed: $out"
jq -e '.last_verified_at != null' <<< "$out" >/dev/null \
  || fail "a failure must still report when verification last passed: $out"
jq -e '.snapshot_id == "snapok11"' <<< "$out" >/dev/null \
  || fail "the reported snapshot must be the last VERIFIED one, not the failed one: $out"

rm -f "$VDIR"/*.env

# ---------------------------------------------------------------------------
# 5. The verification routine must be isolated and non-destructive by design.
# ---------------------------------------------------------------------------
fn="$(awk '/^do_verify_restore\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
[[ -n "$fn" ]] || fail "could not extract do_verify_restore"

grep -q 'mktemp -d' <<< "$fn" || fail "verification must restore into a scratch directory"
grep -q 'trap .*rm -rf .*scratch' <<< "$fn" || fail "the scratch directory must always be cleaned up"
# A cleanup-only signal trap would delete the scratch and let execution carry on
# into validation, recording a genuine-looking failure for an interrupted run.
grep -qE 'trap .*scratch.*exit [0-9]+.*(HUP|INT|TERM)' <<< "$fn" \
  || fail "the signal traps must terminate, not merely clean up and continue"
grep -q 'Refusing to verify' <<< "$fn" || fail "verification must refuse a scratch path inside a live data root"
grep -qE 'restore latest --target "\$scratch"' <<< "$fn" \
  || fail "verification must restore into the scratch directory, never a live path"

# It must perform the same three checks the dump itself had to pass.
for check in 'gzip -t' 'PostgreSQL database dump complete' '1024'; do
  grep -qF "$check" <<< "$fn" || fail "verification is missing the '$check' check"
done

# It must never write to the repository.
for forbidden in ' backup ' ' forget' ' prune' ' repair' ' init' ' unlock'; do
  grep -qE "restic_for_target \"\\\$target\"$forbidden" <<< "$fn" \
    && fail "verification performs a repository write: $forbidden"
done

# Success may only be recorded after every check has run.
success_line="$(grep -n 'record_restore_verification "\$target" success' <<< "$fn" | cut -d: -f1)"
footer_line="$(grep -n 'PostgreSQL database dump complete' <<< "$fn" | cut -d: -f1)"
[[ -n "$success_line" && -n "$footer_line" ]] || fail "could not locate the success/footer ordering"
(( success_line > footer_line )) \
  || fail "a success is recorded before the final check has run"

# ---------------------------------------------------------------------------
# 6. The CLI must actually dispatch it.
# ---------------------------------------------------------------------------
grep -qE '^ +verify-restore\)' "$REPO_ROOT/bin/domum-media-backup" \
  || fail "domum-media-backup does not dispatch verify-restore"
grep -q 'verify-restore' "$REPO_ROOT/bin/domum-media" \
  || fail "domum-media usage does not mention verify-restore"


# ---------------------------------------------------------------------------
# Sampled asset verification is reported SEPARATELY from the dump restore
# verification, and never borrows its language.
# ---------------------------------------------------------------------------
report_sample() {
  bash -c "
set -uo pipefail
cmd_exists() { command -v \"\$1\" >/dev/null 2>&1; }
DOMUM_STATE_ROOT='$STATE'
REPORT_NOW_EPOCH=\$(date +%s)
source '$REPO_ROOT/bin/domum-media-report'
report_asset_sample_verification
"
}

SAMPLE="$VDIR/cloud-sample.jsonl"
rm -f "$SAMPLE"

# No manifest -> unknown, with a reason, and never "verified".
out="$(report_sample)" || fail "report_asset_sample_verification failed with no manifest"
jq -e '.state == "unknown" and .reason != null' <<< "$out" >/dev/null \
  || fail "with no sample manifest the state must be unknown: $out"

now="$(date -Iseconds)"
row() { # result, type, size
  jq -cn --arg r "$1" --arg m "$2" --argjson b "$3" --arg ts "$now" \
    '{target:"cloud",snapshot_id:"deadbeef",path:"/srv/data/immich/library/x",
      media_type:$m,size_bytes:$b,source_sha256:"a",restored_sha256:"a",
      result:$r,verified_at:$ts}'
}

# All matched -> "sampled". It must NOT be called "verified": a sample is a
# weaker claim than the dump restore verification and must stay distinguishable.
{ row match heic 100; row match mov 200; } > "$SAMPLE"
out="$(report_sample)"
jq -e '.state == "sampled"' <<< "$out" >/dev/null \
  || fail "a fully matching sample must report state 'sampled': $out"
jq -e '.state != "verified"' <<< "$out" >/dev/null \
  || fail "a sample must never report itself as 'verified': $out"
jq -e '.sampled_files == 2 and .matched == 2 and .mismatched == 0
       and .sampled_bytes == 300 and (.media_types | sort) == ["heic","mov"]
       and .snapshot_id == "deadbeef" and .age_seconds != null' <<< "$out" >/dev/null \
  || fail "sample summary lost its evidence: $out"

# One mismatch -> failed. If this reports anything else, the command is theatre.
{ row match heic 100; row MISMATCH mov 200; } > "$SAMPLE"
out="$(report_sample)"
jq -e '.state == "failed" and .mismatched == 1 and .reason != null' <<< "$out" >/dev/null \
  || fail "a mismatching sample must report state 'failed': $out"

# An empty manifest is not a pass, and it is distinguishable from never having
# sampled at all -- otherwise a truncated manifest looks like a clean slate.
: > "$SAMPLE"
out="$(report_sample)"
jq -e '.state == "unknown" and (.reason | test("empty"))' <<< "$out" >/dev/null \
  || fail "an empty manifest must report itself as empty, not as never-sampled: $out"

# A manifest whose timestamps are unusable must still be reported, not silently
# treated as "no sampling has ever run".
jq -cn '{target:"cloud",snapshot_id:"deadbeef",path:"/x",media_type:"heic",
         size_bytes:1,source_sha256:"a",restored_sha256:"a",result:"match",
         verified_at:""}' > "$SAMPLE"
out="$(report_sample)"
jq -e '.state == "sampled" and .last_sampled_at != null' <<< "$out" >/dev/null \
  || fail "a manifest with unusable timestamps must still be reported: $out"
rm -f "$SAMPLE"

# ---------------------------------------------------------------------------
# AND NOW IT IS EXECUTED.
#
# Everything above asserts on this function's TEXT. Measured 2026-11-06 by
# instrumenting the binaries and running the whole suite: `do_verify_restore`
# was one of only three functions that no test ever ran. It is the function
# whose recorded evidence `dr-status` promotes into a DR tier, so its
# classification deciding success-vs-failure had never been observed.
#
# Every seam was read before being stubbed -- four fixture mistakes in one
# earlier sitting all came from guessing at seams.
# ---------------------------------------------------------------------------
echo "== do_verify_restore, EXECUTED =="
vr() {  # $1 = how the fixture behaves, rest unused -> output then rc=N
  local mode="$1"
  local root="$TMP_DIR/vr/$mode"
  rm -rf "$root"; mkdir -p "$root/state" "$root/data/immich/backup-staging"
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    DOMUM_DATA_ROOT="$root/data"
    DOMUM_MEDIA_ROOT="$root/media"
    DOMUM_STATE_ROOT="$root/state"
    VR_MODE="$mode"
    VR_REL="$root/data/immich/backup-staging/immich-postgres.dump.sql.gz"
    die() { echo "DIE: $*"; exit 1; }
    log() { :; }
    backup_target_enabled() { return 0; }
    record_restore_verification() {
      # $1 target $2 result $3 snapshot $4 rel $5 bytes $6 checks $7 reason
      printf 'RECORDED result=%s snapshot=%s bytes=%s checks=%s reason=%s\n' \
        "$2" "$3" "$5" "$6" "$7"
      return 0
    }
    restic_for_target() {
      local tgt="$1"; shift
      case "${1:-}" in
        snapshots) printf '[{"short_id":"abc1234","id":"abc1234def"}]\n'; return 0 ;;
        restore)
          [[ "$VR_MODE" == restore-fails ]] && return 1
          # Mirror restic: the artefact lands at <scratch><absolute rel>.
          local scratch=""
          while [[ $# -gt 0 ]]; do [[ "$1" == --target ]] && { scratch="$2"; break; }; shift; done
          [[ -n "$scratch" ]] || return 1
          [[ "$VR_MODE" == absent ]] && return 0
          mkdir -p "$scratch$(dirname "$VR_REL")"
          case "$VR_MODE" in
            badgzip) printf 'not gzip at all' > "$scratch$VR_REL" ;;
            tiny)    printf 'x' | gzip -c > "$scratch$VR_REL" ;;
            nofooter) { head -c 8192 /dev/urandom | base64; echo "no footer here"; } \
                        | gzip -c > "$scratch$VR_REL" ;;
            *)       { head -c 8192 /dev/urandom | base64
                       echo "-- PostgreSQL database dump complete"; } | gzip -c > "$scratch$VR_REL" ;;
          esac
          return 0 ;;
        *) return 0 ;;
      esac
    }
    do_verify_restore cloud
    echo "rc=$?"
  ) 2>&1
}

out="$(vr ok)"
grep -q 'rc=0' <<< "$out" || fail "a sound artefact did not verify: $out"
grep -q 'RECORDED result=success' <<< "$out" || fail "success was not recorded: $out"
grep -q 'checks=gzip,size,footer' <<< "$out" \
  || fail "the three checks are not all recorded on success: $out"
grep -q 'snapshot=abc1234' <<< "$out" || fail "the snapshot id was not recorded: $out"
echo "   sound artefact -> success, checks=gzip,size,footer, snapshot recorded"

# Every failure path must RECORD before dying: dr-status reads that evidence,
# and a failure that records nothing is indistinguishable from never having run.
for mode in restore-fails absent badgzip tiny nofooter; do
  out="$(vr "$mode")"
  grep -q 'rc=0' <<< "$out" && fail "$mode verified successfully: $out"
  grep -q 'RECORDED result=failure' <<< "$out" \
    || fail "$mode did not RECORD a failure before dying: $out"
  grep -q 'DIE: Restore verification FAILED' <<< "$out" \
    || fail "$mode did not fail loudly: $out"
done
echo "   all five failure paths record evidence and then die"

# The checks accumulate, so the recorded value says HOW FAR it got -- which is
# what distinguishes a corrupt archive from a truncated one.
out="$(vr badgzip)";  grep -q 'checks=gzip reason=restored artifact failed gzip' <<< "$out" \
  || fail "a bad gzip does not record checks=gzip: $out"
out="$(vr tiny)";     grep -q 'checks=gzip reason=restored artifact is implausibly small' <<< "$out" \
  || fail "a tiny artefact does not record that it passed gzip first: $out"
out="$(vr nofooter)"; grep -q 'checks=gzip,size reason=restored dump is missing' <<< "$out" \
  || fail "a footerless dump does not record gzip,size: $out"
echo "   the recorded checks say how far it got: gzip / gzip / gzip,size"

echo "== it refuses a scratch location inside a live data root =="
# The isolation is structural, and this is the assertion that proves the guard
# fires rather than that the comment exists.
out="$( ( source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1; set +e
  DOMUM_DATA_ROOT="$TMP_DIR/vr/live"; DOMUM_MEDIA_ROOT="$TMP_DIR/vr/media"
  mkdir -p "$DOMUM_DATA_ROOT/restore-verification"
  die() { echo "DIE: $*"; exit 1; }
  log() { :; }
  backup_target_enabled() { return 0; }
  restore_verification_dir() { printf '%s' "$DOMUM_DATA_ROOT/restore-verification"; }
  do_verify_restore cloud ) 2>&1 )"
grep -q 'inside a live data root' <<< "$out" \
  || fail "a scratch directory inside the data root was accepted: $out"
echo "   refused, naming the reason"

echo "== MUTATION: without the footer check a footerless dump verifies =="
mutv="$TMP_DIR/backup-cli-mut"
cp "$REPO_ROOT/bin/domum-media-backup" "$mutv"
python3 - "$mutv" <<'PYMV'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "  if ! grep -Fqx -- '-- PostgreSQL database dump complete' <<< \"$artifact_tail\"; then"
new = "  if false; then"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMV
grep -qF 'if false; then' "$mutv" || fail "the footer mutation did not apply"
mout="$(bash -c '
  root="'"$TMP_DIR"'/vr/mut"; rm -rf "$root"; mkdir -p "$root/state" "$root/data/immich/backup-staging"
  source "'"$mutv"'" >/dev/null 2>&1; set +e
  DOMUM_DATA_ROOT="$root/data"; DOMUM_MEDIA_ROOT="$root/media"; DOMUM_STATE_ROOT="$root/state"
  VR_REL="$root/data/immich/backup-staging/immich-postgres.dump.sql.gz"
  die(){ echo "DIE: $*"; exit 1; }; log(){ :; }
  backup_target_enabled(){ return 0; }
  record_restore_verification(){ printf "RECORDED result=%s checks=%s\n" "$2" "$6"; return 0; }
  restic_for_target(){ local t="$1"; shift
    case "${1:-}" in
      snapshots) printf "[{\"short_id\":\"abc1234\"}]\n" ;;
      restore) local sc=""; while [[ $# -gt 0 ]]; do [[ "$1" == --target ]] && { sc="$2"; break; }; shift; done
               mkdir -p "$sc$(dirname "$VR_REL")"
               { head -c 8192 /dev/urandom | base64; echo "no footer here"; } | gzip -c > "$sc$VR_REL" ;;
    esac; return 0; }
  do_verify_restore cloud; echo "rc=$?"' 2>&1)"
grep -q 'RECORDED result=success' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the footer check a dump with
no completion footer must verify as a success: $mout"
echo "  killed: the mutant accepts a dump with no completion footer"

echo "PASS: restore verification smoke test"
