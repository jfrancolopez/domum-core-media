#!/usr/bin/env bash
# A BARE CALL WHOSE STATUS IS CAPTURED ON THE NEXT STATEMENT EXITS THE SHELL.
#
# `f "$x"; rc=$?` reads as "run f and keep its status". Under `set -e` it is
# not: a simple command that fails IS the errexit trigger, so the shell dies
# before `rc=$?` ever runs. The `case "$rc"` written to handle the non-zero
# answers is unreachable, and the function's ordinary answers become fatal.
#
# Measured in production 2026-11-19. `sudo domum-media report weekly --stdout`
# printed NOTHING -- not a header, not an error -- and returned in 6 seconds.
# The cause:
#
#     mreport_smart_interpretable "$dev"; interp=$?
#
# That function returns 1 when a drive's SMART attributes all read alike
# (vendor placeholders) and 2 when the table cannot be read. On this host
# /dev/sdb reports all 30 attributes at value=100, so it returns 1 -- and
# `checkup_disk_wear` died there, inside `checkup_collect_all`, which
# `checkup`, `health-notify` AND `report weekly` all run before printing a
# single line. All three went silent at once, and silence is this project's
# healthy signal: a host that can no longer report anything looked fine.
#
# The shape arrived with the 2026-11-18 deployment -- `a63ad199bfa2` has zero
# occurrences, `f647aa2` has two -- so it is a deployed regression, not a
# main-only one.
#
# NO SUITE COULD HAVE CAUGHT IT. `weekly-report-render-smoke` runs `set +e`
# immediately before driving the command, and its smartctl stub returns a table
# with two distinct values, so the non-zero branches were unreachable twice
# over. "A test that relaxes production's shell options is not a test of
# production", and a fixture that cannot reach the branch proves nothing about
# it. Every driver below therefore keeps errexit ON, and the fixtures drive the
# answers that are non-zero.
#
# Swept for the shape afterwards: four sites in code that runs under
# `set -euo pipefail`, all fixed and all driven here. The three in
# `operator/*.sh` are NOT instances -- those scripts run `set -u` only, which
# was checked rather than assumed.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
BACKUP_CLI="$REPO_ROOT/bin/domum-media-backup"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# What the drivers LOAD. A mutation repoints these at a mutated COPY, so the
# tracked CLIs are never written: an interrupted run leaves no neutralised
# guard behind, and a concurrent run cannot read a half-mutated file.
MUTCLI="$CLI"
MUT_BACKUP="$BACKUP_CLI"
PRISTINE="$TMP/cli.pristine";          cp "$CLI" "$PRISTINE"
PRISTINE_B="$TMP/backup.pristine";     cp "$BACKUP_CLI" "$PRISTINE_B"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; exit 0; }

# ---------------------------------------------------------------------------
#  A fake smartctl. The three cases are the three answers
#  `mreport_smart_interpretable` can give, and two of them are non-zero.
# ---------------------------------------------------------------------------
cat > "$TMP/smartctl" <<'FAKE'
#!/usr/bin/env bash
case "${SMART_CASE:-}" in
  interpretable)
    printf '{"ata_smart_attributes":{"table":[{"name":"Wear_Leveling_Count","value":99},{"name":"Other","value":100},{"name":"Third","value":55}]}}' ;;
  placeholders)
    # Every attribute identical -- /dev/sdb on the production host. n == 1.
    printf '{"ata_smart_attributes":{"table":[{"name":"A","value":100},{"name":"B","value":100},{"name":"C","value":100}]}}' ;;
  unreadable)
    # smartctl exits non-zero and emits nothing readable: needs root.
    exit 2 ;;
esac
FAKE
chmod +x "$TMP/smartctl"

# ---------------------------------------------------------------------------
#  A. checkup_disk_wear -- the site that blanked production.
# ---------------------------------------------------------------------------
cat > "$TMP/drive-wear.sh" <<'DRIVER'
# Deliberately NO `set +e`. Sourcing the CLI turns on its own
# `set -euo pipefail`, which is the condition under test.
# shellcheck disable=SC1090
source "$CLI_PATH"
smartctl_bin() { printf '%s' "$FAKE_SMARTCTL"; }
CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=(); CHECKUP_ACTIONS=(); CHECKUP_ADVICE=()
checkup_disk_wear sdb
# If the call above exits the shell, this line never runs -- which is exactly
# what the operator saw: no output at all.
echo "SURVIVED"
printf 'ADVICE %s\n' "${CHECKUP_ADVICE[@]:-}"
printf 'CRITICAL %s\n' "${CHECKUP_CRITICAL[@]:-}"
DRIVER

wear() {  # $1 = SMART_CASE -> prints the driver's output, then RC=<status>
  local out rc
  out="$( SMART_CASE="$1" CLI_PATH="$MUTCLI" FAKE_SMARTCTL="$TMP/smartctl" \
          bash "$TMP/drive-wear.sh" 2>&1 )"; rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

sect "A1 positive control: an INTERPRETABLE drive survives and reports wear"
# Without this every assertion below is satisfied by a function that always
# dies, or by one that never reports anything.
out="$(wear interpretable)"
grep -q '^SURVIVED$' <<< "$out" || fail "an interpretable drive did not survive: $out"
grep -q '^RC=0$'     <<< "$out" || fail "an interpretable drive exited non-zero: $out"

sect "A2 PLACEHOLDERS (status 1) must not kill the shell"
out="$(wear placeholders)"
grep -q '^SURVIVED$' <<< "$out" \
  || fail "a drive whose attributes read alike KILLED the shell -- this is the
production defect: checkup, health-notify and report weekly all print nothing.
Output was: $out"
grep -q '^RC=0$' <<< "$out" || fail "placeholders exited non-zero: $out"
grep -q 'NOT INTERPRETABLE' <<< "$out" || fail "no placeholder advice was recorded: $out"

sect "A3 UNREADABLE table (status 2) must not kill the shell either"
out="$(wear unreadable)"
grep -q '^SURVIVED$' <<< "$out" || fail "an unreadable SMART table killed the shell: $out"
grep -q '^RC=0$'     <<< "$out" || fail "an unreadable table exited non-zero: $out"
grep -q 'could not be READ' <<< "$out" || fail "no unreadable advice was recorded: $out"
# The two causes must stay distinct -- "I could not check it" is not "it reads
# alike", and borrowing the other's wording names the wrong cause.
grep -q 'NOT INTERPRETABLE' <<< "$out" \
  && fail "an unreadable table borrowed the placeholder wording: $out"

# ---------------------------------------------------------------------------
#  B. The REPORT. Same shape, second site: the whole report truncates.
# ---------------------------------------------------------------------------
cat > "$TMP/c.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
DOMUM_LOG_DIR=$TMP/log
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS=cloud
DOMUM_EMAIL=ops@example.invalid
CFG
mkdir -p "$TMP/data" "$TMP/state" "$TMP/log" "$TMP/secrets" "$TMP/media" "$TMP/snapshots"

cat > "$TMP/drive-report.sh" <<'DRIVER'
# Again NO `set +e`: the report is rendered under production's options.
export CFG_FILE DOMUM_STATE_ROOT DOMUM_DATA_ROOT
# shellcheck disable=SC1090
source "$CLI_PATH"
need_root() { :; }
ensure_dirs() { :; }
export_env_for_compose() { :; }
mreport_append_history() { :; }
checkup_collect_all() { checkup_add healthy "all good."; }
backup_last_success_epoch() { printf '%s' "$(( $(date +%s) - 3600 ))"; }
btrfs_unique_roots() { printf '/srv/data\tFS-A\n'; }
btrfs() { return 1; }
journalctl() { return 1; }
service_lifecycle_specs() { printf 'plex|ENABLE_PLEX|a|b|c|d|e\n'; }
service_health_state() { printf 'nohc\n'; }
ENABLE_PLEX=1
lsblk() { printf 'sdb disk\n'; }
smartctl_bin() { printf '%s' "$FAKE_SMARTCTL"; }
smartctl() { SMART_CASE="$SMART_CASE" "$FAKE_SMARTCTL" "$@"; }
mreport_weekly_cmd --stdout
echo "REPORT-COMPLETED"
DRIVER

report() {  # $1 = SMART_CASE
  local out rc
  out="$( SMART_CASE="$1" CLI_PATH="$MUTCLI" FAKE_SMARTCTL="$TMP/smartctl" \
          CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$TMP/state" DOMUM_DATA_ROOT="$TMP/data" \
          bash "$TMP/drive-report.sh" 2>&1 )"; rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

sect "B1 positive control: the report completes for an interpretable drive"
out="$(report interpretable)"
grep -q '^REPORT-COMPLETED$' <<< "$out" || fail "the report did not complete: $(tail -5 <<< "$out")"
grep -q 'INFRASTRUCTURE MONITOR' <<< "$out" || fail "the report printed no header: $out"

sect "B2 a PLACEHOLDER drive must not truncate the report"
out="$(report placeholders)"
grep -q '^REPORT-COMPLETED$' <<< "$out" \
  || fail "a placeholder drive truncated the whole report: $(tail -5 <<< "$out")"
grep -q 'INFRASTRUCTURE MONITOR' <<< "$out" || fail "the report printed no header: $out"
grep -q 'NOT INTERPRETABLE' <<< "$out" || fail "the wear line did not state the cause: $out"

sect "B3 an UNREADABLE table must not truncate the report, and names its own cause"
out="$(report unreadable)"
grep -q '^REPORT-COMPLETED$' <<< "$out" \
  || fail "an unreadable SMART table truncated the report: $(tail -5 <<< "$out")"
grep -q 'could not be read' <<< "$out" || fail "the wear line did not say it could not be read: $out"

# ---------------------------------------------------------------------------
#  C. backup-scope. Here the answer that was lost is the FINDING: the verdict
#     disappeared exactly when a path is NOT protected off-site.
# ---------------------------------------------------------------------------
cat > "$TMP/b.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
DOMUM_LOG_DIR=$TMP/log
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS="cloud"
BACKUP_TARGET_CLOUD_ENABLED=1
BACKUP_TARGET_CLOUD_REPOSITORY="sftp:example.invalid:/probe"
BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$TMP/data/immich/library"
CFG

cat > "$TMP/drive-scope.sh" <<'DRIVER'
# shellcheck disable=SC1090
source "$BACKUP_PATH"
load_cfg
# A BARE call: errexit is in force. Invoking this as part of a `&&`/`||` list
# would suppress errexit INSIDE the function and hide the very defect.
do_backup_scope "$QPATH"
echo "SCOPE-COMPLETED"
DRIVER

scope() {  # $1 = path to ask about
  local out rc
  out="$( QPATH="$1" BACKUP_PATH="$MUT_BACKUP" CFG_FILE="$TMP/b.conf" \
          bash "$TMP/drive-scope.sh" 2>&1 )"; rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}

sect "C1 positive control: an IN-SCOPE path prints its verdict and exits 0"
out="$(scope "$TMP/data/immich/library")"
grep -q 'IN SCOPE' <<< "$out" || fail "an in-scope path did not report in scope: $out"
grep -q '^RC=0$'   <<< "$out" || fail "an in-scope path did not exit 0: $out"

sect "C2 an OUT-OF-SCOPE path must still PRINT its verdict"
# The defect lost the report precisely when there was something to report --
# the same shape as the coverage check that lost its own INCOMPLETE verdict.
# The exit status is the contract and stays 1; what must not vanish is the text.
out="$(scope "$TMP/data/backups/images")"
grep -q 'NOT IN SCOPE' <<< "$out" \
  || fail "an out-of-scope path printed NO verdict -- the finding was lost
exactly when there was a finding: $out"
grep -q '^RC=1$' <<< "$out" || fail "the exit-status contract changed: $out"

# ---------------------------------------------------------------------------
#  D. Mutations. Each restores the bare-call form and must bring the silence
#     back. A mutant that still behaves correctly proves nothing.
# ---------------------------------------------------------------------------
mutate() {  # $1 = src, $2 = old, $3 = new -> prints the mutant path
  local mut="$TMP/mut-$RANDOM-$$"
  MUT_OLD="$2" MUT_NEW="$3" MUT_SRC="$1" MUT_DST="$mut" python3 -I -c '
import io, os
s = io.open(os.environ["MUT_SRC"], encoding="utf-8").read()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
n = s.count(old)
assert n == 1, "mutation target matched %d times, refusing: %r" % (n, old[:70])
io.open(os.environ["MUT_DST"], "w", encoding="utf-8").write(s.replace(old, new, 1))
' || return 1
  printf '%s' "$mut"
}

sect "D1 mutation: the bare call in checkup_disk_wear blanks the check again"
# Anchored on the PRECEDING NEWLINE. `str.count` counts substrings, so a
# 2-space anchor also matches inside the 8-space copy in the renderer and the
# edit is refused as ambiguous -- which is what the `matched %d times`
# assertion is for. A leading newline makes the indentation exact.
MUT="$(mutate "$CLI" \
  $'\n  interp=0; mreport_smart_interpretable "$dev" || interp=$?' \
  $'\n  mreport_smart_interpretable "$dev"; interp=$?')" \
  || fail "the checkup_disk_wear mutation could not be applied"
grep -q 'mreport_smart_interpretable "$dev"; interp=$?' "$MUT" \
  || fail "the mutation did not apply; it proves nothing"
MUTCLI="$MUT"
out="$(wear placeholders)"
grep -q '^SURVIVED$' <<< "$out" \
  && fail "the mutant still survived -- the fix is not what makes A2 pass"
grep -q '^RC=1$' <<< "$out" || fail "the mutant did not exit with the function's status: $out"
MUTCLI="$CLI"

sect "D2 mutation: the bare call in the renderer truncates the report again"
MUT="$(mutate "$CLI" \
  $'\n        interp=0; mreport_smart_interpretable "$dev" || interp=$?' \
  $'\n        mreport_smart_interpretable "$dev"; interp=$?')" \
  || fail "the renderer mutation could not be applied"
MUTCLI="$MUT"
out="$(report placeholders)"
grep -q '^REPORT-COMPLETED$' <<< "$out" \
  && fail "the renderer mutant still completed -- D2 proves nothing"
# The observable is that the report is LOST, not the exit status: a truncated
# report and a clean one are told apart by the header being absent.
grep -q 'DRIVE HEALTH' <<< "$out" \
  && fail "the renderer mutant printed the drive section it should have died in"
MUTCLI="$CLI"

sect "D3 mutation: the bare call in backup-scope loses the verdict again"
MUT="$(mutate "$BACKUP_CLI" \
  $'\n    rc=0; dr_path_configured "$path" "$target" || rc=$?' \
  $'\n    dr_path_configured "$path" "$target"; rc=$?')" \
  || fail "the backup-scope mutation could not be applied"
MUT_BACKUP="$MUT"
out="$(scope "$TMP/data/backups/images")"
grep -q 'NOT IN SCOPE' <<< "$out" \
  && fail "the mutant still printed a verdict -- C2 proves nothing"
MUT_BACKUP="$BACKUP_CLI"

# ---------------------------------------------------------------------------
#  E. The shape itself, so a NEW site cannot be added silently. Comments are
#     stripped first: this file's own explanation quotes the broken form, and
#     a comment quoting a defect is how a fix documents itself.
# ---------------------------------------------------------------------------
sect "E no production file that runs under set -e carries the shape"
found=0; scanned=0
for f in "$CLI" "$BACKUP_CLI" "$REPO_ROOT/bin/domum-media-report" "$REPO_ROOT/install.sh"; do
  [[ -f "$f" ]] || continue
  grep -qE '^set -[a-z]*e' "$f" || continue   # only files that enable errexit
  scanned=$((scanned + 1))
  hits="$(sed 's/#.*//' "$f" | grep -nE ';[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*=[$][?][[:space:]]*$' || true)"
  if [[ -n "$hits" ]]; then
    found=$((found + 1))
    echo "   !! $f" >&2
    sed -n '1,10p' <<< "$hits" >&2
  fi
done
(( scanned >= 2 )) || fail "the scan found fewer than 2 errexit files; the target list is stale"
(( found == 0 )) || fail "a bare call whose status is captured on the next statement
exits the shell under set -e. Write: rc=0; f ... || rc=\$?"
echo "  $scanned file(s) scanned, 0 instances"

sect "E2 the scan can actually find the shape (negative control)"
# A clean verdict above means nothing unless the scan has been shown finding it.
probe="$TMP/probe.sh"
printf 'set -euo pipefail\nf "$x"; rc=$?\n' > "$probe"
hits="$(sed 's/#.*//' "$probe" | grep -nE ';[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*=[$][?][[:space:]]*$' || true)"
[[ -n "$hits" ]] || fail "the scan cannot find the shape it exists to catch"
echo "  the scan rejects a planted instance"

sect "F the tracked CLIs were never written"
cmp -s "$CLI" "$PRISTINE"          || fail "bin/domum-media was mutated in place"
cmp -s "$BACKUP_CLI" "$PRISTINE_B" || fail "bin/domum-media-backup was mutated in place"
echo "  both pristine"

echo "PASS: errexit-bare-call-smoke"
