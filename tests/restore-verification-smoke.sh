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
# 5. The verification routine must be isolated and non-destructive by design.
# ---------------------------------------------------------------------------
fn="$(awk '/^do_verify_restore\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
[[ -n "$fn" ]] || fail "could not extract do_verify_restore"

grep -q 'mktemp -d' <<< "$fn" || fail "verification must restore into a scratch directory"
grep -q 'trap .*rm -rf .*scratch' <<< "$fn" || fail "the scratch directory must always be cleaned up"
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

echo "PASS: restore verification smoke test"
