#!/usr/bin/env bash
set -uo pipefail

# "I could not check this database" must not read as "this database is broken",
# and must not read as "I checked it" either.
#
# The Plex migration completed correctly and then reported
#
#   recovery point  : DID NOT VERIFY
#
# because this host's SQLite raises `unknown tokenizer: collating` on Plex's two
# FTS virtual tables. Measured on the real recovery point:
#
#   python sqlite3 3.46.1  integrity_check -> OperationalError: unknown tokenizer
#                          quick_check     -> same
#                          page_count, page_size, schema_version, journal_mode
#                          and all 254 sqlite_master rows -> read fine
#                          objects using the `collating` tokenizer -> exactly 2
#   Plex's own SQLite      integrity_check -> ok,  foreign_key_check -> 0
#
# So the databases were sound and the migration said the recovery point had
# failed. migrate_sqlite_integrity's own comment already promised it "returns
# non-zero only for a database that is genuinely broken -- never for one that
# could not be checked"; its case statement sent anything unrecognised to bad=1.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

probe() {
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    printf '%s\n' "$1"
  } > "$TMP_DIR/probe.sh"
  bash "$TMP_DIR/probe.sh" 2>&1
}

mkdb() {  # $1 = path; a real SQLite file
  python3 - "$1" <<'MKDB'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table t(id integer primary key, v text)")
con.execute("insert into t values (1,'x')")
con.commit(); con.close()
MKDB
}

echo "== 1. a sound database is ok =="
mkdb "$TMP_DIR/good.db"
out="$(probe "domum_sqlite_check $(printf '%q' "$TMP_DIR/good.db")")"
[ "$out" = "ok" ] || fail "a sound database should be ok, got: $out"
echo "  ok"

echo "== 2. a file that is not SQLite at all is reported, not called broken =="
printf 'definitely not a database' > "$TMP_DIR/bogus.db"
out="$(probe "domum_sqlite_check $(printf '%q' "$TMP_DIR/bogus.db")")"
case "$out" in
  ok) fail "a non-database must not report ok" ;;
esac
echo "  reported as: ${out:0:48}"

echo "== 3. an UNSUPPORTED extension is classified separately from broken =="
# A virtual table using a module this SQLite does not have. Writing the schema
# directly is how a real Plex database looks to a generic SQLite.
python3 - "$TMP_DIR/unsup.db" <<'MK'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table real(id integer primary key)")
con.commit()
# Forge a virtual table whose module does not exist here, the way Plex's FTS
# tables look to a SQLite without its `collating` tokenizer.
con.execute("pragma writable_schema=ON")
con.execute("insert into sqlite_master (type,name,tbl_name,rootpage,sql) "
            "values ('table','fts_thing','fts_thing',0,"
            "'CREATE VIRTUAL TABLE fts_thing USING fts4(tokenize=collating)')")
con.commit(); con.close()
MK
out="$(probe "domum_sqlite_check $(printf '%q' "$TMP_DIR/unsup.db")")"
case "$out" in
  unsupported:*) echo "  classified: ${out:0:56}" ;;
  ok)      fail "an unreadable schema must not report ok: $out" ;;
  failed:*) fail "an extension this SQLite LACKS was called a failure, which is what
reported plex's sound databases as a failed recovery point: $out" ;;
  *)       fail "unexpected classification: $out" ;;
esac

echo "== 4. migrate_sqlite_integrity does NOT fail on unsupported =="
mkdir -p "$TMP_DIR/tree"
cp "$TMP_DIR/unsup.db" "$TMP_DIR/tree/app.db"
out="$(probe "migrate_sqlite_integrity $(printf '%q' "$TMP_DIR/tree") verify; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" \
  || fail "an unsupported schema failed the integrity stage. The function's contract is
that it never fails a database it could not check: $out"
grep -q 'NOT checked' <<< "$out" || fail "it was not reported as NOT checked: $out"
grep -q 'not checked' <<< "$out" || fail "the tally does not count it as not-checked: $out"
echo "  rc=0, reported as NOT checked"

echo "== 5. a GENUINELY broken database still fails =="
# Truncate a real database mid-page: integrity_check can run and will object.
mkdb "$TMP_DIR/broken.db"
python3 - "$TMP_DIR/broken.db" <<'MK'
import sys
p = sys.argv[1]
d = bytearray(open(p,'rb').read())
# Corrupt the first page's content, leaving the header magic intact so it is
# still recognised as SQLite and the check actually runs.
for i in range(100, min(len(d), 400)):
    d[i] = 0xFF
open(p,'wb').write(bytes(d))
MK
mkdir -p "$TMP_DIR/tree2"; cp "$TMP_DIR/broken.db" "$TMP_DIR/tree2/app.db"
out="$(probe "migrate_sqlite_integrity $(printf '%q' "$TMP_DIR/tree2") verify; echo RC=\$?")"
# Strict. The first version accepted rc=0 so long as the file was not called
# "ok", and a mutant that removed `bad=1` from the broken case survived. The
# whole point of classifying "unsupported" separately is that genuinely broken
# must STILL fail, so assert exactly that.
grep -q 'RC=0' <<< "$out" \
  && fail "a corrupted database did not fail the integrity stage. Separating
'unsupported' from 'broken' is only safe while broken still fails: $out"
grep -q 'app.db: ok' <<< "$out" && fail "a corrupted database reported ok: $out"
grep -q 'unsupported' <<< "$out" \
  && fail "corruption was classified as 'unsupported', which does not fail: $out"
echo "  rc!=0, corruption fails the stage"

echo "== 6. the per-service SQLite fallback exists and is per-service =="
out="$(probe "service_sqlite_binary plex; echo \" rc=\$?\"")"
grep -q 'Plex SQLite' <<< "$out" || fail "plex has no application SQLite recorded: $out"
out="$(probe "service_sqlite_binary jellyfin >/dev/null; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a service with no private SQLite must return non-zero: $out"
echo "  plex -> Plex SQLite; jellyfin -> none"

echo "== 7. the probe copy is removed AFTER the fallback, not before =="
# The fallback copies the probe file into the container. Deleting it first made
# `docker cp` fail and the fallback silently never ran -- it reported "not
# checked" while a real answer was available.
fn="$(awk '/^migrate_sqlite_integrity\(\) \{/,/^\}/' "$CLI")"
rm_line="$(grep -n 'rm -f -- "\$tmp/probe.db"' <<< "$fn" | head -1 | cut -d: -f1)"
fb_line="$(grep -n 'domum_sqlite_check_via_container' <<< "$fn" | head -1 | cut -d: -f1)"
[ -n "$rm_line" ] && [ -n "$fb_line" ] || fail "could not locate the removal and the fallback"
[ "$rm_line" -gt "$fb_line" ] \
  || fail "the probe copy is removed at relative line $rm_line, BEFORE the fallback at $fb_line.
docker cp would have nothing to copy and the fallback would silently never run."
echo "  removal at $rm_line, after the fallback at $fb_line"

echo "== 8. --deep can re-prove an existing recovery point =="
grep -q 'verify-recovery <service> <point> \[--deep\]' "$CLI" \
  || fail "--deep is not in the usage text"
vr="$(awk '/^storage_verify_recovery\(\) \{/,/^\}/' "$CLI")"
grep -q 'deep=1' <<< "$vr" || fail "storage_verify_recovery does not parse --deep"
grep -q 'migrate_verify_recovery_point' <<< "$vr" \
  || fail "--deep does not re-run the integrity proof"
# And it must refuse honestly when .premigration is gone, rather than passing.
grep -q 'NOT POSSIBLE' <<< "$vr" \
  || fail "--deep does not say it cannot verify once .premigration is removed"
# The deep block must be REACHABLE: an early `return 0` before it made it dead
# code, and the suite passed anyway until this assertion existed.
d_line="$(grep -n '(( deep == 1 ))' <<< "$vr" | head -1 | cut -d: -f1)"
r_line="$(grep -n '^  return 0$' <<< "$vr" | head -1 | cut -d: -f1)"
[ -n "$d_line" ] || fail "could not find the deep block"
if [ -n "$r_line" ]; then
  [ "$r_line" -gt "$d_line" ] \
    || fail "a 'return 0' at relative line $r_line precedes the deep block at $d_line, making it unreachable"
fi
echo "  --deep parsed, re-runs the proof, refuses without .premigration, reachable"

echo "PASS: sqlite unsupported classification smoke test"
