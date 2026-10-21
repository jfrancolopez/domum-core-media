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

echo "PASS: monitoring completeness smoke test"
