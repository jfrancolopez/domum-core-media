#!/usr/bin/env bash
set -uo pipefail

# TWO notification behaviours, and the whole point is that they are different.
#
# On Sunday 2026-11-08 the weekly unit ran and SUCCEEDED -- status 0/SUCCESS,
# the full report generated -- and the operator received nothing. The journal
# line was `health-notify: nothing needs attention; no mail sent`: 2 warnings,
# 0 actions, 0 critical, so the silence gate held exactly as designed. The
# defect was not SMTP and not a missed timer; it was that NO unit ever invoked
# the comprehensive HTML report. It existed only behind a manual
# `report weekly --email`.
#
#   REPORT  every Sunday, healthy or not. A weekly report that arrives only
#           when something is wrong cannot be told apart from one that is
#           broken.
#   ALERT   silent unless action or critical. Unchanged.
#
# ...and they must not both mail about one state.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE" "$TMP/data" "$TMP/media" "$TMP/snapshots" "$TMP/log" "$TMP/secrets" "$TMP/meta"
: > "$TMP/c.conf"

# ---------------------------------------------------------------------------
# The weekly report. Renderers are stubbed only where they need host state;
# the SEND DECISION, the same-day guard and the evidence are the real code.
# ---------------------------------------------------------------------------
run_weekly() {  # $1 = extra shell, rest = argv -> output then rc=N
  local extra="$1"; shift
  ( export CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$STATE" DOMUM_DATA_ROOT="$TMP/data"
    export DOMUM_MEDIA_ROOT="$TMP/media" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
    export DOMUM_LOG_DIR="$TMP/log" SECRETS_DIR="$TMP/secrets" REPO_META_DIR="$TMP/meta"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    RECOVERY_PACK_EMAIL_ENABLED=1
    die() { echo "DIE: $*"; exit 1; }
    warn() { echo "WARN: $*"; }
    need_root() { :; }
    ensure_dirs() { :; }
    export_compose_env() { :; }
    # A report whose content is not what this suite is about.
    mreport_render_text() { printf 'domum-media report: TEST\n  Verdict: TEST\n' > "$1"; }
    mreport_render_html() { printf '<html><body>test</body></html>\n' > "$2"; }
    mreport_build_mime() { printf 'Subject: %s\n\nbody\n' "$1" > "$4"; }
    health_verdict() { printf 'HEALTHY'; }
    smtp_send_message() { printf 'SENT\n'; return 0; }
    eval "$extra"
    mreport_weekly_cmd "$@"
    echo "rc=$?"
  ) 2>&1
}

ev() { printf '%s' "$STATE/weekly-report.env"; }
fresh() { rm -f "$(ev)"; }

sect "1. HEALTHY: the scheduled report is sent anyway"
fresh
out="$(run_weekly '' --email --scheduled)"
grep -q 'rc=0' <<< "$out" || fail "1: a healthy host did not send the report: $out"
grep -q 'SENT' <<< "$out" || fail "1: the message was never handed to the transport: $out"
grep -q 'weekly report emailed' <<< "$out" || fail "1: it did not report sending: $out"
[[ -f "$(ev)" ]] || fail "1: the send was not recorded"
grep -q "^RESULT=success$" "$(ev)" || fail "1: success was not recorded: $(cat "$(ev)")"
# THE RECORDED DATE IS IN THE CLI's TIMEZONE, NOT THIS TEST's. bin/domum-media
# exports TZ="${TZ:-UTC}" for the containers and it leaks into its own process --
# CLAUDE.md records that leak and records it as load-bearing for the journal
# --since window -- so `date -I` inside the CLI is UTC while the same call here is
# local. Measured 2026-11-10 21:47 EST: local 2026-11-10, UTC 2026-11-11. So a
# locally computed expectation failed on this host every evening between 19:00
# and midnight and passed in CI, which runs UTC: the "passes in CI, fails
# locally" inversion, with the host's TIMEZONE as the dependence.
#
# Derived the way the code derives it, so the test follows if that ever changes,
# and the TS/SENT_DATE agreement is asserted too -- that one holds whatever the
# clock says, so it cannot rot back into a time-of-day dependence.
want_date="$(TZ="${TZ:-UTC}" date -I)"
grep -q "^SENT_DATE=$want_date$" "$(ev)" \
  || fail "1: the CLI's own date was not recorded (expected $want_date): $(cat "$(ev)")"
rec_ts="$(sed -n 's/^TS=//p' "$(ev)")"
[[ -n "$rec_ts" ]] || fail "1: no TS was recorded: $(cat "$(ev)")"
[[ "$(TZ="${TZ:-UTC}" date -I -d "@$rec_ts")" == "$want_date" ]] \
  || fail "1: TS and SENT_DATE disagree: $(cat "$(ev)")"
echo "   sent on a healthy host, and recorded"

sect "2. the same day twice: the SECOND scheduled send is refused"
# This is what keeps Persistent=true from mailing twice when a missed Sunday
# fires at boot and the machine is rebooted again the same day.
out="$(run_weekly '' --email --scheduled)"
grep -q 'rc=0' <<< "$out" || fail "2: a skipped second send must not fail: $out"
grep -q 'already emailed today' <<< "$out" || fail "2: it did not say why it skipped: $out"
grep -q 'SENT' <<< "$out" && fail "2: it sent a SECOND report the same day: $out"
echo "   refused, exit 0, and it says why"

sect "3. a MANUAL --email always sends, even after a scheduled one today"
# An explicit operator action is never silenced by what the timer did.
out="$(run_weekly '' --email)"
grep -q 'SENT' <<< "$out" || fail "3: a manual send was suppressed by the scheduled record: $out"
grep -q 'already emailed today' <<< "$out" && fail "3: the manual path consulted the same-day guard: $out"
echo "   manual send is unconditional"

sect "4. a manual send records NOTHING, so it cannot suppress a later alert"
fresh
run_weekly '' --email >/dev/null
[[ ! -f "$(ev)" ]] || fail "4: a manual send wrote scheduled evidence: $(cat "$(ev)")"
echo "   no evidence written by the manual path"

sect "5. SMTP FAILURE: recorded as a failure, and it still dies"
fresh
out="$(run_weekly 'smtp_send_message() { return 1; }' --email --scheduled)"
grep -q 'rc=0' <<< "$out" && fail "5: an undeliverable report reported success: $out"
grep -q 'could not be sent' <<< "$out" || fail "5: it did not fail loudly: $out"
grep -q "^RESULT=failure$" "$(ev)" \
  || fail "5: the failure was not RECORDED, so nothing could surface it: $(cat "$(ev)" 2>/dev/null)"
echo "   dies, and the failure is recorded for checkup to raise"

sect "6. email disabled is refused, not silently skipped"
fresh
out="$(run_weekly 'RECOVERY_PACK_EMAIL_ENABLED=0' --email --scheduled)"
grep -q 'Email is disabled' <<< "$out" || fail "6: a disabled transport was not named: $out"
grep -q 'SENT' <<< "$out" && fail "6: it sent with email disabled: $out"
echo "   refused, naming the reason"

# ---------------------------------------------------------------------------
# The alert path, and the de-duplication.
# ---------------------------------------------------------------------------
run_notify() {  # $1 = extra shell, rest = argv
  local extra="$1"; shift
  ( export CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$STATE" DOMUM_DATA_ROOT="$TMP/data"
    export DOMUM_MEDIA_ROOT="$TMP/media" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
    export DOMUM_LOG_DIR="$TMP/log" SECRETS_DIR="$TMP/secrets" REPO_META_DIR="$TMP/meta"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    RECOVERY_PACK_EMAIL_ENABLED=1
    die() { echo "DIE: $*"; exit 1; }
    warn() { echo "WARN: $*"; }
    need_root() { :; }
    ensure_dirs() { :; }
    export_env_for_compose() { :; }
    health_summary_text() { printf 'summary\n'; }
    smtp_send_message() { printf 'ALERT-SENT\n'; return 0; }
    eval "$extra"
    health_notify_cmd "$@"
    echo "rc=$?"
  ) 2>&1
}

HEALTHY='checkup_collect_all() { checkup_add healthy "all good"; }'
WARN_ONLY='checkup_collect_all() { checkup_add warning "routine"; checkup_add advice "look"; }'
ACTIONABLE='checkup_collect_all() { checkup_add action "do the thing"; }'
CRITICAL='checkup_collect_all() { checkup_add critical "BACKUP GAP: 3 originals"; }'

sect "7. the ALERT policy is unchanged: silent on healthy and on warnings"
out="$(run_notify "$HEALTHY")"
grep -q 'ALERT-SENT' <<< "$out" && fail "7: a healthy host mailed an alert: $out"
out="$(run_notify "$WARN_ONLY")"
grep -q 'ALERT-SENT' <<< "$out" && fail "7: routine warnings mailed an alert: $out"
echo "   healthy and warning-only stay silent"

sect "8. action and critical still mail"
out="$(run_notify "$ACTIONABLE")"
grep -q 'ALERT-SENT' <<< "$out" || fail "8: an action did not mail: $out"
out="$(run_notify "$CRITICAL")"
grep -q 'ALERT-SENT' <<< "$out" || fail "8: a critical did not mail: $out"
echo "   action and critical both mail"

sect "9. NO DUPLICATE: a report sent in this same activation suppresses the alert"
# Keyed on systemd's INVOCATION_ID, which is identical for every ExecStart of
# one activation. The report already carries the verdict and every finding, so
# a second message would be two notifications about one state.
fresh
INVOCATION_ID=act-1 run_weekly '' --email --scheduled >/dev/null
out="$(run_notify "$CRITICAL
INVOCATION_ID=act-1" --unless-reported)"
grep -q 'ALERT-SENT' <<< "$out" && fail "9: the alert duplicated the report in one activation: $out"
grep -q 'emailed in this same run' <<< "$out" || fail "9: it did not say why it was silent: $out"
grep -q 'rc=0' <<< "$out" || fail "9: suppressing a duplicate must not fail the unit: $out"
echo "   suppressed, and it says why"

sect "10. a DIFFERENT activation is not a duplicate, so the alert goes"
out="$(run_notify "$CRITICAL
INVOCATION_ID=act-2" --unless-reported)"
grep -q 'ALERT-SENT' <<< "$out" \
  || fail "10: a later activation was silenced by an earlier report: $out"
echo "   a later activation still alerts"

sect "11. a FAILED report never suppresses the alert"
# The unit tolerates a failed send precisely so the alert still runs. If a
# recorded FAILURE suppressed it, the operator would get nothing at all --
# silence meaning "could not tell you".
fresh
INVOCATION_ID=act-3 run_weekly 'smtp_send_message() { return 1; }' --email --scheduled >/dev/null 2>&1
out="$(run_notify "$CRITICAL
INVOCATION_ID=act-3" --unless-reported)"
grep -q 'ALERT-SENT' <<< "$out" \
  || fail "11: a FAILED report suppressed the alert, so nothing would be sent: $out"
echo "   a failed report leaves the alert as the only message, and it is sent"

sect "12. a MANUAL health-notify is never suppressed (no INVOCATION_ID)"
fresh
INVOCATION_ID=act-4 run_weekly '' --email --scheduled >/dev/null
out="$(run_notify "$CRITICAL" --unless-reported)"   # no INVOCATION_ID in the environment
grep -q 'ALERT-SENT' <<< "$out" \
  || fail "12: a manual health-notify was silenced by a report the timer sent: $out"
echo "   manual alerts always evaluated"

sect "13. without --unless-reported the alert is never suppressed"
out="$(run_notify "$CRITICAL
INVOCATION_ID=act-4" --force)"
grep -q 'ALERT-SENT' <<< "$out" || fail "13: --force did not send: $out"
echo "   the flag is opt-in"

# ---------------------------------------------------------------------------
# checkup must surface a failed scheduled report, or the unit's tolerance of it
# becomes silence.
# ---------------------------------------------------------------------------
run_check() {
  ( export CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$STATE" DOMUM_DATA_ROOT="$TMP/data"
    export DOMUM_MEDIA_ROOT="$TMP/media" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    CHECKUP_HEALTHY=(); CHECKUP_WARNINGS=(); CHECKUP_ACTIONS=(); CHECKUP_CRITICAL=(); CHECKUP_ADVICE=()
    checkup_weekly_report_delivery
    printf 'CRIT=%s WARN=%s ADVICE=%s HEALTHY=%s\n' \
      "${#CHECKUP_CRITICAL[@]}" "${#CHECKUP_WARNINGS[@]}" "${#CHECKUP_ADVICE[@]}" "${#CHECKUP_HEALTHY[@]}"
    local all
    all="$(printf '%s\n' "${CHECKUP_CRITICAL[@]}" "${CHECKUP_ADVICE[@]}" "${CHECKUP_HEALTHY[@]}" 2>/dev/null || true)"
    sed -n '/[^[:space:]]/{p;q;}' <<< "$all" ) 2>&1
}

sect "14. checkup: a failed scheduled report is CRITICAL with a remedy"
fresh
INVOCATION_ID=act-5 run_weekly 'smtp_send_message() { return 1; }' --email --scheduled >/dev/null 2>&1
out="$(run_check)"
grep -q 'CRIT=1' <<< "$out" || fail "14: a failed scheduled report is not critical: $out"
grep -q 'could NOT be emailed' <<< "$out" || fail "14: it does not name the failure: $out"
echo "   critical, and it says the operator is receiving nothing"

sect "15. checkup: a successful send is healthy, and an ABSENT record is advice"
fresh
run_weekly '' --email --scheduled >/dev/null
out="$(run_check)"
grep -q 'HEALTHY=1' <<< "$out" || fail "15: a successful send is not healthy: $out"
fresh
out="$(run_check)"
grep -q 'ADVICE=1' <<< "$out" \
  || fail "15: no record at all must be ADVICE -- it is the honest state of a host
where the scheduled report has not run yet, and alarming on it is a false alarm
manufactured on purpose: $out"
grep -q 'CRIT=0' <<< "$out" || fail "15: an absent record raised a critical: $out"
echo "   success -> healthy; absent -> advice, never a critical"

sect "16. MUTATION: without the INVOCATION_ID match the alert duplicates the report"
mut="$TMP/cli-mut-dedup"
cp "$CLI" "$mut"
python3 - "$mut" <<'PYM'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Neutralise the comparison itself -- never `&& false` inside [[ ]], where the
# bare word is a non-empty STRING and the mutation changes nothing.
old = '      if [[ "$wr_result" == success && -n "$wr_inv" && "$wr_inv" == "${INVOCATION_ID}" ]]; then'
new = '      if [[ "$wr_result" == success && -n "$wr_inv" && "$wr_inv" != "$wr_inv" ]]; then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYM
grep -qF '"$wr_inv" != "$wr_inv"' "$mut" || fail "16: the dedup mutation did not apply"
fresh
INVOCATION_ID=act-6 run_weekly '' --email --scheduled >/dev/null
mout="$( ( source "$mut" >/dev/null 2>&1; set +e
  DOMUM_STATE_ROOT="$STATE"; RECOVERY_PACK_EMAIL_ENABLED=1; INVOCATION_ID=act-6
  die(){ echo "DIE: $*"; exit 1; }; warn(){ :; }; need_root(){ :; }; load_cfg(){ :; }
  export_env_for_compose(){ :; }; health_summary_text(){ printf 'summary\n'; }
  smtp_send_message(){ printf 'ALERT-SENT\n'; return 0; }
  checkup_collect_all() { checkup_add critical "BACKUP GAP: 3 originals"; }
  health_notify_cmd --unless-reported ) 2>&1 )"
grep -q 'ALERT-SENT' <<< "$mout" \
  || fail "16: the mutation changed no ANSWER -- without the match the alert must
mail alongside the report it duplicates: $mout"
echo "  killed: the mutant mails twice about one state"

sect "17. MUTATION: without the same-day guard a Persistent replay mails twice"
mut2="$TMP/cli-mut-sameday"
cp "$CLI" "$mut2"
python3 - "$mut2" <<'PYM2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '          if [[ "$prev_result" == success && "$prev_date" == "$(date -I)" ]]; then'
new = '          if [[ "$prev_result" == success && "$prev_date" != "$prev_date" ]]; then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYM2
grep -qF '"$prev_date" != "$prev_date"' "$mut2" || fail "17: the same-day mutation did not apply"
fresh
run_weekly '' --email --scheduled >/dev/null
mout2="$( CLI="$mut2" run_weekly '' --email --scheduled )"
grep -q 'SENT' <<< "$mout2" \
  || fail "17: the mutation changed no ANSWER -- without the same-day guard a
second scheduled run must send again: $mout2"
echo "  killed: the mutant sends a second report the same day"

sect "18. the unit wires all three steps, with the prefixes the design needs"
unit="$REPO_ROOT/systemd/domum-media-weekly-report.service"
execs="$(grep -E '^ExecStart' "$unit")"
[[ "$(wc -l <<< "$execs")" == "3" ]] || fail "18: expected three ExecStart lines: $execs"
grep -qE '^ExecStart=-.*report --write$' <<< "$execs" \
  || fail "18: 'report --write' must be TOLERATED, or a failed evidence write stops everything: $execs"
grep -qE '^ExecStart=-.*report weekly --email --scheduled$' <<< "$execs" \
  || fail "18: the weekly report must be scheduled AND tolerated -- without the '-'
a failed send would stop the unit and the alert would never run: $execs"
grep -qE '^ExecStart=/usr/local/bin/domum-media health-notify --unless-reported$' <<< "$execs" \
  || fail "18: health-notify must be LAST, unprefixed (so an undeliverable alert
fails the unit) and deduplicated: $execs"
# Order matters: the report must precede the alert, or the dedup cannot work.
rline="$(grep -n '^ExecStart=.*report weekly --email' "$unit" | cut -d: -f1)"
hline="$(grep -n '^ExecStart=.*health-notify --unless-reported' "$unit" | cut -d: -f1)"
(( rline < hline )) || fail "18: the alert runs BEFORE the report, so the dedup can never fire"
echo "   three steps, right prefixes, report before alert"

echo "ALL WEEKLY-NOTIFICATION-POLICY CHECKS PASSED"
