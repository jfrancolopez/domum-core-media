#!/usr/bin/env bash
set -uo pipefail

# The ENCRYPTED RECOVERY PACK is what makes every other off-site copy openable:
# the configuration, the secrets, Traefik's ACME account private key and the
# validated Uptime Kuma dump. Two commands reported on it -- `dr-status` and
# `dr-offhost-audit` -- and NEITHER is a notification path, so a pack that never
# left this machine was visible only to an operator who ran a command by hand.
#
# `pack-offhost` is the bridge, and its contract is an EXIT STATUS, because a
# wrapper asserts on behaviour and never on prose. This suite drives it and the
# `checkup` reader that consumes it.
#
# The load-bearing assertion is the NON-ANSWER: an installed binary that
# predates this subcommand dies with status 1, which is the ALARMING answer. A
# critical about the family photographs manufactured from a binary that never
# looked is worse than no check at all, so a reply that does not parse must read
# as "could not ask".
#
# Hermetic: every root is redirected into the fixture, no restic, no network,
# no production path.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

export DOMUM_DATA_ROOT="$TMP_DIR/data"
export DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$TMP_DIR/state"
export DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
export DOMUM_LOG_DIR="$TMP_DIR/log"
export SECRETS_DIR="$TMP_DIR/secrets"
export REPO_META_DIR="$TMP_DIR/state/backups"
export BACKUP_TARGETS="cloud"
mkdir -p "$DOMUM_DATA_ROOT" "$DOMUM_MEDIA_ROOT" "$DOMUM_STATE_ROOT/recovery-pack" \
         "$DOMUM_SNAPSHOT_ROOT" "$DOMUM_LOG_DIR" "$SECRETS_DIR" "$REPO_META_DIR"
PACK="$DOMUM_STATE_ROOT/recovery-pack"
export CFG_FILE="$TMP_DIR/fixture.conf"
: > "$CFG_FILE"

# ---------------------------------------------------------------------------
# The subcommand.
# ---------------------------------------------------------------------------
run_cmd() {  # $1 = setup, rest = argv -> output then "exit=N"
  local setup="$1"; shift
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    die() { echo "DIE: $*"; exit 9; }
    RECOVERY_PACK_DEST="$PACK"
    [[ -n "$setup" ]] && eval "$setup"
    do_pack_offhost "$@" 2>&1
    echo "exit=$?"
  )
}

sect "the four verdicts, and each one's exit status"
# Production's shape: delivered off-host AND inside the cloud scope. The copy
# inside the repository is redundancy while the email route exists.
o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=1
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$PACK"' --json)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "offhost" ]] \
  || fail "a delivered pack is not reported as reaching off-host: $o"
[[ "$(jq -r '.in_backup_set' <<< "${o%$'\n'exit=*}")" == "yes" ]] \
  || fail "the in-set component is wrong for a pack under the target's root: $o"
grep -q 'exit=0$' <<< "$o" || fail "a delivered pack did not exit 0: $o"
echo "  delivered + in the scope -> offhost, exit 0"

# The polarity correction: being outside the backup scope is not a defect. The
# first version of this check reported it as a risk, which contradicted
# dr-offhost-audit calling the pack being INSIDE the backup circular.
o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=1
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$DOMUM_DATA_ROOT"' --json)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "offhost" ]] \
  || fail "a delivered pack outside the backup scope was not reported as safe,
which asserts a defect about the designed route: $o"
[[ "$(jq -r '.in_backup_set' <<< "${o%$'\n'exit=*}")" == "no" ]] \
  || fail "the in-set component is wrong: $o"
grep -q 'exit=0$' <<< "$o" || fail "it did not exit 0: $o"
echo "  delivered + outside the scope -> offhost, exit 0"

o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=0
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$PACK"' --json)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "circular" ]] \
  || fail "a pack whose only off-host copy is inside the repository it opens was
not reported as circular: $o"
grep -q 'exit=1$' <<< "$o" || fail "circular did not exit 1: $o"
echo "  not delivered + in the scope -> circular, exit 1"

o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=0
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$DOMUM_DATA_ROOT"' --json)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "none" ]] \
  || fail "a pack that never leaves the host was not reported: $o"
grep -q 'exit=1$' <<< "$o" || fail "none did not exit 1: $o"
echo "  not delivered + outside the scope -> none, exit 1"

sect "an unread setting is not a setting of 0"
# The production config is 0600 root, so an unprivileged caller reads the
# DEFAULT of 0 -- and reporting that as "the pack never leaves" would be a
# confident wrong answer from a command that could not see.
o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=1; CFG_FILE="$TMP_DIR/absent.conf"' --json)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "unknown" ]] \
  || fail "an unreadable config did not produce UNKNOWN: $o"
[[ "$(jq -r '.delivery' <<< "${o%$'\n'exit=*}")" == "unknown" ]] \
  || fail "the delivery component should be unknown, not a default: $o"
grep -q 'exit=2$' <<< "$o" || fail "unknown must exit 2, never 0 or 1: $o"
echo "  unreadable config -> unknown, exit 2"

sect "the human report never claims proven delivery"
o="$(run_cmd 'RECOVERY_PACK_EMAIL_ENABLED=1
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$PACK"')"
grep -q 'not the same as proven' <<< "$o" \
  || fail "the report does not distinguish configured from delivered: $o"
grep -q 'age PRIVATE key' <<< "$o" \
  || fail "the report omits the single point of failure: $o"
echo "  configured is stated as configured, and the age key is named"

sect "a typo must not widen the question, and must not be answered"
o="$(run_cmd '' bogus-target --json)"
grep -q 'DIE: Unknown backup target: bogus-target' <<< "$o" \
  || fail "an unknown target was not refused: $o"
o="$(run_cmd '' --nope)"
grep -q 'DIE: Unknown option' <<< "$o" || fail "an unknown option was not refused: $o"
echo "  an unknown target and an unknown option both die"

sect "it is reachable through the real argv dispatcher"
# A function that works when called directly but is unreachable through main is
# the defect the capabilities audit exists for.
o="$(
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
  need_root() { :; }; load_cfg() { :; }
  export_compose_env() { :; }; ensure_dirs() { :; }
  set +e
  RECOVERY_PACK_DEST="$PACK"
  RECOVERY_PACK_EMAIL_ENABLED=1
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$PACK"
  main pack-offhost --json 2>&1
  echo "exit=$?"
)"
[[ "$(jq -r '.verdict' <<< "${o%$'\n'exit=*}")" == "offhost" ]] \
  || fail "the dispatcher does not reach do_pack_offhost: $o"
grep -q 'exit=0$' <<< "$o" || fail "the dispatcher lost the exit status: $o"
echo "  main pack-offhost --json answers and preserves the status"

sect "it reads configuration only -- no restic, no network, no docker"
body="$(sed -n '/^do_pack_offhost() {$/,/^}$/p' "$REPO_ROOT/bin/domum-media-backup" | sed 's/#.*//')"
[[ -n "$body" ]] || fail "the function body could not be extracted"
for forbidden in restic docker curl ssh sftp; do
  grep -qw "$forbidden" <<< "$body" \
    && fail "do_pack_offhost invokes $forbidden; a report must do no recovery work"
done
echo "  nothing in it can leave the host"

sect "recovery_pack_coverage is the ONE implementation of the in-set question"
# dr-offhost-audit carried its own copy that read the GLOBAL
# BACKUP_INCLUDE_PATHS while the cloud target's scope is three narrow roots --
# so on production it answered the OPPOSITE of the truth. Comments are stripped
# first, because the comment recording that mistake names the global.
code="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media-backup")"
n="$(grep -c 'dr_path_configured "\$(recovery_pack_dest)"' <<< "$code" || true)"
[[ "$n" == "1" ]] \
  || fail "the pack-in-set comparison appears $n times in code; it must be one
implementation: $(grep -n 'recovery_pack_dest' <<< "$code")"
# Capture first, then count -- `grep -c … | grep -q` is the banned shape, and
# the audit found this line before CI did.
consumers="$(grep -c 'recovery_pack_coverage ' <<< "$code" || true)"
[[ "${consumers:-0}" -ge 3 ]] \
  || fail "only $consumers reader(s) consume recovery_pack_coverage; the risk
block, the off-host audit's circularity row and pack-offhost must all use it"
echo "  one comparison, consumed by every reader"

# ---------------------------------------------------------------------------
# The checkup reader.
# ---------------------------------------------------------------------------
# A stub standing in for the backup CLI. DOMUM_BACKUP_CLI exists so a fixture
# can redirect it: every root a test uses must be redirected into it.
make_cli() {  # $1 = stdout, $2 = exit status
  local out="$1" rc="$2"
  cat > "$TMP_DIR/stub-cli" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$out'
exit $rc
STUB
  chmod +x "$TMP_DIR/stub-cli"
}

run_checkup() {  # $1 = optional extra shell -> "LEVEL|text" lines
  local extra="${1:-}"
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media" >/dev/null 2>&1
    set +e
    CFG_FILE="$TMP_DIR/fixture.conf"
    CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=()
    CHECKUP_ACTIONS=(); CHECKUP_ADVICE=()
    [[ -n "$extra" ]] && eval "$extra"
    checkup_recovery_pack_offhost
    local t
    for t in ${CHECKUP_CRITICAL[@]+"${CHECKUP_CRITICAL[@]}"}; do :; done
    printf 'CRITICAL|%s\n' ${CHECKUP_CRITICAL[@]+"${CHECKUP_CRITICAL[@]}"}
    printf 'WARNING|%s\n'  ${CHECKUP_WARNINGS[@]+"${CHECKUP_WARNINGS[@]}"}
    printf 'HEALTHY|%s\n'  ${CHECKUP_HEALTHY[@]+"${CHECKUP_HEALTHY[@]}"}
    printf 'ACTION|%s\n'   ${CHECKUP_ACTIONS[@]+"${CHECKUP_ACTIONS[@]}"}
    printf 'ADVICE|%s\n'   ${CHECKUP_ADVICE[@]+"${CHECKUP_ADVICE[@]}"}
  )
}
export DOMUM_BACKUP_CLI="$TMP_DIR/stub-cli"

sect "checkup: a delivered pack is healthy and raises nothing"
make_cli '{"verdict":"offhost","delivery":"enabled","in_backup_set":"yes"}' 0
o="$(run_checkup)"
grep -q '^HEALTHY|.*delivered off-host' <<< "$o" || fail "not reported healthy: $o"
grep -q '^CRITICAL|.' <<< "$o" && fail "a healthy pack raised a critical: $o"
grep -q '^ACTION|.' <<< "$o" && fail "a healthy pack raised an action, which mails: $o"
echo "  healthy, and nothing escalates"

sect "checkup: circular and none are CRITICAL and carry an action, so they mail"
# Only CHECKUP_CRITICAL and CHECKUP_ACTIONS pass the notifier's silence gate.
# This is the whole point of the bridge: the finding existed in two commands and
# could never be mailed from either.
make_cli '{"verdict":"circular","delivery":"disabled","in_backup_set":"yes"}' 1
o="$(run_checkup)"
grep -q '^CRITICAL|.*credentials in order to fetch' <<< "$o" \
  || fail "circular is not critical, or does not name the trap: $o"
grep -q '^ACTION|.*RECOVERY_PACK_EMAIL_ENABLED=1' <<< "$o" \
  || fail "circular carries no action, so it would never mail: $o"
make_cli '{"verdict":"none","delivery":"disabled","in_backup_set":"no"}' 1
o="$(run_checkup)"
grep -q '^CRITICAL|.*never leaves this host' <<< "$o" \
  || fail "a pack that never leaves is not critical: $o"
grep -q '^ACTION|.*RECOVERY_PACK_EMAIL_ENABLED=1' <<< "$o" \
  || fail "it carries no action: $o"
echo "  both are critical with an action -- they reach the notifier"

sect "checkup: UNKNOWN is a warning with advice, and never a pass"
# "I could not check it" is not "it is broken", and it is not healthy either.
# A warning does not mail, which is right for a configuration that could not be
# read; what must not happen is a clean line.
make_cli '{"verdict":"unknown","delivery":"unknown","in_backup_set":"unknown"}' 2
o="$(run_checkup)"
grep -q '^WARNING|.*UNKNOWN' <<< "$o" || fail "unknown was not a warning: $o"
grep -q '^ADVICE|.' <<< "$o" || fail "the warning carries no remedy at all: $o"
grep -q '^HEALTHY|.' <<< "$o" && fail "an unreadable configuration produced a healthy line: $o"
grep -q '^ACTION|.' <<< "$o" && fail "unknown escalated to an action: $o"
echo "  warning + advice, no healthy line, no escalation"

sect "A BINARY THAT NEVER LOOKED MUST NOT PRODUCE A CRITICAL"
# The load-bearing case. An installed binary predating `pack-offhost` dies with
# a usage error and status 1 -- and 1 is the alarming answer. A critical about
# the family photographs, manufactured from a command that never ran, is worse
# than no check: it is the cry-wolf failure in the one path whose value is that
# silence means something.
make_cli 'ERROR: Unknown command: pack-offhost' 1
o="$(run_checkup)"
grep -q '^CRITICAL|.' <<< "$o" \
  && fail "an older binary's usage error was read as a finding about the pack: $o"
grep -q '^WARNING|.*could not be checked' <<< "$o" \
  || fail "a non-answer was not reported as a non-answer: $o"
grep -q '^ADVICE|.*predates this check' <<< "$o" \
  || fail "the advice does not say the installed binary may be too old: $o"
echo "  usage error -> could not ask, never a critical"

sect "and so must a reply with a verdict this reader has not been taught"
make_cli '{"verdict":"brand-new-word"}' 0
o="$(run_checkup)"
grep -q '^CRITICAL|.' <<< "$o" && fail "an unknown verdict word produced a critical: $o"
grep -q '^HEALTHY|.' <<< "$o" && fail "an unknown verdict word produced a healthy line: $o"
grep -q '^WARNING|.' <<< "$o" || fail "an unknown verdict word was silently dropped: $o"
echo "  an unknown verdict is neither a yes nor a no"

sect "an absent backup CLI is reported, not assumed"
o="$(run_checkup "DOMUM_BACKUP_CLI='$TMP_DIR/no-such-cli'")"
grep -q '^WARNING|.*not executable' <<< "$o" || fail "an absent CLI was not reported: $o"
grep -q '^CRITICAL|.' <<< "$o" && fail "an absent CLI produced a critical: $o"
echo "  absent CLI -> warning naming the path"

sect "MUTATION: classifying on the exit status alone must invent a critical"
# This is the assertion the whole design rests on. Reading the status without
# requiring the JSON makes an older binary's usage error -- exit 1 -- into
# "the pack never leaves this host".
MUT="$TMP_DIR/mut-media"
cp "$REPO_ROOT/bin/domum-media" "$MUT"
cat > "$TMP_DIR/mut.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''  verdict="$(jq -r '.verdict // empty' <<< "$json_line" 2>/dev/null || true)"'''
new = '''  verdict="$(jq -r '.verdict // empty' <<< "$json_line" 2>/dev/null || true)"
  case "$rc" in 0) verdict=offhost ;; 1) verdict=none ;; *) verdict=unknown ;; esac'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP_DIR/mut.py" "$MUT" ) || fail "the mutation did not apply"
grep -q 'case "$rc" in 0) verdict=offhost' "$MUT" || fail "the mutation is not in the file"
make_cli 'ERROR: Unknown command: pack-offhost' 1
mout="$(
  # shellcheck disable=SC1090
  source "$MUT" >/dev/null 2>&1
  set +e
  CFG_FILE="$TMP_DIR/fixture.conf"
  CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=()
  CHECKUP_ACTIONS=(); CHECKUP_ADVICE=()
  checkup_recovery_pack_offhost
  printf 'CRITICAL|%s\n' ${CHECKUP_CRITICAL[@]+"${CHECKUP_CRITICAL[@]}"}
)"
grep -q '^CRITICAL|.*never leaves this host' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the JSON requirement an
older binary's usage error must become a critical about the pack"
echo "  killed: status-only classification turns a usage error into a critical"

sect "MUTATION: folding the non-answer into critical must make it mail"
MUT2="$TMP_DIR/mut-media-2"
cp "$REPO_ROOT/bin/domum-media" "$MUT2"
cat > "$TMP_DIR/mut2.py" <<'PYMUT2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''      checkup_add warning "Whether the encrypted recovery pack can leave this host could not be checked: $(basename "$cli") pack-offhost did not answer (exit $rc)."'''
new = '''      checkup_add critical "Whether the encrypted recovery pack can leave this host could not be checked: $(basename "$cli") pack-offhost did not answer (exit $rc)."'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT2
( python3 -I "$TMP_DIR/mut2.py" "$MUT2" ) || fail "the second mutation did not apply"
make_cli 'ERROR: Unknown command: pack-offhost' 1
mout="$(
  # shellcheck disable=SC1090
  source "$MUT2" >/dev/null 2>&1
  set +e
  CFG_FILE="$TMP_DIR/fixture.conf"
  CHECKUP_CRITICAL=(); CHECKUP_WARNINGS=(); CHECKUP_HEALTHY=()
  CHECKUP_ACTIONS=(); CHECKUP_ADVICE=()
  checkup_recovery_pack_offhost
  printf 'CRITICAL|%s\n' ${CHECKUP_CRITICAL[@]+"${CHECKUP_CRITICAL[@]}"}
)"
grep -q '^CRITICAL|.*could not be checked' <<< "$mout" \
  || fail "the second mutation changed no ANSWER -- a non-answer promoted to
critical must start mailing"
echo "  killed: a non-answer promoted to critical would mail every week"

sect "the reader is wired into the one collection"
# checkup, health-notify and report weekly all collect through
# checkup_collect_all. A check registered anywhere else is a check that one of
# the three cannot see -- the gap that made the notifier run a four-check
# subset while checkup looked complete.
collect="$(sed -n '/^checkup_collect_all() {$/,/^}$/p' "$REPO_ROOT/bin/domum-media")"
grep -q 'checkup_recovery_pack_offhost' <<< "$collect" \
  || fail "checkup_recovery_pack_offhost is not called by checkup_collect_all"
echo "  checkup, health-notify and the weekly report all see it"

echo "PASS: pack-offhost-bridge-smoke"
