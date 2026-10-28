#!/usr/bin/env bash
# The EXCLUSIVE restic operations -- the weekly integrity check and retention --
# now record durable evidence, and `checkup` reads it to tell a stale failure
# from a current one.
#
# Why this suite exists. Production, 2026-10-25 to 2026-10-28:
# `domum-media-check.service` exited 11 (restic: repository already locked), so
# that run's check never ran and `--weekly-retention` -- the second ExecStart
# with no `-` prefix -- was skipped with it. The operator removed the stale lock
# on 2026-10-27 and ran the check by hand; it passed, and passed again the next
# day. systemd keeps a unit's failed state until the unit itself runs again, so
# `checkup` went on reporting the failure in the PRESENT TENSE and telling the
# operator to perform an approval-gated `restic unlock` they had already
# completed. Nothing recorded either success, so the report had no way to know.
#
# Everything below is driven, never grepped: a test that reads a function's
# text does not prove the function runs.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_CLI="$REPO_ROOT/bin/domum-media-backup"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# ---------------------------------------------------------------------------
#  The writer, driven through the real functions in bin/domum-media-backup.
# ---------------------------------------------------------------------------
# Only the restic invocation is stubbed. The recording, the mode derivation and
# the exit-status handling are the production code.
#
# A FILE with a quoted heredoc, not a nested -c string: expressing this through
# another layer of quoting is what once produced a mutation that silently did
# nothing.
cat > "$TMP/drive-writer.sh" <<'DRIVER'
set -uo pipefail
REPO_META_DIR="$META"
LOG_FILE="$TMPDIR_T/backup.log"
RESTIC_KEEP_DAILY=7 RESTIC_KEEP_WEEKLY=5 RESTIC_KEEP_MONTHLY=12 RESTIC_KEEP_YEARLY=3
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
# The stub exits with $RESTIC_RC so the real exit-status path is exercised.
restic_for_target() { return "${RESTIC_RC:-0}"; }
# One contiguous range covering the four writer functions, stopping at the
# next unrelated definition. Extracting each separately produced unbalanced
# output and the functions were never defined -- the driver then "failed" for a
# reason that had nothing to do with the code under test.
source <(awk '/^restic_op_evidence_file\(\) \{/,/^list_latest_snapshots\(\) \{/' "$CLI_BACKUP" \
         | sed '/^list_latest_snapshots() {/d')
eval "$DRIVE"
DRIVER

drive_writer() {  # $1 = shell to run with the writer functions loaded
  (
    export META="$TMP/meta" TMPDIR_T="$TMP" CLI_BACKUP="$BACKUP_CLI" DRIVE="$1"
    bash "$TMP/drive-writer.sh"
  )
}

rm -rf -- "$TMP/meta"
sect "a successful structure check records evidence, and calls itself 'structure'"
# `restic check` with no further argument reads trees, indexes and blob
# metadata. It does NOT read pack contents, so recording it without a mode
# would let a structure check be reported as a read-data verification -- two
# different claims, which is the conflation the five recovery levels exist to
# prevent.
RESTIC_RC=0 drive_writer 'restic_check_for cloud' || fail "a successful check returned non-zero"
ev="$TMP/meta/cloud-check.env"
[[ -f "$ev" ]] || fail "no check evidence was recorded at $ev"
grep -q '^RESULT=success$'   "$ev" || fail "the result was not recorded: $(cat "$ev")"
grep -q '^OPERATION=check$'  "$ev" || fail "the operation was not recorded: $(cat "$ev")"
grep -q '^MODE=structure$'   "$ev" || fail "a bare check must record MODE=structure: $(cat "$ev")"
grep -q '^TARGET=cloud$'     "$ev" || fail "the target was not recorded: $(cat "$ev")"
grep -q '^FINISHED_TS=.\+$'  "$ev" || fail "no finish timestamp was recorded: $(cat "$ev")"
perm="$(stat -c '%a' "$ev")"
[[ "$perm" == "600" ]] || fail "check evidence is mode $perm, expected 600"
echo "  recorded, 0600, MODE=structure"

sect "a read-data check is recorded as a DIFFERENT mode"
RESTIC_RC=0 drive_writer 'restic_check_for cloud --read-data' || fail "read-data check returned non-zero"
grep -q '^MODE=read-data$' "$TMP/meta/cloud-check.env" \
  || fail "--read-data was not distinguished from a structure check: $(cat "$TMP/meta/cloud-check.env")"
RESTIC_RC=0 drive_writer 'restic_check_for cloud --read-data-subset=5%' || fail "subset check returned non-zero"
grep -q '^MODE=read-data-subset$' "$TMP/meta/cloud-check.env" \
  || fail "--read-data-subset was not distinguished: $(cat "$TMP/meta/cloud-check.env")"
echo "  structure, read-data and read-data-subset are three recorded modes"

sect "a FAILING check preserves restic's exit status AND records a failure"
# The exit status is the whole mechanism by which a locked repository fails the
# unit: restic exit 11 is what `checkup` reads to say the check never ran.
# Swallowing it to make room for the recording would turn a skipped check into
# a green unit -- "warn and continue" in the one place it must not happen.
rc=0
RESTIC_RC=11 drive_writer 'restic_check_for cloud' || rc=$?
(( rc == 11 )) || fail "restic's exit status was not preserved: got $rc, expected 11"
grep -q '^RESULT=failure$' "$TMP/meta/cloud-check.env" \
  || fail "a failed check was not recorded as a failure: $(cat "$TMP/meta/cloud-check.env")"
echo "  exit 11 preserved, failure recorded"

sect "retention records its own evidence and preserves its exit status"
# forget --prune takes the same EXCLUSIVE lock, so it fails on a locked
# repository exactly as the check does.
RESTIC_RC=0 drive_writer 'restic_forget_for cloud' || fail "a successful retention returned non-zero"
rev="$TMP/meta/cloud-retention.env"
[[ -f "$rev" ]] || fail "no retention evidence was recorded"
grep -q '^RESULT=success$'       "$rev" || fail "retention result not recorded: $(cat "$rev")"
grep -q '^OPERATION=retention$'  "$rev" || fail "retention operation not recorded: $(cat "$rev")"
rc=0
RESTIC_RC=11 drive_writer 'restic_forget_for cloud' || rc=$?
(( rc == 11 )) || fail "retention's exit status was not preserved: got $rc, expected 11"
grep -q '^RESULT=failure$' "$rev" || fail "a failed retention was not recorded: $(cat "$rev")"
echo "  recorded both ways, exit status preserved"

# ---------------------------------------------------------------------------
#  The reader, driven through the real functions in bin/domum-media.
# ---------------------------------------------------------------------------
read_probe() {  # $1 = fixture, $2 = expression to evaluate
  (
    export REPO_META_DIR="$TMP/rmeta"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    eval "$1"
    eval "$2"
  ) 2>&1
}

mkdir -p "$TMP/rmeta"
write_ev() {  # $1 = target, $2 = op, $3 = result, $4 = iso, $5 = mode
  printf 'RESULT=%s\nMODE=%s\nFINISHED_TS=%s\n' "$3" "${5:-structure}" "$4" \
    > "$TMP/rmeta/$1-$2.env"
}
TWO_TARGETS='enabled_backup_targets() { printf "nas\ncloud\n"; }'

sect "a recorded FAILURE is not read as a success"
# "When did this last succeed" and "when was it last attempted" are different
# questions. Reading an attempt as a result is the defect record_backup_target_run
# already carries a comment about.
write_ev cloud check failure 2026-10-28T10:00:00-0400
out="$(read_probe "$TWO_TARGETS" 'restic_op_last_success cloud check && echo UNEXPECTED')"
grep -q UNEXPECTED <<< "$out" && fail "a failure record was read as a success: $out"
echo "  a failure record yields nothing"

sect "a key that was never written reads as absent, not as zero"
# Evidence written before MODE existed has no MODE line. The accessor must
# still answer, with the mode reported as unknown rather than invented.
printf 'RESULT=success\nFINISHED_TS=2026-10-28T10:00:00-0400\n' > "$TMP/rmeta/cloud-check.env"
out="$(read_probe "$TWO_TARGETS" 'restic_op_last_success cloud check')"
grep -q 'unknown' <<< "$out" || fail "a missing MODE was not reported as unknown: $out"
echo "  a missing mode reads as unknown"

sect "superseded requires EVERY enabled target, not just one"
# A Jellyfin snapshot must never satisfy a Plex upgrade, and one repository's
# clean check says nothing about another's. The conservative direction is the
# only safe one: a partially-verified fleet must keep reporting the failure.
SINCE=$(date -d 2026-10-25T03:37:11-0400 +%s)
write_ev nas   check success 2026-10-28T10:51:00-0400
write_ev cloud check success 2026-10-28T10:52:00-0400
out="$(read_probe "$TWO_TARGETS" "restic_checks_since $SINCE")"
[[ "$out" == superseded* ]] || fail "both targets verified later, yet not superseded: $out"
grep -q 'nas@' <<< "$out"   || fail "the superseding evidence does not name nas: $out"
grep -q 'cloud@' <<< "$out" || fail "the superseding evidence does not name cloud: $out"

write_ev cloud check success 2026-10-20T03:40:00-0400   # BEFORE the failed run
out="$(read_probe "$TWO_TARGETS" "restic_checks_since $SINCE")"
[[ "$out" == outstanding* ]] || fail "one target unverified, yet reported superseded: $out"
grep -q 'cloud' <<< "$out" || fail "the outstanding target is not named: $out"
echo "  all targets required; the unverified one is named"

sect "no enumerable target is UNKNOWN, never superseded"
# A third answer on purpose: "no evidence could be read" is not "nothing has
# been verified", and it is certainly not "everything has".
out="$(read_probe 'enabled_backup_targets() { return 0; }' "restic_checks_since $SINCE")"
[[ "$out" == "unknown" ]] || fail "an unenumerable target set did not read as unknown: $out"
echo "  unknown is its own answer"

sect "an unreadable unit timestamp is UNKNOWN, so a live failure is never downgraded"
NO_TS='systemctl() { return 1; }'
out="$(read_probe "$TWO_TARGETS; $NO_TS" 'check_unit_verdict domum-media-check.service')"
[[ "$out" == "unknown" ]] || fail "an unreadable exit timestamp did not read as unknown: $out"
echo "  unreadable timestamp cannot supersede"

sect "retention recency is stated with its DATE, or honestly as unrecorded"
write_ev nas retention success 2026-10-18T03:40:00-0400 forget-prune
out="$(read_probe "$TWO_TARGETS" 'retention_last_success_text')"
grep -q '2026-10-18' <<< "$out" || fail "the recorded retention date is not stated: $out"
rm -f "$TMP/rmeta"/*-retention.env
out="$(read_probe "$TWO_TARGETS" 'retention_last_success_text')"
grep -qi 'no successful retention run is recorded' <<< "$out" \
  || fail "absent retention evidence was not reported honestly: $out"
echo "  dated when recorded, unrecorded when not"

# ---------------------------------------------------------------------------
#  Drift guard: one default path, written identically in both CLIs.
# ---------------------------------------------------------------------------
sect "both CLIs default the evidence directory to the SAME path"
# The writer lives in domum-media-backup and the reader in domum-media. If the
# two derived the default differently -- one from DOMUM_STATE_ROOT, the other
# hardcoded -- they would agree on this host only BY ACCIDENT, exactly as the
# recovery pack's backup path once did, and moving the state root would leave
# the reader silently finding nothing.
w="$(sed -nE 's/^REPO_META_DIR="\$\{REPO_META_DIR:-(.*)\}"$/\1/p' "$BACKUP_CLI")"
r="$(sed -nE 's/.*REPO_META_DIR:-([^}]*)\}.*/\1/p' "$CLI" | sort -u)"
[[ -n "$w" ]] || fail "the writer's default evidence dir could not be extracted"
[[ -n "$r" ]] || fail "the reader's default evidence dir could not be extracted"
[[ "$w" == "$r" ]] || fail "writer defaults to '$w' but reader defaults to '$r'"
echo "  both default to $w"

# ---------------------------------------------------------------------------
#  Mutations. Each must make the suite fail; a mutation that changes no ANSWER
#  proves nothing, so each names the observable it changes.
# ---------------------------------------------------------------------------
mutate() {  # $1 = python source, $2 = file
  python3 -I - "$2" <<PYEOF
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
$1
io.open(p, "w", encoding="utf-8").write(s)
PYEOF
}

sect "MUTATION: 'any target verified' instead of 'every target'"
# Take the backup BEFORE the mutation, unconditionally and on its own line -- a
# short-circuited && chain leaves the mutation applied with no way back.
cp "$CLI" "$TMP/cli.orig"
mutate 'old = "  if (( ${#outstanding[@]} == 0 )); then"
new = "  if (( ${#later[@]} > 0 )); then"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
s = s.replace(old, new)' "$CLI" || { cp "$TMP/cli.orig" "$CLI"; fail "the mutation did not apply"; }
write_ev nas   check success 2026-10-28T10:51:00-0400
write_ev cloud check success 2026-10-20T03:40:00-0400
out="$(read_probe "$TWO_TARGETS" "restic_checks_since $SINCE")"
cp "$TMP/cli.orig" "$CLI"
[[ "$out" == superseded* ]] \
  || fail "the mutation changed no ANSWER -- it must make one verified target supersede the fleet: $out"
echo "  caught: one target's clean check would have excused an unverified one"

sect "MUTATION: a failure record read as a success"
cp "$CLI" "$TMP/cli.orig"
mutate 'old = """    [[ "${RESULT:-}" == "success" ]] || exit 1
    [[ -n "${FINISHED_TS:-}" ]] || exit 1"""
new = """    [[ -n "${FINISHED_TS:-}" ]] || exit 1"""
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
s = s.replace(old, new)' "$CLI" || { cp "$TMP/cli.orig" "$CLI"; fail "the mutation did not apply"; }
write_ev cloud check failure 2026-10-28T10:00:00-0400
out="$(read_probe "$TWO_TARGETS" 'restic_op_last_success cloud check && echo READ_AS_SUCCESS')"
cp "$TMP/cli.orig" "$CLI"
grep -q READ_AS_SUCCESS <<< "$out" \
  || fail "the mutation changed no ANSWER -- a recorded failure must read as a success: $out"
echo "  caught: a FAILED check would have superseded the failure it caused"

sect "MUTATION: the check's exit status swallowed"
cp "$BACKUP_CLI" "$TMP/backup.orig"
mutate 'old = """  # Preserved so a locked repository still fails the unit. restic exit 11 is
  # what makes `checkup` able to say the check never ran.
  return "$rc"
}"""
new = """  return 0
}"""
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
s = s.replace(old, new)' "$BACKUP_CLI" || { cp "$TMP/backup.orig" "$BACKUP_CLI"; fail "the mutation did not apply"; }
rc=0
RESTIC_RC=11 drive_writer 'restic_check_for cloud' || rc=$?
cp "$TMP/backup.orig" "$BACKUP_CLI"
(( rc == 0 )) \
  || fail "the mutation changed no ANSWER -- a locked repository must stop failing: got $rc"
echo "  caught: a locked repository would have left the unit green"

echo "ALL RESTIC-OP-EVIDENCE CHECKS PASSED"
