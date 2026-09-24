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

echo "PASS: storage migration failure smoke test"
