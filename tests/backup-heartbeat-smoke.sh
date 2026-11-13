#!/usr/bin/env bash
# The backup heartbeat: an EMPTY marker must read as "cannot tell", never as a
# successful backup.
#
# Why this suite exists. `date -d ""` is NOT an error. GNU date reads an empty
# string as today at 00:00:00 and exits 0 -- measured, byte-identical to
# `date -d 'today 00:00:00'`, and a whitespace-only string does the same. So
# `backup_last_success_epoch`, which did
#
#     date -d "$(head -n1 "$file")" +%s 2>/dev/null || return 1
#
# fabricated "the backup succeeded today at midnight" from an empty marker:
# `checkup` reported a healthy recent backup, and `verify_backup_freshness` --
# the gate that refuses a stateful image update when no successful backup is
# recorded -- PASSED, because an age of 0-23h is under its 48h limit. That is
# HEALTHY-must-not-mean-UNMEASURED inside the one check that says whether the
# photographs are protected.
#
# Found by sweeping for the shape after fixing truncate-before-write elsewhere.
# Every other `date -d "$var"` site across the three CLIs is already guarded
# with [[ -n ... ]]; this was the single outlier, which is why the convention
# being universal is itself the evidence that this one was wrong.
#
# Everything below is DRIVEN. A test that reads a function's text does not
# prove the function runs.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
BACKUP_CLI="$REPO_ROOT/bin/domum-media-backup"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# What the drivers LOAD. A mutation repoints these at a mutated COPY, so bin/ is
# never written: an interrupted run leaves nothing behind and a concurrent run
# cannot read a half-mutated file.
MUTCLI="$CLI"
MUT_BACKUP="$BACKUP_CLI"
PRISTINE="$TMP/cli.pristine"; cp "$CLI" "$PRISTINE"
PRISTINE_B="$TMP/backup.pristine"; cp "$BACKUP_CLI" "$PRISTINE_B"

# ---------------------------------------------------------------------------
#  The READER, driven through the real function.
# ---------------------------------------------------------------------------
cat > "$TMP/drive-reader.sh" <<'DRIVER'
set -uo pipefail
DOMUM_LOG_DIR="$LOGDIR"
source <(awk '/^backup_last_success_epoch\(\) \{/,/^\}/' "$CLI_PATH")
eval "$DRIVE"
DRIVER

read_epoch() {  # $1 = marker contents, or the literal ABSENT
  local body="$1"
  rm -rf -- "$TMP/log"; mkdir -p "$TMP/log"
  [[ "$body" == "ABSENT" ]] || printf '%s' "$body" > "$TMP/log/last-success"
  (
    export LOGDIR="$TMP/log" CLI_PATH="$MUTCLI" \
           DRIVE='if e="$(backup_last_success_epoch)"; then printf "OK %s\n" "$e"; else printf "REFUSED\n"; fi'
    bash "$TMP/drive-reader.sh"
  )
}

sect "a real timestamp is read"
out="$(read_epoch '2026-11-12T02:41:19-05:00
')"
[[ "$out" == OK\ * ]] || fail "a valid marker did not read: $out"
want="$(date -d '2026-11-12T02:41:19-05:00' +%s)"
[[ "$out" == "OK $want" ]] || fail "wrong epoch: $out, wanted OK $want"

sect "an EMPTY marker must REFUSE, not fabricate today at midnight"
# The defect: before the guard this returned $(date -d '' +%s), i.e. today
# 00:00:00, which is a plausible recent backup that never happened.
midnight="$(date -d 'today 00:00:00' +%s)"
out="$(read_epoch '')"
[[ "$out" == "REFUSED" ]] || fail "an empty marker read as a timestamp: $out"
[[ "$out" != "OK $midnight" ]] || fail "an empty marker fabricated today-midnight"

sect "a WHITESPACE-ONLY marker must REFUSE too"
# date -d '   ' also exits 0 with today-midnight, so trimming is required and a
# bare -n test on the raw line would not catch it.
out="$(read_epoch '   
')"
[[ "$out" == "REFUSED" ]] || fail "a whitespace-only marker read as a timestamp: $out"

sect "garbage and an absent marker still REFUSE (behaviour preserved)"
out="$(read_epoch 'not a date
')"; [[ "$out" == "REFUSED" ]] || fail "garbage read as a timestamp: $out"
out="$(read_epoch ABSENT)";        [[ "$out" == "REFUSED" ]] || fail "an absent marker read as a timestamp: $out"

# ---------------------------------------------------------------------------
#  The GATE. This is the observable that matters: an empty marker must not let
#  a stateful image update proceed.
# ---------------------------------------------------------------------------
cat > "$TMP/drive-gate.sh" <<'DRIVER'
set -uo pipefail
DOMUM_LOG_DIR="$LOGDIR"
BACKUP_POLICY=STRICT
BACKUP_REQUIRED_MAX_AGE_HOURS=48
die() { echo "DIED: $*"; exit 9; }
service_backup_required() { return 0; }
service_strict_backup_required() { return 0; }
source <(awk '/^backup_last_success_epoch\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^verify_backup_freshness\(\) \{/,/^\}/' "$CLI_PATH")
verify_backup_freshness plex && echo "GATE-PASSED"
DRIVER

run_gate() {  # $1 = marker contents
  rm -rf -- "$TMP/log"; mkdir -p "$TMP/log"
  printf '%s' "$1" > "$TMP/log/last-success"
  ( export LOGDIR="$TMP/log" CLI_PATH="$MUTCLI"; bash "$TMP/drive-gate.sh" 2>&1 )
}

sect "a FRESH marker lets the update gate pass (the positive control)"
# Without this, every assertion below is satisfied by a gate that never passes.
out="$(run_gate "$(date -Iseconds)")"
grep -q 'GATE-PASSED' <<< "$out" || fail "a fresh backup did not pass the gate: $out"

sect "an EMPTY marker must make the update gate REFUSE"
out="$(run_gate '')"
grep -q 'DIED: Refusing to update' <<< "$out" \
  || fail "an empty marker did not stop the update gate: $out"
grep -q 'GATE-PASSED' <<< "$out" && fail "an empty marker PASSED the update gate: $out"

# ---------------------------------------------------------------------------
#  The WRITER, driven through the real function.
# ---------------------------------------------------------------------------
# The driver runs with PRODUCTION's shell options. A harness that relaxes them
# is not a test of production: the fatal path below depends on `set -e`.
cat > "$TMP/drive-hb.sh" <<'DRIVER'
set -euo pipefail
HEARTBEAT_FILE="$HB"
warn() { echo "WARNING: $*" >&2; }
die() { echo "DIED: $*" >&2; exit 1; }
source <(awk '/^heartbeat\(\) \{/,/^\}/' "$BACKUP_PATH")
heartbeat
echo "HEARTBEAT-RETURNED"
DRIVER

sect "the writer leaves a non-empty marker, and no staging file behind"
rm -rf -- "$TMP/hb"; mkdir -p "$TMP/hb"
( export HB="$TMP/hb/last-success" BACKUP_PATH="$MUT_BACKUP"; bash "$TMP/drive-hb.sh" >/dev/null ) \
  || fail "heartbeat returned non-zero"
[[ -s "$TMP/hb/last-success" ]] || fail "the marker is empty or missing after heartbeat"
date -d "$(head -n1 "$TMP/hb/last-success")" +%s >/dev/null 2>&1 \
  || fail "the marker is not a parseable timestamp: $(cat "$TMP/hb/last-success")"
leftovers="$(find "$TMP/hb" -name 'last-success.tmp*' | wc -l)"
[[ "$leftovers" == "0" ]] || fail "heartbeat left $leftovers staging file(s) behind"

sect "the writer PUBLISHES BY RENAME, so the marker is never briefly empty"
# Observable: the published file's inode CHANGES across a refresh. An in-place
# truncating write keeps the inode and empties the file first; a rename gives a
# new one. Both files are in the same directory, so the rename cannot degrade
# into a copy.
before_ino="$(stat -c %i "$TMP/hb/last-success")"
( export HB="$TMP/hb/last-success" BACKUP_PATH="$MUT_BACKUP"; bash "$TMP/drive-hb.sh" >/dev/null ) \
  || fail "second heartbeat returned non-zero"
after_ino="$(stat -c %i "$TMP/hb/last-success")"
[[ "$before_ino" != "$after_ino" ]] \
  || fail "the marker kept inode $before_ino across a refresh -- it was rewritten in place"

sect "an UNWRITABLE destination must FAIL the run, not continue quietly"
# The CLI runs `set -euo pipefail` and the original truncating write aborted the
# run when it failed. The heartbeat is a must-happen step: a backup whose
# success was never recorded has to fail the unit, rather than report success
# and leave checkup to raise a separate critical about a missing marker. Adding
# atomicity must not quietly turn that into a warning.
# chmod is a no-op for root, so this section cannot be driven as root. Say so
# rather than skipping silently -- a branch that depends on the machine is
# PRINTED, or it is indistinguishable from one that asserts nothing.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "   SKIPPED as root: a mode-500 directory does not block root, so the failure cannot be provoked"
else
rm -rf -- "$TMP/ro"; mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
out="$( export HB="$TMP/ro/last-success" BACKUP_PATH="$MUT_BACKUP"; bash "$TMP/drive-hb.sh" 2>&1 )"; rc=$?
chmod 700 "$TMP/ro"
(( rc != 0 )) || fail "an unwritable heartbeat destination returned success: $out"
grep -q 'HEARTBEAT-RETURNED' <<< "$out" && fail "heartbeat continued past an unwritable destination: $out"
[[ -e "$TMP/ro/last-success" ]] && fail "a marker was published despite the failure"
fi

# ---------------------------------------------------------------------------
#  MUTATION. Name the observable the mutation actually changes: the FABRICATED
#  TIMESTAMP must come back, and with it the gate passing on an empty marker.
# ---------------------------------------------------------------------------
sect "MUTATION: removing the blank-line guard must fabricate a backup again"
MUT="$TMP/cli.mutant"; cp "$CLI" "$MUT"
python3 - "$MUT" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  [[ -n "${line//[[:space:]]/}" ]] || return 1\n'
assert s.count(old) == 1, "mutation anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PY
[[ $? -eq 0 ]] || fail "the mutation did not apply"
grep -q 'line//\[\[:space:\]\]' "$MUT" && fail "the mutation did not remove the guard"

MUTCLI="$MUT"
midnight="$(date -d 'today 00:00:00' +%s)"
out="$(read_epoch '')"
[[ "$out" == "OK $midnight" ]] \
  || fail "the mutant did not fabricate today-midnight from an empty marker: $out"
out="$(run_gate '')"
grep -q 'GATE-PASSED' <<< "$out" \
  || fail "the mutant did not let an empty marker pass the update gate: $out"
echo "   killed: without the guard an empty marker becomes a backup 'today at 00:00' and the update gate passes"
MUTCLI="$CLI"

sect "the tracked CLIs were never written"
cmp -s "$CLI" "$PRISTINE"          || fail "bin/domum-media was mutated in place"
cmp -s "$BACKUP_CLI" "$PRISTINE_B" || fail "bin/domum-media-backup was mutated in place"

echo "PASS: backup heartbeat -- an empty marker reads as unknown, not as a backup"
