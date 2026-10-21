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
grep -q '^RC=0$' <<< "$out" || fail "status is read-only and must exit 0: $out"
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
old = 'btrfs scrub start -B ${limit:+--limit "$limit"} "$root" || rc=$?'
assert s.count(old) == 1, "mutation target not unique: %d" % s.count(old)
s = s.replace(old, 'btrfs scrub start ${limit:+--limit "$limit"} "$root" || rc=$?', 1)
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

echo "PASS: btrfs scrub smoke test"
