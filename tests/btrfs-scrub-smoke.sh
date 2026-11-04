#!/usr/bin/env bash
# `storage scrub`, driven against a recording btrfs stub.
#
# The contract this suite pins:
#   - ONE scrub per filesystem, however many roots live on it;
#   - `-B` is always passed, or the unit would go green without reading a block;
#   - exit 3 (uncorrectable errors) is propagated, not flattened to a warning;
#   - "Error summary: no errors found" is printed for a scrub that NEVER RAN and
#     must never be reported as clean.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# BOTH roots must exist, or btrfs_unique_roots skips the second and every dedup
# assertion below passes for the wrong reason.
mkdir -p "$TMP/data" "$TMP/snapshots"

NEVER='UUID:             211e06b3-6aaf-40d8-8646-9361b8399eb2
        no stats available
Total to scrub:   215.87GiB
Error summary:    no errors found'

# $1 = extra shell (stubs), $2 = function + args. Prints argv log then output.
# need_root and load_cfg are replaced deliberately: this suite is about the
# scrub logic, and the two roots are exported so nothing the function reads is
# left unbound -- an unbound variable under `set -u` would kill the shell before
# a single assertion, which is how a blank result once read as a pass.
drive() {
  (
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
    export BTRFS_LOG="$TMP/argv.log"
    : > "$BTRFS_LOG"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    need_root() { :; }
    load_cfg()  { :; }
    stat() { case "$*" in *-f*%T*) printf 'btrfs\n' ;; *) command stat "$@" ;; esac; }
    findmnt() {
      case "$*" in
        *"$TMP/data"*)      printf 'FS-A\n' ;;
        *"$TMP/snapshots"*) printf "${SNAP_FS:-FS-A}\n" ;;
        *) printf '/dev/sda1[/@x]\n' ;;
      esac
    }
    eval "$1"
    set +e
    eval "$2"
    echo "RC=$?"
    echo "--- argv ---"
    cat "$BTRFS_LOG"
  ) 2>&1
}

CLEAN='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "Scrub started:    Mon Oct 20 03:00:00 2026\nError summary:    no errors found\n" ;; "scrub start") return 0 ;; esac; }'

# ---------------------------------------------------------------------------
sect "two roots on ONE filesystem are scrubbed ONCE"
out="$(drive "$CLEAN" 'storage_scrub_start')"
n="$(grep -c '^scrub start' <<< "$out")"
[[ "$n" == "1" ]] || fail "one filesystem produced $n scrub starts:
$out"
grep -q 'scrubbed 1 filesystem' <<< "$out" || fail "it did not report one filesystem: $out"
grep -q '^RC=0$' <<< "$out" || fail "a clean scrub must exit 0: $out"
echo "  one scrub, one filesystem, exit 0"

sect "two roots on DIFFERENT filesystems are BOTH scrubbed"
# The other direction of the dedup. Without this, the single-scrub assertion
# above is indistinguishable from never having looked at the second root.
out="$(SNAP_FS=FS-B drive "$CLEAN" 'storage_scrub_start')"
n="$(grep -c '^scrub start' <<< "$out")"
[[ "$n" == "2" ]] || fail "two filesystems produced $n scrub starts: $out"
grep -q 'scrubbed 2 filesystem' <<< "$out" || fail "it did not report two: $out"
echo "  both scrubbed when the UUIDs differ"

sect "-B is ALWAYS passed, or the unit reports success without reading anything"
out="$(drive "$CLEAN" 'storage_scrub_start')"
grep -qE '^scrub start .*-B' <<< "$out" \
  || fail "scrub start was invoked without -B; a oneshot unit would go green immediately: $out"
echo "  -B present"

sect "--limit is passed when given, and ABSENT when not"
out="$(drive "$CLEAN" 'storage_scrub_start --limit 150M')"
grep -qE '^scrub start .*--limit 150M' <<< "$out" || fail "--limit was not forwarded: $out"
out="$(drive "$CLEAN" 'storage_scrub_start')"
grep -q -- '--limit' <<< "$(grep '^scrub start' <<< "$out")" \
  && fail "an unlimited run still passed --limit: $out"
echo "  forwarded when asked, omitted when not"

sect "--limit with no value is refused rather than silently dropped"
out="$(drive "$CLEAN" 'storage_scrub_start --limit')"
grep -q '^RC=0$' <<< "$out" && fail "a bare --limit was accepted: $out"
grep -qi 'needs a size' <<< "$out" || fail "the refusal does not say what is wrong: $out"
echo "  refused, with the reason"

# ---------------------------------------------------------------------------
sect "exit 3 (UNCORRECTABLE errors) is PROPAGATED, not flattened to a warning"
# This is the whole point: a scrub that found corruption must fail the unit, so
# checkup_systemd_health escalates it and health-notify mails. "Warn and
# continue" is not a safety mechanism.
BAD='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "Scrub started:    Mon Oct 20 03:00:00 2026\n" ;; "scrub start") return 3 ;; esac; }'
out="$(drive "$BAD" 'storage_scrub_start')"
grep -q '^RC=3$' <<< "$out" || fail "uncorrectable errors must exit 3: $out"
grep -q 'UNCORRECTABLE ERRORS FOUND' <<< "$out" || fail "the finding is not named: $out"
grep -q 'scrub status -R' <<< "$out" || fail "it does not say how to capture the evidence: $out"
grep -q 'csum failed' <<< "$out" || fail "it does not point at the kernel log that names the file: $out"
grep -qi 'do NOT attempt a repair' <<< "$out" || fail "it does not warn against repairing: $out"
echo "  exit 3, named, with the capture commands and no repair advice"

sect "a scrub that could not run exits 1, distinctly from finding errors"
ERR='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "Scrub started:    Mon Oct 20 03:00:00 2026\n" ;; "scrub start") return 1 ;; esac; }'
out="$(drive "$ERR" 'storage_scrub_start')"
grep -q '^RC=1$' <<< "$out" || fail "a failed scrub must exit 1, not 3: $out"
grep -q 'scrub FAILED' <<< "$out" || fail "the failure is not reported: $out"
echo "  exit 1, and not confused with exit 3"

sect "the WORST result across filesystems governs"
# One clean, one with errors, must still exit 3 -- a clean filesystem must never
# mask corruption on another.
MIX='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in
  "scrub status") printf "Scrub started:    Mon Oct 20 03:00:00 2026\n" ;;
  "scrub start") case "$*" in *snapshots*) return 3 ;; *) return 0 ;; esac ;;
esac; }'
out="$(SNAP_FS=FS-B drive "$MIX" 'storage_scrub_start')"
grep -q '^RC=3$' <<< "$out" || fail "a clean filesystem masked corruption on another: $out"
grep -q 'worst result 3' <<< "$out" || fail "it did not report the worst result: $out"
echo "  one clean plus one corrupt still exits 3"

# ---------------------------------------------------------------------------
sect "status: NEVER SCRUBBED is reported, and 'no errors found' is NOT clean"
# btrfs prints "Error summary: no errors found" for a scrub that never ran.
# Reading that as a clean result is how a filesystem with nothing looking for
# corruption reports as healthy.
NEV="btrfs() { printf '%s\n' \"\$*\" >> \"\$BTRFS_LOG\"; case \"\$1 \$2\" in 'scrub status') printf '%s\n' '$NEVER' ;; esac; }"
out="$(drive "$NEV" 'storage_scrub_status')"
grep -q 'NEVER SCRUBBED' <<< "$out" || fail "a never-scrubbed filesystem was not flagged: $out"
grep -q 'no errors found' <<< "$out" && fail "it echoed 'no errors found' for a scrub that never ran: $out"
grep -qE 'first run.*~10 min.*215\.87GiB' <<< "$out" \
  || fail "status does not quote the measured size and derived duration: $out"
grep -q 'storage scrub start' <<< "$out" || fail "no remedy named: $out"
grep -q '^RC=0$' <<< "$out" || fail "status reports only and must exit 0: $out"
echo "  flagged, estimated, remedy named, and 'no errors found' withheld"

sect "status: an unreadable scrub status is UNKNOWN, never healthy"
NOST='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; return 1; }'
out="$(drive "$NOST" 'storage_scrub_status')"
grep -q 'UNKNOWN' <<< "$out" || fail "an unreadable status must be UNKNOWN: $out"
grep -qi 'clean\|healthy' <<< "$out" && fail "an unreadable status read as healthy: $out"
echo "  UNKNOWN, not healthy"

sect "no Btrfs filesystem at all is refused, not reported as success"
out="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  need_root() { :; }; load_cfg() { :; }
  stat() { case "$*" in *-f*%T*) printf 'ext4\n' ;; *) command stat "$@" ;; esac; }
  set +e
  storage_scrub_start 2>&1
  echo "RC=$?"
)"
grep -q '^RC=0$' <<< "$out" && fail "it reported success having scrubbed nothing: $out"
grep -qi 'no btrfs filesystem' <<< "$out" || fail "the refusal does not say why: $out"
echo "  refused -- scrubbing nothing is not a clean scrub"

# ---------------------------------------------------------------------------
sect "mutation: dropping -B lets the unit report success without waiting"
MUT="$TMP/mut-b"
cp "$CLI" "$MUT"
python3 - "$CLI" "$MUT" <<'PY'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()
old = 'scrub_out="$(btrfs scrub start -B ${limit:+--limit "$limit"} "$root" 2>&1)" || rc=$?'
assert s.count(old) == 1, "mutation target not unique: %d" % s.count(old)
s = s.replace(old, 'scrub_out="$(btrfs scrub start ${limit:+--limit "$limit"} "$root" 2>&1)" || rc=$?', 1)
io.open(dst, "w", encoding="utf-8").write(s)
PY
grep -q 'btrfs scrub start \${limit' "$MUT" || fail "the -B mutation was not applied; it proves nothing"
mout="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots" BTRFS_LOG="$TMP/mut.log"
  : > "$BTRFS_LOG"
  # shellcheck disable=SC1090
  source "$MUT" >/dev/null 2>&1
  need_root() { :; }; load_cfg() { :; }
  stat() { case "$*" in *-f*%T*) printf 'btrfs\n' ;; *) command stat "$@" ;; esac; }
  findmnt() { printf 'FS-A\n'; }
  btrfs() { printf '%s\n' "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "Scrub started: x\n" ;; "scrub start") return 0 ;; esac; }
  set +e
  storage_scrub_start >/dev/null 2>&1
  grep '^scrub start' "$BTRFS_LOG"
)"
grep -qE -- '-B' <<< "$mout" && fail "the mutant still passed -B: $mout"
echo "  killed: without -B the invocation does not block ($mout)"

# ---------------------------------------------------------------------------
sect "a scrub ALREADY RUNNING is SKIPPED, and does not fail the unit"
# btrfs refuses to start a second scrub on the same filesystem, so without this
# the error landed in the generic branch, reported "scrub FAILED", and failed
# the oneshot unit -- which `checkup_systemd_health` reports as CRITICAL and
# `health-notify` mails. The monthly timer firing while a manual scrub is still
# going is an entirely normal condition, and mailing a critical for it is the
# false-alarm defect this project keeps correcting.
RUNNING='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "UUID:             abc\nScrub started:    Mon Oct 20 03:00:00 2026\nStatus:           running\n" ;; "scrub start") return 0 ;; esac; }'
out="$(drive "$RUNNING" 'storage_scrub_start')"
grep -q 'SKIPPED' <<< "$out" || fail "a running scrub was not reported as skipped: $out"
grep -q '^RC=0$' <<< "$out" || fail "an already-running scrub must not fail the unit: $out"
n="$(grep -c '^scrub start -B' <<< "$out" || true)"
[[ "$n" == "0" ]] \
  || fail "it started a second scrub on a filesystem already being scrubbed ($n): $out"
echo "  skipped, no second scrub started, exit 0"

sect "the SUMMARY must not say 'clean' about a filesystem it skipped"
# HEALTHY must not mean UNMEASURED: a skipped filesystem makes no claim, and
# the summary narrows rather than hiding the skip.
grep -q 'already running' <<< "$out" || fail "the summary does not say what was skipped: $out"
grep -qE 'scrubbed 1 filesystem\(s\); worst result' <<< "$out" \
  && fail "it reported a plain 'scrubbed N' summary for a run that scrubbed
nothing -- that reads as a clean pass: $out"
grep -q 'make no claim here' <<< "$out" \
  || fail "the summary does not state that the skipped filesystem is unproven: $out"
echo "  the skip is counted and the claim narrowed"

sect "a scrub that STARTS between the check and the call is still skipped"
# The status check closes the common case; btrfs's own refusal closes the race.
# Anything NEITHER recognises stays a failure, because an unrecognised error
# genuinely may be one.
RACE='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "UUID: abc\nStatus:           finished\n" ;; "scrub start") printf "ERROR: scrub is already running\n" >&2; return 1 ;; esac; }'
out="$(drive "$RACE" 'storage_scrub_start')"
grep -q 'SKIPPED' <<< "$out" || fail "btrfs's own 'already running' error was not recognised: $out"
grep -q '^RC=0$' <<< "$out" || fail "the race case must not fail the unit: $out"
echo "  recognised from btrfs's own error, exit 0"

sect "an UNRECOGNISED failure is still a failure"
OTHER='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "UUID: abc\nStatus:           finished\n" ;; "scrub start") printf "ERROR: cannot open device\n" >&2; return 1 ;; esac; }'
out="$(drive "$OTHER" 'storage_scrub_start')"
grep -q 'scrub FAILED' <<< "$out" \
  || fail "an unrecognised error was not reported as a failure -- the skip must
not become a blanket excuse for any non-zero exit: $out"
grep -q '^RC=1$' <<< "$out" || fail "an unrecognised failure must exit 1: $out"
grep -q 'SKIPPED' <<< "$out" && fail "it called an unrecognised error a skip: $out"
echo "  reported as a failure, exit 1"

sect "an UNREADABLE scrub status is not read as 'not running'"
# `btrfs scrub status` needs privilege. If it cannot be read the status check
# must abstain, leaving btrfs's own refusal as the control -- not assume the
# filesystem is idle and then report a confident failure.
[[ "$(drive 'btrfs() { return 1; }' "btrfs_scrub_running '$TMP/data'")" == *unknown* ]] \
  || fail "an unreadable scrub status did not report 'unknown'"
[[ "$(drive "$RUNNING" "btrfs_scrub_running '$TMP/data'")" == *running* ]] \
  || fail "a running scrub was not detected from the Status field"
[[ "$(drive "$CLEAN" "btrfs_scrub_running '$TMP/data'")" == *no* ]] \
  || fail "a finished/never-run scrub was not reported as not running"
# The older wording this host actually prints for a never-scrubbed filesystem.
NOSTATS='btrfs() { case "$1 $2" in "scrub status") printf "no stats available\n" ;; esac; }'
[[ "$(drive "$NOSTATS" "btrfs_scrub_running '$TMP/data'")" == *no* ]] \
  || fail "'no stats available' -- a filesystem never scrubbed -- was not read as not running"
echo "  unknown / running / no, and the no-stats wording handled"

sect "MUTATION: without the running check it starts a second scrub"
MUT2="$TMP/mut-dup"
cp "$CLI" "$MUT2"
cat > "$TMP/mutdup.py" <<'PYMUT'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()
old = '    if [[ "$(btrfs_scrub_running "$root")" == "running" ]]; then'
new = '    if [[ "$root" != "$root" ]]; then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP/mutdup.py" "$CLI" "$MUT2" ) || fail "the duplicate-run mutation did not apply"
mout="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots" BTRFS_LOG="$TMP/mutdup.log"
  : > "$BTRFS_LOG"
  # shellcheck disable=SC1090
  source "$MUT2" >/dev/null 2>&1
  need_root() { :; }; load_cfg() { :; }
  stat() { case "$*" in *-f*%T*) printf 'btrfs\n' ;; *) command stat "$@" ;; esac; }
  findmnt() { printf 'FS-A\n'; }
  btrfs() { printf '%s\n' "$*" >> "$BTRFS_LOG"; case "$1 $2" in "scrub status") printf "UUID: abc\nStatus:           running\n" ;; "scrub start") return 0 ;; esac; }
  set +e
  storage_scrub_start >/dev/null 2>&1
  grep -c '^scrub start -B' "$BTRFS_LOG" || true
)"
[[ "$mout" == "1" ]] \
  || fail "the mutation changed no ANSWER -- with the running check neutralised a
scrub must actually be started on a filesystem already being scrubbed (got '$mout')"
echo "  killed: without the check, a second scrub is started"

sect "the scrub does NOT claim to be read-only, because it is not"
# The implementation does not pass -r, and btrfs-scrub(8) says a read-write
# scrub repairs damage from a replica. Metadata here is DUP, so a scrub WRITES.
# "read-only" appeared in the runtime message, two checkup remedies, the unit
# Description, the function header and five places in the plan -- including
# "it never writes ... and cannot be the cause of corruption". A report that
# describes an operation as something it is not is the defect this repository
# exists to correct.
out="$(drive "$CLEAN" 'storage_scrub_start')"
grep -qi 'read-only' <<< "$out" \
  && fail "the scrub still describes itself as read-only. It does not pass -r,
so on any replicated profile it repairs by writing: $out"
grep -q 'READ-WRITE' <<< "$out" || fail "it does not say it is read-write: $out"
grep -q 'not passed -r' <<< "$out" || fail "it does not say -r is absent: $out"
echo "  says READ-WRITE and that -r is not passed"

sect "it READS the profiles rather than asserting this host's"
# The first version of the message hardcoded "Metadata is DUP here, Data is
# 'single'". That is THIS filesystem's layout baked into generic code -- the
# stale-assertion mistake. A filesystem with `-d dup` repairs data too.
PROF='btrfs() { printf "%s\n" "$*" >> "$BTRFS_LOG"; case "$1 $2" in
  "scrub status") printf "Scrub started:    Mon Oct 20 03:00:00 2026\nError summary:    no errors found\n" ;;
  "filesystem df") printf "Data, single: total=218.01GiB, used=215.26GiB\nMetadata, DUP: total=1.00GiB, used=313.98MiB\n" ;;
  "scrub start") return 0 ;;
esac; }'
out="$(drive "$PROF" 'storage_scrub_start')"
grep -q 'filesystem df' <<< "$out" || fail "it never asked for the profiles: $out"
grep -qE 'Data: single' <<< "$out" || fail "it did not print the real data profile: $out"
grep -qE 'Metadata: DUP' <<< "$out" || fail "it did not print the real metadata profile: $out"
grep -q "replicated profile" <<< "$out" || fail "it does not say which kind is repairable: $out"
echo "  prints Data: single and Metadata: DUP, read from the filesystem"

sect "profiles that cannot be read are UNKNOWN, not guessed"
# Saying "metadata is DUP" when the profiles are unreadable would be asserting
# the common case as fact. The whole point of reading them is that they vary.
out="$(drive "$CLEAN" 'storage_scrub_start')"
grep -q 'could not be read' <<< "$out" \
  || fail "unreadable profiles did not report UNKNOWN: $out"
grep -qE 'Data: |Metadata: ' <<< "$out" \
  && fail "it printed a profile it could not read: $out"
grep -qi 'DUP' <<< "$out" && fail "it named DUP without having read it: $out"
echo "  UNKNOWN, and it names no profile it did not read"

sect "the invocation really has no -r, so the claim above matches the code"
# Assert on the CODE as well as the message: a future edit could add -r and make
# the message wrong in the other direction. Comments stripped first, because the
# explanation above legitimately contains the flag.
code="$(sed -e 's/#.*//' "$CLI")"
# Several lines mention `btrfs scrub start` -- the invocation and the two
# remedies. Select the EXECUTED one by the -B that only it carries, or the
# assertion below reads a remedy string and reports the wrong line.
inv="$(grep 'btrfs scrub start' <<< "$code" | grep -- '-B' | tr -s ' ' | sed 's/^ *//')"
[[ "$(wc -l <<< "$inv")" == "1" ]] \
  || fail "expected exactly one executed invocation, got:
$inv"
# NOT anchored at column 0: the invocation's output is captured into a variable
# so an "already running" error can be recognised, so the line begins with the
# assignment. What matters is that -B is an argument of `scrub start` itself.
grep -qE 'btrfs scrub start -B( |$)' <<< "$inv" || fail "the invocation lost -B: $inv"
grep -qE '(^| )-r( |$)' <<< "$inv" \
  && fail "the invocation now passes -r, so it IS read-only and every message is
wrong in the other direction: $inv"
echo "  no -r in: $inv"

sect "exit 3 is attributed to DATA corruption, which is what DUP metadata implies"
# A metadata error would have been CORRECTED and exited 0, so on this filesystem
# "uncorrectable" can only be the half with no second copy. Saying only
# "uncorrectable errors" leaves the operator to work that out.
out="$(drive "$BAD" 'storage_scrub_start')"
grep -q 'means DATA corruption' <<< "$out" \
  || fail "exit 3 is not attributed to data specifically: $out"
grep -qi 'corrected_errors' <<< "$out" \
  || fail "it does not explain that a metadata error would have been corrected: $out"
echo "  exit 3 attributed to data, with the reason"


sect "NO TRACKED FILE describes the scrub as read-only -- repository-wide"
# The section above drives the runtime OUTPUT. That is why three textual claims
# survived the correction that fixed this in thirteen places:
#
#   systemd/auto-enable.timers          "Read-only, and protective"
#   tests/timer-auto-enable-safety-smoke.sh  "Not a DEPLOYMENT timer -- read-only --"
#   bin/domum-media  (storage_cmd)      "Read-only verification."
#
# The last one is in the INSTALLED binary too. And a line-at-a-time grep MISSED
# the first, because the word "scrub" is on the preceding line -- the same
# blind spot that hid two of the pipefail audit's ten findings. So this scans a
# WINDOW, not a line.
#
# CLAUDE.md is exempt by name: it is the historical record and quotes the
# broken form in order to document the fix. A window that also contains a
# negation, or that is about `scrub status` (which genuinely is read-only), is
# not a claim.
scrub_claims="$(python3 - "$REPO_ROOT" <<'PY'
import io, os, re, sys
root = sys.argv[1]
SCRUB = re.compile(r'scrub', re.I)
CLAIM = re.compile(r'read[- ]only|never writes|deletes nothing|cannot be the cause', re.I)
# A window that says the opposite, or is about `scrub status`, is not a claim.
# A window that says the opposite, discusses the -r flag that WOULD make it
# read-only, or is about a different read-only command, is not a claim. These
# were measured against the real tree: without them the scan reports 9 windows
# of which 5 are its own documentation and 2 are legitimate -- and an audit
# that cries wolf is one somebody switches off.
OK = re.compile(r'not read-only|NOT read-only|read-write|READ-WRITE|is not\b'
                r'|scrub status|genuinely read-only|detection pass'
                r'|(?<![A-Za-z])-r(?![A-Za-z])|findmnt|filesystem df'
                r'|no root required', re.I)
# CLAUDE.md is the historical record and QUEUE.md records the fix; both quote
# the broken form deliberately. This suite is exempt for the same reason -- it
# has to name the exact sentences it exists to catch, including in its own
# negative control.
EXEMPT = {"CLAUDE.md", os.path.join("tests", "btrfs-scrub-smoke.sh")}
WINDOW = 3
found = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
    for fn in filenames:
        rel = os.path.relpath(os.path.join(dirpath, fn), root)
        if rel in EXEMPT:
            continue
        if not re.search(r'\.(md|sh|py|timer|service|timers|yml|conf)$', fn) \
           and fn not in ("domum-media", "domum-media-backup", "domum-media-report"):
            continue
        try:
            lines = io.open(os.path.join(dirpath, fn), encoding="utf-8",
                            errors="replace").read().split("\n")
        except OSError:
            continue
        for i, line in enumerate(lines):
            if not CLAIM.search(line):
                continue
            lo, hi = max(0, i - WINDOW), min(len(lines), i + WINDOW + 1)
            window = "\n".join(lines[lo:hi])
            if not SCRUB.search(window):
                continue
            if OK.search(window):
                continue
            print("%s:%d  %s" % (rel, i + 1, line.strip()[:100]))
            found += 1
print("windows flagged: %d" % found)
PY
)"
printf '%s\n' "$scrub_claims"
flagged="$(sed -n 's/^windows flagged: //p' <<< "$scrub_claims")"
[ "${flagged:-1}" = "0" ] \
  || fail "a tracked file still describes the scrub as read-only. It passes no -r,
so on a replicated profile it repairs by WRITING -- and Metadata and System on
this host are DUP."
# It must not be able to pass by scanning nothing: the scrub IS described in
# several files, so a window count of zero with no file read is a broken scan.
grep -q 'windows flagged' <<< "$scrub_claims" \
  || fail "the scan produced no verdict at all"
echo "  no tracked file outside CLAUDE.md makes the claim"

sect "and the scan would CATCH the claim if it came back"
# Proves the window logic rather than trusting it, including the cross-line
# case a grep missed. Without this the section above could pass against a scan
# that matches nothing.
probe_dir="$TMP/scrubclaim"
rm -rf "$probe_dir"; mkdir -p "$probe_dir"
printf '#   domum-media-btrfs-scrub.timer\n#       Read-only, and protective.\n' \
  > "$probe_dir/auto-enable.timers"
caught="$(python3 - "$probe_dir" <<'PY'
import io, os, re, sys
root = sys.argv[1]
SCRUB = re.compile(r'scrub', re.I)
CLAIM = re.compile(r'read[- ]only|never writes|deletes nothing|cannot be the cause', re.I)
OK = re.compile(r'not read-only|NOT read-only|read-write|READ-WRITE|is not\b|scrub status|genuinely read-only', re.I)
n = 0
for fn in os.listdir(root):
    lines = io.open(os.path.join(root, fn), encoding="utf-8").read().split("\n")
    for i, line in enumerate(lines):
        if not CLAIM.search(line):
            continue
        w = "\n".join(lines[max(0, i - 3):i + 4])
        if SCRUB.search(w) and not OK.search(w):
            n += 1
print(n)
PY
)"
[ "$caught" = "1" ] \
  || fail "the scan did not catch the exact historical claim, with 'scrub' on the
PRECEDING line -- so the real scan above proves nothing (got: $caught)"
echo "  catches it across lines, which is how the real one hid"

echo "PASS: btrfs scrub smoke test"
