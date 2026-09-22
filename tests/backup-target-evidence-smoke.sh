#!/usr/bin/env bash
set -uo pipefail

# Proves that per-target backup evidence is recorded independently, and that the
# report never infers a target's result from the aggregate heartbeat.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

META_DIR="$TMP_DIR/state/backups"
mkdir -p "$META_DIR" "$TMP_DIR/log"

# ---------------------------------------------------------------------------
# 1. record_backup_target_run writes durable, atomic, per-target evidence.
# ---------------------------------------------------------------------------
run_recorder() {
  bash -c "
set -uo pipefail
REPO_META_DIR='$META_DIR'
DOMUM_LOG_DIR='$TMP_DIR/log'
repo_meta_file() { printf '%s' \"\$REPO_META_DIR/\$1-repo.env\"; }
source <(sed -n '/^record_backup_target_run() {/,/^}/p' '$REPO_ROOT/bin/domum-media-backup')
$1
"
}

printf 'REPOSITORY_ID=abc123def456\n' > "$META_DIR/cloud-repo.env"
run_recorder "record_backup_target_run cloud success 2026-01-01T00:00:00+00:00 deadbeef" \
  || fail "record_backup_target_run failed"

run_file="$META_DIR/cloud-run.env"
[[ -f "$run_file" ]] || fail "no per-target run evidence was written"

grep -q '^TARGET=cloud$'        "$run_file" || fail "run evidence is missing the target name"
grep -q '^RESULT=success$'      "$run_file" || fail "run evidence is missing the result"
grep -q '^SNAPSHOT_ID=deadbeef$' "$run_file" || fail "run evidence is missing the snapshot id"
grep -q '^REPOSITORY_ID=abc123def456$' "$run_file" || fail "run evidence is missing the repository identity"
grep -q '^STARTED_TS='  "$run_file" || fail "run evidence is missing the start time"
grep -q '^FINISHED_TS=' "$run_file" || fail "run evidence is missing the finish time"
grep -q '^SCHEMA_VERSION=' "$run_file" || fail "run evidence is missing a schema version"

perms="$(stat -c %a "$run_file")"
[[ "$perms" == "600" ]] || fail "run evidence should be 0600, found $perms"

# No temporary file may be left behind: the write must be atomic.
leftovers="$(find "$META_DIR" -name '.cloud-run.env.*' 2>/dev/null)"
[[ -z "$leftovers" ]] || fail "atomic write left a temporary file behind: $leftovers"

# A failure must be recorded as a failure, not omitted.
run_recorder "record_backup_target_run cloud failure 2026-01-01T00:00:00+00:00 ''" \
  || fail "recording a failure failed"
grep -q '^RESULT=failure$' "$run_file" || fail "a failed run was not recorded as failed"

# Each target gets its own record; one target cannot vouch for another.
run_recorder "record_backup_target_run nas success 2026-01-01T00:00:00+00:00 cafe1234" \
  || fail "recording a second target failed"
[[ -f "$META_DIR/nas-run.env" ]] || fail "a second target did not get its own evidence file"
grep -q '^RESULT=failure$' "$run_file" || fail "recording one target overwrote another's result"

# ---------------------------------------------------------------------------
# 2. The report reads that evidence, and reports unknown where none exists.
# ---------------------------------------------------------------------------
report_target() {
  bash -c "
set -uo pipefail
cmd_exists() { command -v \"\$1\" >/dev/null 2>&1; }
REPO_META_DIR='$META_DIR'
DOMUM_STATE_ROOT='$TMP_DIR/state'
REPORT_NOW_EPOCH=\$(date +%s)
source '$REPO_ROOT/bin/domum-media-report'
report_backup_target_state '$1'
"
}

printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=success\nSTARTED_TS=%s\nFINISHED_TS=%s\nSNAPSHOT_ID=abcdef12\nREPOSITORY_ID=abc123\n' \
  "$(date -Iseconds)" "$(date -Iseconds)" > "$run_file"

out="$(report_target cloud)" || fail "report_backup_target_state failed"
jq -e '.last_run.state == "ok"' <<< "$out" >/dev/null \
  || fail "a recorded success was not reported as ok: $out"
jq -e '.last_run.snapshot_id == "abcdef12"' <<< "$out" >/dev/null \
  || fail "the recorded snapshot id was not reported: $out"
jq -e '.last_run.age_seconds != null' <<< "$out" >/dev/null \
  || fail "a recorded run should have a computable age: $out"

printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=failure\nFINISHED_TS=%s\nSNAPSHOT_ID=\n' "$(date -Iseconds)" > "$run_file"
out="$(report_target cloud)" || fail "report_backup_target_state failed on a failure record"
jq -e '.last_run.state == "failed"' <<< "$out" >/dev/null \
  || fail "a recorded failure was not reported as failed: $out"

# A target with no evidence must report unknown, never inherit another's result.
out="$(report_target archive)" || fail "report_backup_target_state failed for an unrecorded target"
jq -e '.last_run.state == "unknown"' <<< "$out" >/dev/null \
  || fail "a target with no evidence must report unknown: $out"
jq -e '.last_run.reason != null' <<< "$out" >/dev/null \
  || fail "an unknown run state must explain itself: $out"

# ---------------------------------------------------------------------------
# 3. The aggregate heartbeat must never be used as per-target evidence.
# ---------------------------------------------------------------------------
grep -n 'last_run' "$REPO_ROOT/bin/domum-media-report" | grep -qi 'heartbeat' \
  && fail "per-target run state must not be derived from the aggregate heartbeat"

# ---------------------------------------------------------------------------
# 4. A failed target must still abort the run (fail-fast is preserved).
# ---------------------------------------------------------------------------
awk '/while IFS= read -r target; do/,/done < <\(enabled_backup_targets\)/' "$REPO_ROOT/bin/domum-media-backup" \
  | grep -q 'die "Backup failed for target' \
  || fail "a failing target no longer aborts the backup run"

# ---------------------------------------------------------------------------
# 5. restic_backup_to must stream to the log, capture the snapshot id, and
#    propagate restic's own exit status -- not tee's. A regression here would
#    mark a failed backup as successful.
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/backup-harness.sh" <<HARNESS
set -uo pipefail
LOG_FILE="$TMP_DIR/stream.log"
DOMUM_DATA_ROOT=/tmp/domum-test-d
DOMUM_MEDIA_ROOT=/tmp/domum-test-m
REPO_SRC="$REPO_ROOT/bin/domum-media-backup"
HARNESS
cat >> "$TMP_DIR/backup-harness.sh" <<'HARNESS'
die() { echo "ERR $*" >&2; exit 1; }
log() { :; }
backup_target_include_paths() { echo /tmp; }
restic_for_target() { printf 'scanning...
snapshot ab12cd34 saved
'; return "${FAKE_RC:-0}"; }
eval "$(awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_SRC")"
restic_backup_to cloud >/dev/null 2>&1
echo "rc=$? id=${BACKUP_LAST_SNAPSHOT_ID:-}"
HARNESS

out="$(FAKE_RC=0 bash "$TMP_DIR/backup-harness.sh")"
grep -q 'rc=0' <<< "$out" || fail "a successful backup did not return 0: $out"
grep -q 'id=ab12cd34' <<< "$out" || fail "the snapshot id was not captured: $out"

out="$(FAKE_RC=3 bash "$TMP_DIR/backup-harness.sh")"
grep -q 'rc=3' <<< "$out" \
  || fail "restic's exit status was not propagated (tee's status leaked through): $out"

grep -q 'snapshot ab12cd34 saved' "$TMP_DIR/stream.log" \
  || fail "backup output was not streamed to the log"

# The implementation must read PIPESTATUS, not the pipeline's own status.
awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup" \
  | grep -q 'PIPESTATUS\[0\]' \
  || fail "restic_backup_to must read PIPESTATUS[0] so tee cannot mask a failure"

# A killed run (systemd TimeoutStartSec is 18h) must not leave its capture file
# behind, and the signal traps must terminate rather than letting the shell
# continue after the signal.
fn_backup="$(awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
grep -q "trap .*runlog.* EXIT" <<< "$fn_backup" \
  || fail "restic_backup_to must clean its capture file on exit"
grep -qE "trap .*runlog.*exit [0-9]+.* (HUP|INT|TERM)" <<< "$fn_backup" \
  || fail "the signal traps must terminate, not merely clean up and continue"
grep -q 'trap - EXIT' <<< "$fn_backup" \
  || fail "the trap must be cleared once the capture file is gone"

echo "PASS: backup target evidence smoke test"
