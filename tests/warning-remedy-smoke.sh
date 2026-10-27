#!/usr/bin/env bash
# A warning with no paired action NEVER mails.
#
# WHY IT EXISTS. health_notify_cmd's silence gate sends only when
# CHECKUP_CRITICAL or CHECKUP_ACTIONS is non-empty. That is deliberate -- it is
# what stops a weekly mail saying "3 general package updates are available".
# But seven warnings carried no remedy and were therefore invisible to the
# notifier: a container UNHEALTHY, a service down, a path filling up, unreadable
# Btrfs error counters, unreadable scrub status, unparseable scrub history, and a
# suspiciously short restic password file.
#
# A container going unhealthy produced NO notification. That is the
# HEALTHY-means-unmeasured defect one layer out: the check runs, records the
# problem, and nothing can see it.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP"/{bin,data,snapshots,state,media,secrets,log}
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

SB="$TMP/sysblock"; mkdir -p "$SB/ssdz/queue"; echo 0 > "$SB/ssdz/queue/rotational"

probe() {  # $1 = stubs, $2 = function -> flat classes
  (
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export DOMUM_SNAPSHOT_ROOT="$TMP/snapshots" DOMUM_SYSBLOCK_ROOT="$SB"
    export DOMUM_DIR="$TMP/repo"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=(); CHECKUP_ACTIONS=()
    findmnt() { printf '/dev/ssdz1[/@data]\n'; }
    eval "$1"
    "$2"
    (( ${#CHECKUP_CRITICAL[@]} )) && printf 'CRIT|%s\n' "${CHECKUP_CRITICAL[@]}"
    (( ${#CHECKUP_WARNINGS[@]} )) && printf 'WARN|%s\n' "${CHECKUP_WARNINGS[@]}"
    (( ${#CHECKUP_ACTIONS[@]} ))  && printf 'ACT|%s\n'  "${CHECKUP_ACTIONS[@]}"
    true
  ) 2>&1
}

BTRFS_FS='stat() { case "$*" in *-f*%T*) printf "btrfs\n" ;; *) command stat "$@" ;; esac; }'

# ---------------------------------------------------------------------------
sect "unreadable Btrfs error counters produce an ACTION, so they notify"
out="$(probe "$BTRFS_FS
btrfs() { return 1; }" checkup_btrfs_health)"
grep -q 'WARN|Btrfs error counters .* could not be read' <<< "$out" \
  || fail "the warning is gone: $out"
grep -q 'ACT|btrfs device stats' <<< "$out" \
  || fail "no remedy, so this never reaches the operator: $out"
grep -q 'corruption_errs' <<< "$out" || fail "the remedy does not say what to look for: $out"
echo "  warning plus a remedy naming corruption_errs"

sect "unreadable scrub status produces an ACTION"
out="$(probe "$BTRFS_FS
btrfs() { case \"\$1 \$2\" in 'device stats') printf '[/dev/sda1].write_io_errs 0\n' ;; *) return 1 ;; esac; }" checkup_btrfs_health)"
grep -q 'WARN|Btrfs scrub status .* could not be read' <<< "$out" || fail "warning gone: $out"
grep -q 'ACT|btrfs scrub status' <<< "$out" || fail "no remedy: $out"
echo "  warning plus a remedy"

sect "an unparseable scrub history produces an ACTION"
out="$(probe "$BTRFS_FS
btrfs() { case \"\$1 \$2\" in 'device stats') printf '[/dev/sda1].write_io_errs 0\n' ;; 'scrub status') printf 'UUID: x\nSomething unexpected\n' ;; esac; }" checkup_btrfs_health)"
grep -q 'WARN|Btrfs scrub history .* could not be parsed' <<< "$out" || fail "warning gone: $out"
grep -q 'ACT|btrfs scrub status -R' <<< "$out" || fail "no remedy: $out"
echo "  warning plus the raw-counter remedy"

# ---------------------------------------------------------------------------
sect "a filesystem over 90% full produces an ACTION"
# This check is inline in checkup_cmd rather than its own function, so it cannot
# be probed in isolation; the pairing is asserted on the source instead and the
# allow-list section below is what guarantees the set stays complete. The window
# is 7 lines because an explanatory comment sits between the warning and the
# remedy -- a 3-line window missed it and the assertion failed against correct
# code.
src="$(sed -e 's/#.*//' "$CLI")"
full_ctx="$(grep -A7 'is \${pcent}% full' <<< "$src")"
grep -q 'checkup_add action' <<< "$full_ctx" \
  || fail "the disk-full warning has no paired action, so a filling protected tier never mails:
$full_ctx"
grep -q 'df -h' <<< "$full_ctx" || fail "the remedy does not locate the usage: $full_ctx"
grep -qE 'rm -|cleanup .*--confirm|prune' <<< "$full_ctx" \
  && fail "the disk-full remedy deletes something. Every deletion path here is
operator-initiated by design; a remedy must locate the usage, not free it."
echo "  warning plus a remedy that locates the usage and deletes nothing"

# ---------------------------------------------------------------------------
sect "the stopped-service remedy is 'compose start', NEVER 'up -d'"
# up -d RECONCILES: it would recreate the container on whatever the image tag
# now resolves to, so a routine "start it again" would silently deploy a staged
# image. This is the single most dangerous thing a remedy could say.
src="$(sed -e 's/#.*//' "$CLI")"
stopped_ctx="$(grep -A3 'is not running' <<< "$src")"
grep -q 'compose start' <<< "$stopped_ctx" \
  || fail "the stopped-service remedy does not use compose start: $stopped_ctx"
grep -qE 'up -d' <<< "$stopped_ctx" \
  && fail "the stopped-service remedy says 'up -d'. That recreates the container on
the staged image, turning a restart into an unreviewed deployment."
echo "  compose start, and no up -d"

sect "the container remedies name the COMPOSE services, not the logical one"
# immich maps to four containers, so `docker logs immich` would fail on the one
# service where a failed healthcheck matters most.
grep -A3 'is UNHEALTHY' <<< "$src" | grep -q 'service_compose_services' \
  || fail "the unhealthy remedy uses the logical name; it would fail for immich"
grep -q 'service_compose_services' <<< "$stopped_ctx" \
  || fail "the stopped remedy uses the logical name; it would fail for immich"
echo "  both resolve the compose service list"

sect "the restic remedy does NOT suggest rotating the password, and never prints it"
pw_ctx="$(grep -A8 'looks very short' <<< "$src")"
grep -q 'checkup_add action' <<< "$pw_ctx" || fail "no remedy for a short restic password: $pw_ctx"
grep -qE 'restic key|restic forget|restic prune' <<< "$pw_ctx" \
  && fail "the remedy suggests a restic key/retention operation. Those require
explicit approval and are not routine remedies."
grep -qE 'cat |printf .*pw_file|echo .*pw_file' <<< "$pw_ctx" \
  && fail "the remedy would print the password file's CONTENTS"
echo "  checks for truncation, suggests no restic operation, prints nothing"

# ---------------------------------------------------------------------------
sect "the notifier MAILS when one of these fires -- the whole point"
# Driving the real gate: with an action recorded and none critical, it must not
# take the silent path.
mail_out="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CFG_FILE="$TMP/c.conf"
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
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  need_root() { :; }
  export_env_for_compose() { :; }
  # Stub the FOUR checks health_notify_cmd actually calls. The first version
  # stubbed a collector function that DOES NOT EXIST, so the real checks ran
  # against the HOST and this section passed only because the host happened
  # to produce an action. A stub of a function nobody calls is not a stub.
  # The COLLECTION is stubbed, not the four individual checks: health_notify_cmd
  # collects through checkup_collect_all now, so stubbing the four left the
  # real collection running against the host fixture and the notifier was
  # never silent. The case below replaces the collection itself.
  checkup_collect_all() { :; }
  smtp_send_message() { echo "MAIL SENT"; return 0; }
  # The action must be added BY a check: health_notify_cmd resets all four
  # arrays at entry, so a value seeded by the caller is wiped. Seeding it was
  # how the first version of this section silently tested nothing.
  checkup_collect_all() {
    checkup_add warning "traefik is not running."
    checkup_add action  "cd /x && docker compose start traefik"
  }
  set +e
  RECOVERY_PACK_EMAIL_ENABLED=1
  health_notify_cmd 2>&1
  echo "RC=$?"
)"
grep -q 'no mail sent' <<< "$mail_out" \
  && fail "an action recorded still took the silent path: $mail_out"
# Positive form: it must actually reach the transport. "Did not take the silent
# path" alone would be satisfied by dying somewhere in between.
grep -q 'MAIL SENT' <<< "$mail_out" \
  || fail "it did not reach the SMTP transport, so nothing was delivered: $mail_out"

# The negative control. Without it the assertion above is unfalsifiable: it
# would pass against a notifier that never prints that line at all, for any
# input. With zero actions and zero criticals the silent path MUST be taken.
silent_out="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CFG_FILE="$TMP/c.conf"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  need_root() { :; }
  export_env_for_compose() { :; }
  # The COLLECTION is stubbed, not the four individual checks: health_notify_cmd
  # collects through checkup_collect_all now, so stubbing the four left the
  # real collection running against the host fixture and the notifier was
  # never silent. The case below replaces the collection itself.
  checkup_collect_all() { :; }
  smtp_send_message() { echo "MAIL SENT"; return 0; }
  # A routine warning and NO action -- the healthy-with-noise case.
  checkup_collect_all() { checkup_add warning "3 general package updates are available."; }
  set +e
  RECOVERY_PACK_EMAIL_ENABLED=1
  health_notify_cmd 2>&1
)"
grep -q 'no mail sent' <<< "$silent_out" \
  || fail "a healthy server with only a routine WARNING did not take the silent path.
Silence is the healthy signal; this is the flood the gate exists to prevent: $silent_out"
grep -q 'MAIL SENT' <<< "$silent_out" \
  && fail "it mailed about a routine package-update warning: $silent_out"
echo "  an action mails; a routine warning alone stays silent"

sect "the ROUTINE warnings still do NOT notify -- the anti-flood contract"
# The other direction, and it is what makes the fix a classification rather than
# "make warnings mail". These four must stay silent, or the operator starts
# getting weekly mail about available package updates and stops reading it.
for phrase in 'service update candidates are waiting' 'Immich bundle candidate' \
              'security updates are available' 'general package updates are available'; do
  ctx="$(grep -A4 "$phrase" <<< "$src")"
  grep -q 'checkup_add action' <<< "$ctx" \
    && fail "'$phrase' gained a remedy, so routine activity now mails every week.
That is the flood the silence gate exists to prevent."
done
echo "  all four routine warnings remain silent"

sect "the set of non-notifying warnings is EXACTLY the four routine ones"
# A guard against a FUTURE warning being added with no remedy. It is a source
# scan, so it proves pairing rather than execution -- the behavioural assertions
# above are what prove the seven real cases actually fire. Comments are stripped
# first, because a comment quoting a warning would otherwise be counted.
mapfile -t orphans < <(python3 - "$CLI" <<'PY'
import io, sys
lines = [l.split("#")[0] if l.strip().startswith("#") else l
         for l in io.open(sys.argv[1], encoding="utf-8").read().split("\n")]
for i, l in enumerate(lines):
    if "checkup_add warning" not in l or l.strip().startswith("#"):
        continue
    if "checkup_add action" in "\n".join(lines[i+1:i+8]):
        continue
    print(l.strip()[:80])
PY
)
[[ "${#orphans[@]}" -eq 4 ]] || {
  printf '  %s\n' "${orphans[@]}"
  fail "${#orphans[@]} warnings have no remedy and therefore never mail; expected exactly 4
routine ones. A new warning without a remedy is invisible to the notifier."
}
echo "  exactly 4, all routine"

sect "mutation: removing the stopped-service remedy makes a dead service silent"
MUT="$TMP/mut"
cp "$CLI" "$MUT"
( python3 - "$CLI" "$MUT" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
old = '''                 checkup_add action "sudo domum-media compose start $(service_compose_services "$service" | tr '\\n' ' ')   # NOT 'up -d': that reconciles and would recreate on whatever the tag now resolves to" ;;'''
assert s.count(old) == 1, "mutation target not unique: %d" % s.count(old)
io.open(sys.argv[2], "w", encoding="utf-8").write(s.replace(old, '                 : ;;', 1))
PY
) || fail "the stopped-service remedy mutation could not be applied -- its
target text changed. A mutation that does not apply proves nothing, and
without this the suite failed later with a confusing orphan count."
grep -q 'is not running' "$MUT" || fail "the mutant lost the warning too; it proves nothing"
mcount="$(python3 - "$MUT" <<'PY'
import io, sys
lines = io.open(sys.argv[1], encoding="utf-8").read().split("\n")
n = 0
for i, l in enumerate(lines):
    if "checkup_add warning" not in l or l.strip().startswith("#"):
        continue
    if "checkup_add action" in "\n".join(lines[i+1:i+8]):
        continue
    n += 1
print(n)
PY
)"
[[ "$mcount" -eq 5 ]] \
  || fail "the mutation did not create an orphan warning (got $mcount, expected 5)"
echo "  killed: without the remedy a stopped service is one of 5 silent warnings"

echo "PASS: warning remedy smoke test"
