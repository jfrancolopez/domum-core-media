#!/usr/bin/env bash
# The terminal-style weekly report: rendering, MIME, escaping, and the two
# email behaviours.
#
# Adapted from domum-core's weekly report, and the architecture is the reason:
# THE PLAIN TEXT IS THE SOURCE and the HTML wraps its lines. So these tests
# drive the real renderers and assert on decoded MIME parts, never on the
# presence of HTML strings in the source.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP"/{state/restore-verification,state/report,data,snapshots,media,secrets,log}
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

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
ENABLE_IMMICH=1
CFG

mk_coverage() {  # $1 originals $2 in_snapshot $3 missing $4 gap $5 pend $6 unk $7 classified
  cat > "$TMP/state/restore-verification/cloud-snapshot-coverage.json" <<J
{"target":"cloud","snapshot_id":"90774d4b","recorded_at":"2026-10-21T10:21:25-04:00",
 "originals":$1,"in_snapshot":$2,"missing_from_snapshot":$3,
 "missing_backup_gap":$4,"missing_pending_next_backup":$5,"missing_timing_unknown":$6,
 "missing_classified":"$7","result":"X"}
J
}
mk_coverage 23155 23155 0 0 0 0 known

# Drive the REAL command. Externals are stubbed so nothing can reach the host;
# load_cfg is NOT stubbed, because it applies every default the chain reads --
# stubbing it left variables unbound and killed the shell before any output.
# `$1` = extra shell, `$2..` = mreport_weekly_cmd args.
drive() {
  local extra="$1"; shift
  (
    export CFG_FILE="$TMP/c.conf" DOMUM_STATE_ROOT="$TMP/state" DOMUM_DATA_ROOT="$TMP/data"
    export CAPTURE="$TMP/captured.eml"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    need_root() { :; }
    ensure_dirs() { :; }
    export_env_for_compose() { :; }
    mreport_append_history() { :; }
    backup_last_success_epoch() { printf '%s' "$(( $(date +%s) - 28800 ))"; }
    recovery_pack_state_file() { printf '%s' "$TMP/state/pack.env"; }
    btrfs_unique_roots() { printf '/srv/data\tFS-A\n'; }
    btrfs() {
      case "$1 $2" in
        "scrub status") printf 'Scrub started:    Wed Oct 21 10:24:23 2026\nError summary:    no errors found\nTotal to scrub:   215.87GiB\n' ;;
        "device stats") printf '[/dev/sda1].write_io_errs 0\n' ;;
        "filesystem df") printf 'Data, single: total=218.01GiB\nMetadata, DUP: total=1.00GiB\n' ;;
      esac
    }
    lsblk() { printf 'sda disk\n'; }
    smartctl() {
      case "$*" in
        *-i*) printf '{"model_name":"TEST SSD","power_on_time":{"hours":3568}}' ;;
        *-H*) printf '{"smart_status":{"passed":true}}' ;;
        *-A*) printf '{"temperature":{"current":37},"ata_smart_attributes":{"table":[{"name":"Wear_Leveling_Count","value":99},{"name":"X","value":100}]}}' ;;
      esac
    }
    journalctl() { return 1; }
    service_lifecycle_specs() { printf 'plex|ENABLE_PLEX|a|b|c|d|e\n'; }
    service_health_state() { printf 'nohc\n'; }
    ENABLE_PLEX=1
    # The capturing transport: the complete RFC-822 message, never sent.
    smtp_send_message() { cp "$1" "$CAPTURE"; return 0; }
    checkup_collect_all() { checkup_add healthy "all good."; }
    eval "$extra"
    set +e
    mreport_weekly_cmd "$@"
    echo "RC=$?"
  ) 2>&1
}

ACTION_STATE='checkup_collect_all() {
  checkup_add healthy "one other check passed."
  checkup_add warning "Btrfs on /srv/data has NEVER been scrubbed."
  checkup_add action "btrfs scrub start /srv/data"
}'
CRIT_STATE='checkup_collect_all() {
  checkup_add critical "Btrfs CHECKSUM failures on /srv/data: corruption_errs = 3."
  checkup_add action "btrfs device stats /srv/data"
}'
WARN_STATE='checkup_collect_all() { checkup_add warning "7 general package updates are available."; }'

# ---------------------------------------------------------------------------
sect "the four verdicts are distinct, and warnings get their own"
for spec in "::HEALTHY:\xe2\x97\x8f" "$WARN_STATE::WARNINGS (1):\xe2\x96\xb4" \
            "$ACTION_STATE::ACTION REQUIRED (1):\xe2\x96\xb2" "$CRIT_STATE::CRITICAL (1 critical, 1 action(s)):\xe2\x9c\x97"; do
  st="${spec%%::*}"; rest="${spec#*::}"; want="${rest%%:*}"; gl="$(printf '%b' "${rest##*:}")"
  out="$(drive "$st" --stdout)"
  grep -qF "Verdict: $gl $want" <<< "$out" \
    || fail "expected 'Verdict: $gl $want', got: $(grep '^Verdict' <<< "$out")"
done
echo "  HEALTHY / WARNINGS / ACTION REQUIRED / CRITICAL, each with its own glyph"

sect "the report carries the sections the operator asked for"
out="$(drive "" --stdout)"
for s in "IMMICH & DISASTER RECOVERY" BACKUPS SYSTEM "TRENDS (WEEK BY WEEK)" \
         "DRIVE HEALTH" SERVICES UPDATES "LOG ERRORS (7 DAYS)" FINDINGS "SUGGESTED ACTIONS"; do
  grep -qF "$s" <<< "$out" || fail "section missing: $s"
done
grep -qF "POWER" <<< "$out" && fail "a POWER section was emitted. There is no trustworthy
power measurement on an N100; domum-core's Pi wattage must not be copied."
echo "  all ten sections present, and POWER correctly absent"

sect "the Immich section reports RECORDED coverage, never a live query"
out="$(drive "" --stdout)"
grep -q 'Immich originals       23155' <<< "$out" || fail "recorded originals not shown: $out"
grep -q 'In off-site snapshot   23155 of 23155' <<< "$out" || fail "coverage not shown: $out"
grep -q 'Reconciled snapshot    90774d4b' <<< "$out" || fail "the snapshot is not cited: $out"
grep -qi 'Full recovery.*NOT ACHIEVED' <<< "$out" || fail "full recovery must not be claimed: $out"
echo "  counts, the snapshot they are about, and no FULL RECOVERY claim"

sect "a BACKUP GAP is shown with the critical glyph and split from pending"
mk_coverage 23160 23150 10 7 2 1 known
out="$(drive "" --stdout)"
grep -qE "BACKUP GAP +7 $(printf '\xe2\x9c\x97')" <<< "$out" || fail "the gap is not flagged: $out"
grep -q 'pending next run     2' <<< "$out" || fail "pending is not separated: $out"
grep -q 'timing unknown       1' <<< "$out" || fail "unknown is not separated: $out"
echo "  gap flagged, pending and unknown kept separate"

sect "unreadable coverage is NOT CHECKED, never a clean zero"
rm -f "$TMP/state/restore-verification/cloud-snapshot-coverage.json"
out="$(drive "" --stdout)"
grep -q 'NOT CHECKED' <<< "$out" || fail "absent evidence must say NOT CHECKED: $out"
grep -q 'Immich originals' <<< "$out" && fail "it invented a count from nothing: $out"
grep -q 'downloads nothing' <<< "$out" || fail "the remedy must state its cost: $out"
mk_coverage 23155 23155 0 0 0 0 known
echo "  NOT CHECKED, no invented count, remedy priced"

sect "the backup scope states what is NOT covered"
out="$(drive "" --stdout)"
grep -q 'NOT in that scope' <<< "$out" || fail "the scope limitation is missing: $out"
grep -qi 'media-service state' <<< "$out" || fail "it does not name what is uncovered: $out"
echo "  the five services and the image archives are named as uncovered"

sect "trends refuse to invent history from one measurement"
out="$(drive "" --stdout)"
grep -qE 'No history recorded yet|Still collecting' <<< "$out" \
  || fail "with no history it must say so, not draw a chart: $out"
grep -qE "$(printf '\xe2\x96\x81|\xe2\x96\x88')" <<< "$out" \
  && fail "it drew a sparkline with no recorded history: $out"
echo "  says it is collecting; draws nothing"

sect "a real history produces real sparklines"
{ echo 'date,disk_data_pct,mem_pct,containers_running,journal_errors,immich_originals,scrub_age_days,disk_temp_c'
  for d in 1 2 3 4 5 6 7 8; do printf '2026-10-0%s,%s,%s,11,%s,2310%s,%s,3%s\n' "$d" "$((20+d))" "$((30+d))" "$d" "$d" "$d" "$d"; done
} > "$TMP/state/report/history.csv"
out="$(drive "" --stdout)"
grep -qE "Data disk +$(printf '\xe2\x96')" <<< "$out" || fail "no sparkline from real history: $out"
grep -q 'oldest -> newest' <<< "$out" || fail "the axis is not explained: $out"
echo "  eight-point sparklines rendered from recorded rows"
rm -f "$TMP/state/report/history.csv"

# ---------------------------------------------------------------------------
sect "--html prints HTML and sends NOTHING"
rm -f "$TMP/captured.eml"
out="$(drive "" --html)"
grep -q '^<!DOCTYPE html>' <<< "$out" || fail "no doctype: $(head -1 <<< "$out")"
[[ -f "$TMP/captured.eml" ]] && fail "a preview SENT mail. Preview must never send."
echo "  doctype present, nothing sent"

sect "the HTML is email-safe by construction"
out="$(drive "" --html)"
grep -qE '<script|javascript:' <<< "$out" && fail "the HTML contains script: $out"
grep -qE 'src=|@import|url\(' <<< "$out" && fail "the HTML references a remote asset"
grep -q 'max-width:600px' <<< "$out" || fail "the 600px column is missing"
grep -q 'color-scheme" content="dark"' <<< "$out" || fail "no dark color-scheme hint"
o="$(grep -o '<div' <<< "$out" | wc -l)"; c="$(grep -o '</div>' <<< "$out" | wc -l)"
[[ "$o" == "$c" ]] || fail "unbalanced divs: $o open, $c closed"
echo "  no script, no remote assets, 600px, dark hint, balanced markup"

sect "--stdout and --dry-run send nothing either"
for m in --stdout --dry-run; do
  rm -f "$TMP/captured.eml"
  out="$(drive "" "$m")"
  [[ -f "$TMP/captured.eml" ]] && fail "$m SENT mail"
  grep -q '^RC=0$' <<< "$out" || fail "$m did not exit 0: $out"
done
echo "  neither sends"

sect "--email refuses when email is disabled, and does not send"
rm -f "$TMP/captured.eml"
out="$(drive 'RECOVERY_PACK_EMAIL_ENABLED=0' --email)"
grep -q '^RC=0$' <<< "$out" && fail "it accepted --email with email disabled: $out"
[[ -f "$TMP/captured.eml" ]] && fail "it sent mail with email disabled"
grep -qi 'preview' <<< "$out" || fail "the refusal does not point at the preview: $out"
echo "  refused, nothing sent, preview suggested"

# ---------------------------------------------------------------------------
sect "--email builds a real multipart/alternative, text part FIRST"
rm -f "$TMP/captured.eml"
out="$(drive 'RECOVERY_PACK_EMAIL_ENABLED=1' --email)"
grep -q '^RC=0$' <<< "$out" || fail "--email failed: $out"
[[ -f "$TMP/captured.eml" ]] || fail "no message was captured"
PYTHONIOENCODING=utf-8 python3 - "$TMP/captured.eml" <<'PY' || fail "MIME assertions failed"
import sys, re
from email import message_from_binary_file
# message_from_binary_file, NOT message_from_file: on a TEXT stream
# get_payload(decode=True) round-trips through raw-unicode-escape and
# manufactures \uXXXX for every box-drawing character, which made a correct
# message look broken.
with open(sys.argv[1], "rb") as fh:
    m = message_from_binary_file(fh)
assert m.get_content_type() == "multipart/alternative", m.get_content_type()
parts = m.get_payload()
assert len(parts) == 2, len(parts)
assert [p.get_content_type() for p in parts] == ["text/plain", "text/html"], "wrong order"
t = parts[0].get_payload(decode=True).decode("utf-8")
h = parts[1].get_payload(decode=True).decode("utf-8")
for p in parts:
    assert p.get_content_charset() == "utf-8", p.get_content_charset()
assert all(c in t for c in "╔╚║"), "box characters lost in the text part"
assert "──" in t, "section rules lost"
assert not re.search(r"<(div|span|table|html)", t), "the text part contains HTML tags"
assert h.lstrip().startswith("<!DOCTYPE html>"), "html part does not start with a doctype"
assert "▌" in h, "the terminal cursor glyph is missing from the HTML"
assert m["Subject"].startswith("domum-media weekly report - "), m["Subject"]
print("  multipart/alternative, text first, utf-8 both, glyphs intact")
PY

sect "the subject and the body carry the SAME verdict"
rm -f "$TMP/captured.eml"
drive "$ACTION_STATE
RECOVERY_PACK_EMAIL_ENABLED=1" --email >/dev/null
PYTHONIOENCODING=utf-8 python3 - "$TMP/captured.eml" <<'PY' || fail "subject/body verdict disagree"
import sys
from email import message_from_binary_file
with open(sys.argv[1], "rb") as fh:
    m = message_from_binary_file(fh)
subj = m["Subject"]
t = m.get_payload()[0].get_payload(decode=True).decode("utf-8")
v = [l for l in t.splitlines() if l.startswith("Verdict: ")][0]
word = v.split(" ", 2)[2]
assert word in subj, "subject %r does not carry the body verdict %r" % (subj, word)
print("  subject %r carries %r" % (subj, word))
PY

# ---------------------------------------------------------------------------
sect "dynamic text is HTML-escaped; the plain text keeps it literal"
HOSTILE='checkup_collect_all() {
  checkup_add critical "<script>alert(1)</script> & <b>x</b> \"q\" '"'"'s'"'"'"
}'
out="$(drive "$HOSTILE" --html)"
grep -q '<script>alert(1)' <<< "$out" && fail "RAW script tag reached the HTML: injection"
grep -q '&lt;script&gt;alert(1)' <<< "$out" || fail "the finding was not escaped at all: $out"
grep -q '&amp;' <<< "$out" || fail "an ampersand was not escaped"
txt="$(drive "$HOSTILE" --stdout)"
grep -q '<script>alert(1)' <<< "$txt" || fail "the text part should keep it literal: $txt"
echo "  escaped in HTML, literal in text, ampersand handled"

sect "a header value cannot inject another header"
inj="$(
  export CFG_FILE="$TMP/c.conf"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  mreport_header_safe "$(printf 'Subject\r\nBcc: attacker@evil.invalid\nX-Injected: yes')"
)"
grep -q $'\r' <<< "$inj" && fail "a CR survived into a header value"
[[ "$(wc -l <<< "$inj")" == "1" ]] || fail "a newline survived into a header value: $inj"
want='SubjectBcc: attacker@evil.invalidX-Injected: yes'
[[ "$inj" == "$want" ]] || fail "sanitisation did not simply remove CR/LF.
  expected: $want
  got:      $inj"
echo "  CR and LF stripped; the injected text is concatenated, never a new header"

sect "no credential ever reaches either MIME part"
printf 'super-secret-smtp-password\n' > "$TMP/secrets/recovery_pack_smtp_password"
printf 'smtp-user-name\n' > "$TMP/secrets/recovery_pack_smtp_username"
rm -f "$TMP/captured.eml"
drive 'RECOVERY_PACK_EMAIL_ENABLED=1' --email >/dev/null
for leak in super-secret-smtp-password smtp-user-name; do
  grep -q "$leak" "$TMP/captured.eml" && fail "a credential leaked into the message: $leak"
done
echo "  neither the SMTP username nor the password appears in the message"

sect "long and malformed dynamic text does not break the layout"
LONG="checkup_collect_all() { checkup_add warning \"$(printf 'x%.0s' $(seq 1 400))\"; checkup_add action \"$(printf 'y%.0s' $(seq 1 400))\"; }"
out="$(drive "$LONG" --html)"
grep -q '^RC=0$' <<< "$out" || fail "a 400-character finding broke rendering: $(tail -3 <<< "$out")"
o="$(grep -o '<div' <<< "$out" | wc -l)"; c="$(grep -o '</div>' <<< "$out" | wc -l)"
[[ "$o" == "$c" ]] || fail "long text unbalanced the markup: $o/$c"
grep -q 'white-space:pre-wrap' <<< "$out" || fail "nothing allows long lines to wrap"
echo "  renders, stays balanced, and wraps"

sect "a report runs no recovery work: no restic, no asset table, no media"
src="$(sed -e 's/#.*//' "$CLI")"
body="$(awk '/^mreport_render_text\(\) \{/,/^\}/' <<< "$src")"
grep -qE 'restic|immich_original_inventory|docker exec.*psql' <<< "$body" \
  && fail "the renderer reaches for recovery work. A scheduled report must not
download from Hetzner or query the asset table: $body"
echo "  reads recorded evidence and cheap local probes only"

# ---------------------------------------------------------------------------
#  Mutations on the invariants that matter. Each must make a SAFE behaviour
#  unsafe; a mutant that still behaves correctly proves nothing.
# ---------------------------------------------------------------------------
mutate() {  # $1 = old text, $2 = new text -> prints the mutant path
  local mut="$TMP/mut-$RANDOM-$$"
  MUT_OLD="$1" MUT_NEW="$2" MUT_SRC="$CLI" MUT_DST="$mut" python3 -I -c '
import io, os
s = io.open(os.environ["MUT_SRC"], encoding="utf-8").read()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
n = s.count(old)
assert n == 1, "mutation target matched %d times, refusing: %r" % (n, old[:70])
io.open(os.environ["MUT_DST"], "w", encoding="utf-8").write(s.replace(old, new, 1))
' || return 1
  printf '%s' "$mut"
}

sect "mutation: dropping the HTML escape lets a finding inject markup"
MUT="$(mutate "-e 's/</\&lt;/g'" "-e 's/@@NEVERMATCHES@@/x/'")" \
  || fail "the escape mutation could not be applied"
grep -q 'NEVERMATCHES' "$MUT" || fail "the mutation did not apply; it proves nothing"
mout="$( CLI="$MUT" drive 'checkup_collect_all() { checkup_add critical "<script>alert(1)</script>"; }' --html )"
grep -q '<script' <<< "$mout" \
  || fail "the mutant did NOT emit a raw '<', so that sed rule is not what prevents it"
real="$(drive 'checkup_collect_all() { checkup_add critical "<script>alert(1)</script>"; }' --html)"
grep -q '&lt;script' <<< "$real" || fail "the REAL renderer did not escape it"
grep -qE '<script[^"]' <<< "$real" && fail "the REAL renderer emitted a raw script tag"
echo "  killed: the mutant emits a raw '<', the real renderer emits &lt;"

sect "mutation: dropping header sanitisation forges a second header"
MUT="$(mutate "| tr -d '\r\n' | tr -d '\000'" "| cat")" \
  || fail "the header mutation could not be applied"
inj="$(
  export CFG_FILE="$TMP/c.conf"
  # shellcheck disable=SC1090
  source "$MUT" >/dev/null 2>&1
  mreport_header_safe "$(printf 'S\r\nBcc: attacker@evil.invalid')"
)"
[[ "$(wc -l <<< "$inj")" == "1" ]] \
  && fail "the mutant did not let a newline through, so sanitisation is not what stops it"
echo "  killed: without it a newline survives and a second header is forgeable"

sect "mutation: putting the HTML part first makes it the fallback"
MUT="$(mutate \
  "printf '\n--%s\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n' \"\$boundary\"" \
  "printf '\n--%s\nContent-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n' \"\$boundary\"")" \
  || fail "the ordering mutation could not be applied"
rm -f "$TMP/captured.eml"
( CLI="$MUT" drive 'RECOVERY_PACK_EMAIL_ENABLED=1' --email ) >/dev/null 2>&1
first="$(PYTHONIOENCODING=utf-8 python3 -I -c '
import sys
from email import message_from_binary_file
with open(sys.argv[1], "rb") as fh:
    m = message_from_binary_file(fh)
print([p.get_content_type() for p in m.get_payload()][0])
' "$TMP/captured.eml" 2>/dev/null || echo error)"
[[ "$first" == "text/plain" ]] \
  && fail "the mutant still put text/plain first, so the order is not what makes it the fallback"
echo "  killed: the part order is what makes plain text the fallback (mutant first part: $first)"

sect "mutation: a preview that sends is the worst possible regression"
MUT="$(mutate \
  '    stdout) cat "$text"; rm -f "$text" ;;' \
  '    stdout) cat "$text"; mreport_build_mime "x" "$text" "$text" "$text.eml"; smtp_send_message "$text.eml"; rm -f "$text" ;;')" \
  || fail "the preview mutation could not be applied"
rm -f "$TMP/captured.eml"
( CLI="$MUT" drive "" --stdout ) >/dev/null 2>&1
[[ -f "$TMP/captured.eml" ]] \
  || fail "the mutant did not send, so the preview path is not what guarantees silence"
rm -f "$TMP/captured.eml"
drive "" --stdout >/dev/null
[[ -f "$TMP/captured.eml" ]] && fail "the REAL preview sent mail"
echo "  killed: the mutant sends, the real preview does not"

echo "PASS: weekly report render smoke test"
