#!/usr/bin/env bash
set -uo pipefail

# The migration's own integrity claim, and what "healthy" is allowed to mean.
#
# CLAUDE.md section 13b states the claim: `.premigration` == proof snapshot --
# the original that was moved aside, against a snapshot of the copy that replaced
# it. Both are static, so a running application cannot disturb the comparison, and
# it catches corruption introduced after migrate_verify has already passed.
#
# Until `migrate_verify_recovery_point` existed, that comparison lived ONLY in a
# hand-written operator script. A migration run straight from the CLI never made
# its own central claim, and the only copy of it was in a file CI never sees --
# which is exactly how the stale topology invariant came to abort a correct
# deployment. Same class, higher stakes.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdb() {  # $1 = path
  python3 - "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
# WAL mode deliberately: opening a WAL database creates -shm and -wal beside it
# and LEAVES them there, even read-only. That is what makes case 11 able to tell
# an in-place check from one against a copy.
con.execute("pragma journal_mode=wal")
con.execute("create table parent(id integer primary key)")
con.execute("create table child(id integer primary key, pid integer references parent(id))")
con.execute("insert into parent values (1)")
con.execute("insert into child values (1, 1)")
for i in range(2, 200):
    con.execute("insert into parent values (?)", (i,))
con.commit()
con.execute("pragma wal_checkpoint(truncate)")
con.close()
import os
for ext in ("-wal", "-shm"):
    try: os.unlink(sys.argv[1] + ext)
    except FileNotFoundError: pass
PY
}

# A file that IS SQLite -- the magic header is intact, so it is selected for
# checking -- but whose pages are damaged. Hashes cannot tell this from a healthy
# database; opening it can. That is the whole reason the check exists.
corrupt_db() {  # $1 = path to an existing database
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
    f.seek(4096)              # well past the header, into page content
    f.write(b"\xde\xad\xbe\xef" * 256)
PY
}

harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
DOMUM_STATE_ROOT="$TMP_DIR/state"
DOMUM_DATA_ROOT="$TMP_DIR/data"
need_root() { :; }
load_cfg() { :; }
# The fixture is on /tmp, which is not Btrfs, so a real read-only property cannot
# exist here. Read-only-ness against a REAL snapshot is asserted in
# tests/integration/btrfs-migration-integration.sh.
btrfs() { [[ "\${1:-}" == property ]] && printf 'ro=true\n'; return 0; }
EOF
}

# $1 = scenario name, $2 = extra stubs -> echoes combined output, returns rc
verify_rp() {
  local name="$1" stubs="${2:-}"
  bash -c "$(harness)
$stubs
migrate_verify_recovery_point '$TMP_DIR/$name/premigration' '$TMP_DIR/$name/snapshot'" 2>&1
}

# A matching pair: the preserved original, and a snapshot of its replacement.
build_pair() {  # $1 = scenario name
  local d="$TMP_DIR/$1"
  rm -rf "$d"; mkdir -p "$d/premigration/config" "$d/snapshot/config"
  printf 'settings\n' > "$d/premigration/config/app.xml"
  mkdir -p "$d/premigration/config/empty"
  ln -s config/app.xml "$d/premigration/link"
  mkdb "$d/premigration/config/app.db"
  cp -a "$d/premigration/." "$d/snapshot/"
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# 1. The happy path: identical trees, a loadable database.
# ---------------------------------------------------------------------------
build_pair ok >/dev/null
out="$(verify_rp ok)"; rc=$?
(( rc == 0 )) || fail "1: a matching recovery point did not verify (rc=$rc): $out"
grep -q 'integrity proven' <<< "$out" || fail "1: the claim was not stated: $out"
grep -q 'sqlite config/app.db: ok' <<< "$out" || fail "1: the database was not checked: $out"

# ---------------------------------------------------------------------------
# 2. Content divergence. This is the corruption migrate_verify cannot see,
#    because it ran before the snapshot existed.
# ---------------------------------------------------------------------------
d="$(build_pair content)"
printf 'tampered\n' > "$d/snapshot/config/app.xml"
out="$(verify_rp content)"; rc=$?
(( rc == 1 )) || fail "2: a divergent snapshot verified clean (rc=$rc): $out"
grep -q 'PRESERVED ORIGINAL AND THE PROOF SNAPSHOT DIFFER' <<< "$out" || fail "2: not reported: $out"
grep -qi 'do NOT delete either' <<< "$out" || fail "2: the operator was not told both copies are intact: $out"

# ---------------------------------------------------------------------------
# 3. Metadata-only divergence: same bytes, different mode. `cp -a --reflink`
#    preserves mode, so a difference means the copy is wrong.
# ---------------------------------------------------------------------------
d="$(build_pair meta)"
chmod 0600 "$d/snapshot/config/app.xml"
out="$(verify_rp meta)"; rc=$?
(( rc == 1 )) || fail "3: a mode difference verified clean (rc=$rc): $out"
grep -q 'metadata mismatch' <<< "$out" || fail "3: the metadata difference was not named: $out"

# ---------------------------------------------------------------------------
# 4. A snapshot that is not read-only is not a proof. It is another mutable copy.
# ---------------------------------------------------------------------------
build_pair rw >/dev/null
out="$(verify_rp rw "btrfs() { [[ \"\${1:-}\" == property ]] && printf 'ro=false\n'; return 0; }")"; rc=$?
(( rc == 1 )) || fail "4: a writable snapshot was accepted as a proof (rc=$rc): $out"
grep -q 'not read-only' <<< "$out" || fail "4: not reported: $out"

# ---------------------------------------------------------------------------
# 5/6. A missing tree on either side must refuse, not pass by vacuity.
# ---------------------------------------------------------------------------
d="$(build_pair nosnap)"; rm -rf "$d/snapshot"
out="$(verify_rp nosnap)"; rc=$?
(( rc == 1 )) || fail "5: a missing snapshot verified clean (rc=$rc): $out"
grep -q 'proof snapshot is missing' <<< "$out" || fail "5: not reported: $out"

d="$(build_pair nopre)"; rm -rf "$d/premigration"
out="$(verify_rp nopre)"; rc=$?
(( rc == 1 )) || fail "6: a missing preserved original verified clean (rc=$rc): $out"
grep -q 'preserved original is missing' <<< "$out" || fail "6: not reported: $out"

# ---------------------------------------------------------------------------
# 7. THE CASE HASHES CANNOT SEE.
#
# Both trees hold the SAME corrupted database, so every hash and every byte
# count matches and migrate_verify passes. A faithful copy of a broken database
# is still a broken recovery point.
# ---------------------------------------------------------------------------
d="$(build_pair corrupt)"
corrupt_db "$d/premigration/config/app.db"
cp -a "$d/premigration/config/app.db" "$d/snapshot/config/app.db"
# Confirm the fixture really is byte-identical, or this proves nothing.
[[ "$(sha256sum < "$d/premigration/config/app.db")" == "$(sha256sum < "$d/snapshot/config/app.db")" ]] \
  || fail "7: fixture is wrong; the two databases are not byte-identical"
out="$(verify_rp corrupt)"; rc=$?
(( rc == 1 )) || fail "7: a byte-identical but CORRUPT recovery point verified clean (rc=$rc): $out"
grep -q 'content manifest identical' <<< "$out" \
  || fail "7: fixture is wrong; the hashes should have matched: $out"
grep -qE 'sqlite config/app.db: (integrity_check|failed|cannot open)' <<< "$out" \
  || fail "7: the corruption was not reported: $out"

# ---------------------------------------------------------------------------
# 8. A `.db` that is not SQLite must be skipped, not failed. The extension is a
#    naming convention; a false positive here would abort a correct migration.
# ---------------------------------------------------------------------------
d="$(build_pair notadb)"
printf 'this is plain text, not a database\n' > "$d/premigration/config/other.db"
cp -a "$d/premigration/config/other.db" "$d/snapshot/config/other.db"
out="$(verify_rp notadb)"; rc=$?
(( rc == 0 )) || fail "8: a non-SQLite .db file failed the migration (rc=$rc): $out"
grep -q 'not a SQLite database; not checked' <<< "$out" || fail "8: not reported honestly: $out"

# ---------------------------------------------------------------------------
# 9. A database too large to copy is reported as NOT checked, never as checked.
# ---------------------------------------------------------------------------
build_pair big >/dev/null
out="$(verify_rp big "MIGRATE_SQLITE_MAX_BYTES=1")"; rc=$?
(( rc == 0 )) || fail "9: an oversized database failed the migration (rc=$rc): $out"
grep -q 'exceeds the check limit; NOT checked' <<< "$out" || fail "9: not reported: $out"
grep -q 'sqlite config/app.db: ok' <<< "$out" && fail "9: an unchecked database was reported as ok: $out"

# ---------------------------------------------------------------------------
# 10. No tool available: "I could not check" must not read as "I checked".
# ---------------------------------------------------------------------------
build_pair notool >/dev/null
out="$(verify_rp notool "cmd_exists() { case \"\$1\" in sqlite3|python3) return 1 ;; *) command -v \"\$1\" >/dev/null 2>&1 ;; esac; }")"; rc=$?
(( rc == 0 )) || fail "10: a missing tool failed the migration (rc=$rc): $out"
grep -q 'NOT checked (no sqlite3 and no python3)' <<< "$out" || fail "10: silence instead of an admission: $out"
grep -q ': ok' <<< "$out" && fail "10: claimed a check that could not run: $out"

# ---------------------------------------------------------------------------
# 11. Neither tree may be written to. The snapshot is read-only and
#     .premigration is the last independent copy; opening a WAL-mode database in
#     place would create sidecars in one of them.
# ---------------------------------------------------------------------------
d="$(build_pair readonly)"
# The fixture database is WAL mode, so an in-place open would leave `-shm` and
# `-wal` behind. In .premigration that would make the preserved original differ
# from the proof snapshot -- the act of verifying the claim would break it.
before="$( { find "$d/premigration" -printf '%p %s %T@\n'; find "$d/snapshot" -printf '%p %s %T@\n'; } | LC_ALL=C sort)"
out="$(verify_rp readonly)"; rc=$?
(( rc == 0 )) || fail "11: setup failed: $out"
after="$( { find "$d/premigration" -printf '%p %s %T@\n'; find "$d/snapshot" -printf '%p %s %T@\n'; } | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || { diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2
  fail "11: the integrity check MODIFIED one of the trees it was verifying"; }

# ---------------------------------------------------------------------------
# 12. `starting` is not `healthy`.
#
# Docker reports `starting` for the whole StartPeriod after a restart. The
# previous code only rejected `unhealthy`, so wait_for_service_health returned on
# its FIRST poll and the healthcheck never ran. Measured on this host, kavita's
# healthcheck is `curl -fsS http://localhost:5000/api/health` with
# StartPeriod=30s -- a real application-level signal that was being discarded.
# ---------------------------------------------------------------------------
health_state() {  # $1 = docker health value(s), one per compose service
  bash -c "$(harness)
service_compose_services() { printf '%s' \"\$COMPOSE_SVCS\"; }
tracked_service_container_id() { printf 'cid-%s' \"\$1\"; }
docker() {
  local fmt=\"\$3\" cid=\"\$4\"
  case \"\$fmt\" in
    *State.Status*) printf '%s' \"\${STATUS:-running}\" ;;
    *State.Health*) printf '%s' \"\$(eval printf '%s' \\\"\\\$H_\${cid#cid-}\\\")\" ;;
  esac
}
COMPOSE_SVCS='$1'
$2
service_health_state svc" 2>/dev/null
}

[[ "$(health_state 'a' "H_a=starting")"  == "starting"  ]] || fail "12: starting was not reported as starting"
[[ "$(health_state 'a' "H_a=healthy")"   == "healthy"   ]] || fail "12: healthy was not reported as healthy"
[[ "$(health_state 'a' "H_a=unhealthy")" == "unhealthy" ]] || fail "12: unhealthy was not reported"
[[ "$(health_state 'a' "H_a=none")"      == "none"      ]] || fail "12: a service with no healthcheck must report none, not healthy"
[[ "$(health_state 'a' "H_a=healthy
STATUS=exited")" == "stopped" ]] || fail "12: a non-running container must report stopped"

# Multi-container precedence: unhealthy > starting > healthy > none. immich has
# four containers, and one still starting means the service is still starting.
[[ "$(health_state 'a b c' "H_a=healthy; H_b=starting; H_c=healthy")" == "starting" ]] \
  || fail "12: one starting container did not make the service starting"
[[ "$(health_state 'a b c' "H_a=healthy; H_b=starting; H_c=unhealthy")" == "unhealthy" ]] \
  || fail "12: unhealthy did not take precedence over starting"
[[ "$(health_state 'a b' "H_a=none; H_b=healthy")" == "healthy" ]] \
  || fail "12: a healthchecked container alongside one without must report healthy"

# And service_is_healthy -- what wait_for_service_health polls -- must agree.
is_healthy() {
  bash -c "$(harness)
service_compose_services() { printf 'a'; }
tracked_service_container_id() { printf 'cid-a'; }
service_health_url() { return 1; }
docker() {
  case \"\$3\" in
    *State.Status*) printf 'running' ;;
    *State.Health*) printf '%s' '$1' ;;
  esac
}
service_is_healthy svc && echo YES || echo NO" 2>/dev/null
}
[[ "$(is_healthy starting)"  == "NO"  ]] || fail "12: service_is_healthy accepted 'starting' -- the whole defect"
[[ "$(is_healthy healthy)"   == "YES" ]] || fail "12: service_is_healthy rejected 'healthy'"
[[ "$(is_healthy unhealthy)" == "NO"  ]] || fail "12: service_is_healthy accepted 'unhealthy'"
[[ "$(is_healthy none)"      == "YES" ]] || fail "12: a service with no healthcheck must still count as healthy"

# ---------------------------------------------------------------------------
# 13. A probe copy that FAILS -- a full filesystem, say -- must refuse, not pass.
#     "I could not copy it so I did not look" is the same class of silent pass as
#     a manifest that skipped a file it could not read.
# ---------------------------------------------------------------------------
build_pair cpfail >/dev/null
out="$(verify_rp cpfail "cp() { if [[ \"\${*}\" == *probe.db* ]]; then return 1; fi; command cp \"\$@\"; }")"; rc=$?
(( rc == 1 )) || fail "13: a failed probe copy passed verification (rc=$rc): $out"
grep -q 'could not be copied for checking' <<< "$out" || fail "13: not reported: $out"

echo "PASS: migration recovery point smoke test"
