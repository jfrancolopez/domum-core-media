#!/usr/bin/env bash
set -uo pipefail

# Drives the REAL do_daily_backup end to end against stubbed outward-facing
# functions. No restic repository is contacted and nothing outside a temporary
# directory is written.
#
# The question this answers: after a scheduled backup, can the recorded evidence
# ever claim more than actually happened?

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Scenario runner. $1 = scenario name, $2 = extra stub code.
# Produces $TMP_DIR/<name>/ containing the evidence dir and a result file.
# ---------------------------------------------------------------------------
run_scenario() {
  local name="$1" stubs="$2"
  local dir="$TMP_DIR/$name"
  mkdir -p "$dir/state/backups" "$dir/log"

  # Repository identities, as the pinned metadata would hold them.
  printf 'REPOSITORY_ID=cloudrepo1111\n' > "$dir/state/backups/cloud-repo.env"
  printf 'REPOSITORY_ID=nasrepo2222\n'   > "$dir/state/backups/nas-repo.env"

  cat > "$dir/harness.sh" <<HARNESS
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$dir/absent.conf"
source "$REPO_ROOT/bin/domum-media-backup"
DOMUM_LOG_DIR="$dir/log"
DOMUM_DATA_ROOT="$dir/data"
DOMUM_MEDIA_ROOT="$dir/media"
DOMUM_STATE_ROOT="$dir/state"
REPO_META_DIR="$dir/state/backups"
RECOVERY_PACK_ENABLED=0
ENABLE_IMMICH=0
ensure_dirs
log() { :; }
quiesce_immich_postgres() { return 0; }
retention_targets() { :; }
restic_forget_for() { :; }
enabled_backup_targets() { printf '%s\n' cloud nas; }
backup_target_include_paths() { printf '%s' /tmp; }
check_repo_identity() { return 0; }
restic_for_target() { printf 'snapshot aaaa1111 saved\n'; return 0; }
$stubs
do_daily_backup
HARNESS

  bash "$dir/harness.sh" >"$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
  printf '%s' "$dir"
}

# Re-run an already-prepared scenario in place (used to test what a second run
# does to evidence left by a first).
rerun_scenario() {
  local dir="$1"
  bash "$dir/harness.sh" >"$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
}

field() { grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# A. Both targets succeed.
# ---------------------------------------------------------------------------
d="$(run_scenario both-ok '')"
[ "$(cat "$d/rc")" = "0" ] || fail "A: a fully successful run should exit 0 (got $(cat "$d/rc"))"

for t in cloud nas; do
  f="$d/state/backups/$t-run.env"
  [ -f "$f" ] || fail "A: no evidence recorded for $t"
  [ "$(field "$f" RESULT)" = "success" ] || fail "A: $t not recorded as success"
  [ "$(field "$f" TARGET)" = "$t" ] || fail "A: $t recorded under the wrong target name"
  [ "$(field "$f" SNAPSHOT_ID)" = "aaaa1111" ] || fail "A: $t has the wrong snapshot id"
  [ -n "$(field "$f" STARTED_TS)" ] || fail "A: $t has no start time"
  [ -n "$(field "$f" FINISHED_TS)" ] || fail "A: $t has no finish time"
done
# A success must say WHAT it backed up. A record that claims success without
# naming its scope can overstate the protection it represents.
for t in cloud nas; do
  f="$d/state/backups/$t-run.env"
  grep -q '^PATHS=' "$f" || fail "A: $t success record does not say what was backed up"
  [ -n "$(field "$f" PATHS)" ] || fail "A: $t recorded an empty scope for a success"
done

# Repository identity must come from that target's own pinned metadata.
[ "$(field "$d/state/backups/cloud-run.env" REPOSITORY_ID)" = "cloudrepo1111" ] \
  || fail "A: cloud recorded the wrong repository identity"
[ "$(field "$d/state/backups/nas-run.env" REPOSITORY_ID)" = "nasrepo2222" ] \
  || fail "A: nas recorded the wrong repository identity (identities crossed between targets)"
[ -f "$d/log/last-success" ] || fail "A: the aggregate heartbeat was not written after a full success"
# Atomic write: nothing left behind.
leftover="$(find "$d/state/backups" -name '.*-run.env.*' 2>/dev/null)"
[ -z "$leftover" ] || fail "A: atomic write left a temporary file: $leftover"

# ---------------------------------------------------------------------------
# B. Partial failure: first target succeeds, second target's restic fails.
# ---------------------------------------------------------------------------
d="$(run_scenario second-fails '
restic_for_target() {
  if [[ "$1" == "nas" ]]; then return 7; fi
  printf "snapshot aaaa1111 saved\n"; return 0
}')"
[ "$(cat "$d/rc")" != "0" ] || fail "B: a failing target must make the run exit non-zero"
[ "$(field "$d/state/backups/cloud-run.env" RESULT)" = "success" ] \
  || fail "B: the target that succeeded should be recorded as success"
[ "$(field "$d/state/backups/nas-run.env" RESULT)" = "failure" ] \
  || fail "B: the target that failed must be recorded as failure, not success"
[ -z "$(field "$d/state/backups/nas-run.env" SNAPSHOT_ID)" ] \
  || fail "B: a failed target must not record a snapshot id"
[ ! -f "$d/log/last-success" ] \
  || fail "B: the aggregate heartbeat must NOT be written when a target failed"

# ---------------------------------------------------------------------------
# C. Repository identity mismatch aborts before the backup runs.
#    The attempt must not be left looking successful.
# ---------------------------------------------------------------------------
d="$(run_scenario identity-mismatch '
check_repo_identity() {
  if [[ "$1" == "nas" ]]; then die "repository ID mismatch"; fi
  return 0
}
restic_for_target() { printf "snapshot aaaa1111 saved\n"; return 0; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "C: an identity mismatch must abort the run"
[ "$(field "$d/state/backups/nas-run.env" RESULT)" = "running" ] \
  || fail "C: an aborted target must stay 'running', never success (got '$(field "$d/state/backups/nas-run.env" RESULT)')"
[ ! -f "$d/log/last-success" ] \
  || fail "C: the heartbeat must NOT be written when a target was rejected"

# ---------------------------------------------------------------------------
# D. Evidence must follow the backup, not precede it. A target whose restic
#    never ran must never carry a success record from a previous run.
# ---------------------------------------------------------------------------
d="$(run_scenario stale-run '
check_repo_identity() {
  if [[ "$1" == "nas" ]]; then die "repository ID mismatch"; fi
  return 0
}')"
# Seed yesterday's success for nas, then run again. The rejected target must not
# keep claiming success from the previous run.
printf 'SCHEMA_VERSION=1\nTARGET=nas\nRESULT=success\nFINISHED_TS=2020-01-01T00:00:00+00:00\nSNAPSHOT_ID=old11111\n' \
  > "$d/state/backups/nas-run.env"
rerun_scenario "$d"
[ "$(field "$d/state/backups/nas-run.env" RESULT)" != "success" ] \
  || fail "D: a stale success survived a run in which the target was rejected"
[ "$(field "$d/state/backups/nas-run.env" SNAPSHOT_ID)" != "old11111" ] \
  || fail "D: a stale snapshot id survived a failed run"

# ---------------------------------------------------------------------------
# E. The aggregate heartbeat must never stand in for per-target evidence.
# ---------------------------------------------------------------------------
probe="$TMP_DIR/probe"
mkdir -p "$probe/state/backups"
report_target() {
  bash -c "
cmd_exists() { command -v \"\$1\" >/dev/null 2>&1; }
REPO_META_DIR='$probe/state/backups'
DOMUM_STATE_ROOT='$probe/state'
REPORT_NOW_EPOCH=\$(date +%s)
source '$REPO_ROOT/bin/domum-media-report'
report_backup_target_state '$1'
"
}
# A fresh heartbeat exists, but this target has no record of its own.
mkdir -p "$probe/log" && date -Iseconds > "$probe/log/last-success"
out="$(report_target cloud)" || fail "E: report_backup_target_state failed"
echo "$out" | jq -e '.last_run.state == "unknown"' >/dev/null \
  || fail "E: a fresh aggregate heartbeat made a target with no record look known: $out"

# A 'running' record must read as incomplete, never ok.
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=running\nFINISHED_TS=%s\n' "$(date -Iseconds)" \
  > "$probe/state/backups/cloud-run.env"
out="$(report_target cloud)" || fail "E: report_backup_target_state failed on a running record"
echo "$out" | jq -e '.last_run.state == "incomplete"' >/dev/null \
  || fail "E: an interrupted run must read as incomplete: $out"

# Stale evidence must be recognisable: an old success keeps an age the report
# can act on.
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=success\nFINISHED_TS=2020-01-01T00:00:00+00:00\nSNAPSHOT_ID=old11111\n' \
  > "$probe/state/backups/cloud-run.env"
out="$(report_target cloud)" || fail "E: report_backup_target_state failed on a stale record"
echo "$out" | jq -e '.last_run.state == "ok"' >/dev/null || fail "E: a stale success should still parse as ok"
age="$(echo "$out" | jq -r '.last_run.age_seconds')"
[ "$age" != "null" ] && [ "$age" -gt 172800 ] \
  || fail "E: a stale success must carry an age the report can act on (got $age)"

# ---------------------------------------------------------------------------
# F. A configured include path that does not exist must be recorded, not
#    silently dropped from a success, and must be surfaced as a finding.
# ---------------------------------------------------------------------------
d="$(run_scenario missing-path '
backup_target_include_paths() { printf "%s" "/tmp /definitely/not/here"; }')"
[ "$(cat "$d/rc")" = "0" ] || fail "F: a run with one usable path should still succeed"
f="$d/state/backups/cloud-run.env"
[ "$(field "$f" RESULT)" = "success" ] || fail "F: expected success with one usable path"
# Captured first. `cmd | grep -q` exits at the first match, the left side takes
# SIGPIPE, and under pipefail the PIPELINE reports 141 -- so a MATCH reads as a
# no-match and the assertion silently stops asserting.
missing_f="$(field "$f" PATHS_MISSING)"
grep -q 'not/here' <<< "$missing_f" \
  || fail "F: a skipped configured path was not recorded: $missing_f"
paths_f="$(field "$f" PATHS)"
grep -q '/tmp' <<< "$paths_f" || fail "F: the usable path was not recorded"

# ...and no usable path at all must fail rather than record an empty success.
d="$(run_scenario no-paths '
backup_target_include_paths() { printf "%s" "/definitely/not/here"; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "F: a target with no existing include path must not succeed"
[ "$(field "$d/state/backups/cloud-run.env" RESULT)" = "failure" ] \
  || fail "F: a target with nothing to back up must be recorded as failure"
[ ! -f "$d/log/last-success" ] \
  || fail "F: the heartbeat must not be written when a target had nothing to back up"

# ---------------------------------------------------------------------------
# F2. EFFECTIVE target configuration: configured is not enabled, and enabled is
#     not undergoing retention.
#
# Every suite stubbed `retention_targets`, so nothing drove the real
# enabled_backup_targets -> retention_targets chain. That gap let an UNPROVEN
# claim stand: "only cloud is enabled" was inferred from a report in which no
# per-target line named nas -- but those lines are conditional on the
# repository being `sftp:`, so a non-sftp enabled target prints nothing, and
# the inference was invalid.
#
# The trap is the DEFAULT: backup_target_default_enabled returns 1 for `nas`
# and for `cloud`. A target listed in BACKUP_TARGETS is therefore ENABLED
# unless the configuration explicitly disables it, and "not mentioned" is not
# evidence of anything.
# ---------------------------------------------------------------------------
targets_probe() {  # $1 = config assignments -> prints the three resolved lists
  (
    DOMUM_DIR="$REPO_ROOT"
    CFG_FILE="$TMP_DIR/absent.conf"
    SECRETS_DIR="$TMP_DIR/secrets"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    eval "$1"
    printf 'enabled: %s\n' "$(enabled_backup_targets | tr '\n' ' ')"
    printf 'daily:   %s\n' "$(retention_targets daily | tr '\n' ' ')"
    printf 'weekly:  %s\n' "$(retention_targets weekly | tr '\n' ' ')"
  ) 2>&1
}

# The production shape, as the 0600 config holds it.
PROD_TARGETS='
BACKUP_TARGETS="nas cloud archive"
BACKUP_TARGET_NAS_ENABLED=0
BACKUP_TARGET_NAS_RETENTION="daily"
BACKUP_TARGET_CLOUD_RETENTION=weekly
BACKUP_TARGET_ARCHIVE_RETENTION="none"'

out="$(targets_probe "$PROD_TARGETS")"
grep -q '^enabled: cloud $' <<< "$out" \
  || fail "F2: the production shape must enable cloud ONLY: $out"
grep -q '^daily:   $' <<< "$out" \
  || fail "F2: no daily-retention target may be selected in the production shape: $out"
grep -q '^weekly:  cloud $' <<< "$out" \
  || fail "F2: cloud must be the weekly-retention target: $out"
echo "  F2: configured nas+cloud+archive -> enabled cloud only; daily empty, weekly cloud"

# An explicit 0 must beat a DEFAULT of 1. This is the whole semantic: nas is
# listed and carries daily retention, and is inert only because of that 0.
out="$(targets_probe "$PROD_TARGETS
BACKUP_TARGET_NAS_ENABLED=1")"
grep -q 'nas' <<< "$(sed -n 's/^daily:   //p' <<< "$out")" \
  || fail "F2: with nas ENABLED its daily retention must be selected -- the fixed
loop is reachable by configuration, not dead code: $out"
echo "  F2: enabling nas makes the DAILY retention path live -- the fix is not dead code"

# archive is default-disabled AND cadence none: it must never appear anywhere.
out="$(targets_probe "$PROD_TARGETS")"
grep -q 'archive' <<< "$out" \
  && fail "F2: archive is listed but default-disabled; it must not be selected: $out"
echo "  F2: a listed, default-disabled target is excluded from all three lists"

# ---------------------------------------------------------------------------
# G. A RETENTION failure is not a BACKUP failure.
#
# `restic_forget_for` returns restic's status, and the unguarded call under
# `set -e` aborted do_daily_backup right there -- before `heartbeat`, which
# writes $DOMUM_LOG_DIR/last-success, the marker `checkup` reads for "Last
# backup completed Nh ago". So a backup that had fully succeeded, and whose own
# per-target evidence already said RESULT=success, was reported as a STALE
# backup, and the recovery-pack refresh was skipped as well.
#
# Latent rather than active on this host: `cloud` defaults to WEEKLY retention
# and is the only enabled target, so `retention_targets daily` is empty -- which
# is why the nightly backup survived the stale lock of 2026-10-20..27. It goes
# live the moment any daily-retention target is enabled.
# ---------------------------------------------------------------------------
RETENTION_FAILS='
retention_targets() { [ "$1" = daily ] && printf "%s\n" cloud; }
restic_forget_for() { return 1; }'

d="$(run_scenario retention-fails "$RETENTION_FAILS")"
[ "$(cat "$d/rc")" != "0" ] \
  || fail "G: a failed retention must still FAIL the unit -- silence is not a safety mechanism"
# The backup's own success must be recorded and durable.
[ "$(field "$d/state/backups/cloud-run.env" RESULT)" = "success" ] \
  || fail "G: the backup itself succeeded and must be recorded as success"
# And the heartbeat MUST be written: this is the whole defect.
[ -f "$d/log/last-success" ] \
  || fail "G: the heartbeat was skipped, so a successful backup reads as STALE -- the defect"
grep -qi 'retention' "$d/out.txt" \
  || fail "G: the failure does not name retention, so the cause is misattributed: $(cat "$d/out.txt")"
grep -qi 'backup itself SUCCEEDED' "$d/out.txt" \
  || fail "G: it does not say the backup succeeded, which is the distinction: $(cat "$d/out.txt")"
echo "  G: retention failure fails the unit, names retention, and keeps the heartbeat"

# One target's retention failure must not skip another's.
d="$(run_scenario retention-partial '
retention_targets() { [ "$1" = daily ] && printf "%s\n" cloud nas; }
restic_forget_for() { printf "FORGET %s\n" "$1" >> "'"$TMP_DIR"'/forgets"; [ "$1" = cloud ] && return 1; return 0; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "G: a partial retention failure must still fail the unit"
grep -q 'FORGET nas' "$TMP_DIR/forgets" \
  || fail "G: cloud's failure skipped nas entirely -- one target must not abort the others"
echo "  G: every target is attempted even after one fails"

# The success path must be unaffected: no retention failure, no extra noise.
d="$(run_scenario retention-ok '
retention_targets() { [ "$1" = daily ] && printf "%s\n" cloud; }
restic_forget_for() { return 0; }')"
[ "$(cat "$d/rc")" = "0" ] \
  || fail "G: a successful retention must not fail the run: $(cat "$d/out.txt")"
[ -f "$d/log/last-success" ] || fail "G: the heartbeat is missing on a fully successful run"
echo "  G: a successful retention leaves the run clean"

# The mutation: restore the unguarded call. The observable is the HEARTBEAT --
# the run fails either way, so asserting the exit status would pass against the
# defect. Name the observable the mutation actually changes.
MUT="$TMP_DIR/mutant-backup"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
cat > "$TMP_DIR/mutate-retention.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = """    restic_forget_for "$target" \\
      || retention_failed="${retention_failed:+$retention_failed }$target"
"""
new = """    restic_forget_for "$target"
"""
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP_DIR/mutate-retention.py" "$MUT" ) || fail "the retention mutation did not apply"
md="$TMP_DIR/mutant-run"
mkdir -p "$md/state/backups" "$md/log"
printf 'REPOSITORY_ID=cloudrepo1111\n' > "$md/state/backups/cloud-repo.env"
sed -e "s|$TMP_DIR/retention-fails|$md|g" -e "s|$REPO_ROOT/bin/domum-media-backup|$MUT|" \
    "$TMP_DIR/retention-fails/harness.sh" > "$md/harness.sh"
bash "$md/harness.sh" >"$md/out.txt" 2>&1
[ ! -f "$md/log/last-success" ] \
  || fail "the mutation changed no ANSWER -- unguarded, the heartbeat must be skipped"
echo "  killed: unguarded, a successful backup loses its heartbeat and reads as STALE"

echo "PASS: backup evidence end-to-end smoke test"
