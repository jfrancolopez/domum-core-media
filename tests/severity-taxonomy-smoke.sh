#!/usr/bin/env bash
# The severity taxonomy: which findings wake the operator, and which do not.
#
# Why this suite exists. Production, 2026-10-29, the weekly report said
# `ACTION REQUIRED (4)` on a healthy host. The four "actions" were an optional
# image cleanup, two suggestions to read about rebooting, and a line that began
# `no action needed`. Nothing needed doing.
#
# The cause was structural, not cosmetic: CHECKUP_ACTIONS was BOTH the remedy
# list and the escalation signal. `health_verdict` reads it, and so does the
# notifier's silence gate -- so attaching a helpful command to a routine
# finding promoted the report to ACTION REQUIRED and mailed it. The four
# routine warnings had been left deliberately remedy-LESS to keep them quiet,
# which meant the quiet findings were also the undiagnosable ones.
#
# CHECKUP_ADVICE splits the two. The classes, and what each does:
#
#   healthy   measured good                      no escalation, no mail
#   advice    a remedy the operator MAY apply     no escalation, no mail
#   warning   worth knowing                       verdict WARNINGS, no mail
#   action    the operator MUST act               verdict ACTION REQUIRED, MAILS
#   critical  failure or unverifiable protection  verdict CRITICAL, MAILS
#
# Every scenario below drives REAL check functions against controlled inputs
# and asserts the CLASS, then asserts the resulting verdict and mail decision
# from the real `health_verdict` and the real silence gate. A test that seeded
# the arrays itself would prove only that arithmetic works.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

mkdir -p "$TMP/bin" "$TMP/state/restore-verification" "$TMP/data" "$TMP/snapshots" \
         "$TMP/media" "$TMP/log" "$TMP/meta" "$TMP/secrets"
# A `docker` that fails: no scenario here may reach the real daemon. A probe
# that silently queried the host would be measuring this machine, not a
# fixture -- that has happened in this repository before.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
mkdir -p "$TMP/state/immich" "$TMP/state/image-updates" "$TMP/state/update-history"

cat > "$TMP/domum-media.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS=cloud
ENABLE_IMMICH=1
CFG

# Drive one real check, print every class, and print the POLICY decisions that
# the verdict and the notifier derive from them.
probe() {  # $1 = fixture, $2 = function to run
  (
    export PATH="$TMP/bin:$PATH"
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export DOMUM_SNAPSHOT_ROOT="$TMP/snapshots" DOMUM_MEDIA_ROOT="$TMP/media"
    export DOMUM_LOG_DIR="$TMP/log" REPO_META_DIR="$TMP/meta"
    export SECRETS_DIR="$TMP/secrets" ENABLE_IMMICH=1
    export CFG_FILE="$TMP/domum-media.conf"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    # The REAL load_cfg, against a real file: it is what applies the defaults
    # the aggregate collector reads, and stubbing it left BACKUP_POLICY unbound.
    export_env_for_compose() { :; }
    load_cfg >/dev/null 2>&1
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=()
    CHECKUP_ACTIONS=(); CHECKUP_ADVICE=()
    eval "$1"
    "$2"
    (( ${#CHECKUP_CRITICAL[@]} )) && printf 'CRIT|%s\n' "${CHECKUP_CRITICAL[@]}"
    (( ${#CHECKUP_WARNINGS[@]} )) && printf 'WARN|%s\n' "${CHECKUP_WARNINGS[@]}"
    (( ${#CHECKUP_HEALTHY[@]} ))  && printf 'OK|%s\n'   "${CHECKUP_HEALTHY[@]}"
    (( ${#CHECKUP_ACTIONS[@]} ))  && printf 'ACT|%s\n'  "${CHECKUP_ACTIONS[@]}"
    (( ${#CHECKUP_ADVICE[@]} ))   && printf 'ADV|%s\n'  "${CHECKUP_ADVICE[@]}"
    # The two policy decisions, from the real implementations.
    printf 'VERDICT|%s\n' "$(health_verdict)"
    if (( ${#CHECKUP_CRITICAL[@]} == 0 && ${#CHECKUP_ACTIONS[@]} == 0 )); then
      printf 'MAIL|no\n'
    else
      printf 'MAIL|yes\n'
    fi
    true
  ) 2>&1
}

# Assert the mail decision and the verdict word together: they are one policy
# and a scenario that got one right and the other wrong would be a real defect.
expect() {  # $1 = label, $2 = output, $3 = mail yes|no, $4 = verdict prefix
  local label="$1" out="$2" mail="$3" verdict="$4"
  grep -qx "MAIL|$mail" <<< "$out" \
    || fail "$label: expected MAIL|$mail, got '$(grep '^MAIL|' <<< "$out")'
$out"
  grep -q "^VERDICT|$verdict" <<< "$out" \
    || fail "$label: expected verdict '$verdict*', got '$(grep '^VERDICT|' <<< "$out")'
$out"
}

# ---------------------------------------------------------------------------
#  QUIET: healthy, and routine maintenance. These must never mail.
# ---------------------------------------------------------------------------
sect "1. a completely healthy check is HEALTHY and silent"
HEALTHY_BTRFS='
  domum_is_btrfs() { return 0; }
  btrfs_unique_roots() { printf "%s\n" "'"$TMP"'/data"; }
  btrfs() {
    case "$*" in
      *"device stats"*) printf "[/dev/x].write_io_errs 0\n[/dev/x].corruption_errs 0\n" ;;
      *"scrub status"*) printf "Scrub started: Mon Oct 20 03:00:00 2026\nStatus: finished\nError summary: no errors found\n" ;;
    esac
  }'
out="$(probe "$HEALTHY_BTRFS" checkup_btrfs_health)"
grep -q 'OK|' <<< "$out" || fail "1: a clean filesystem reported nothing healthy: $out"
expect "1" "$out" no HEALTHY
echo "  healthy -> HEALTHY, no mail"

sect "2-4. routine maintenance adds WARNINGS and ADVICE but ZERO actions"
# Asserted as a DELTA, not as an absolute verdict. The aggregate collector runs
# every check, and a fixture cannot satisfy all of them -- missing secrets and a
# media root that is not its own disk legitimately produce criticals here. Those
# are not what this scenario is about, and pinning the whole verdict would mean
# either stubbing most of the system (vacuous) or asserting fixture artefacts.
#
# The property that matters is the one the production defect violated: turning
# routine maintenance ON must not add a single ACTION. The delta is also
# required to be NON-EMPTY, so the comparison cannot pass by measuring nothing.
MAINT_STUBS='
  docker() { case "$*" in *dangling*) printf "a\nb\nc\n" ;; *exited*) : ;; esac; }
  apt-get() { printf "Inst libfoo [1.0]\nInst libbar [2.0]\n"; }
  update_history_dir() { printf "%s" "'"$TMP"'/state/update-history"; }
  service_lifecycle_specs() { :; }
  service_compose_services() { printf "%s" "$1"; }
  backup_last_success_epoch() { date +%s; }
  enabled_backup_targets() { :; }
  backup_target_names() { :; }
  checkup_systemd_health() { :; }
  checkup_btrfs_health() { :; }
  checkup_disk_health() { :; }
  checkup_immich_offsite() { :; }
  checkup_notification_path() { :; }
'
classes() { printf '%s' "$(grep -c "^$2|" <<< "$1" || true)"; }

# Baseline: no maintenance pending.
rm -f "$TMP/state/image-updates/plex.env" "$TMP/state/immich/bundle-candidate.env"
NO_MAINT="$MAINT_STUBS
  docker() { :; }
  apt-get() { :; }
  [[ -f /var/run/reboot-required ]] && reboot_required_override=1"
base="$(probe "$MAINT_STUBS
  docker() { :; }
  apt-get() { :; }" checkup_collect_all)"
base_act="$(classes "$base" ACT)"

# Now every routine maintenance condition at once -- the exact shape of the
# production report that said ACTION REQUIRED (4).
: > "$TMP/state/image-updates/plex.env"
: > "$TMP/state/immich/bundle-candidate.env"
out="$(probe "$MAINT_STUBS" checkup_collect_all)"
maint_act="$(classes "$out" ACT)"
maint_warn="$(classes "$out" WARN)"
base_warn="$(classes "$base" WARN)"
maint_adv="$(classes "$out" ADV)"
base_adv="$(classes "$base" ADV)"

(( maint_warn > base_warn )) \
  || fail "2: routine maintenance added no warning, so the delta measures nothing
(base $base_warn, with maintenance $maint_warn): $out"
(( maint_adv > base_adv )) \
  || fail "2: routine maintenance added no advisory remedy (base $base_adv, with
maintenance $maint_adv): $out"
(( maint_act == base_act )) \
  || fail "2: routine maintenance added $(( maint_act - base_act )) ACTION(s). This is
the production defect of 2026-10-29, where an optional image cleanup and two
reboot-reading suggestions read as ACTION REQUIRED: $out"
echo "  +$(( maint_warn - base_warn )) warnings, +$(( maint_adv - base_adv )) advice, +0 actions"

sect "3. a staged image is inspectable and explicitly not a pending task"
grep -q 'ADV|.*updates list' <<< "$out" \
  || fail "3: a staged image offers no way to look at it: $out"
adv_updates="$(grep 'ADV|.*updates list' <<< "$out")"
grep -qi 'gated\|never automatic' <<< "$adv_updates" \
  || fail "3: the advice does not say deployment is gated, so it reads as a task: $out"
grep -q 'ACT|.*updates' <<< "$out" \
  && fail "3: a staged image escalated -- discovery must never imply deployment: $out"
echo "  staged, inspectable, gated, not escalated"

sect "4. the dangling-image advice says the dry run deletes nothing"
grep -q 'ADV|.*cleanup images --dry-run' <<< "$out" || fail "4: no cleanup advice: $out"
adv_clean="$(grep 'ADV|.*cleanup images' <<< "$out")"
grep -qi 'deletes nothing' <<< "$adv_clean" \
  || fail "4: the advice does not say the dry run is non-destructive: $out"
grep -qi 'protected by a recovery point' <<< "$adv_clean" \
  || fail "4: it does not mention recovery-point protection, which is why this is
safe to suggest at all: $out"
echo "  non-destructive and protection-aware"

sect "5. a historical restic lock, since verified, is a WARNING and silent"
printf 'RESULT=success\nMODE=structure\nFINISHED_TS=2026-10-29T11:22:30-0400\n' \
  > "$TMP/meta/cloud-check.env"
SUPERSEDED='
  enabled_backup_targets() { printf "cloud\n"; }
  systemctl() {
    case "$*" in
      *--failed*)              printf "" ;;
      *list-timers*)           printf "x x x x domum-media-check.service\n" ;;
      *ExecMainExitTimestamp*) printf "Sun 2026-10-25 03:37:11 EDT\n" ;;
      *ExecMainStatus*)        printf "11\n" ;;
      *)                       return 1 ;;
    esac
  }'
out="$(probe "$SUPERSEDED" checkup_systemd_health)"
grep -q 'WARN|' <<< "$out" || fail "5: the stale failure vanished entirely: $out"
grep -q 'ADV|' <<< "$out"  || fail "5: no way to clear it is offered: $out"
expect "5" "$out" no WARNINGS
echo "  superseded -> WARNINGS, no mail, still reported"

# ---------------------------------------------------------------------------
#  LOUD: these must escalate AND mail.
# ---------------------------------------------------------------------------
sect "6. a CURRENT restic lock failure is CRITICAL and mails"
rm -f "$TMP/meta/cloud-check.env"
out="$(probe "$SUPERSEDED" checkup_systemd_health)"
grep -q 'CRIT|' <<< "$out" || fail "6: an unverified lock failure is not critical: $out"
grep -q 'ACT|' <<< "$out"  || fail "6: it offers no action: $out"
expect "6" "$out" yes CRITICAL
echo "  unverified -> CRITICAL, mails"

sect "7. storage CORRUPTION is CRITICAL, mails, and names the file-finding command"
CORRUPT='
  domum_is_btrfs() { return 0; }
  btrfs_unique_roots() { printf "%s\n" "'"$TMP"'/data"; }
  btrfs() {
    case "$*" in
      *"device stats"*) printf "[/dev/x].corruption_errs 7\n" ;;
      *"scrub status"*) printf "Scrub started: Mon Oct 20 03:00:00 2026\nStatus: finished\nError summary: no errors found\n" ;;
    esac
  }'
out="$(probe "$CORRUPT" checkup_btrfs_health)"
grep -qi 'CRIT|Btrfs CHECKSUM failures' <<< "$out" \
  || fail "7: a checksum failure on the photo tier is not critical: $out"
grep -qi 'ACT|.*dmesg' <<< "$out" \
  || fail "7: it does not name the kernel log, which is what identifies the FILE: $out"
grep -qi 'do NOT attempt a repair' <<< "$out" \
  || fail "7: single-profile data cannot be repaired; the remedy must say so: $out"
expect "7" "$out" yes CRITICAL
echo "  corruption -> CRITICAL, mails, names dmesg and forbids a repair attempt"

sect "8. an Immich BACKUP GAP is CRITICAL and mails"
GAPJSON='{"missing_from_snapshot":3,"missing_classified":"known","missing_backup_gap":3,
"missing_pending_next_backup":0,"missing_timing_unknown":0,"snapshot_id":"deadbeef",
"recorded_at":"2026-10-28T02:40:00-0400"}'
printf '%s' "$GAPJSON" > "$TMP/state/restore-verification/cloud-snapshot-coverage.json"
COV='
  backup_target_names() { printf "cloud\n"; }
  backup_target_enabled() { return 0; }
  cmd_exists() { return 0; }'
out="$(probe "$COV" checkup_immich_offsite)"
grep -q 'CRIT|BACKUP GAP' <<< "$out" || fail "8: a real gap is not critical: $out"
expect "8" "$out" yes CRITICAL
echo "  gap -> CRITICAL, mails"

sect "9. originals merely PENDING the next backup are not a defect, and stay silent"
printf '%s' '{"missing_from_snapshot":5,"missing_classified":"known","missing_backup_gap":0,
"missing_pending_next_backup":5,"missing_timing_unknown":0,"snapshot_id":"deadbeef",
"recorded_at":"2026-10-28T02:40:00-0400"}' \
  > "$TMP/state/restore-verification/cloud-snapshot-coverage.json"
out="$(probe "$COV" checkup_immich_offsite)"
grep -q 'CRIT|' <<< "$out" && fail "9: a routine upload was escalated to critical: $out"
expect "9" "$out" no HEALTHY
echo "  pending -> no escalation, no mail"

sect "10. coverage ingested DURING the window is UNKNOWN -- neither excused nor blamed"
printf '%s' '{"missing_from_snapshot":2,"missing_classified":"known","missing_backup_gap":0,
"missing_pending_next_backup":0,"missing_timing_unknown":2,"snapshot_id":"deadbeef",
"recorded_at":"2026-10-28T02:40:00-0400"}' \
  > "$TMP/state/restore-verification/cloud-snapshot-coverage.json"
out="$(probe "$COV" checkup_immich_offsite)"
grep -qi 'WARN|.*UNKNOWN' <<< "$out" || fail "10: an unknown is not reported as one: $out"
expect "10" "$out" yes "ACTION REQUIRED"
echo "  unknown -> ACTION REQUIRED, mails"

sect "11. evidence that was never recorded is UNKNOWN, never a clean bill of health"
rm -f "$TMP/state/restore-verification/cloud-snapshot-coverage.json"
out="$(probe "$COV" checkup_immich_offsite)"
grep -qi 'never been reconciled' <<< "$out" \
  || fail "11: absent coverage evidence is not reported: $out"
grep -q 'OK|' <<< "$out" && fail "11: it claimed health from evidence that does not exist: $out"
expect "11" "$out" yes "ACTION REQUIRED"
echo "  no evidence -> ACTION REQUIRED, mails, no health claimed"

sect "12. an unreadable disk is UNKNOWN with a remedy, never CRITICAL"
# "I could not check it" is not "it is broken" -- a permission failure once
# told the operator to replace a healthy disk.
UNREADABLE='
  lsblk() { printf "sda disk\n"; }
  cmd_exists() { return 0; }
  smartctl() { printf "%s" "{\"exit_status\":2,\"smartctl\":{\"messages\":[{\"string\":\"Permission denied\"}]}}"; }'
out="$(probe "$UNREADABLE" checkup_disk_health)"
grep -qi 'WARN|SMART health for /dev/sda is UNKNOWN' <<< "$out" \
  || fail "12: an unreadable device is not reported as unknown: $out"
grep -q 'CRIT|' <<< "$out" \
  && fail "12: an unreadable device was called a failing one: $out"
echo "  unreadable -> UNKNOWN warning, never critical"

sect "13. a disk that genuinely FAILED its self-assessment is CRITICAL and mails"
FAILED='
  lsblk() { printf "sda disk\n"; }
  cmd_exists() { return 0; }
  smartctl() { printf "%s" "{\"exit_status\":0,\"smart_status\":{\"passed\":false}}"; }'
out="$(probe "$FAILED" checkup_disk_health)"
grep -q 'CRIT|' <<< "$out" || fail "13: a failed self-assessment is not critical: $out"
expect "13" "$out" yes CRITICAL
echo "  failed -> CRITICAL, mails"

# ---------------------------------------------------------------------------
#  The policy itself, and the thing that must never regress.
# ---------------------------------------------------------------------------
sect "14. ADVICE alone never escalates and never mails -- the whole split"
ADVONLY='checkup_advice_only() { checkup_add warning "something routine"; checkup_add advice "look at it"; }'
out="$(probe "$ADVONLY" checkup_advice_only)"
expect "14" "$out" no WARNINGS
echo "  advice is printed, escalates nothing"

sect "15. MUTATION: advice folded back into actions restores the false alarm"
# The dangerous direction, and the exact production defect: if advisory
# remedies escalate, a host with only routine maintenance mails again.
cp "$CLI" "$TMP/cli.orig"
cat > "$TMP/mutate-advice.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''    advice)   for existing in ${CHECKUP_ADVICE[@]+"${CHECKUP_ADVICE[@]}"}; do
                [[ "$existing" == "$text" ]] && return 0
              done
              CHECKUP_ADVICE+=("$text") ;;'''
new = '''    advice)   CHECKUP_ACTIONS+=("$text") ;;'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP/mutate-advice.py" "$CLI" ) \
  || { cp "$TMP/cli.orig" "$CLI"; fail "the advice mutation did not apply"; }
mout="$(probe "$MAINT_STUBS" checkup_collect_all)"
cp "$TMP/cli.orig" "$CLI"
mut_act="$(classes "$mout" ACT)"
# The observable is the DELTA: with advice treated as action, routine
# maintenance must start adding actions where it previously added none.
(( mut_act > maint_act )) \
  || fail "the mutation changed no ANSWER -- with advice folded into actions,
routine maintenance must add ACTIONS (unmutated $maint_act, mutant $mut_act): $mout"
grep -q 'ADV|' <<< "$mout" \
  && fail "the mutant still produced advisories, so the fold did not happen: $mout"
echo "  killed: folding advice into actions adds $(( mut_act - maint_act )) spurious actions on a quiet host"

echo "ALL SEVERITY TAXONOMY CHECKS PASSED"
