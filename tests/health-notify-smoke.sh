#!/usr/bin/env bash
# Silence must mean healthy, and only actionable findings may break it.
#
# Every scheduled job on this host wrote to the journal and nothing read it, so
# the operator learned the server's state by running commands. This suite pins
# the contract that replaces that: no mail when healthy, one mail when something
# needs doing, and never a claim of delivery that did not happen.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state/restore-verification" "$TMP/data" "$TMP/secrets"
# The host must be unreachable: a check that can silently read production is not
# a test of the check.
for stub in docker systemctl btrfs smartctl lsblk curl; do
  printf '#!/usr/bin/env bash\necho "%s is unavailable in this test" >&2\nexit 127\n' "$stub" \
    > "$TMP/bin/$stub"
  chmod +x "$TMP/bin/$stub"
done
# Distinctive sentinels. The first version used 'u' and 'p', single characters
# that occur in any English sentence, so the leak assertion could only ever
# fail -- a fixture that cannot distinguish a leak from prose tests nothing.
printf 'SMTPUSER-7f3a9d1e-SENTINEL\n' > "$TMP/secrets/smtp_user"
printf 'SMTPPASS-9b2c4a8f-SENTINEL\n' > "$TMP/secrets/smtp_pass"

# Drive the notifier with a controlled finding set, recording whether mail left.
run_notify() {  # $1 = setup shell, rest = argv
  local setup="$1"; shift
  (
    export PATH="$TMP/bin:$PATH"
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export RECOVERY_PACK_SMTP_HOST=smtp.invalid RECOVERY_PACK_SMTP_PORT=465
    export RECOVERY_PACK_SMTP_USERNAME_FILE="$TMP/secrets/smtp_user"
    export RECOVERY_PACK_SMTP_PASSWORD_FILE="$TMP/secrets/smtp_pass"
    export RECOVERY_PACK_EMAIL_ENABLED=1
    export DOMUM_EMAIL=op@example.invalid
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    need_root() { :; }
    load_cfg() { :; }
    export_env_for_compose() { :; }
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    die()  { echo "DIE: $*"; exit 9; }
    # The COLLECTION is replaced: this suite is about the NOTIFICATION contract,
    # not about what the checks find. Stubbing the four individual checks stopped
    # working when health_notify_cmd began collecting through
    # checkup_collect_all -- the fix for it having run only a SUBSET of the
    # checks -- because the full collection reads configuration this fixture
    # does not supply. Each case ADDS its findings, because health_notify_cmd
    # clears the arrays before collecting, as it must to gather fresh state.
    checkup_collect_all() { :; }
    # Record a send instead of performing one.
    smtp_send_message() { cp "$1" "$TMP/sent.eml"; echo "SENT"; return 0; }
    rm -f "$TMP/sent.eml"
    eval "$setup"
    health_notify_cmd "$@"
    echo "EXITCODE=$?"
  ) 2>&1
}
sent() { [[ -f "$TMP/sent.eml" ]]; }

sect "HEALTHY sends NO mail -- silence is the healthy signal"
out="$(run_notify 'checkup_collect_all() { checkup_add healthy a; checkup_add healthy b; }')"
sent && fail "a healthy run sent mail: $out"
grep -q 'nothing needs attention' <<< "$out" || fail "it did not say why it stayed silent: $out"
grep -q 'EXITCODE=0' <<< "$out" || fail "a healthy run must exit 0: $out"
echo "  no mail, exit 0, and the reason is logged"

sect "a CRITICAL finding sends exactly one mail, named in the subject"
out="$(run_notify 'checkup_collect_all() { checkup_add critical "BACKUP GAP: 3 originals"; }')"
sent || fail "a critical finding sent no mail: $out"
grep -qE '^Subject: domum-media: CRITICAL \(' "$TMP/sent.eml" \
  || fail "the subject does not name CRITICAL: $(grep ^Subject "$TMP/sent.eml")"
grep -q 'CRITICAL' "$TMP/sent.eml" \
  || fail "the message does not label the severity at all"
grep -qE 'Verdict: .* CRITICAL' "$TMP/sent.eml" \
  || fail "the body does not state the verdict: $(cat "$TMP/sent.eml")"
grep -q 'BACKUP GAP: 3 originals' "$TMP/sent.eml" || fail "the finding itself is missing"
echo "  one mail, CRITICAL in the subject, the finding in the body"

sect "an ACTION with no critical still sends -- that is the point"
out="$(run_notify 'checkup_collect_all() { checkup_add action "apt-get install -y smartmontools"; }')"
sent || fail "an actionable finding sent no mail: $out"
grep -qE '^Subject: domum-media: ACTION REQUIRED \(1\)' "$TMP/sent.eml" \
  || fail "wrong subject: $(grep ^Subject "$TMP/sent.eml")"
grep -q 'smartmontools' "$TMP/sent.eml" || fail "the action is not in the body"
echo "  mailed, with the remedy in the body"

sect "warnings ALONE do not mail -- expected activity is not an incident"
out="$(run_notify 'checkup_collect_all() { checkup_add warning "5 originals await the next backup"; }')"
sent && fail "a warning with no action sent mail; this is the daily-noise failure: $out"
grep -q 'EXITCODE=0' <<< "$out" || fail "must still exit 0: $out"
echo "  recorded, not mailed"

sect "--force proves delivery works without waiting for a failure"
out="$(run_notify 'checkup_collect_all() { checkup_add healthy a; }' --force)"
sent || fail "--force did not send: $out"
grep -q '^Subject: domum-media: HEALTHY' "$TMP/sent.eml" \
  || fail "a forced healthy mail should say healthy: $(grep ^Subject "$TMP/sent.eml")"
echo "  sends on demand, and says it is healthy"

sect "--dry-run prints the summary and sends nothing"
out="$(run_notify 'checkup_collect_all() { checkup_add critical x; }' --dry-run)"
sent && fail "--dry-run sent mail: $out"
grep -q 'dry run: no mail was sent' <<< "$out" || fail "it does not say it was a dry run: $out"
grep -q 'VERDICT: CRITICAL' <<< "$out" || fail "the verdict is missing: $out"
echo "  nothing sent, and the verdict is still stated"

sect "delivery NOT enabled is never reported as delivered"
out="$(
  (
    export PATH="$TMP/bin:$PATH" DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export RECOVERY_PACK_EMAIL_ENABLED=0 DOMUM_EMAIL=op@example.invalid
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    need_root() { :; }; load_cfg() { :; }; export_env_for_compose() { :; }
    log() { echo "LOG: $*"; }; warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 9; }
    checkup_collect_all() { checkup_add critical "real problem"; }
    smtp_send_message() { echo "SENT-UNEXPECTEDLY"; }
    health_notify_cmd
    echo "EXITCODE=$?"
  ) 2>&1
)"
grep -q 'SENT-UNEXPECTEDLY' <<< "$out" && fail "it tried to send with delivery disabled: $out"
grep -q 'mail delivery is not enabled' <<< "$out" \
  || fail "it did not say delivery is off: $out"
grep -q 'real problem' <<< "$out" || fail "the finding must still be printed: $out"
echo "  says delivery is off, prints the finding, claims nothing"

sect "a FAILED send is a failure, not a silent success"
out="$(
  (
    export PATH="$TMP/bin:$PATH" DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export RECOVERY_PACK_EMAIL_ENABLED=1 DOMUM_EMAIL=op@example.invalid
    export RECOVERY_PACK_SMTP_HOST=smtp.invalid RECOVERY_PACK_SMTP_PORT=465
    export RECOVERY_PACK_SMTP_USERNAME_FILE="$TMP/secrets/smtp_user"
    export RECOVERY_PACK_SMTP_PASSWORD_FILE="$TMP/secrets/smtp_pass"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    need_root() { :; }; load_cfg() { :; }; export_env_for_compose() { :; }
    log() { echo "LOG: $*"; }; warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 9; }
    checkup_collect_all() { checkup_add critical "real problem"; }
    smtp_send_message() { return 1; }
    health_notify_cmd
    echo "EXITCODE=$?"
  ) 2>&1
)"
grep -q 'could NOT be delivered' <<< "$out" \
  || fail "a failed send must be reported as a failure: $out"
grep -q 'health-notify: sent' <<< "$out" && fail "it claimed to have sent: $out"
echo "  reported as undelivered, never as sent"

sect "the summary carries no secret value"
run_notify 'checkup_collect_all() { checkup_add critical x; }' >/dev/null
for leak in $(cat "$TMP/secrets/smtp_user") $(cat "$TMP/secrets/smtp_pass"); do
  grep -q "$leak" "$TMP/sent.eml" && fail "a credential appeared in the message body"
done
echo "  no SMTP credential reaches the message"

sect "mutation: removing the silence gate must mail a healthy server"
MUT="$TMP/mut"
cp "$CLI" "$MUT"
python3 - "$MUT" <<'PYM'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = '''  if (( ${#CHECKUP_CRITICAL[@]} == 0 && ${#CHECKUP_ACTIONS[@]} == 0 && force == 0 )); then'''
assert s.count(a) == 1, "the silence gate moved; update this mutation"
p.write_text(s.replace(a, '''  if false; then''', 1))
PYM
grep -q '^  if false; then' "$MUT" || fail "the silence mutation was not applied"
mout="$(
  (
    export PATH="$TMP/bin:$PATH" DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export RECOVERY_PACK_EMAIL_ENABLED=1 DOMUM_EMAIL=op@example.invalid
    export RECOVERY_PACK_SMTP_HOST=smtp.invalid RECOVERY_PACK_SMTP_PORT=465
    export RECOVERY_PACK_SMTP_USERNAME_FILE="$TMP/secrets/smtp_user"
    export RECOVERY_PACK_SMTP_PASSWORD_FILE="$TMP/secrets/smtp_pass"
    # shellcheck disable=SC1090
    source "$MUT" >/dev/null 2>&1
    set +e
    need_root() { :; }; load_cfg() { :; }; export_env_for_compose() { :; }
    log() { echo "LOG: $*"; }; warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 9; }
    checkup_collect_all() { checkup_add healthy a; checkup_add healthy b; }
    smtp_send_message() { echo "SENT"; return 0; }
    health_notify_cmd
  ) 2>&1
)"
grep -q 'SENT' <<< "$mout" \
  || fail "without the gate a healthy server still sent nothing; the gate is not load-bearing"
echo "  killed: without the gate a perfectly healthy server mails every week"

# ---------------------------------------------------------------------------
sect "the alert mail is multipart, with the terminal design and text first"
# The automatic notification now uses the same renderer as the weekly report,
# in ALERT mode: the finding first, then only what is needed to act.
src="$(sed -e 's/#.*//' "$CLI")"
notify="$(awk '/^health_notify_cmd\(\) \{/,/^\}/' <<< "$src")"
grep -q 'mreport_render_text .* alert' <<< "$notify" \
  || fail "the notification does not render in alert mode: $notify"
grep -q 'mreport_build_mime' <<< "$notify" \
  || fail "the notification does not build a multipart message"
grep -q 'Content-Type: text/plain; charset="utf-8"' <<< "$notify" \
  && fail "the notification still sends a single text/plain part"
echo "  alert mode, multipart, built by the shared renderer"

sect "health-notify collects through checkup_collect_all, not a subset"
# Measured defect: health_notify_cmd called only the four EXTRACTED checks, so
# the INLINE ones -- container health and filesystem capacity among them --
# never ran for a notification. A container going UNHEALTHY or /srv/data
# filling up could appear in `checkup` and never be mailed.
grep -q 'checkup_collect_all' <<< "$notify" \
  || fail "health_notify_cmd does not use the shared collection: $notify"
for only in checkup_systemd_health checkup_btrfs_health checkup_disk_health checkup_immich_offsite; do
  grep -qE "^  $only\$" <<< "$notify" \
    && fail "health_notify_cmd still calls $only directly, which means it is
collecting a SUBSET of what checkup collects."
done
# And the collection must genuinely contain the inline checks.
collect="$(awk '/^checkup_collect_all\(\) \{/,/^\}/' <<< "$src")"
for must in 'is UNHEALTHY' 'is not running' '% full'; do
  grep -qF "$must" <<< "$collect" \
    || fail "checkup_collect_all does not contain the '$must' check, so a
notification still cannot mention it"
done
echo "  one collection; container health and capacity are in it"

sect "mutation: collecting only the four extracted checks loses container health"
MUTC="$TMP/mut-collect"
cp "$CLI" "$MUTC"
MUT_SRC="$CLI" MUT_DST="$MUTC" python3 -I -c '
import io, os
s = io.open(os.environ["MUT_SRC"], encoding="utf-8").read()
old = """  # The SAME collection checkup runs. Calling only the four extracted checks
  # here meant a notification could never mention a stopped container or a
  # filling filesystem, because those checks are inline in the collection.
  checkup_collect_all"""
assert s.count(old) == 1, s.count(old)
new = """  checkup_systemd_health
  checkup_btrfs_health
  checkup_disk_health
  checkup_immich_offsite"""
io.open(os.environ["MUT_DST"], "w", encoding="utf-8").write(s.replace(old, new, 1))
' || fail "the collection mutation could not be applied"
mnotify="$(awk '/^health_notify_cmd\(\) \{/,/^\}/' <<< "$(sed -e 's/#.*//' "$MUTC")")"
grep -q 'checkup_collect_all' <<< "$mnotify" \
  && fail "the mutation did not remove the shared collection; it proves nothing"
grep -qE '^  checkup_disk_health$' <<< "$mnotify" \
  || fail "the mutant does not call the four directly, so this is not the regression"
echo "  killed: the mutant reverts to a subset that cannot see a stopped container"

echo "PASS: health-notify smoke test"
