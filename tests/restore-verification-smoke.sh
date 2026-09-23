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

echo "PASS: restore verification smoke test"
