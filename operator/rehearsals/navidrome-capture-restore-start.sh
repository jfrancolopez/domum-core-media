#!/usr/bin/env bash
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO=/home/jfranco/src/domum-core-media-dev
P1=domum-navstart-a; P2=domum-navstart-b
TMP="$(mktemp -d)"
echo "fixture: $TMP"
SQ=/usr/bin/sqlite3

say "0. isolation, before anything is created"
PROD_CID="$(docker inspect navidrome --format '{{.Id}}' 2>/dev/null)" || fail "no production navidrome"
PROD_IMG="$(docker inspect navidrome --format '{{.Image}}' 2>/dev/null)"
BEFORE_N="$(docker ps -q | wc -l)"
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "project name taken: $p"
done
echo "  production ${PROD_CID:0:12}, containers=$BEFORE_N, both project names free"

cleanup() {
  for p in "$P1" "$P2"; do
    docker compose -p "$p" -f "$TMP/$p.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

mk() {  # $1 = project, $2 = data dir
  mkdir -p "$2" "$TMP/music"
  cat > "$TMP/$1.yml" <<YML
services:
  navidrome:
    image: $PROD_IMG
    network_mode: "none"
    user: "$(id -u):$(id -g)"
    environment:
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /music
      ND_LOGLEVEL: info
      ND_SCANSCHEDULE: "0"
    volumes:
      - $2:/data
      - $TMP/music:/music:ro
YML
  docker compose -p "$1" -f "$TMP/$1.yml" up -d >/dev/null 2>&1 || fail "$1 did not start"
  docker compose -p "$1" -f "$TMP/$1.yml" ps -q navidrome
}

say "1. source navidrome, capture, restore"
mkdir -p "$TMP/data/navidrome" "$TMP/cap" "$TMP/restore"
CID_A="$(mk "$P1" "$TMP/data/navidrome")"
[[ -n "$CID_A" && "$CID_A" != "$PROD_CID" ]] || fail "resolved production"
for _ in $(seq 1 60); do [[ -s "$TMP/data/navidrome/navidrome.db" ]] && break; sleep 1; done
[[ -s "$TMP/data/navidrome/navidrome.db" ]] || fail "no source database"

run_cli() {  # $1 = cid, $2 = expression
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/music" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
           CFG_FILE="$TMP/absent.conf"
    mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    tracked_service_container_id_any() { printf '%s' "$1"; }
    eval "$2"
    echo "rc=$?"
  )
}
out="$(run_cli "$CID_A" "tracked_service_container_id_any() { printf '%s' '$CID_A'; }
service_state_capture navidrome '$TMP/cap/nav'")"
grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "capture failed"; }
out="$(run_cli "$CID_A" "tracked_service_container_id_any() { printf '%s' '$CID_A'; }
service_state_restore '$TMP/cap/nav' '$TMP/restore'")"
printf '%s\n' "$out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$out" || fail "restore failed"
RDB="$(find "$TMP/restore" -name navidrome.db | head -1)"
[[ -n "$RDB" ]] || fail "no restored database"
echo "  restored: $(stat -c %s "$RDB") bytes"

say "2. a MARKER, so 'it started' cannot be confused with 'it made a new database'"
# A fresh navidrome also creates ~24 tables, so a table count cannot tell a
# REUSED database from a RECREATED one. A row only the restored copy carries
# can. This is instrumentation to identify the file, not evidence about health
# -- nothing here makes navidrome look healthier than it is.
MARK="domum-rehearsal-$(date -u +%s)"
docker cp "$RDB" "$CID_A:/tmp/m.db" >/dev/null 2>&1 || fail "copy in failed"
docker exec "$CID_A" "$SQ" /tmp/m.db \
  "CREATE TABLE IF NOT EXISTS domum_rehearsal_marker(k TEXT); INSERT INTO domum_rehearsal_marker VALUES('$MARK');" \
  >/dev/null 2>&1 || fail "could not write the marker"
docker cp "$CID_A:/tmp/m.db" "$RDB" >/dev/null 2>&1 || fail "copy out failed"
docker exec "$CID_A" rm -f /tmp/m.db >/dev/null 2>&1 || true
echo "  marker written: $MARK"

say "3. a SECOND disposable navidrome, started on the RESTORED capture only"
mkdir -p "$TMP/restore-data"
cp "$RDB" "$TMP/restore-data/navidrome.db"
CID_B="$(mk "$P2" "$TMP/restore-data")"
[[ -n "$CID_B" && "$CID_B" != "$PROD_CID" && "$CID_B" != "$CID_A" ]] || fail "bad second container"
echo "  ${CID_B:0:12} started with /data holding ONLY the restored database"

say "4. did it come up?"
ready=""
for _ in $(seq 1 90); do
  # The pattern is MEASURED from this image's own output, not guessed: the
  # first attempt looked for "accepting requests" and navidrome actually logs
  # "----> Navidrome server is ready!". A readiness pattern invented rather
  # than observed reports a healthy start as a failure.
  logs="$(docker logs "$CID_B" 2>&1 || true)"
  if grep -qF 'Navidrome server is ready!' <<< "$logs"; then
    ready=yes; break
  fi
  [[ "$(docker inspect -f '{{.State.Status}}' "$CID_B" 2>/dev/null)" == "running" ]] || break
  sleep 1
done
echo "  --- last log lines ---"
docker logs "$CID_B" 2>&1 | tail -8 | sed 's/^/    /'
status="$(docker inspect -f '{{.State.Status}}' "$CID_B" 2>/dev/null)"
echo "  container status: $status   readiness line seen: ${ready:-no}"
[[ "$status" == "running" ]] || fail "navidrome did not stay running on the restored capture"
[[ "$ready" == "yes" ]] || fail "navidrome never logged that it was accepting requests"
logs="$(docker logs "$CID_B" 2>&1 || true)"
grep -qiE 'panic|fatal' <<< "$logs" \
  && fail "navidrome logged a fatal error against the restored capture"

say "4b. it MIGRATED the restored database on startup -- which is why pairing matters"
# navidrome logged "Full scan required after migration", i.e. it forward-
# migrated the schema it was given. That is the same behaviour this project
# records for Kavita and Uptime Kuma, and it is exactly why a recovery point is
# service + state + the APPLICATION THAT WROTE IT: restored under a newer
# navidrome, this database would be migrated in place on first boot.
if grep -qiE 'after migration|Migrating|migration' <<< "$logs"; then
  sed -n '/[Aa]fter migration\|Migrating/{p;}' <<< "$logs" | sed -n '1,2p' | sed 's/^/    /'
  echo "  observed: the restored database was migrated by the application on startup"
else
  echo "  no migration line logged (same image, so nothing to migrate)"
fi

say "5. it used THAT database -- the marker survived, and no fresh install replaced it"
mk2="$(docker exec "$CID_B" "$SQ" /data/navidrome.db \
  "SELECT k FROM domum_rehearsal_marker;" 2>&1 | head -1)"
tbl2="$(docker exec "$CID_B" "$SQ" /data/navidrome.db \
  "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>&1 | head -1)"
ic2="$(docker exec "$CID_B" "$SQ" /data/navidrome.db 'PRAGMA integrity_check;' 2>&1 | head -1)"
echo "  marker read back : $mk2"
echo "  tables           : $tbl2"
echo "  integrity_check  : $ic2"
[[ "$mk2" == "$MARK" ]] \
  || fail "the marker is gone -- navidrome did not open the restored database, or
replaced it with a fresh one"
[[ "$ic2" == "ok" ]] || fail "the database is not sound after navidrome ran against it"
[[ "${tbl2:-0}" -ge 24 ]] || fail "only $tbl2 tables after startup"

say "6. teardown, asserted"
cleanup; trap - EXIT
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "$p left a container"
  [[ -z "$(docker volume ls -q --filter "name=^${p}" 2>/dev/null)" ]] || fail "$p left a volume"
done
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect navidrome --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production navidrome was replaced"
echo "  production navidrome still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: navidrome STARTS against a restored capture"
