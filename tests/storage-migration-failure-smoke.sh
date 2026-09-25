#!/usr/bin/env bash
set -uo pipefail

# Failure injection for `domum-media storage migrate-subvolume`.
#
# The invariant under test, for EVERY failure mode:
#
#   A migration failure must never leave less recoverable state than existed
#   before it started.
#
# Concretely: the original service data must still be readable, either at its
# original path or at the preserved .premigration path, and nothing may be
# deleted. Btrfs primitives are stubbed -- their real behaviour is proven
# separately in docs/BTRFS-MIGRATION-PLAN.md; what is exercised here is the
# algorithm, its guards, and its recovery paths.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo "kept: $TMP_DIR" || rm -rf "$TMP_DIR"' EXIT

CANARY='the-original-bytes-that-must-survive'

# $1 = scenario dir, $2 = extra stub overrides
run_migration() {
  local dir="$TMP_DIR/$1" stubs="${2:-}"
  rm -rf "$dir"; mkdir -p "$dir/data/jellyfin/config" "$dir/snapshots"
  printf '%s\n' "$CANARY" > "$dir/data/jellyfin/config/jellyfin.db"
  printf 'more\n' > "$dir/data/jellyfin/config/settings.xml"

  cat > "$dir/harness.sh" <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$dir/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$dir/data"
DOMUM_MEDIA_ROOT="$dir/media"
DOMUM_SNAPSHOT_ROOT="$dir/snapshots"
DOMUM_STATE_ROOT="$dir/state"
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
service_data_path() { printf '%s' "$dir/data/\$1"; }
service_compose_services() { printf 'jellyfin'; }
compose_cmd() { :; }
docker() { :; }
wait_for_service_health() { return 0; }
create_service_snapshot() { printf 'jellyfin-stub-snap'; }
# Track subvolume-ness out of band: a marker file inside the directory would
# inflate the file/byte counts that migrate_verify compares.
SUBVOL_REG="$dir/.subvols"
path_is_subvolume() { grep -qxF "\$1" "\$SUBVOL_REG" 2>/dev/null; }
btrfs() { case "\$1" in subvolume) mkdir -p "\${!#}" && printf '%s\\n' "\${!#}" >> "\$SUBVOL_REG";; esac; }
mv() {
  local src="\${@: -2:1}" dst="\${@: -1}"
  command mv "\$@" || return 1
  if grep -qxF "\$src" "\$SUBVOL_REG" 2>/dev/null; then
    printf '%s\\n' "\$dst" >> "\$SUBVOL_REG"
  fi
}
migrate_assert_same_btrfs() { :; }
# The fixture lives on /tmp, which is not Btrfs, so --reflink=always cannot
# work here. Reflink behaviour is proven separately against the real filesystem
# (see docs/BTRFS-MIGRATION-PLAN.md); this suite exercises the algorithm, its
# guards and its recovery paths.
cp() { command cp -a "\${@: -2:1}" "\${@: -1}"; }
$stubs
storage_migrate_subvolume jellyfin
EOF
  bash "$dir/harness.sh" >"$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
  printf '%s' "$dir"
}

# The canary must be findable somewhere, and nothing may have been destroyed.
assert_data_survives() {
  local dir="$1" label="$2" found
  found="$(grep -rl "$CANARY" "$dir/data" 2>/dev/null | head -1)"
  [ -n "$found" ] || fail "$label: the original data was DESTROYED — no copy of the canary remains"
  printf '    %-42s data survives at %s\n' "$label" "${found#"$dir/data/"}"
}

# ---------------------------------------------------------------------------
# Guards: refusals that must happen before anything changes.
# ---------------------------------------------------------------------------
echo "  guards:"

d="$(run_migration guard-unknown '' )"
out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'; CFG_FILE='$d/absent.conf'
source '$REPO_ROOT/bin/domum-media'
need_root() { :; }; load_cfg() { :; }; export_env_for_compose() { :; }
storage_migrate_subvolume definitely-not-a-service" 2>&1 || true)"
grep -qi 'not in the migration allowlist' <<< "$out" || fail "an unknown service must be refused: $out"
echo "    unknown service                            refused"

d="$(run_migration guard-already-subvol 'path_is_subvolume() { return 0; }')"
grep -qi 'already a Btrfs subvolume' "$d/out.txt" || fail "an existing subvolume must be refused"
[ "$(cat "$d/rc")" != "0" ] || fail "refusal must exit non-zero"
assert_data_survives "$d" "already a subvolume"

d="$(run_migration guard-premigration 'mkdir -p "'"$TMP_DIR"'/guard-premigration/data/jellyfin.premigration"')"
grep -qi 'premigration already exists' "$d/out.txt" || fail "an existing .premigration must be refused"
assert_data_survives "$d" "premigration already exists"

d="$(run_migration guard-newsub 'mkdir -p "'"$TMP_DIR"'/guard-newsub/data/jellyfin.new"')"
grep -qi 'already exists from an interrupted run' "$d/out.txt" || fail "a leftover .new must be refused"
assert_data_survives "$d" "leftover .new from an interrupted run"

d="$(run_migration guard-media 'service_data_path() { printf "%s" "'"$TMP_DIR"'/guard-media/media/jellyfin"; }
mkdir -p "'"$TMP_DIR"'/guard-media/media/jellyfin"')"
grep -qi 'media tier' "$d/out.txt" || fail "a path inside the media tier must be refused: $(cat "$d/out.txt")"
echo "    path inside the media tier                 refused"

# ---------------------------------------------------------------------------
# Failure injection: every stage that can fail.
# ---------------------------------------------------------------------------
echo "  failure injection:"

d="$(run_migration fail-stop 'compose_cmd() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a service that refuses to stop must abort the migration"
grep -qi 'could not stop' "$d/out.txt" || fail "the stop failure must be reported"
assert_data_survives "$d" "service refuses to stop"

# The quiesce check runs AFTER the service has been stopped, so aborting is only
# half the job: the service must also be put back. `migrate_assert_quiesced` used
# to call `die`, which exits the shell outright and made the caller's
# `|| { migrate_restart; exit 1; }` unreachable -- the migration refused, and
# left the service down until someone noticed.
d="$(run_migration fail-wal 'printf "wal" > "'"$TMP_DIR"'/fail-wal/data/jellyfin/config/jellyfin.db-wal"
compose_cmd() { printf "compose %s\n" "$*" >> "'"$TMP_DIR"'/fail-wal/compose.log"; return 0; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a non-empty WAL must abort the migration"
grep -qi 'write-ahead log' "$d/out.txt" || fail "the WAL condition must be reported"
assert_data_survives "$d" "non-empty SQLite WAL remains"
grep -q 'compose stop' "$d/compose.log" 2>/dev/null \
  || fail "the WAL scenario never reached the stop, so the restart assertion below proves nothing"
grep -q 'compose up -d' "$d/compose.log" 2>/dev/null \
  || fail "the migration aborted on a non-empty WAL and left the service stopped"

d="$(run_migration fail-create 'btrfs() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a failed subvolume creation must abort"
assert_data_survives "$d" "subvolume creation fails"

d="$(run_migration fail-copy 'cp() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a failed copy must abort"
grep -qi 'nothing was lost' "$d/out.txt" || fail "the copy failure must state that nothing was lost"
assert_data_survives "$d" "copy fails"
[ ! -e "$d/data/jellyfin.new" ] || fail "copy failure: the partial copy was not cleaned up"

d="$(run_migration fail-verify 'migrate_verify() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a verification mismatch must abort"
assert_data_survives "$d" "verification mismatch"
[ ! -e "$d/data/jellyfin.new" ] || fail "verify failure: the unverified copy was not cleaned up"
[ -d "$d/data/jellyfin" ] || fail "verify failure: the original is no longer at its original path"

# Cutover: the second rename fails, so the original must be put BACK.
# The real call is `mv -- SRC DST`, so inspect the LAST two arguments.
d="$(run_migration fail-cutover '
mv() {
  local src="${@: -2:1}" dst="${@: -1}"
  case "$src" in *.new) return 1 ;; esac
  command mv "$@"
}')"
[ "$(cat "$d/rc")" != "0" ] || fail "a failed cutover must abort"
assert_data_survives "$d" "cutover rename fails"
[ -d "$d/data/jellyfin" ] || fail "cutover failure: the original was NOT restored to its path"
grep -qi 'original was restored' "$d/out.txt" || fail "the cutover recovery must be reported"

d="$(run_migration fail-health 'wait_for_service_health() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "an unhealthy service must be reported as a failure"
grep -qi 'previous state is intact' "$d/out.txt" || fail "the health failure must point at the preserved state"
assert_data_survives "$d" "service unhealthy after migration"
[ -d "$d/data/jellyfin.premigration" ] || fail "health failure: the premigration copy is missing"

d="$(run_migration fail-snapshot 'create_service_snapshot() { return 1; }')"
grep -qi 'could NOT be created' "$d/out.txt" || fail "a failed proof snapshot must be reported"
assert_data_survives "$d" "proof snapshot fails"

# ---------------------------------------------------------------------------
# Success path.
# ---------------------------------------------------------------------------
echo "  success path:"
d="$(run_migration success '')"
[ "$(cat "$d/rc")" = "0" ] || fail "the success path failed: $(cat "$d/out.txt")"
grep -qxF "$d/data/jellyfin" "$d/.subvols" || fail "success: the service path is not a subvolume"
[ -d "$d/data/jellyfin.premigration" ] || fail "success: the previous state was not preserved"
grep -q "$CANARY" "$d/data/jellyfin/config/jellyfin.db" || fail "success: content did not survive the migration"
grep -q "$CANARY" "$d/data/jellyfin.premigration/config/jellyfin.db" || fail "success: the preserved copy is wrong"
grep -qi 'retained deliberately' "$d/out.txt" || fail "success: the operator was not told the previous state is kept"
echo "    migrated, verified, premigration retained  OK"

# Nothing in the implementation may delete a premigration copy.
grep -nE 'rm -rf.*premigration|rm -r .*premigration' "$REPO_ROOT/bin/domum-media" \
  && fail "the implementation deletes a premigration copy"

# ---------------------------------------------------------------------------
# migrate_verify must never pass having hashed nothing.
#
# The sampling branch selected `NR % step == 1`, which for step == 1 is never
# true. The sample came out EMPTY, the comparison loop never ran, and
# verification reported success on a copy it had not looked at. Reachable
# whenever MIGRATE_FULL_HASH_MAX_FILES < files < 400, which a config line
# lowering that knob is enough to arm.
# ---------------------------------------------------------------------------
verify_fixture() {  # $1 = dir, $2 = n files, $3 = dst content
  rm -rf "$TMP_DIR/$1"; mkdir -p "$TMP_DIR/$1/src" "$TMP_DIR/$1/dst"
  local i
  for i in $(seq 1 "$2"); do
    printf 'AAAAAAAA\n' > "$TMP_DIR/$1/src/f$i"
    printf '%s\n' "$3"   > "$TMP_DIR/$1/dst/f$i"
  done
}

run_verify() {  # $1 = dir, $2 = cap
  bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
MIGRATE_FULL_HASH_MAX_FILES=$2
migrate_verify '$TMP_DIR/$1/src' '$TMP_DIR/$1/dst'
" 2>&1
}

# 250 files with a cap of 100 puts step at 1 -- the degenerate case. Byte totals
# match exactly, so nothing earlier in migrate_verify can catch this: only the
# content comparison can, and it must.
verify_fixture vzero 250 BBBBBBBB
out="$(run_verify vzero 100)"
rc=$?
(( rc != 0 )) || fail "migrate_verify PASSED on a copy whose content is 100% different: $out"
grep -q 'mismatch' <<< "$out" || fail "migrate_verify failed without naming a mismatch: $out"

# The same fixture with identical content must still pass, and must SAY how many
# files it actually hashed -- a verification that reports no count can hide a
# sample of zero.
verify_fixture vsame 250 AAAAAAAA
out="$(run_verify vsame 100)"
rc=$?
(( rc == 0 )) || fail "migrate_verify failed on identical trees: $out"
grep -qE 'sampled content identical \([1-9][0-9]* of [0-9]+ file' <<< "$out" \
  || fail "migrate_verify did not report a non-zero sample size: $out"

# Pin the selector: first, last, every Nth, and the largest file.
#
# 501 files put the stride at 2, so EVEN positions are the strided ones. f001,
# f501 and f249 all sit at ODD positions, which means each is reachable only via
# its own rule -- drop that rule and the differing file goes unnoticed. f249 is
# made the largest so "largest" cannot be satisfied by accident: when every file
# is the same size the first one is trivially the largest, and a first/largest
# mix-up would hide behind that.
rm -rf "$TMP_DIR/vstride"; mkdir -p "$TMP_DIR/vstride/src" "$TMP_DIR/vstride/dst"
for i in $(seq -w 1 501); do
  printf 'AAAAAAAA\n' > "$TMP_DIR/vstride/src/f$i"
done
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$TMP_DIR/vstride/src/f249"
cp -a "$TMP_DIR/vstride/src/." "$TMP_DIR/vstride/dst/"

out="$(run_verify vstride 100)"
rc=$?
(( rc == 0 )) || fail "migrate_verify failed on 501 identical files: $out"
sampled="$(sed -n 's/.*sampled content identical (\([0-9]*\) of .*/\1/p' <<< "$out")"
[[ "$sampled" =~ ^[0-9]+$ ]] || fail "could not read the sample size from: $out"
(( sampled > 150 && sampled < 350 )) \
  || fail "step-2 sampling of 501 files hashed $sampled file(s); the stride is not working"

# Each of the four selection rules, isolated.
# The corruption must be the SAME SIZE as the original, or migrate_verify stops
# at the byte-count check and never reaches the sampling code this is testing --
# which would make every assertion below pass for the wrong reason.
check_caught() {  # $1 = file, $2 = which rule
  cp -a "$TMP_DIR/vstride/src/." "$TMP_DIR/vstride/dst/"
  local f="$TMP_DIR/vstride/dst/$1" n o rc
  n="$(stat -c %s "$f")"
  head -c "$n" /dev/zero | tr '\0' 'B' > "$f"
  [[ "$(stat -c %s "$f")" == "$n" ]] || fail "test bug: corruption changed the size of $1"
  o="$(run_verify vstride 100)"; rc=$?
  (( rc != 0 )) || fail "migrate_verify missed a differing $2 file ($1): $o"
  grep -q "mismatch: ./$1" <<< "$o" \
    || fail "migrate_verify failed but did not name $1 as the mismatch: $o"
}
check_caught f001 FIRST
check_caught f501 LAST
check_caught f249 LARGEST
check_caught f002 STRIDED
cp -a "$TMP_DIR/vstride/src/." "$TMP_DIR/vstride/dst/"

# A filename containing a newline must be compared, not split into two paths
# that both fail to hash -- and not silently skipped.
verify_fixture vnl 250 AAAAAAAA
printf 'AAAAAAAA\n' > "$TMP_DIR/vnl/src/od
d"
printf 'BBBBBBBB\n' > "$TMP_DIR/vnl/dst/od
d"
out="$(run_verify vnl 100)"
rc=$?
(( rc != 0 )) || fail "migrate_verify PASSED despite a differing file whose name contains a newline: $out"

# ---------------------------------------------------------------------------
# migrate_verify must compare metadata, not only content.
#
# BTRFS-MIGRATION-PLAN.md has always claimed ownership and permissions are
# verified; they were not. `cp -a --reflink` preserves type, mode, owner, group
# and symlink targets, so any difference means the copy is wrong -- and the
# content manifest, which only hashes regular files, cannot see any of it.
#
# /srv/data really does contain symlinks (7, under plex/…/Drivers), so this is
# not hypothetical.
# ---------------------------------------------------------------------------
meta_fixture() {
  rm -rf "$TMP_DIR/vmeta"; mkdir -p "$TMP_DIR/vmeta/src/sub" "$TMP_DIR/vmeta/src/empty"
  printf 'content\n' > "$TMP_DIR/vmeta/src/a"
  ln -s a "$TMP_DIR/vmeta/src/link"
  mkdir -p "$TMP_DIR/vmeta/dst"
  cp -a "$TMP_DIR/vmeta/src/." "$TMP_DIR/vmeta/dst/"
}

meta_fixture
out="$(run_verify vmeta 10000)"
rc=$?
(( rc == 0 )) || fail "migrate_verify failed on a faithful copy: $out"
grep -q 'symlink targets identical' <<< "$out" \
  || fail "migrate_verify did not report that it checked metadata: $out"

# A symlink retargeted to a name of the SAME LENGTH: identical file count,
# identical byte total, identical content hashes. Only the metadata check sees it.
meta_fixture
rm "$TMP_DIR/vmeta/dst/link"; ln -s b "$TMP_DIR/vmeta/dst/link"
out="$(run_verify vmeta 10000)"
rc=$?
(( rc != 0 )) || fail "migrate_verify missed a retargeted symlink: $out"

# Permissions.
meta_fixture
chmod 700 "$TMP_DIR/vmeta/dst/sub"
out="$(run_verify vmeta 10000)"
rc=$?
(( rc != 0 )) || fail "migrate_verify missed a permissions difference: $out"

# An empty directory that never arrived: no files, no bytes, nothing to hash.
meta_fixture
rmdir "$TMP_DIR/vmeta/dst/empty"
out="$(run_verify vmeta 10000)"
rc=$?
(( rc != 0 )) || fail "migrate_verify missed a missing empty directory: $out"

# A migration must refuse while another operation holds the lock -- and must
# refuse BEFORE touching anything, so the refusal is free.
lockdir="$TMP_DIR/locked"
rm -rf "$lockdir"; mkdir -p "$lockdir/state"
(
  exec 9>>"$lockdir/state/operation.lock"
  flock -n 9 || exit 1
  printf '999 now other-operation\n' > "$lockdir/state/operation.lock.holder"
  while [[ ! -e "$lockdir/release" ]]; do sleep 0.05; done
) &
lock_pid=$!
for _ in $(seq 1 100); do [[ -e "$lockdir/state/operation.lock.holder" ]] && break; sleep 0.05; done

d="$(run_migration locked-out 'DOMUM_STATE_ROOT="'"$lockdir"'/state"')"
[ "$(cat "$d/rc")" != "0" ] || fail "a migration ran while another operation held the lock"
grep -qi 'holds the lock' "$d/out.txt" || fail "the lock refusal was not reported: $(cat "$d/out.txt")"
grep -qi 'other-operation' "$d/out.txt" || fail "the refusal did not name the lock holder"
assert_data_survives "$d" "another operation holds the lock"
[ ! -e "$d/data/jellyfin.new" ] || fail "a lock refusal still staged a copy"

touch "$lockdir/release"
wait "$lock_pid" 2>/dev/null

# A migration that completes but cannot establish rollback protection must not
# report a clean exit status. The old `[[ -n "$proof" ]] && echo …` was the
# function's last statement, so an empty proof returned 1 SILENTLY, immediately
# after printing "Migration complete" -- correct by accident, and unexplained.
d="$(run_migration no-proof 'create_service_snapshot() { return 1; }')"
[ "$(cat "$d/rc")" != "0" ] || fail "a migration with no proof snapshot reported success"
grep -qi 'rollback protection was not established' "$d/out.txt" \
  || fail "the missing proof snapshot was not explained: $(cat "$d/out.txt")"
grep -qi 'migration complete' "$d/out.txt" \
  || fail "the migration did not actually complete, so this proves nothing"
[ -d "$d/data/jellyfin.premigration" ] \
  || fail "the premigration copy is missing after a completed migration"

# ...and the success path, with a proof snapshot, must exit zero.
d="$(run_migration with-proof)"
[ "$(cat "$d/rc")" = "0" ] \
  || fail "a fully successful migration did not exit zero: $(cat "$d/out.txt")"

# The runbooks must not tell an operator to run a bare `docker compose`. There is
# no compose.yml in the installation -- the stack is assembled from fragments --
# so it fails with "no configuration file provided", during recovery, which is
# the worst possible time to find out.
# Only command lines count -- prose explaining what the CLI does internally, or
# explaining why this rule exists, is fine.
if grep -rnE '^[[:space:]]*(sudo[[:space:]]+)?docker[[:space:]]+compose[[:space:]]' "$REPO_ROOT/docs"/*.md; then
  fail "a runbook still tells the operator to run docker compose directly"
fi
grep -q 'compose)   shift; compose_passthrough' "$REPO_ROOT/bin/domum-media" \
  || fail "domum-media compose is not wired into the dispatcher"

# ---------------------------------------------------------------------------
# "The containers are stopped" is not "nothing is writing".
#
# A leftover process, a manual `docker run`, an editor, a stray rsync -- none of
# them appear in `docker ps`, and the migration's whole safety argument rests on
# the tree being still. Read from /proc rather than lsof/fuser: fuser is NOT
# installed on this host, and a check that degrades to "no tool, assume fine" is
# worse than no check.
# ---------------------------------------------------------------------------
oh() {
  bash -c "
set -uo pipefail
$(awk '/^migrate_process_group\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")
$(awk '/^migrate_open_handles\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")
$1"
}

ohdir="$TMP_DIR/openhandles"
mkdir -p "$ohdir"
printf 'x\n' > "$ohdir/file"

# Nothing open -> nothing reported.
[[ -z "$(oh "migrate_open_handles '$ohdir'")" ]] \
  || fail "a quiet directory reported open handles"

# Our OWN inherited descriptors must stay invisible. Excluding only the shell PID is not
# enough: every subshell and pipeline member inherits the parent's descriptors,
# so a PID-only exclusion reports the checker itself as a foreign writer.
out="$(oh "exec 7>'$ohdir/file'; migrate_open_handles '$ohdir'")"
[[ -z "$out" ]] || fail "the check reported its own inherited descriptors: $out"

# A process in a DIFFERENT process group must be seen.
# `setsid` forks, so $! is setsid's PID, not the sleep's. The holder records its
# own PID instead, and is killed by PID rather than by pattern: this runs on a
# live host where a pattern match could take out something unrelated.
setsid bash -c 'echo $$ > "$1"; exec sleep 30' _ "$ohdir/holder.pid" < "$ohdir/file" &
for _ in $(seq 1 40); do [[ -s "$ohdir/holder.pid" ]] && break; sleep 0.05; done
holder="$(cat "$ohdir/holder.pid" 2>/dev/null || true)"
[[ -n "$holder" ]] || fail "the test holder process never started"
sleep 0.5
out="$(oh "migrate_open_handles '$ohdir'")"
[[ -n "$holder" ]] && kill "$holder" 2>/dev/null
wait 2>/dev/null || true
rm -f "$ohdir/holder.pid"
[[ -n "$out" ]] || fail "a foreign process holding a file open was not detected"
grep -q 'sleep' <<< "$out" || fail "the open handle was not attributed to a process: $out"

# And the quiesce check must refuse on it rather than migrating over a live writer.
# `setsid` forks, so $! is setsid's PID, not the sleep's. The holder records its
# own PID instead, and is killed by PID rather than by pattern: this runs on a
# live host where a pattern match could take out something unrelated.
setsid bash -c 'echo $$ > "$1"; exec sleep 30' _ "$ohdir/holder.pid" < "$ohdir/file" &
for _ in $(seq 1 40); do [[ -s "$ohdir/holder.pid" ]] && break; sleep 0.05; done
holder="$(cat "$ohdir/holder.pid" 2>/dev/null || true)"
[[ -n "$holder" ]] || fail "the test holder process never started"
sleep 0.5
out="$( { bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
migrate_assert_quiesced '$ohdir'" ; } 2>&1 )"
rc=$?
[[ -n "$holder" ]] && kill "$holder" 2>/dev/null
wait 2>/dev/null || true
rm -f "$ohdir/holder.pid"
(( rc != 0 )) || fail "the quiesce check passed while a process held a file open: $out"
grep -qi 'still has files open' <<< "$out" || fail "the refusal did not explain itself: $out"

# A hot rollback journal is NOT a refusal: with the writer stopped the journal is
# copied alongside its database and SQLite recovers from the pair. It is recorded,
# not treated as an error.
rm -rf "$ohdir"; mkdir -p "$ohdir"
printf 'j\n' > "$ohdir/app.db-journal"
out="$( { bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
migrate_assert_quiesced '$ohdir'" ; } 2>&1 )"
rc=$?
(( rc == 0 )) || fail "a hot rollback journal must not block the migration: $out"
grep -qi 'rollback journal' <<< "$out" || fail "the hot journal was not recorded: $out"

# The proof snapshot must be taken while the service is still stopped, so it is
# a snapshot of a cleanly quiesced tree rather than a running one. Ordering is
# asserted from the stage log, because that is what an operator reads too.
# migrate_restart sends compose output to /dev/null, so the stubs record their
# order in a file rather than on stderr.
d="$(run_migration proof-order 'ORDER="'"$TMP_DIR"'/proof-order/order.log"
create_service_snapshot() { printf "proof\n" >> "$ORDER"; printf "jellyfin-stub-snap"; }
compose_cmd() { [[ "${1:-}" == "up" ]] && printf "restart\n" >> "$ORDER"; return 0; }')"
[ "$(cat "$d/rc")" = "0" ] || fail "the ordering scenario did not complete: $(cat "$d/out.txt")"
[ -f "$d/order.log" ] || fail "neither the proof snapshot nor the restart happened"
grep -q '^proof$' "$d/order.log" || fail "the proof snapshot was never taken"
grep -q '^restart$' "$d/order.log" || fail "the service was never restarted"
[ "$(head -1 "$d/order.log")" = "proof" ] \
  || fail "the proof snapshot was taken AFTER the restart, so it is crash-consistent rather than clean: $(cat "$d/order.log")"

# ---------------------------------------------------------------------------
# migrate_verify must not report "content manifest identical" over files it
# never hashed.
#
# `migrate_manifest` pipes through `xargs -0 sha256sum 2>/dev/null`, so a file
# sha256sum cannot read is DROPPED from the manifest silently -- and because it
# drops out of both manifests identically, the diff passes. The file count comes
# from `find`, so it cannot catch this either. Demonstrated: 2 files on disk,
# 1 line in the manifest.
#
# Root can normally read everything, so this guards a verification that quietly
# proves less than it claims rather than a condition seen today.
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR/vunread"; mkdir -p "$TMP_DIR/vunread/src" "$TMP_DIR/vunread/dst"
printf 'readable\n' > "$TMP_DIR/vunread/src/ok.dat"
printf 'secretxx\n' > "$TMP_DIR/vunread/src/secret.dat"
cp -a "$TMP_DIR/vunread/src/." "$TMP_DIR/vunread/dst/"

if [ "$(id -u)" -eq 0 ]; then
  echo "    manifest completeness                      skipped (root reads everything)"
else
  chmod 000 "$TMP_DIR/vunread/src/secret.dat" "$TMP_DIR/vunread/dst/secret.dat"
  out="$(run_verify vunread 10000)"
  rc=$?
  chmod 644 "$TMP_DIR/vunread/src/secret.dat" "$TMP_DIR/vunread/dst/secret.dat"
  (( rc != 0 )) \
    || fail "migrate_verify reported success over a file it never hashed: $out"
  grep -qi 'could not be hashed' <<< "$out" \
    || fail "the incomplete manifest was not reported: $out"
  grep -qE 'manifests cover 1 and 1 of 2' <<< "$out" \
    || fail "the refusal did not say how much of the tree was actually covered: $out"

  # And a fully readable pair must still pass, and must say how many it covered.
  out="$(run_verify vunread 10000)"
  rc=$?
  (( rc == 0 )) || fail "migrate_verify failed on a fully readable pair: $out"
  grep -qE 'content manifest identical \(2 of 2 file' <<< "$out" \
    || fail "migrate_verify did not report the manifest coverage: $out"
fi

echo "PASS: storage migration failure smoke test"
