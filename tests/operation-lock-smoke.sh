#!/usr/bin/env bash
set -uo pipefail

# Proves that state-mutating operations cannot run concurrently, and that the
# lock cannot silently stop working.
#
# The hazard: the nightly backup fires at 02:30 (+15m jitter) and reads all of
# /srv/data with no exclude for .new / .premigration / .rollback-*. A migration
# renaming directories underneath restic makes the backup fail for a reason
# nobody can see the next morning.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v flock >/dev/null 2>&1 || fail "flock is required for this test"

# ---------------------------------------------------------------------------
# 1. The helper is byte-identical in both scripts.
#
# It is deliberately duplicated rather than sourced from a new file. That trade
# is only safe while the two copies agree: if they ever computed different lock
# paths the scripts would take different locks, exclude nothing, and fail
# silently -- the worst possible failure for a lock. This repository has already
# shipped one bug of exactly that shape (two `backup_target_names` with
# divergent defaults), so it is pinned here.
# ---------------------------------------------------------------------------
extract_helper() {
  awk '/^# BEGIN SHARED LOCK HELPER$/,/^# END SHARED LOCK HELPER$/' "$1"
}
a="$(extract_helper "$REPO_ROOT/bin/domum-media")"
b="$(extract_helper "$REPO_ROOT/bin/domum-media-backup")"
[[ -n "$a" ]] || fail "bin/domum-media has no shared lock helper"
[[ -n "$b" ]] || fail "bin/domum-media-backup has no shared lock helper"
[[ "$a" == "$b" ]] || {
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") >&2
  fail "the lock helper has drifted between the two scripts"
}

# Both must resolve the same lock path for the same state root.
for script in domum-media domum-media-backup; do
  got="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$(extract_helper "$REPO_ROOT/bin/$script")
domum_lock_file")"
  [[ "$got" == "$TMP_DIR/state/operation.lock" ]] \
    || fail "$script resolved an unexpected lock path: $got"
done

# ---------------------------------------------------------------------------
# 2. The lock actually excludes.
# ---------------------------------------------------------------------------
lock_helper="$(extract_helper "$REPO_ROOT/bin/domum-media")"

# Holder: takes the lock, then waits for a file to appear before exiting.
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'holder-op' 0 || exit 9
touch '$TMP_DIR/held'
while [[ ! -e '$TMP_DIR/release' ]]; do sleep 0.05; done
" &
holder_pid=$!
for _ in $(seq 1 100); do [[ -e "$TMP_DIR/held" ]] && break; sleep 0.05; done
[[ -e "$TMP_DIR/held" ]] || fail "the holder never acquired the lock"

# A second attempt with no wait must fail immediately.
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'second-op' 0
" && fail "a second operation acquired the lock while it was held"

# ...and must be able to say who holds it.
holder="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_lock_holder")"
grep -q 'holder-op' <<< "$holder" || fail "the holder was not reported: $holder"

# A bounded wait that expires must also fail, rather than proceeding.
start=$(date +%s)
bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'waiter-op' 1
" && fail "a waiting operation acquired a lock that was never released"
(( $(date +%s) - start >= 1 )) || fail "the bounded wait did not actually wait"

# ---------------------------------------------------------------------------
# 3. Releasing is automatic. The lock lives in a file descriptor, so a process
#    that is SIGKILLed -- leaving no chance to clean up -- must not wedge the
#    system. A lock scheme that needs a stale-lock reaper becomes the outage.
# ---------------------------------------------------------------------------
kill -9 "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
touch "$TMP_DIR/release"

ok=0
for _ in $(seq 1 100); do
  if bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
$lock_helper
domum_acquire_lock 'after-kill' 0"; then ok=1; break; fi
  sleep 0.05
done
(( ok == 1 )) || fail "the lock was not released when the holder was SIGKILLed"

# ---------------------------------------------------------------------------
# 4. The operations that need the lock actually take it.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "storage migrate-subvolume' "$REPO_ROOT/bin/domum-media" \
  || fail "storage migrate-subvolume does not take the operation lock"
grep -q 'domum_acquire_lock "rollback apply' "$REPO_ROOT/bin/domum-media" \
  || fail "rollback apply does not take the operation lock"
grep -q 'domum_acquire_lock "daily backup"' "$REPO_ROOT/bin/domum-media-backup" \
  || fail "the daily backup does not take the operation lock"

# The unattended backup must WAIT; the attended operations must not. A backup
# that gave up would silently skip a night, which is what the lock exists to
# prevent.
grep -q 'domum_acquire_lock "daily backup" "${BACKUP_LOCK_WAIT_SECONDS:-1800}"' \
  "$REPO_ROOT/bin/domum-media-backup" \
  || fail "the daily backup must wait for the lock, not fail immediately"

# ---------------------------------------------------------------------------
# 5. The lock must not be inheritable by a child that outlives the acquirer.
#
# The lock lives in an open file descriptor, and every child inherits it. A
# service started under the lock and left running keeps holding it after the
# acquiring process is long gone -- and because there is deliberately no
# stale-lock reaper, the next backup waits its full timeout and fails, every
# night, until reboot.
#
# Found by the real-Btrfs integration test: `compose_cmd up -d` starts
# long-lived processes while a migration holds the lock. compose_cmd therefore
# drops the descriptor for that command.
# ---------------------------------------------------------------------------
grep -q 'DOMUM_LOCK_FD}>&-' "$REPO_ROOT/bin/domum-media" \
  || fail "compose_cmd does not close the lock descriptor; a started service would inherit and hold the lock"

# A child WITHOUT the fd closed keeps the lock after its parent exits; with the
# fd closed it does not. Holders record their own PID and are killed by PID --
# `pkill -f` on a live host can match the test's own shell (it did).
probe_leak() {  # $1 = state dir, $2 = "inherit" | "closed"
  local d="$1" mode="$2"
  mkdir -p "$d"
  if [[ "$mode" == "closed" ]]; then
    bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$d'
$lock_helper
domum_acquire_lock 'probe' 0 || exit 9
setsid bash -c 'echo \$\$ > \"\$1\"; exec sleep 20' _ '$d/holder.pid' >/dev/null 2>&1 {DOMUM_LOCK_FD}>&- &
for _ in \$(seq 1 40); do [[ -s '$d/holder.pid' ]] && break; sleep 0.05; done
"
  else
    bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$d'
$lock_helper
domum_acquire_lock 'probe' 0 || exit 9
setsid bash -c 'echo \$\$ > \"\$1\"; exec sleep 20' _ '$d/holder.pid' >/dev/null 2>&1 &
for _ in \$(seq 1 40); do [[ -s '$d/holder.pid' ]] && break; sleep 0.05; done
"
  fi
}

held_after_parent_exit() {  # $1 = state dir -> prints yes/no, then cleans up
  local d="$1" pid
  if bash -c "exec 9>>'$d/operation.lock'; flock -n 9"; then printf 'no'; else printf 'yes'; fi
  pid="$(cat "$d/holder.pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
}

probe_leak "$TMP_DIR/leak" inherit   || fail "the inherit probe could not acquire the lock"
[[ "$(held_after_parent_exit "$TMP_DIR/leak")" == "yes" ]] \
  || fail "fixture is wrong: an inheriting child should have held the lock, so the next check proves nothing"

probe_leak "$TMP_DIR/noleak" closed  || fail "the closed-fd probe could not acquire the lock"
[[ "$(held_after_parent_exit "$TMP_DIR/noleak")" == "no" ]] \
  || fail "a child spawned with the lock descriptor closed still holds the lock"

# ---------------------------------------------------------------------------
# 6. host-upgrade must take the lock.
#
# It runs `apt-get install --only-upgrade docker-ce containerd.io btrfs-progs …`
# on Mondays at 05:45 (+45m) and can then reboot the host. Upgrading docker-ce
# RESTARTS the Docker daemon, which restarts containers -- and a migration has
# those containers deliberately stopped while it copies and then renames their
# data directory. The daemon would bring a service back up onto a half-copied
# .new, or during the cutover rename itself.
#
# It waits rather than skipping: giving up would silently miss a week of
# security updates.
# ---------------------------------------------------------------------------
grep -q 'domum_acquire_lock "host-upgrade"' "$REPO_ROOT/bin/domum-media" \
  || fail "host-upgrade does not take the operation lock; a Docker daemon restart could land mid-migration"
grep -q 'domum_acquire_lock "host-upgrade" "${HOST_UPGRADE_LOCK_WAIT_SECONDS:-1800}"' "$REPO_ROOT/bin/domum-media" \
  || fail "host-upgrade must wait for the lock, not fail immediately"

# The lock must be taken only AFTER the enable gate, so a disabled upgrade stays
# a cheap no-op that cannot block anything.
gate_line="$(grep -n 'Scheduled host package upgrades disabled' "$REPO_ROOT/bin/domum-media" | head -1 | cut -d: -f1)"
lock_line="$(grep -n 'domum_acquire_lock "host-upgrade"' "$REPO_ROOT/bin/domum-media" | head -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$lock_line" && "$gate_line" -lt "$lock_line" ]] \
  || fail "host-upgrade takes the lock before checking whether it is enabled (gate=$gate_line lock=$lock_line)"

# And it must actually refuse while the lock is held.
hudir="$TMP_DIR/hu"; mkdir -p "$hudir"
setsid bash -c 'exec 9>>"$1/operation.lock"; flock 9; echo $$ > "$1/holder.pid"; exec sleep 30' \
  _ "$hudir" >/dev/null 2>&1 &
for _ in $(seq 1 40); do [[ -s "$hudir/holder.pid" ]] && break; sleep 0.05; done
huholder="$(cat "$hudir/holder.pid" 2>/dev/null || true)"
[[ -n "$huholder" ]] || fail "could not start a competing lock holder"
out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
DOMUM_STATE_ROOT='$hudir'
HOST_UPGRADE_LOCK_WAIT_SECONDS=1
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
apt-get() { echo 'APT RAN'; }
host_upgrade --force" 2>&1)"
rc=$?
kill "$huholder" 2>/dev/null; wait 2>/dev/null
(( rc != 0 )) || fail "host-upgrade ran while the operation lock was held: $out"
grep -q 'APT RAN' <<< "$out" && fail "apt was invoked despite the lock being held: $out"
grep -qi 'Timed out waiting' <<< "$out" || fail "the lock refusal did not explain itself: $out"

# ---------------------------------------------------------------------------
# 7. The stop verification must not use a SIGPIPE-prone pipeline.
#
# Under `pipefail`, `cmd | grep -q` reports 141 when grep matches: grep exits at
# the first hit and the left-hand command takes SIGPIPE. Measured:
# `sed bin/domum-media | grep -q <hit>` returns 141.
#
# In stop_compose_services_verified an inverted result declares a RUNNING
# container stopped and lets the migration proceed over live state. It does not
# bite at 130 bytes of `docker ps` output -- 0 inversions in 1000 trials, because
# that fits the pipe buffer -- but the entire migration safety argument should not
# rest on the output staying small.
# ---------------------------------------------------------------------------
# Comments stripped: this function's own comment explains the hazard by naming the
# pattern, and matching that would fail on correct code.
fn_stop="$(awk '/^stop_compose_services_verified\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media" | sed 's/#.*//')"
[[ -n "$fn_stop" ]] || fail "could not extract stop_compose_services_verified"
if grep -qE 'docker ps[^|]*\|[[:space:]]*grep' <<< "$fn_stop"; then
  fail "the stop verification pipes docker ps into grep; under pipefail a match reads as no-match and a running container would be declared stopped"
fi
grep -q 'running="\$(docker ps' <<< "$fn_stop" \
  || fail "the stop verification does not capture docker ps output before matching"
grep -q 'grep -qFx -- "\$svc" <<< "\$running"' <<< "$fn_stop" \
  || fail "the stop verification does not match against the captured output"

# ---------------------------------------------------------------------------
# AND NOW IT IS EXECUTED, not merely read.
#
# The assertions above are about the function's TEXT. This project already
# records why that is not enough -- `service_upgrade` shipped calling an
# undefined helper while 41 suites passed, because every assertion about it
# read its source and none ran it. Swept 2026-11-06: `stop_compose_services_
# verified` was in exactly that state. It is text-asserted here and STUBBED to
# `return 0` in the three other suites that touch it, so its real logic had
# never been executed by any test -- and it is the check the whole migration
# safety argument rests on, since a false "stopped" lets a migration copy a
# live database.
# ---------------------------------------------------------------------------
echo "== the stop verification, EXECUTED =="
stopv() {  # $1 = services, $2 = docker ps output, $3 = compose stop rc
  local SV_SVCS="$1" SV_PS="$2" SV_RC="$3"
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media" >/dev/null 2>&1
    set +e
    # NAMED variables, not positionals: inside these stubs $2 and $3 are the
    # STUB's own arguments -- `docker ps --format ...` would make $2 the format
    # flag and `compose_cmd stop kavita plex` would make $3 the second service.
    compose_cmd() { return "$SV_RC"; }
    docker() { [[ "${1:-}" == "ps" ]] && printf '%s\n' "$SV_PS"; return 0; }
    stop_compose_services_verified "$SV_SVCS"
    echo "rc=$?"
  ) 2>&1
}

# Nothing to stop is success, and it must not consult docker at all.
out="$(stopv "" "" 0)"
grep -q 'rc=0' <<< "$out" || fail "an empty service list did not succeed: $out"

# Everything stopped -> success.
out="$(stopv "kavita plex" "traefik
immich_server" 0)"
grep -q 'rc=0' <<< "$out" || fail "all services stopped did not succeed: $out"

# ONE still running -> refuse, and NAME it. This is the direction that matters.
out="$(stopv "kavita plex" "traefik
plex
immich_server" 0)"
grep -q 'rc=1' <<< "$out" || fail "a still-running container was declared stopped: $out"
grep -q 'Still running after stop: plex' <<< "$out" \
  || fail "the refusal does not name the service still running: $out"
grep -qF 'kavita' <<< "$(sed -n '/Still running/p' <<< "$out")" \
  && fail "it names a service that HAD stopped: $out"

# A failed `compose stop` refuses before any verification.
out="$(stopv "kavita" "" 1)"
grep -q 'rc=1' <<< "$out" || fail "a failed compose stop did not refuse: $out"
grep -q 'Could not stop: kavita' <<< "$out" || fail "the stop failure is not reported: $out"

# A SUBSTRING must not count as stopped or as running: the match is whole-line.
# `kavita` must not be satisfied by a running `kavita-extra`, and must not be
# excused by one either.
out="$(stopv "kavita" "kavita-extra" 0)"
grep -q 'rc=0' <<< "$out" \
  || fail "a running container whose name merely CONTAINS the service name was
treated as that service still running: $out"
out="$(stopv "kavita-extra" "kavita" 0)"
grep -q 'rc=0' <<< "$out" \
  || fail "a prefix of the service name was treated as the service itself: $out"
echo "   empty / all-stopped / one-running(named) / stop-failed / whole-line match"

echo "== MUTATION: an inverted match declares a running container stopped =="
mut="$TMP_DIR/cli-stopmut"
cp "$REPO_ROOT/bin/domum-media" "$mut"
python3 - "$mut" <<'PYSM'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '    if grep -qFx -- "$svc" <<< "$running"; then'
new = '    if ! grep -qFx -- "$svc" <<< "$running"; then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYSM
grep -qF 'if ! grep -qFx -- "$svc"' "$mut" || fail "the inversion mutation did not apply"
mout="$( ( source "$mut" >/dev/null 2>&1; set +e
           compose_cmd() { return 0; }
           docker() { [[ "${1:-}" == "ps" ]] && printf 'plex\n'; return 0; }
           stop_compose_services_verified "plex"; echo "rc=$?" ) 2>&1 )"
grep -q 'rc=0' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- an inverted match must declare the
RUNNING container stopped: $mout"
echo "  killed: the mutant lets a migration proceed over a running container"

# ---------------------------------------------------------------------------
# The check compares COMPOSE SERVICE names against `docker ps --format
# '{{.Names}}'`, which lists CONTAINER names. Those are only the same because
# every service sets `container_name` equal to its key -- measured 2026-11-06,
# all 13 do. Nothing enforced it, and that is the invariant the verification
# silently depends on: without `container_name`, compose names the container
# `<project>-<service>-1`, the whole-line match never fires, `still` stays
# empty, and a RUNNING container is declared stopped.
# ---------------------------------------------------------------------------
echo "== every compose service sets container_name equal to its key =="
cat > "$TMP_DIR/cnguard.py" <<'PYCN'
import glob, os, re, sys
root = sys.argv[1]
bad, n = [], 0
for f in sorted(glob.glob(os.path.join(root, "compose/**/*.yml"), recursive=True)):
    section = None
    for line in open(f):
        m = re.match(r"^([a-z]+):\s*$", line)
        if m:
            section = m.group(1); continue
        k = re.match(r"^  ([A-Za-z][A-Za-z0-9_.-]*):", line)
        if k and section == "services":
            cur = k.group(1); n += 1
            bad.append([f, cur, None])
        elif section == "services" and bad:
            cn = re.match(r"^\s+container_name:\s*(\S+)\s*$", line)
            if cn:
                bad[-1][2] = cn.group(1)
offenders = [(f, s, c) for f, s, c in bad if c != s]
print("   %d service(s) checked" % n)
for f, s, c in offenders:
    print("   !! %s: service %r has container_name %r" % (os.path.relpath(f, root), s, c))
sys.exit(1 if offenders else 0)
PYCN
python3 -I "$TMP_DIR/cnguard.py" "$REPO_ROOT" \
  || fail "a compose service does not set container_name == its key"

# NEGATIVE CONTROL: the same guard, against a tree that breaks the invariant.
# Without this the check has only ever seen a passing tree, which is the
# vacuity hole -- it would pass just as happily if its parser matched nothing.
bad_tree="$TMP_DIR/badcompose"; rm -rf "$bad_tree"; mkdir -p "$bad_tree/compose/media"
cat > "$bad_tree/compose/media/ok.yml" <<'OKY'
services:
  goodsvc:
    image: x
    container_name: goodsvc
OKY
python3 -I "$TMP_DIR/cnguard.py" "$bad_tree" >/dev/null 2>&1 \
  || fail "the guard rejects a tree that SATISFIES the invariant"
cat > "$bad_tree/compose/media/bad.yml" <<'BADY'
services:
  nocontainername:
    image: x
BADY
if python3 -I "$TMP_DIR/cnguard.py" "$bad_tree" >/dev/null 2>&1; then
  fail "the guard ACCEPTED a service with no container_name, so it proves nothing
about the real tree either"
fi
cat > "$bad_tree/compose/media/bad.yml" <<'BADY2'
services:
  mismatched:
    image: x
    container_name: something-else
BADY2
if python3 -I "$TMP_DIR/cnguard.py" "$bad_tree" >/dev/null 2>&1; then
  fail "the guard ACCEPTED a container_name that differs from the service key"
fi
echo "   the invariant the stop verification rests on is enforced, and the guard
   rejects both a missing and a mismatched container_name"

echo "PASS: operation lock smoke test"
