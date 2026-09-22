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
jq -e '.schema_version == 1' "$report_json" >/dev/null || fail "missing or unexpected schema_version"
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
jq -e 'any(.findings[]; .level == "critical" and (.message | test("snapshot")))' "$report_json" >/dev/null \
  || fail "missing snapshot protection finding"

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

echo "PASS: operational report smoke test"
