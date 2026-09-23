#!/usr/bin/env bash
set -euo pipefail

# Proves the operational report's behavior, not merely that it exits zero.
# Every assertion below targets a way the report could lie: claiming snapshot
# protection that does not exist, converting an uninspectable state into a
# healthy one, or reporting evidence the host never recorded.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DOMUM_DATA_ROOT="$TMP_DIR/data"
DOMUM_STATE_ROOT="$TMP_DIR/state"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
FAKE_BIN="$TMP_DIR/bin"

mkdir -p \
  "$DOMUM_DATA_ROOT/immich/library" \
  "$DOMUM_DATA_ROOT/immich/backup-staging" \
  "$DOMUM_STATE_ROOT/backups" \
  "$DOMUM_SNAPSHOT_ROOT" \
  "$FAKE_BIN"

# ---------------------------------------------------------------------------
# 1. CLI dispatch: `domum-media report` must reach the command, not fall
#    through to usage. Unprivileged it must refuse with the root error.
# ---------------------------------------------------------------------------
dispatch_out="$(bash "$REPO_ROOT/bin/domum-media" report 2>&1 || true)"
case "$dispatch_out" in
  *"Run as root"*) ;;
  *Usage:*) fail "domum-media report fell through to usage; the CLI has no report dispatch" ;;
  *) fail "unexpected output from 'domum-media report': $dispatch_out" ;;
esac

# ---------------------------------------------------------------------------
# 2. The weekly systemd unit must invoke a subcommand the CLI implements.
# ---------------------------------------------------------------------------
unit="$REPO_ROOT/systemd/domum-media-weekly-report.service"
[[ -f "$unit" ]] || fail "missing $unit"
exec_line="$(grep -E '^ExecStart=' "$unit" | head -1)"
[[ -n "$exec_line" ]] || fail "weekly report unit has no ExecStart"
subcommand="$(printf '%s' "$exec_line" | sed -E 's/^ExecStart=[^ ]+ +([a-z-]+).*/\1/')"
grep -qE "^ +${subcommand}\)" "$REPO_ROOT/bin/domum-media" \
  || fail "weekly report unit invokes '$subcommand', which bin/domum-media does not dispatch"

# ---------------------------------------------------------------------------
# 3. Generate a report against a controlled fake host.
# ---------------------------------------------------------------------------
# Docker is stubbed as absent so container state is *uninspectable*, which must
# not be reported as "not running" or silently treated as healthy.
cat > "$FAKE_BIN/btrfs" <<'EOF'
#!/usr/bin/env bash
# Never a subvolume: every service path here is an ordinary directory.
exit 1
EOF
chmod +x "$FAKE_BIN/btrfs"
export PATH="$FAKE_BIN:$PATH"

# Minimal harness providing the symbols the report library expects from the CLI.
cat > "$TMP_DIR/harness.sh" <<EOF
set -euo pipefail
die() { echo "ERROR: \$*" >&2; exit 1; }
# Docker is forced absent so container state is genuinely uninspectable. The
# report must say so rather than reporting "not running" or dropping the entry.
cmd_exists() {
  [[ "\$1" == "docker" ]] && return 1
  command -v "\$1" >/dev/null 2>&1
}
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
DOMUM_DATA_ROOT="$DOMUM_DATA_ROOT"
DOMUM_MEDIA_ROOT="$TMP_DIR/media"
DOMUM_SNAPSHOT_ROOT="$DOMUM_SNAPSHOT_ROOT"
DOMUM_STATE_ROOT="$DOMUM_STATE_ROOT"
DOMUM_LOG_DIR="$TMP_DIR/log"
REPO_META_DIR="$DOMUM_STATE_ROOT/backups"
RECOVERY_PACK_DEST="$DOMUM_STATE_ROOT/recovery-pack"
ENABLE_IMMICH=1
IMAGE_AUTO_UPDATE_ENABLED=0
DOMUM_REPORT_REBOOT_REQUIRED="$TMP_DIR/no-reboot-required"

service_lifecycle_specs() {
  echo 'immich|ENABLE_IMMICH|C|21|immich_server|IMMICH_SERVER_IMAGE|'
}
service_backup_required() { [[ "\$1" == "immich" ]]; }
service_data_path() { echo "$DOMUM_DATA_ROOT/immich"; }
latest_snapshot_for_service() { return 1; }
snapshot_path_mtime() { return 1; }
backup_last_success_epoch() { return 1; }
recovery_pack_state_file() { echo "$DOMUM_STATE_ROOT/recovery-pack.env"; }
enabled_backup_targets() { echo 'cloud'; }

source "$REPO_ROOT/bin/domum-media-report"
report_generate_json
EOF

report_json="$TMP_DIR/report.json"
bash "$TMP_DIR/harness.sh" > "$report_json" 2>"$TMP_DIR/report.err" \
  || fail "report generation failed: $(cat "$TMP_DIR/report.err")"

# ---------------------------------------------------------------------------
# 4. Structural assertions — valid JSON with the agreed stable schema.
# ---------------------------------------------------------------------------
jq -e 'type == "object"' "$report_json" >/dev/null || fail "report is not a JSON object"
jq -e '.schema_version == 2' "$report_json" >/dev/null || fail "missing or unexpected schema_version"
jq -e '.generated_at | type == "string"' "$report_json" >/dev/null || fail "missing generated_at"
jq -e '.overall | type == "string"' "$report_json" >/dev/null || fail "missing overall verdict"
jq -e '.findings | type == "array"' "$report_json" >/dev/null || fail "findings is not an array"
jq -e 'all(.findings[]; has("level") and has("message") and has("action"))' "$report_json" >/dev/null \
  || fail "every finding must carry level, message and action"

# ---------------------------------------------------------------------------
# 5. Truthfulness assertions.
# ---------------------------------------------------------------------------
# Ordinary directories must never be reported as snapshot-protected.
jq -e '.snapshot_protection.services | length > 0' "$report_json" >/dev/null \
  || fail "no snapshot protection entries were produced"
jq -e 'all(.snapshot_protection.services[]; .state != "protected")' "$report_json" >/dev/null \
  || fail "an ordinary directory was reported as snapshot-protected"
jq -e 'any(.snapshot_protection.services[]; .state == "unprotected")' "$report_json" >/dev/null \
  || fail "expected an unprotected snapshot entry for an ordinary directory"
jq -e 'any(.findings[]; .message | test("snapshot protection"))' "$report_json" >/dev/null \
  || fail "missing snapshot protection finding"
jq -e 'all(.snapshot_protection.services[]; .tier != null)' "$report_json" >/dev/null \
  || fail "snapshot protection entries must carry a risk tier"

# An uninspectable container must still APPEAR in the report. jq object
# construction drops the whole object when an optional field selects nothing,
# which previously made uninspectable containers vanish silently.
jq -e '.containers | length > 0' "$report_json" >/dev/null \
  || fail "container entries vanished from the report instead of being reported"
jq -e 'all(.containers[]; .running == null)' "$report_json" >/dev/null \
  || fail "container running state must be null when Docker cannot be consulted"

# An uninspectable container must not be reported as running or healthy.
jq -e 'all(.containers[]; .running != true)' "$report_json" >/dev/null \
  || fail "a container was reported running while Docker was unavailable"
jq -e 'all(.containers[]; .health != "healthy")' "$report_json" >/dev/null \
  || fail "a container was reported healthy while Docker was unavailable"

# Absent evidence must surface as unknown, never as success.
jq -e '.backups.heartbeat.state != "available"' "$report_json" >/dev/null \
  || fail "backup heartbeat reported available without evidence"
jq -e '.backups.restore_verification.state == "unknown"' "$report_json" >/dev/null \
  || fail "restore verification must be unknown when nothing was recorded"
jq -e 'all(.backups.targets[]; .last_run.state == "unknown")' "$report_json" >/dev/null \
  || fail "per-target last_run must be unknown; no per-target evidence is recorded"
jq -e 'any(.findings[]; .message | test("restore verification"; "i"))' "$report_json" >/dev/null \
  || fail "missing restore-verification finding"

# A timer that has never triggered (a disabled one) must not break the report.
jq -e '.updates.image_refresh.timer | type == "object"' "$report_json" >/dev/null \
  || fail "image refresh timer state is missing; a never-triggered timer must still report"
jq -e '.updates.image_refresh.timer.last_trigger == null' "$report_json" >/dev/null \
  || fail "a never-triggered timer must report a null last_trigger"

# Missing evidence must not produce a healthy verdict.
jq -e '.overall != "healthy"' "$report_json" >/dev/null \
  || fail "report claimed healthy despite unprotected snapshots and missing evidence"

# ---------------------------------------------------------------------------
# 6. Reporting must not mutate production-shaped state.
# ---------------------------------------------------------------------------
[[ -z "$(find "$DOMUM_SNAPSHOT_ROOT" -mindepth 1 2>/dev/null)" ]] \
  || fail "report generation created snapshots"
[[ ! -d "$DOMUM_STATE_ROOT/reports" ]] \
  || fail "report generation wrote report output without --write"

# ---------------------------------------------------------------------------
# 7. systemd timer field mapping must not be swapped.
#    `systemctl show` returns properties in its own order, so the helper must
#    query one property at a time.
# ---------------------------------------------------------------------------
grep -q 'report_systemd_property' "$REPO_ROOT/bin/domum-media-report" \
  || fail "report_systemd_state must query systemd properties individually"
grep -qE -- "--property=[A-Za-z]+,[A-Za-z]+" "$REPO_ROOT/bin/domum-media-report" \
  && fail "multi-property 'systemctl show' parsing is order-dependent and must not be used"

# ---------------------------------------------------------------------------
# 8. A directory's mtime is not content freshness.
#    The Immich library is a directory whose top-level mtime can be months old
#    while photos are still being written deeper inside. It must not be
#    presented as an age.
# ---------------------------------------------------------------------------
jq -e '.immich.library.kind == "directory"' "$report_json" >/dev/null \
  || fail "the Immich library should be reported as a directory"
jq -e '.immich.library.age_seconds == null' "$report_json" >/dev/null \
  || fail "a directory must not report an age; its mtime is not content freshness"
jq -e '.immich.library.path_mtime != null' "$report_json" >/dev/null \
  || fail "a directory should still expose its own mtime under path_mtime"
jq -e '.immich.library.age_basis | test("does not reflect")' "$report_json" >/dev/null \
  || fail "a directory must state that its mtime is not content freshness"

# A real file (the database dump) keeps a meaningful age.
dump_file="$DOMUM_DATA_ROOT/immich/backup-staging/immich-postgres.dump.sql.gz"
printf 'x' > "$dump_file"
bash "$TMP_DIR/harness.sh" > "$TMP_DIR/report2.json" 2>/dev/null \
  || fail "report generation failed after creating a dump file"
jq -e '.immich.database_dump.kind == "file"' "$TMP_DIR/report2.json" >/dev/null \
  || fail "the database dump should be reported as a file"
jq -e '.immich.database_dump.age_seconds != null' "$TMP_DIR/report2.json" >/dev/null \
  || fail "a file must keep a meaningful age"
rm -f "$dump_file"

# ---------------------------------------------------------------------------
# 9. Docker "none" means no healthcheck is configured, and must say so.
# ---------------------------------------------------------------------------
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
# Mimics a container that is running but defines no healthcheck.
case "${1:-}" in
  inspect) printf 'running|none|0|sha256:deadbeef
' ;;
  image)   exit 1 ;;
  *)       exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"
sed 's/\[\[ "\$1" == "docker" \]\] && return 1//' "$TMP_DIR/harness.sh" > "$TMP_DIR/harness-docker.sh"
bash "$TMP_DIR/harness-docker.sh" > "$TMP_DIR/report3.json" 2>/dev/null \
  || fail "report generation failed with a stubbed docker"
jq -e 'any(.containers[]; .health == "no healthcheck")' "$TMP_DIR/report3.json" >/dev/null \
  || fail "a container without a healthcheck must report 'no healthcheck', not 'none'"
jq -e 'all(.containers[]; .health != "none")' "$TMP_DIR/report3.json" >/dev/null \
  || fail "the bare 'none' health value must not reach the report"
# ...and it must not be treated as a problem.
jq -e 'all(.findings[]; (.message | test("no healthcheck")) | not)' "$TMP_DIR/report3.json" >/dev/null \
  || fail "a missing healthcheck must not be raised as a finding"
rm -f "$FAKE_BIN/docker"

# ---------------------------------------------------------------------------
# 10. The backup wrapper's read-only path must not touch the backup log.
# ---------------------------------------------------------------------------
grep -A6 '^ensure_dirs() {' "$REPO_ROOT/bin/domum-media-backup" | grep -qE '^\s*touch ' \
  && fail "ensure_dirs still touches the backup log, so a read-only report mutates its mtime"

# ---------------------------------------------------------------------------
# 11. Snapshot finding severity must follow actual risk, and must ESCALATE when
#     the safety gate is disabled. Severity is never softened to look healthy.
# ---------------------------------------------------------------------------
sed 's/^ENABLE_IMMICH=1$/ENABLE_IMMICH=1\nSNAPSHOT_POLICY=WARN/' "$TMP_DIR/harness.sh" > "$TMP_DIR/harness-warn.sh"
bash "$TMP_DIR/harness-warn.sh" > "$TMP_DIR/report-warn.json" 2>/dev/null \
  || fail "report generation failed with SNAPSHOT_POLICY=WARN"

jq -e '.snapshot_protection.enforced == false' "$TMP_DIR/report-warn.json" >/dev/null \
  || fail "SNAPSHOT_POLICY=WARN must report the gate as not enforced"
jq -e 'any(.findings[]; .level == "critical" and (.message | test("gate is disabled")))' "$TMP_DIR/report-warn.json" >/dev/null \
  || fail "with the gate disabled, unprotected state must be critical"

# With the gate enforcing, the same unprotected state must NOT be critical --
# risky operations are refused rather than run unprotected.
jq -e '.snapshot_protection.enforced == true' "$report_json" >/dev/null \
  || fail "the default policy must report the gate as enforced"
jq -e 'all(.findings[]; (.level == "critical" and (.message | test("snapshot protection"))) | not)' "$report_json" >/dev/null \
  || fail "with the gate enforcing, unprotected state should not be critical"

# The verdict rule itself is exercised directly, because the live fixture always
# contains a critical finding and so cannot distinguish the rules on its own.
# Extract the shipped jq program and run it against synthetic finding sets.
overall_filter="$(sed -n 's/^  overall="\$(jq -r '"'"'\(.*\)'"'"' <<< "\$findings")"$/\1/p' "$REPO_ROOT/bin/domum-media-report")"
[ -n "$overall_filter" ] || fail "could not extract the overall verdict rule from the report library"

verdict_for() { jq -r "$overall_filter" <<< "$1"; }
[ "$(verdict_for '[{"level":"info"}]')" = "healthy" ] \
  || fail "an informational finding must not make the report look degraded"
[ "$(verdict_for '[{"level":"info"},{"level":"warning"}]')" = "warning" ] \
  || fail "a warning must still surface alongside informational findings"
[ "$(verdict_for '[{"level":"info"},{"level":"critical"}]')" = "critical" ] \
  || fail "a critical must still surface alongside informational findings"
[ "$(verdict_for '[]')" = "healthy" ] \
  || fail "no findings must read as healthy"

# ...and the live report's own verdict must obey that same rule.
[ "$(jq -r '.overall' "$report_json")" = "$(verdict_for "$(jq -c '.findings' "$report_json")")" ] \
  || fail "the report's overall verdict does not match its own severity rule"

# ---------------------------------------------------------------------------
# 12. The image-refresh freeze must be reported from the TIMER, which enforces
#     it, and the report must never describe it as frozen when it is not.
# ---------------------------------------------------------------------------
grep -q 'image_refresh.timer.enabled != "enabled") as $frozen' "$REPO_ROOT/bin/domum-media-report" \
  || fail "the frozen/not-frozen wording must be derived from the timer state, not assumed"
grep -q 'image refresh is ENABLED' "$REPO_ROOT/bin/domum-media-report" \
  || fail "the report must say so when image refresh is NOT frozen"

grep -q 'automatic image deployment is no longer frozen' "$REPO_ROOT/bin/domum-media-report" \
  || fail "an enabled image-refresh timer must raise a finding"
awk '/image-refresh timer is ENABLED/{found=1} /level:"critical"/{lvl=1} END{exit (found&&lvl)?0:1}' \
  "$REPO_ROOT/bin/domum-media-report" \
  || fail "an enabled image-refresh timer must be critical"

# Staged candidates are reported as ONE aggregate finding, not one per service:
# a deliberate freeze must not generate a warning per image every week.
grep -q '.updates.candidates\[\] | {level:"warning"' "$REPO_ROOT/bin/domum-media-report" \
  && fail "staged update candidates must be aggregated into a single finding"

# ---------------------------------------------------------------------------
# 13. Writable container state outside the durable data root is neither
#     snapshottable nor backed up, and must be detected from the containers
#     themselves -- a hand-written inventory missed Traefik's ACME store.
# ---------------------------------------------------------------------------
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "inspect" ]; then
  name="$2"
  case "$*" in
    *Mounts*)
      case "$name" in
        immich_server) printf 'volume|some-named-volume|/letsencrypt|true
bind|DATA_ROOT_PLACEHOLDER/immich/library|/upload|true
bind|/etc/localtime|/etc/localtime|false
bind|/srv/media|/media|false
' ;;
      esac ;;
    *) printf 'running|healthy|0|sha256:x
' ;;
  esac
  exit 0
fi
exit 1
EOF
# The stub must reference the harness's own data root, not a literal /srv/data.
sed -i "s|DATA_ROOT_PLACEHOLDER|$DOMUM_DATA_ROOT|" "$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"
sed 's/\[\[ "\$1" == "docker" \]\] && return 1//' "$TMP_DIR/harness.sh" > "$TMP_DIR/harness-exposure.sh"
bash "$TMP_DIR/harness-exposure.sh" > "$TMP_DIR/report-exposure.json" 2>/dev/null \
  || fail "report generation failed while detecting container state exposure"

jq -e '.unprotected_container_state | length > 0' "$TMP_DIR/report-exposure.json" >/dev/null \
  || fail "a writable Docker volume must be detected as unprotected state"
jq -e 'any(.unprotected_container_state[].unprotected_state[]; test("some-named-volume"))' "$TMP_DIR/report-exposure.json" >/dev/null \
  || fail "the named volume was not reported"
# A writable bind UNDER the data root is protected and must not be flagged.
jq -e 'all(.unprotected_container_state[].unprotected_state[]; test("immich/library") | not)' "$TMP_DIR/report-exposure.json" >/dev/null \
  || fail "a bind under the durable data root must not be flagged as unprotected"
# Read-only mounts hold no state and must not be flagged.
jq -e 'all(.unprotected_container_state[].unprotected_state[]; test("localtime|/srv/media") | not)' "$TMP_DIR/report-exposure.json" >/dev/null \
  || fail "read-only mounts must not be flagged as unprotected state"
jq -e 'any(.findings[]; .message | test("outside the durable data root"))' "$TMP_DIR/report-exposure.json" >/dev/null \
  || fail "unprotected container state must raise a finding"
rm -f "$FAKE_BIN/docker"

echo "PASS: operational report smoke test"
