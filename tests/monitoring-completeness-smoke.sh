#!/usr/bin/env bash
# checkup, health-notify and report weekly must evaluate the SAME complete set
# of checks.
#
# WHY IT EXISTS. health_notify_cmd called only the four EXTRACTED checks
# (systemd, btrfs, disk, immich) while every other check is INLINE in
# checkup_cmd's 310 lines. So a container going UNHEALTHY, a service down, or
# /srv/data filling up could appear in `checkup` and NEVER be mailed -- and the
# remedies written for exactly those cases were unreachable from the notifier.
#
# This suite drives all three commands against ONE fixture that produces five
# genuine problems and requires all three to see all five. The collection is
# NOT stubbed: that is the whole point.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP"/{state/restore-verification,state/report,state/updates,state/backups,data,snapshots,media,secrets,log,bin}
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

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
ENABLE_PLEX=1
ENABLE_UPTIME_KUMA=1
CFG

# Externals on PATH, so nothing can reach the host even if a probe escapes the
# function stubs. Each exits non-zero by default: reaching production FAILS
# rather than quietly succeeding.
for x in docker systemctl smartctl restic age curl; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/$x"; chmod +x "$TMP/bin/$x"
done

# THE FIVE PROBLEMS. Produced by the REAL collection, from stubbed externals.
#   1. a container reporting UNHEALTHY
#   2. a service that is not running
#   3. a filesystem over capacity
#   4. a backup that has not succeeded in days
#   5. a Btrfs checksum (corruption) error -- the photo-tier signal
FIXTURE='
  # 1 + 2: one unhealthy, one stopped.
  service_lifecycle_specs() {
    printf "plex|ENABLE_PLEX|a|b|c|d|e\n"
    printf "uptime-kuma|ENABLE_UPTIME_KUMA|a|b|c|d|e\n"
  }
  service_health_state() {
    case "$1" in
      plex)        printf "unhealthy\n" ;;
      uptime-kuma) printf "stopped\n" ;;
      *)           printf "nohc\n" ;;
    esac
  }
  # 3: 96% full.
  df() { printf "Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 100 96 4 96%% /\n"; }
  # 4: last success four days ago.
  backup_last_success_epoch() { printf "%s" "$(( $(date +%s) - 4*86400 ))"; }
  # 5: a non-zero corruption counter.
  btrfs_unique_roots() { printf "%s\tFS-A\n" "$DOMUM_DATA_ROOT"; }
  btrfs() {
    case "$1 $2" in
      "device stats") printf "[/dev/sda1].corruption_errs 3\n[/dev/sda1].write_io_errs 0\n" ;;
      "scrub status") printf "Scrub started:    Wed Oct 21 10:24:23 2026\nError summary:    no errors found\nTotal to scrub:   215.87GiB\n" ;;
      "filesystem df") printf "Data, single: total=218.01GiB\nMetadata, DUP: total=1.00GiB\n" ;;
    esac
  }
  lsblk() { printf "sda disk\n"; }
  smartctl() { printf "%s" "{\"smart_status\":{\"passed\":true},\"model_name\":\"T\"}"; }
  journalctl() { return 1; }
  backup_target_names() { printf "cloud\n"; }
  backup_target_enabled() { :; }
  backup_target_value() { printf "\n"; }
  recovery_pack_state_file() { printf "%s" "$TMP/state/pack.env"; }
'

# Run ONE of the three commands against the fixture. load_cfg is real.
run_cmd() {  # $1 = cli, $2 = which: checkup|notify|report
  local cli="$1" which="$2"
  (
    export PATH="$TMP/bin:$PATH"
    export CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$TMP/state" DOMUM_DATA_ROOT="$TMP/data"
    export TMP
    export RECOVERY_PACK_EMAIL_ENABLED=1 DOMUM_EMAIL=ops@example.invalid
    # shellcheck disable=SC1090
    source "$cli" >/dev/null 2>&1
    set +e
    need_root() { :; }
    ensure_dirs() { :; }
    ensure_state_dirs() { :; }
    export_env_for_compose() { :; }
    mreport_append_history() { :; }
    smtp_send_message() { cp "$1" "$TMP/sent.eml"; return 0; }
    eval "$FIXTURE"
    case "$which" in
      checkup) checkup_cmd ;;
      notify)  health_notify_cmd --dry-run ;;
      report)  mreport_weekly_cmd --stdout ;;
    esac
  ) 2>&1
}

# The five observables, one regex each. Deliberately matched on the FINDING
# text, not on a function name: the question is whether the command SAW it.
declare -a PROBLEM_NAME=(
  "unhealthy container"
  "stopped service"
  "filesystem over capacity"
  "stale backup"
  "Btrfs checksum error"
)
declare -a PROBLEM_RE=(
  'plex is UNHEALTHY'
  'uptime-kuma is not running'
  '9[0-9]% full'
  '[Bb]ackup'
  'CHECKSUM failures'
)

# ---------------------------------------------------------------------------
sect "all three commands SEE all five problems"
for which in checkup notify report; do
  out="$(run_cmd "$CLI" "$which")"
  [[ -n "$out" ]] || fail "$which produced NO output at all"
  for i in 0 1 2 3 4; do
    grep -qE "${PROBLEM_RE[$i]}" <<< "$out" \
      || fail "$which did not see the ${PROBLEM_NAME[$i]}.
A command that cannot see a problem cannot report it.
--- output ---
$out"
  done
  echo "  $which: all five"
done

sect "the critical storage error is CRITICAL in all three, not a warning"
for which in checkup notify report; do
  out="$(run_cmd "$CLI" "$which")"
  grep -qE 'CHECKSUM failures' <<< "$out" || fail "$which lost the checksum finding"
done
out="$(run_cmd "$CLI" checkup)"
# checkup prints classes under headings; the finding must be under Critical.
crit_block="$(sed -n '/^Critical:/,/^$/p' <<< "$out")"
grep -q 'CHECKSUM' <<< "$crit_block" \
  || fail "a Btrfs checksum error is not classified CRITICAL by checkup:
$crit_block"
echo "  classified CRITICAL, not downgraded"

sect "health-notify would MAIL, and names the problems"
out="$(run_cmd "$CLI" notify)"
grep -q 'no mail sent' <<< "$out" \
  && fail "five problems and the notifier stayed SILENT: $out"
grep -qE 'CRITICAL' <<< "$out" || fail "the verdict is not critical: $out"
echo "  not silent, verdict critical"

sect "report weekly carries them in FINDINGS, with the sections intact"
out="$(run_cmd "$CLI" report)"
findings="$(sed -n '/── FINDINGS/,/── SUGGESTED/p' <<< "$out")"
grep -q 'CHECKSUM' <<< "$findings" || fail "the checksum error is not in FINDINGS: $findings"
grep -q 'UNHEALTHY' <<< "$findings" || fail "the unhealthy container is not in FINDINGS: $findings"
grep -qE 'Verdict: .* CRITICAL' <<< "$out" || fail "the report verdict is not critical"
echo "  findings present, verdict critical"

# ---------------------------------------------------------------------------
sect "mutation: reverting the notifier to the four-check subset LOSES them"
# The regression this suite exists for. With the subset, the INLINE checks never
# run, so the notifier cannot see the container, the capacity or the backup.
MUT="$TMP/mut-subset"
MUT_SRC="$CLI" MUT_DST="$MUT" python3 -I -c '
import io, os
s = io.open(os.environ["MUT_SRC"], encoding="utf-8").read()
old = """  # The SAME collection checkup runs. Calling only the four extracted checks
  # here meant a notification could never mention a stopped container or a
  # filling filesystem, because those checks are inline in the collection.
  checkup_collect_all"""
assert s.count(old) == 1, "mutation target matched %d" % s.count(old)
new = """  checkup_systemd_health
  checkup_btrfs_health
  checkup_disk_health
  checkup_immich_offsite"""
io.open(os.environ["MUT_DST"], "w", encoding="utf-8").write(s.replace(old, new, 1))
' || fail "the subset mutation could not be applied"
grep -qE '^  checkup_disk_health$' "$MUT" || fail "the mutation did not apply; it proves nothing"

mout="$(run_cmd "$MUT" notify)"
lost=0
for i in 0 1 2 3; do
  grep -qE "${PROBLEM_RE[$i]}" <<< "$mout" || lost=$(( lost + 1 ))
done
(( lost > 0 )) \
  || fail "the mutant still saw every problem, so checkup_collect_all is NOT what
makes the notifier complete. This suite would be proving nothing.
--- mutant output ---
$mout"
echo "  killed: the subset loses $lost of the first four problems"

sect "and the mutant's checkup still sees them -- the DIVERGENCE is the defect"
# This is what made the gap invisible: checkup looked complete while the
# notification was not. Both must come from one collection.
mck="$(run_cmd "$MUT" checkup)"
for i in 0 1 2; do
  grep -qE "${PROBLEM_RE[$i]}" <<< "$mck" \
    || fail "the mutant's checkup also lost ${PROBLEM_NAME[$i]}; the fixture is wrong"
done
echo "  mutant: checkup complete, notification incomplete -- exactly the defect"

sect "one collection, one definition, and every consumer uses it"
src="$(sed -e 's/#.*//' "$CLI")"
[[ "$(grep -cE '^checkup_collect_all\(\) \{' <<< "$src")" == "1" ]] \
  || fail "checkup_collect_all is defined more than once"
for fn in checkup_cmd health_notify_cmd mreport_weekly_cmd; do
  body="$(awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f, /^\}/' <<< "$src")"
  grep -q 'checkup_collect_all' <<< "$body" \
    || fail "$fn does not collect through checkup_collect_all"
done
echo "  checkup_cmd, health_notify_cmd and mreport_weekly_cmd all collect through it"

# ---------------------------------------------------------------------------
#  Regression fixtures taken from the FIRST REAL production report,
#  2026-10-27. Every one of these was observed, not imagined.
# ---------------------------------------------------------------------------

# `systemctl --failed --no-legend` still prints the leading bullet, so the
# parser's $1 was the bullet character.
BULLET_FIXTURE='
  systemctl() {
    case "$*" in
      *--failed*)       printf "\xe2\x97\x8f domum-media-check.service loaded failed failed domum-media: restic repository integrity check\n" ;;
      *list-timers*)    printf "x x x x domum-media-check.service\n" ;;
      *ExecMainStatus*) printf "11\n" ;;
      *)                return 1 ;;
    esac
  }
'
probe_systemd() {  # $1 = cli, $2 = fixture
  (
    export PATH="$TMP/bin:$PATH" CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$TMP/state"
    # shellcheck disable=SC1090
    source "$1" >/dev/null 2>&1
    set +e
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=(); CHECKUP_ACTIONS=()
    eval "$2"
    checkup_systemd_health
    (( ${#CHECKUP_CRITICAL[@]} )) && printf 'CRIT|%s\n' "${CHECKUP_CRITICAL[@]}"
    (( ${#CHECKUP_WARNINGS[@]} )) && printf 'WARN|%s\n' "${CHECKUP_WARNINGS[@]}"
    (( ${#CHECKUP_ACTIONS[@]} ))  && printf 'ACT|%s\n'  "${CHECKUP_ACTIONS[@]}"
    true
  ) 2>&1
}

sect "a failed unit is NAMED, and a domum unit is CRITICAL not a warning"
# Production said: "systemd unit ● has failed." Two defects at once -- the name
# was the bullet character, and because "●" does not match domum-media* the
# case fell through to the generic branch, DOWNGRADING a failed domum unit to a
# warning. The real failure surfaced only via a separate timer-status loop.
out="$(probe_systemd "$CLI" "$BULLET_FIXTURE")"
grep -q 'CRIT|systemd unit domum-media-check.service has FAILED' <<< "$out" \
  || fail "a failed domum unit is not named and critical: $out"
grep -qE 'WARN\|systemd unit .?.? has failed' <<< "$out" \
  && fail "the bullet is still being read as a unit name: $out"
grep -q '<unit>' <<< "$out" && fail "the remedy still ships an unresolved placeholder: $out"
grep -q 'ACT|systemctl status --no-pager -l domum-media-check.service' <<< "$out" \
  || fail "the remedy does not name the actual unit: $out"
echo "  named, CRITICAL, and the remedy names the unit"

sect "restic exit 11 is reported as a LOCK, not as a possibly-damaged repository"
# Production, 2026-10-25: exit 11 was a lock created on 2026-10-20 from the
# operator's Mac and still present 112h49m later. The check NEVER RAN. Reported
# as a bare "exited non-zero (status 11)" that reads like corruption -- the
# wrong alarm entirely, and it hides that the remedy is `restic unlock`.
out="$(probe_systemd "$CLI" "$BULLET_FIXTURE")"
grep -qi 'could not LOCK the repository' <<< "$out" \
  || fail "exit 11 is not identified as a lock: $out"
grep -qi 'never ran' <<< "$out" \
  || fail "it does not say the check never ran: $out"
grep -qi 'not evidence of damage' <<< "$out" \
  || fail "it does not rule out corruption, which is the wrong alarm to raise: $out"
grep -qi 'not evidence of health' <<< "$out" \
  || fail "it must not read as reassuring either -- nothing was verified: $out"
grep -qi 'restic unlock' <<< "$out" || fail "the actual remedy is not named: $out"
grep -qi 'approval' <<< "$out" \
  || fail "restic unlock is an approved operation; the remedy must say so: $out"
grep -qi 'retention' <<< "$out" \
  || fail "it does not mention that retention is blocked too: $out"
echo "  identified as a lock, neither damage nor health claimed, remedy named"

sect "any OTHER non-zero exit is still reported generically"
# The special case must not swallow every other failure.
OTHER='
  systemctl() {
    case "$*" in
      *--failed*)       printf "" ;;
      *list-timers*)    printf "x x x x domum-media-backup.service\n" ;;
      *ExecMainStatus*) printf "3\n" ;;
      *)                return 1 ;;
    esac
  }
'
out="$(probe_systemd "$CLI" "$OTHER")"
grep -q 'CRIT|domum-media-backup.service last exited non-zero (status 3)' <<< "$out" \
  || fail "a different failure lost its generic reporting: $out"
grep -qi 'could not LOCK' <<< "$out" && fail "the lock wording leaked to an unrelated failure: $out"
echo "  status 3 on another unit still reported generically"

sect "exit 11 on a DIFFERENT unit is not described as a repository lock"
WRONGUNIT='
  systemctl() {
    case "$*" in
      *--failed*)       printf "" ;;
      *list-timers*)    printf "x x x x domum-media-backup.service\n" ;;
      *ExecMainStatus*) printf "11\n" ;;
      *)                return 1 ;;
    esac
  }
'
out="$(probe_systemd "$CLI" "$WRONGUNIT")"
grep -qi 'could not LOCK the repository' <<< "$out" \
  && fail "status 11 from a unit that does not run restic check was described as
a repository lock. 11 only has that meaning for the check: $out"
grep -q 'last exited non-zero (status 11)' <<< "$out" \
  || fail "it should still be reported generically: $out"
echo "  the lock wording is scoped to the check service only"

# ---------------------------------------------------------------------------
#  Production, 2026-10-25 -> 2026-10-28: a RESOLVED failure reported in the
#  present tense.
#
#  The scheduled check exited 11 against a stale lock. The operator removed the
#  lock on 2026-10-27 and ran the check by hand; it passed, and passed again on
#  2026-10-28. systemd keeps a unit's failed state until the unit itself runs
#  again, so `checkup` went on saying the integrity check "never ran" and
#  telling the operator to perform an approval-gated `restic unlock` they had
#  already completed. The unit state was real; the DIAGNOSIS was stale.
# ---------------------------------------------------------------------------
# The unit is failed with exit 11 AND reports when its main process exited, so
# a recorded later success can be compared against it.
LOCKED_WITH_TS='
  systemctl() {
    case "$*" in
      *--failed*)                 printf "\xe2\x97\x8f domum-media-check.service loaded failed failed domum-media: restic repository integrity check\n" ;;
      *list-timers*)              printf "x x x x domum-media-check.service\n" ;;
      *ExecMainExitTimestamp*)    printf "Sun 2026-10-25 03:37:11 EDT\n" ;;
      *ExecMainStatus*)           printf "11\n" ;;
      *)                          return 1 ;;
    esac
  }
  enabled_backup_targets() { printf "cloud\n"; }
'
EVDIR="$TMP/checkev"
mkdir -p "$EVDIR"
probe_systemd_ev() {  # $1 = cli, $2 = fixture -- same as probe_systemd, with an evidence dir
  (
    export REPO_META_DIR="$EVDIR"
    probe_systemd "$1" "$2"
  )
}

sect "a check verified SINCE the failed run is not reported as a current failure"
printf 'RESULT=success\nMODE=structure\nFINISHED_TS=2026-10-28T10:51:00-0400\n' \
  > "$EVDIR/cloud-check.env"
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
# Scoped to THAT run, the statement is accurate and worth keeping -- the run
# really did not check anything. What must be gone is the UNSCOPED present-tense
# form, which asserts the repository is unverified now, and the "not evidence of
# health either" clause, which stops being true once a later check has passed.
grep -qi 'so the integrity check never ran' <<< "$out" \
  && fail "the unscoped present-tense claim survived a later verification: $out"
grep -qi 'not evidence of health' <<< "$out" \
  && fail "a verified repository is still reported as proving nothing: $out"
grep -qi "THAT run" <<< "$out" \
  || fail "the failure is not scoped to the run it actually belongs to: $out"
grep -qi 'restic unlock' <<< "$out" \
  && fail "the operator is still sent to an approval-gated remedy they completed: $out"
grep -q 'CRIT|' <<< "$out" \
  && fail "a resolved failure is still CRITICAL: $out"
grep -qi 'STALE' <<< "$out" \
  || fail "it does not say the unit state is stale: $out"
grep -qi 'has since been verified' <<< "$out" \
  || fail "it does not name the later successful verification: $out"
grep -q '2026-10-28' <<< "$out" \
  || fail "it does not date the verification that supersedes the failure: $out"
grep -q 'ACT|systemctl reset-failed domum-media-check.service' <<< "$out" \
  || fail "the cheap, safe remedy is not named: $out"
# It must still MAIL: an action is what reaches the notifier, and a dirty
# --failed state that nobody is told about stays dirty forever.
grep -q 'ACT|' <<< "$out" || fail "a stale failed state with no action never mails: $out"
echo "  reported as stale, dated, reset-failed offered, no unlock advice"

sect "the superseding remedy is ONE line, not the same command twice"
# Both the --failed summary and the exit-status detail report this unit, so
# without identical wording the operator is shown the same command twice.
n="$(grep -c 'ACT|systemctl reset-failed' <<< "$out")"
[[ "$n" == "1" ]] || fail "the reset-failed remedy appears $n times, expected 1: $out"
echo "  one remedy line"

sect "evidence OLDER than the failed run does not supersede it"
# The direction that matters. A check that passed BEFORE the failure says
# nothing about the repository now, and reading it as reassurance would turn
# the one real finding into a stale-state note.
printf 'RESULT=success\nMODE=structure\nFINISHED_TS=2026-10-20T03:40:00-0400\n' \
  > "$EVDIR/cloud-check.env"
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
grep -qi 'could not LOCK the repository' <<< "$out" \
  || fail "an EARLIER check suppressed a live lock finding: $out"
grep -q 'CRIT|' <<< "$out" || fail "a live failure was downgraded by stale evidence: $out"
grep -qi 'restic unlock' <<< "$out" || fail "the real remedy was withheld: $out"
echo "  an earlier check cannot excuse a later failure"

sect "with NO recorded evidence the finding is unchanged"
# This is production as it stands today: the recording does not exist yet, so
# the report must behave exactly as it did before. A change that only reads
# correctly once new evidence appears would have silenced the finding in the
# meantime.
rm -f "$EVDIR"/*-check.env
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
grep -qi 'could not LOCK the repository' <<< "$out" \
  || fail "absent evidence changed the live finding: $out"
grep -qi 'never ran' <<< "$out" || fail "absent evidence weakened the claim: $out"
grep -q 'CRIT|' <<< "$out" || fail "absent evidence downgraded the severity: $out"
echo "  no evidence means no change -- the conservative direction"

sect "retention's recency is stated with the lock finding, not in the abstract"
# Retention is the second ExecStart with no `-` prefix, so a blocked check
# skips it in the same run. "Retention is blocked" does not tell the operator
# how many weeks of snapshots have accumulated.
printf 'RESULT=success\nMODE=forget-prune\nFINISHED_TS=2026-10-18T03:40:00-0400\n' \
  > "$EVDIR/cloud-retention.env"
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
grep -q '2026-10-18' <<< "$out" \
  || fail "the recorded retention date is not surfaced with the lock finding: $out"
rm -f "$EVDIR"/*-retention.env
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
grep -qi 'no successful retention run is recorded' <<< "$out" \
  || fail "absent retention evidence is not stated honestly: $out"
echo "  dated when recorded, honest when not"

sect "MUTATION: the staleness gate always open downgrades a LIVE failure"
# The dangerous direction. If the superseded branch is taken unconditionally,
# a repository that has genuinely never been verified since its check failed
# reads as a stale-state note with a `reset-failed` remedy -- the report
# agreeing that nothing is wrong, which is the one outcome worse than a false
# alarm.
#
# The backup is taken BEFORE the mutation, unconditionally and on its own line.
cp "$CLI" "$TMP/cli.orig.staleness"
# `[[ x == * ]]` always matches, so the gate is open for every verdict. Written
# as its own file with a quoted heredoc: expressing a mutation through nested
# quoting is how one came to apply textually and change nothing.
cat > "$TMP/mutate-staleness.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '[[ "$verdict" == superseded* ]]'
assert s.count(old) == 2, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, '[[ "$verdict" == * ]]'))
PYMUT
( python3 -I "$TMP/mutate-staleness.py" "$CLI" ) \
  || { cp "$TMP/cli.orig.staleness" "$CLI"; fail "the staleness mutation did not apply"; }
rm -f "$EVDIR"/*-check.env
out="$(probe_systemd_ev "$CLI" "$LOCKED_WITH_TS")"
cp "$TMP/cli.orig.staleness" "$CLI"
grep -qi 'STALE' <<< "$out" \
  || fail "the mutation changed no ANSWER -- with the gate open a live failure must read as stale: $out"
grep -q 'CRIT|' <<< "$out" \
  && fail "the mutation did not actually downgrade the finding: $out"
echo "  killed: an always-open gate reports an unverified repository as stale"

sect "a failed job stays visible even when systemctl --failed no longer lists it"
# systemctl --failed lists only units CURRENTLY failed. A weekly job that
# failed and was later reset must still be visible through its last exit
# status, or the finding disappears on the next boot.
NOFAILED='
  systemctl() {
    case "$*" in
      *--failed*)       printf "" ;;
      *list-timers*)    printf "x x x x domum-media-check.service\n" ;;
      *ExecMainStatus*) printf "11\n" ;;
      *)                return 1 ;;
    esac
  }
'
out="$(probe_systemd "$CLI" "$NOFAILED")"
grep -qE 'CRIT\|domum-media-check\.service (could not LOCK|last exited non-zero)' <<< "$out" \
  || fail "with nothing CURRENTLY failed the historical failure vanished: $out"
grep -q 'ACT|' <<< "$out" || fail "a historical failure with no remedy never mails: $out"
echo "  historical failure still reported, and still critical, from the last exit status"

sect "a line systemctl lists but the parser cannot name is reported, not invented"
# The alternative to the bullet bug is silence, which is worse. An unnameable
# line must say so rather than fabricate a unit.
WEIRD='
  systemctl() {
    case "$*" in
      *--failed*)       printf "?? something entirely unparseable\n" ;;
      *list-timers*)    printf "" ;;
      *)                return 1 ;;
    esac
  }
'
out="$(probe_systemd "$CLI" "$WEIRD")"
grep -q 'could not be parsed' <<< "$out" \
  || fail "an unnameable failed unit was silently dropped: $out"
grep -qE 'CRIT\|systemd unit \?\? ' <<< "$out" && fail "it invented a unit name: $out"
echo "  reported as unparseable; no name invented"

sect "an exact duplicate finding is suppressed"
# A failed unit is found twice -- in systemctl --failed and in its timer's exit
# status. Printing the identical text twice makes the host look twice as bad.
dup="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  CHECKUP_ACTIONS=()
  checkup_add action "sudo domum-media compose logs --tail 50 immich_server immich_redis"
  checkup_add action "sudo domum-media compose logs --tail 50 immich_server immich_redis"
  checkup_add action "a different action"
  printf '%s\n' "${#CHECKUP_ACTIONS[@]}"
  printf '[%s]\n' "${CHECKUP_ACTIONS[@]}"
)"
[[ "$(head -1 <<< "$dup")" == "2" ]] \
  || fail "duplicate suppression failed (expected 2 actions): $dup"
grep -qF '[sudo domom]' <<< "$dup" && fail "an element was word-split"
grep -qF '[sudo domum-media compose logs --tail 50 immich_server immich_redis]' <<< "$dup" \
  || fail "a multi-word action was corrupted by the dedup loop: $dup"
echo "  duplicate dropped, multi-word findings intact"

# ---------------------------------------------------------------------------
sect "every recommendation is safe, uses the wrapper, and has no placeholder"
# Production's first report suggested bare `docker compose logs`, a forced host
# upgrade for a merely-pending reboot, and `systemctl status <unit>`.
src="$(sed -e 's/#.*//' "$CLI")"
acts="$(grep -oE 'checkup_add action "[^"]*"' <<< "$src")"
grep -qE 'checkup_add action "[^"]*<unit>' <<< "$acts" \
  && fail "a remedy still contains an unresolved <unit> placeholder"
grep -qE 'checkup_add action "(cd [^&]*&& *)?docker compose' <<< "$acts" \
  && fail "a remedy calls bare 'docker compose'. Use the project wrapper,
'domum-media compose', which layers the compose fragments."
grep -qE 'checkup_add action "[^"]*host-upgrade --force' <<< "$acts" \
  && fail "a remedy recommends 'host-upgrade --force'. That installs packages
and may reboot -- far more than a pending-reboot finding warrants."
grep -qE 'checkup_add action "[^"]*up -d' <<< "$acts" \
  && fail "a remedy recommends 'up -d', which reconciles and deploys a staged image"
grep -qE 'checkup_add action "[^"]*cleanup images --confirm' <<< "$acts" \
  && fail "a remedy recommends cleanup with --confirm, which DELETES"
echo "  no placeholder, no bare docker compose, no forced upgrade, no up -d, no --confirm"

sect "the reboot remedy is read-only and warns about Persistent=true"
# Read the RAW source here, not $src: the remedies annotate their commands
# after a `#`, and the comment-stripping that protects the absence assertions
# above would delete exactly the operator-facing text being checked.
raw="$(cat "$CLI")"
reboot_ctx="$(grep -A4 'Reboot required by a previous' <<< "$raw")"
grep -q 'list-timers' <<< "$reboot_ctx" \
  || fail "the reboot remedy does not show what would fire: $reboot_ctx"
grep -qi 'snapshot prune' <<< "$reboot_ctx" \
  || fail "it does not warn that a reboot runs the deleting prune job: $reboot_ctx"
grep -q 'host-upgrade' <<< "$reboot_ctx" && fail "it still suggests a host upgrade"
echo "  read-only, and it names the deleting job a reboot would trigger"

sect "the image-cleanup remedy states that the dry run deletes nothing"
clean_ctx="$(grep -A2 'dangling > 0' <<< "$raw")"
grep -q 'deletes nothing' <<< "$clean_ctx" \
  || fail "the cleanup remedy does not say the dry run is safe: $clean_ctx"
grep -qi 'recovery point' <<< "$clean_ctx" \
  || fail "it does not mention recovery-point protection: $clean_ctx"
echo "  dry run named as non-destructive, protection mentioned"

sect "an UNHEALTHY container is never counted as healthy"
# Production: all 11 containers were Up and immich_machine_learning was
# unhealthy. "Up 7 of 8" read as though three containers were missing; it was
# counting LOGICAL SERVICES, of which immich is one mapping to four containers.
rep="$(run_cmd "$CLI" report)"
svc_block="$(sed -n '/── SERVICES/,/── UPDATES/p' <<< "$rep")"
grep -qE 'Logical services +[0-9]+ enabled' <<< "$svc_block" \
  || fail "the logical-service count is not labelled: $svc_block"
grep -qE 'Containers running +[0-9]+' <<< "$svc_block" \
  || fail "the container count is absent, so the denominator stays ambiguous: $svc_block"
grep -qE 'Healthcheck passing +[0-9]+' <<< "$svc_block" \
  || fail "healthcheck-passing is not reported separately: $svc_block"
grep -qE 'No healthcheck +[0-9]+' <<< "$svc_block" \
  || fail "no-healthcheck is not reported separately: $svc_block"
grep -qE 'UNHEALTHY +[0-9]+' <<< "$svc_block" \
  || fail "UNHEALTHY is not its own class: $svc_block"
grep -qi 'RUNNING is the whole claim' <<< "$svc_block" \
  || fail "it does not say running is not healthy: $svc_block"
grep -qE 'Up +[0-9]+ of [0-9]+' <<< "$svc_block" \
  && fail "the ambiguous 'Up N of M' line is still present: $svc_block"
echo "  logical services, containers, and each health class reported separately"

sect "the UNHEALTHY finding NAMES the container, not just the logical service"
# Production: "immich is UNHEALTHY" while all four immich containers were
# running and only immich_machine_learning was unhealthy. The operator had no
# way to know which of four to look at -- the same actionability problem as a
# systemd finding that does not name its unit.
members="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  service_compose_services() { printf 'immich_server\nimmich_machine_learning\nimmich_postgres\nimmich_redis\n'; }
  tracked_service_container_id() { printf 'cid-%s' "$1"; }
  docker() {
    case "$*" in
      *'{{.State.Status}}'*) printf 'running\n' ;;
      *Health*) case "$*" in
                  *machine_learning*) printf 'unhealthy\n' ;;
                  *) printf 'healthy\n' ;;
                esac ;;
    esac
  }
  printf '%s|%s' "$(service_unhealthy_members immich)" "$(service_health_state immich)"
)"
[[ "${members%%|*}" == "immich_machine_learning:unhealthy" ]] \
  || fail "the unhealthy member is not named exactly: [${members%%|*}]"
[[ "${members##*|}" == "unhealthy" ]] \
  || fail "service_health_state's contract changed: [${members##*|}]"
grep -qF 'is UNHEALTHY: $(service_unhealthy_members' "$CLI" \
  || fail "the checkup finding does not interpolate the member names"
echo "  names immich_machine_learning:unhealthy, and the state word is unchanged"

sect "healthy members are NOT listed, so the finding stays short"
allok="$(
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  service_compose_services() { printf 'a\nb\nc\n'; }
  tracked_service_container_id() { printf 'cid-%s' "$1"; }
  docker() { case "$*" in *'{{.State.Status}}'*) printf 'running\n' ;; *Health*) printf 'healthy\n' ;; esac; }
  printf '[%s]' "$(service_unhealthy_members x)"
)"
[[ "$allok" == "[]" ]] || fail "healthy members were listed: $allok"
echo "  empty when everything is healthy"

sect "--unlock lists locks first, removes only stale ones, and is on no timer"
# The remediation for the production finding. restic's own help: "The 'unlock'
# command removes stale locks that have been created by other restic
# processes." It must therefore never be given a force flag, and must never be
# wired to a timer.
BK="$REPO_ROOT/bin/domum-media-backup"
calls="$(
  export PATH="$TMP/bin:$PATH"
  # shellcheck disable=SC1090
  source "$BK" >/dev/null 2>&1
  set +e
  log() { :; }
  die() { echo "DIE: $*"; exit 1; }
  enabled_backup_targets() { printf 'cloud\n'; }
  restic_for_target() { shift; printf 'RESTIC %s\n' "$*" >&2; return 0; }
  do_unlock_stale cloud 2>&1
)"
grep -q 'RESTIC list locks' <<< "$calls" \
  || fail "it does not list the locks before unlocking: $calls"
grep -q 'RESTIC unlock' <<< "$calls" || fail "it never calls unlock: $calls"
[[ "$(grep -c 'RESTIC list locks' <<< "$calls")" == "2" ]] \
  || fail "it should list locks before AND after, so the operator can see the
effect: $calls"
# Ordering: list, unlock, list.
[[ "$(grep -n 'RESTIC' <<< "$calls" | head -1)" == *"list locks"* ]] \
  || fail "the first restic call is not a read-only listing: $calls"
echo "  lists, unlocks, lists again"

sect "--unlock refuses an unknown target and never force-removes"
out="$(
  export PATH="$TMP/bin:$PATH"
  # shellcheck disable=SC1090
  source "$BK" >/dev/null 2>&1
  set +e
  log() { :; }
  die() { echo "DIE: $*"; exit 1; }
  enabled_backup_targets() { printf 'cloud\n'; }
  restic_for_target() { return 0; }
  do_unlock_stale nosuchtarget
  do_unlock_stale ""
)"
grep -qc 'DIE:' <<< "$out" || fail "an unknown target was accepted: $out"
grep -qi 'unknown or disabled' <<< "$out" || fail "the refusal is unclear: $out"
src_bk="$(sed -e 's/#.*//' "$BK")"
unlock_fn="$(awk '/^do_unlock_stale\(\) \{/,/^\}/' <<< "$src_bk")"
grep -qE 'remove-all|--force' <<< "$unlock_fn" \
  && fail "the wrapper passes a force flag. restic removes only STALE locks by
default, and forcing it could interrupt a live backup."
grep -rqE 'unlock' "$REPO_ROOT/systemd/" 2>/dev/null \
  && fail "a systemd unit references unlock. It must stay operator-initiated."
echo "  unknown target refused, no force flag, on no timer"

echo "PASS: monitoring completeness smoke test"
