#!/usr/bin/env bash
set -uo pipefail

# Proves that per-target backup evidence is recorded independently, and that the
# report never infers a target's result from the aggregate heartbeat.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

META_DIR="$TMP_DIR/state/backups"
mkdir -p "$META_DIR" "$TMP_DIR/log"

# ---------------------------------------------------------------------------
# 1. record_backup_target_run writes durable, atomic, per-target evidence.
# ---------------------------------------------------------------------------
run_recorder() {
  bash -c "
set -uo pipefail
REPO_META_DIR='$META_DIR'
DOMUM_LOG_DIR='$TMP_DIR/log'
repo_meta_file() { printf '%s' \"\$REPO_META_DIR/\$1-repo.env\"; }
source <(sed -n '/^record_backup_target_run() {/,/^}/p' '$REPO_ROOT/bin/domum-media-backup')
$1
"
}

printf 'REPOSITORY_ID=abc123def456\n' > "$META_DIR/cloud-repo.env"
run_recorder "record_backup_target_run cloud success 2026-01-01T00:00:00+00:00 deadbeef" \
  || fail "record_backup_target_run failed"

run_file="$META_DIR/cloud-run.env"
[[ -f "$run_file" ]] || fail "no per-target run evidence was written"

grep -q '^TARGET=cloud$'        "$run_file" || fail "run evidence is missing the target name"
grep -q '^RESULT=success$'      "$run_file" || fail "run evidence is missing the result"
grep -q '^SNAPSHOT_ID=deadbeef$' "$run_file" || fail "run evidence is missing the snapshot id"
grep -q '^REPOSITORY_ID=abc123def456$' "$run_file" || fail "run evidence is missing the repository identity"
grep -q '^STARTED_TS='  "$run_file" || fail "run evidence is missing the start time"
grep -q '^FINISHED_TS=' "$run_file" || fail "run evidence is missing the finish time"
grep -q '^SCHEMA_VERSION=' "$run_file" || fail "run evidence is missing a schema version"

perms="$(stat -c %a "$run_file")"
[[ "$perms" == "600" ]] || fail "run evidence should be 0600, found $perms"

# No temporary file may be left behind: the write must be atomic.
leftovers="$(find "$META_DIR" -name '.cloud-run.env.*' 2>/dev/null)"
[[ -z "$leftovers" ]] || fail "atomic write left a temporary file behind: $leftovers"

# A failure must be recorded as a failure, not omitted.
run_recorder "record_backup_target_run cloud failure 2026-01-01T00:00:00+00:00 ''" \
  || fail "recording a failure failed"
grep -q '^RESULT=failure$' "$run_file" || fail "a failed run was not recorded as failed"

# Each target gets its own record; one target cannot vouch for another.
run_recorder "record_backup_target_run nas success 2026-01-01T00:00:00+00:00 cafe1234" \
  || fail "recording a second target failed"
[[ -f "$META_DIR/nas-run.env" ]] || fail "a second target did not get its own evidence file"
grep -q '^RESULT=failure$' "$run_file" || fail "recording one target overwrote another's result"

# ---------------------------------------------------------------------------
# 2. The report reads that evidence, and reports unknown where none exists.
# ---------------------------------------------------------------------------
report_target() {
  bash -c "
set -uo pipefail
cmd_exists() { command -v \"\$1\" >/dev/null 2>&1; }
REPO_META_DIR='$META_DIR'
DOMUM_STATE_ROOT='$TMP_DIR/state'
REPORT_NOW_EPOCH=\$(date +%s)
source '$REPO_ROOT/bin/domum-media-report'
report_backup_target_state '$1'
"
}

printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=success\nSTARTED_TS=%s\nFINISHED_TS=%s\nSNAPSHOT_ID=abcdef12\nREPOSITORY_ID=abc123\n' \
  "$(date -Iseconds)" "$(date -Iseconds)" > "$run_file"

out="$(report_target cloud)" || fail "report_backup_target_state failed"
jq -e '.last_run.state == "ok"' <<< "$out" >/dev/null \
  || fail "a recorded success was not reported as ok: $out"
jq -e '.last_run.snapshot_id == "abcdef12"' <<< "$out" >/dev/null \
  || fail "the recorded snapshot id was not reported: $out"
jq -e '.last_run.age_seconds != null' <<< "$out" >/dev/null \
  || fail "a recorded run should have a computable age: $out"

printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=failure\nFINISHED_TS=%s\nSNAPSHOT_ID=\n' "$(date -Iseconds)" > "$run_file"
out="$(report_target cloud)" || fail "report_backup_target_state failed on a failure record"
jq -e '.last_run.state == "failed"' <<< "$out" >/dev/null \
  || fail "a recorded failure was not reported as failed: $out"

# A run that started but recorded no outcome must never read as ok.
printf 'SCHEMA_VERSION=1\nTARGET=cloud\nRESULT=running\nFINISHED_TS=%s\n' "$(date -Iseconds)" > "$run_file"
out="$(report_target cloud)" || fail "report_backup_target_state failed on a running record"
jq -e '.last_run.state == "incomplete"' <<< "$out" >/dev/null \
  || fail "an interrupted or in-flight run must report incomplete, not ok: $out"

# The wrapper must mark the attempt BEFORE anything that can abort, otherwise a
# killed or identity-rejected run leaves the previous success in place.
awk '/^do_daily_backup\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup" > "$TMP_DIR/loop.txt"
[ -s "$TMP_DIR/loop.txt" ] || fail "could not extract do_daily_backup"
running_line="$(grep -n 'record_backup_target_run "\$target" running' "$TMP_DIR/loop.txt" | head -1 | cut -d: -f1)"
# Ignore comment lines: the code is commented with the very name being searched.
check_line="$(grep -nE '^[[:space:]]*(if )?check_repo_identity' "$TMP_DIR/loop.txt" | head -1 | cut -d: -f1)"
[ -n "$check_line" ] || fail "could not locate check_repo_identity in do_daily_backup"
[ -n "$running_line" ] || fail "the wrapper does not mark the attempt before running the backup"
(( running_line < check_line )) \
  || fail "the attempt must be marked before check_repo_identity, which can abort"

# A target with no evidence must report unknown, never inherit another's result.
out="$(report_target archive)" || fail "report_backup_target_state failed for an unrecorded target"
jq -e '.last_run.state == "unknown"' <<< "$out" >/dev/null \
  || fail "a target with no evidence must report unknown: $out"
jq -e '.last_run.reason != null' <<< "$out" >/dev/null \
  || fail "an unknown run state must explain itself: $out"

# ---------------------------------------------------------------------------
# 3. The aggregate heartbeat must never be used as per-target evidence.
# ---------------------------------------------------------------------------
last_run_lines="$(grep -n 'last_run' "$REPO_ROOT/bin/domum-media-report" || true)"
grep -qi 'heartbeat' <<< "$last_run_lines" \
  && fail "per-target run state must not be derived from the aggregate heartbeat"

# ---------------------------------------------------------------------------
# 4. A failed target must still abort the run BEFORE anything is refreshed.
#
# This asserted the property by grepping the LOOP BODY for the die, which made
# it unable to tell a fix from a regression -- the text-assertion family this
# project records. The die moved OUT of the loop so that every enabled target
# is attempted before the run fails (if `cloud` is locked, `nas` can still get
# a backup, and zero backups is strictly worse than one), and this assertion
# failed against correct code.
#
# What actually matters is the ORDERING, not the location: the refusal must
# precede `heartbeat`, or a failed backup would refresh the marker `checkup`
# reads and a backup that did not happen would report as current. That is what
# is asserted now, by statement position within the function.
#
# The behaviour itself is driven in backup-evidence-endtoend-smoke sections
# L1-L5 and B: both targets attempted, run fails, no heartbeat, per-target
# evidence correct, and a mutation that moves the die back into the loop.
fn_text="$(awk '/^do_daily_backup\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
grep -q 'die "Backup failed for target' <<< "$fn_text" \
  || fail "a failing target no longer aborts the backup run at all"
die_at="$(grep -n 'die "Backup failed for target' <<< "$fn_text" | head -1 | cut -d: -f1)"
hb_at="$(grep -n '^  heartbeat$' <<< "$fn_text" | head -1 | cut -d: -f1)"
[ -n "$die_at" ] && [ -n "$hb_at" ] \
  || fail "could not locate both the refusal and the heartbeat in do_daily_backup"
[ "$die_at" -lt "$hb_at" ] \
  || fail "the backup refusal ($die_at) does not precede the heartbeat ($hb_at), so a
failed backup would refresh the marker checkup reads as 'last backup'"

# ---------------------------------------------------------------------------
# 5. restic_backup_to must stream to the log, capture the snapshot id, and
#    propagate restic's own exit status -- not tee's. A regression here would
#    mark a failed backup as successful.
# ---------------------------------------------------------------------------
cat > "$TMP_DIR/backup-harness.sh" <<HARNESS
set -uo pipefail
LOG_FILE="$TMP_DIR/stream.log"
DOMUM_DATA_ROOT=/tmp/domum-test-d
DOMUM_MEDIA_ROOT=/tmp/domum-test-m
REPO_SRC="$REPO_ROOT/bin/domum-media-backup"
HARNESS
cat >> "$TMP_DIR/backup-harness.sh" <<'HARNESS'
die() { echo "ERR $*" >&2; exit 1; }
log() { :; }
backup_target_include_paths() { echo /tmp; }
restic_for_target() { printf 'scanning...
snapshot ab12cd34 saved
'; return "${FAKE_RC:-0}"; }
eval "$(awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_SRC")"
restic_backup_to cloud >/dev/null 2>&1
echo "rc=$? id=${BACKUP_LAST_SNAPSHOT_ID:-}"
HARNESS

out="$(FAKE_RC=0 bash "$TMP_DIR/backup-harness.sh")"
grep -q 'rc=0' <<< "$out" || fail "a successful backup did not return 0: $out"
grep -q 'id=ab12cd34' <<< "$out" || fail "the snapshot id was not captured: $out"

out="$(FAKE_RC=3 bash "$TMP_DIR/backup-harness.sh")"
grep -q 'rc=3' <<< "$out" \
  || fail "restic's exit status was not propagated (tee's status leaked through): $out"

grep -q 'snapshot ab12cd34 saved' "$TMP_DIR/stream.log" \
  || fail "backup output was not streamed to the log"

# The implementation must read PIPESTATUS, not the pipeline's own status.
backup_fn="$(awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
grep -q 'PIPESTATUS\[0\]' <<< "$backup_fn" \
  || fail "restic_backup_to must read PIPESTATUS[0] so tee cannot mask a failure"

# A killed run (systemd TimeoutStartSec is 18h) must not leave its capture file
# behind, and the signal traps must terminate rather than letting the shell
# continue after the signal.
fn_backup="$(awk '/^restic_backup_to\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media-backup")"
grep -q "trap .*runlog.* EXIT" <<< "$fn_backup" \
  || fail "restic_backup_to must clean its capture file on exit"
grep -qE "trap .*runlog.*exit [0-9]+.* (HUP|INT|TERM)" <<< "$fn_backup" \
  || fail "the signal traps must terminate, not merely clean up and continue"
grep -q 'trap - EXIT' <<< "$fn_backup" \
  || fail "the trap must be cleared once the capture file is gone"

# ---------------------------------------------------------------------------
# The backup must NOT pass --one-file-system.
#
# restic documents that flag as "don't cross filesystem boundaries AND
# SUBVOLUMES". Proven on this host with a disposable repo and a fixture holding a
# nested subvolume:
#
#   without -x :  .../svc/nested/b.txt   .../svc/plain/a.txt
#   with    -x :                         .../svc/plain/a.txt
#
# Every migrated service is a nested subvolume under /srv/data. Adding that flag
# -- which reads like a sensible "do not wander onto other disks" precaution --
# would silently drop every one of them from the backup, and the backup would
# still report success.
# ---------------------------------------------------------------------------
# Checked over the whole file with comments stripped, NOT by requiring the match
# to sit on a line containing "restic": the flag sits on a continuation line of
# its own, which is exactly how the first version of this check missed it.
#
# And NOT as `sed ... | grep -q`. Under `pipefail` that pipeline reports FAILURE
# when grep matches: grep -q exits at the first hit, sed takes SIGPIPE, and the
# pipeline status becomes non-zero -- so the `if` never fired and the check passed
# while the flag was present. Strip to a variable first.
backup_src_nocomments="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media-backup")"
if grep -qE -- '--one-file-system|(^|[[:space:]])-x([[:space:]]|$)' <<< "$backup_src_nocomments"; then
  fail "domum-media-backup passes --one-file-system (or -x) to restic; every migrated service, being a nested subvolume, would silently vanish from the backup"
fi
grep -q 'restic_for_target .* backup' "$REPO_ROOT/bin/domum-media-backup" \
  || fail "could not find the restic backup invocation; this check is not looking at anything"


# ---------------------------------------------------------------------------
# 5. Which repository a deep check, a full check and a restore DEFAULT to.
#
#    `default_restore_target` and `default_full_check_target` are both in the
#    never-executed set, and they decide which repository three operations act
#    on when no target is named. The preference is deliberately ASYMMETRIC and
#    nothing protected it:
#
#      restore / --check-deep   prefer nas    the fast local copy
#      --check-full             prefer cloud  the authoritative off-site copy
#
#    Swapping those would send a read-data check at a local placeholder and a
#    restore across the network, and both would still "work" -- which is why
#    the asymmetry needs pinning rather than a comment.
#
#    NOTE on the stubs: these functions do NOT call enabled_backup_targets.
#    They use backup_target_exists + backup_target_enabled, and
#    backup_target_names for the fallback scan. Stubbing the wrong one is a
#    stub of a function nobody calls, which is how this section was first
#    written and why it reported `nas` for a host with nothing enabled.
# ---------------------------------------------------------------------------
pref() {  # $1 = extra stubs, $2 = function
  bash -c "
set -uo pipefail
source '${PREF_CLI:-$REPO_ROOT/bin/domum-media-backup}' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
$1
$2
"
}

ALL_NAMES='backup_target_names() { printf "%s\n" nas cloud archive; }
backup_target_exists() { case "$1" in nas|cloud|archive) return 0 ;; *) return 1 ;; esac; }'

out="$(pref "$ALL_NAMES
backup_target_enabled() { case \"\$1\" in nas|cloud) return 0 ;; *) return 1 ;; esac; }" default_restore_target)"
[ "$out" = "nas" ] \
  || fail "5: with nas AND cloud enabled a restore must prefer nas, the fast local copy (got '$out')"

out="$(pref "$ALL_NAMES
backup_target_enabled() { case \"\$1\" in nas|cloud) return 0 ;; *) return 1 ;; esac; }" default_full_check_target)"
[ "$out" = "cloud" ] \
  || fail "5: with nas AND cloud enabled a FULL check must prefer cloud, the
authoritative off-site copy -- the asymmetry with restore is deliberate (got '$out')"

# nas disabled: both fall back to cloud.
out="$(pref "$ALL_NAMES
backup_target_enabled() { case \"\$1\" in cloud) return 0 ;; *) return 1 ;; esac; }" default_restore_target)"
[ "$out" = "cloud" ] || fail "5: with nas disabled a restore must fall back to cloud (got '$out')"

# This is production's shape: nas configured but explicitly disabled against a
# default of 1, cloud the only enabled target.
out="$(pref "$ALL_NAMES
backup_target_enabled() { case \"\$1\" in cloud) return 0 ;; *) return 1 ;; esac; }" default_full_check_target)"
[ "$out" = "cloud" ] || fail "5: production's shape must resolve to cloud (got '$out')"

# A target that is enabled but does NOT exist must not be chosen.
out="$(pref 'backup_target_names() { printf "%s\n" cloud; }
backup_target_exists() { case "$1" in cloud) return 0 ;; *) return 1 ;; esac; }
backup_target_enabled() { return 0; }' default_restore_target)"
[ "$out" = "cloud" ] \
  || fail "5: nas is 'enabled' here but does not EXIST, so it must not be
selected -- backup_target_exists is checked for a reason (got '$out')"

# Nothing enabled: refuse, rather than returning an empty target name. An empty
# name would reach restic_for_target and act on an unintended repository.
out="$(pref "$ALL_NAMES
backup_target_enabled() { return 1; }" default_restore_target)"
grep -q '^DIE:' <<< "$out" \
  || fail "5: with nothing enabled it must refuse, not return an empty target
that would reach restic_for_target (got '$out')"
grep -qi 'No enabled backup targets' <<< "$out" \
  || fail "5: the refusal does not say why: $out"

out="$(pref "$ALL_NAMES
backup_target_enabled() { return 1; }" default_full_check_target)"
grep -q '^DIE:' <<< "$out" \
  || fail "5: the full-check defaulter must refuse too, via the restore
defaulter it falls back to (got '$out')"
echo "  5: restore prefers nas, full check prefers cloud, neither invents a target"

# ---------------------------------------------------------------------------
# 6. --check-deep reads a percentage that must be defaulted, not unbound.
# ---------------------------------------------------------------------------
# A variable only load_cfg sets is unbound for any caller that has not run it,
# and under `set -u` that kills the process -- the family that once made
# `checkup` print nothing at all. load_cfg defaults it; this pins that it is
# defaulted somewhere rather than read raw.
grep -q 'BACKUP_DEEP_CHECK_PERCENT="\${BACKUP_DEEP_CHECK_PERCENT:-' "$REPO_ROOT/bin/domum-media-backup" \
  || fail "6: BACKUP_DEEP_CHECK_PERCENT is not defaulted, so --check-deep dies
under set -u for any caller that has not run load_cfg"
echo "  6: the deep-check percentage is defaulted"


# ---------------------------------------------------------------------------
# 7. MUTATION: swapping the full check's preference to nas must be caught.
#
#    The mutation runs against a COPY, so it cannot leave the real CLI
#    mutated -- a suite that mutates a tracked file is a suite that can be
#    stopped mid-run and leave the mutant behind.
# ---------------------------------------------------------------------------
cp "$REPO_ROOT/bin/domum-media-backup" "$TMP_DIR/mut-cli"
cat > "$TMP_DIR/mut7.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '\ndefault_full_check_target() {\n  if backup_target_exists cloud && backup_target_enabled cloud; then\n    echo "cloud"\n'
new = '\ndefault_full_check_target() {\n  if backup_target_exists nas && backup_target_enabled nas; then\n    echo "nas"\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("applied")
PY
python3 -I "$TMP_DIR/mut7.py" "$TMP_DIR/mut-cli" >/dev/null || fail "7: the preference mutation did not apply"
out="$(PREF_CLI="$TMP_DIR/mut-cli" pref "$ALL_NAMES
backup_target_enabled() { case \"\$1\" in nas|cloud) return 0 ;; *) return 1 ;; esac; }" default_full_check_target)"
[ "$out" = "nas" ] \
  || fail "7: the mutation applied but did not change the answer, so section 5
would pass against a swapped preference (got '$out')"
echo "  7: swapping the full check onto nas is caught"


# ---------------------------------------------------------------------------
# 8. --check-deep and --check-full are DIFFERENT checks on DIFFERENT targets.
#
#    Both are one-liners and both were in the never-executed set. What makes
#    them worth driving is that each pairs a flag with a defaulter, and the two
#    pairings are not interchangeable:
#
#      --check-deep   nas    --read-data-subset=<percent>   a sample
#      --check-full   cloud  --read-data                    every byte
#
#    A swapped flag would make a "full" check read 10% and report success,
#    which is the weaker claim in the stronger claim's words -- and a swapped
#    defaulter would read every byte of a local placeholder while the
#    authoritative off-site copy went unverified. Neither is visible from the
#    exit status, so the ARGUMENTS are the observable.
# ---------------------------------------------------------------------------
check_args() {  # $1 = function
  bash -c "
set -uo pipefail
source '$REPO_ROOT/bin/domum-media-backup' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
BACKUP_DEEP_CHECK_PERCENT='10%'
backup_target_names() { printf '%s\n' nas cloud; }
backup_target_exists() { case \"\$1\" in nas|cloud) return 0 ;; *) return 1 ;; esac; }
backup_target_enabled() { case \"\$1\" in nas|cloud) return 0 ;; *) return 1 ;; esac; }
check_repo_identity() { echo \"IDENTITY \$1\"; }
restic_check_for() { echo \"CHECK \$*\"; }
$1
"
}

out="$(check_args do_check_deep)"
grep -qx 'CHECK nas --read-data-subset=10%' <<< "$out" \
  || fail "8: a deep check must read a SUBSET of nas, the fast local copy: $out"
grep -qx 'IDENTITY nas' <<< "$out" \
  || fail "8: a deep check must verify the repository identity first: $out"
grep -q -- '--read-data$' <<< "$out" \
  && fail "8: a deep check must NOT read every byte -- that is the full check: $out"

out="$(check_args do_check_full)"
grep -qx 'CHECK cloud --read-data' <<< "$out" \
  || fail "8: a FULL check must read every byte of cloud, the authoritative
off-site copy: $out"
grep -qx 'IDENTITY cloud' <<< "$out" \
  || fail "8: a full check must verify the repository identity first: $out"
grep -q 'read-data-subset' <<< "$out" \
  && fail "8: a full check must not degrade to a subset: $out"

# An explicitly named target overrides the preference in both.
out="$(check_args 'do_check_deep cloud')"
grep -qx 'CHECK cloud --read-data-subset=10%' <<< "$out" \
  || fail "8: a named target must override the deep check's default: $out"
out="$(check_args 'do_check_full nas')"
grep -qx 'CHECK nas --read-data' <<< "$out" \
  || fail "8: a named target must override the full check's default: $out"
echo "  8: deep reads a subset of nas, full reads every byte of cloud"

echo "PASS: backup target evidence smoke test"
