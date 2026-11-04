#!/usr/bin/env bash
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO=/home/jfranco/src/domum-core-media-dev
PROJ=domum-plexrehearse
TMP="$(mktemp -d)"
echo "fixture: $TMP"

say "0. isolation"
PROD_CID="$(docker inspect plex --format '{{.Id}}' 2>/dev/null)" || fail "no production plex"
PROD_IMG="$(docker inspect plex --format '{{.Image}}' 2>/dev/null)"
BEFORE_N="$(docker ps -q | wc -l)"
echo "  production plex ${PROD_CID:0:12}  image ${PROD_IMG:7:12}  containers=$BEFORE_N"
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "project name taken"
echo "  project name $PROJ is free"

cleanup() {
  docker compose -p "$PROJ" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

say "1. disposable plex on the production image, pinned by ID, PUID=$(id -u)"
mkdir -p "$TMP/data/plex/config" "$TMP/media" "$TMP/cap" "$TMP/restore"
cat > "$TMP/compose.yml" <<YML
services:
  plex:
    image: $PROD_IMG
    network_mode: "none"
    environment:
      PUID: "$(id -u)"
      PGID: "$(id -g)"
      TZ: UTC
      VERSION: docker
    volumes:
      - $TMP/data/plex/config:/config
      - $TMP/media:/media:ro
YML
docker compose -p "$PROJ" -f "$TMP/compose.yml" up -d >/dev/null 2>&1 || fail "plex did not start"
CID="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -q plex)"
[[ -n "$CID" && "$CID" != "$PROD_CID" ]] || fail "resolved the production container"
scope="$(docker compose -p "$PROJ" -f "$TMP/compose.yml" ps -qa || true)"
grep -q "^$PROD_CID" <<< "$scope" \
  && fail "production is inside the disposable project's scope"
echo "  disposable ${CID:0:12}, production absent from scope"

PMS="$TMP/data/plex/config/Library/Application Support/Plex Media Server"
cap() {  # $1 = destination -> prints the run output then rc=N
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
           CFG_FILE="$TMP/absent.conf"
    mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    # THE ONE STUB: which container is this service. The sqlite binary
    # declaration, the host->container path mapping (derived from the
    # container's OWN mounts), docker exec, .backup, integrity_check, docker
    # cp, the digests and the manifest are all real.
    tracked_service_container_id_any() { printf '%s' "$CID"; }
    service_state_capture plex "$1" 2>&1
    echo "rc=$?"
  )
}

say "2. MID-STARTUP: the declared items appear in STAGES, and that must FAIL CLOSED"
# Plex creates library.db and Preferences.xml before blobs.db. A capture taken
# in that window is a PARTIAL capture, and a partial capture presented as a
# backup is the defect this project keeps correcting. Only a real image shows
# this -- a fixture creates every declared file at once.
for _ in $(seq 1 180); do
  [[ -s "$PMS/Plug-in Support/Databases/com.plexapp.plugins.library.db" ]] \
    && [[ -s "$PMS/Preferences.xml" ]] && break
  sleep 1
done
[[ -s "$PMS/Plug-in Support/Databases/com.plexapp.plugins.library.db" ]] \
  || { printf '%s\n' "$(docker logs "$CID" 2>&1 | tail -6 || true)"; fail "the library database never appeared"; }
if [[ ! -s "$PMS/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db" ]]; then
  early="$(cap "$TMP/cap/early")"
  printf '%s\n' "$early" | sed 's/^/  /'
  grep -q 'rc=0' <<< "$early" && fail "2: a capture missing a declared item reported success"
  grep -q 'INCOMPLETE' <<< "$early" || fail "2: it did not say INCOMPLETE"
  grep -q 'not a backup' <<< "$early" || fail "2: it did not say a partial capture is not a backup"
  grep -q '^RESULT=INCOMPLETE$' "$TMP/cap/early/MANIFEST" || fail "2: the manifest does not record INCOMPLETE"
  grep -q 'blobs.db' "$TMP/cap/early/MANIFEST" || fail "2: the manifest does not NAME the missing item"
  echo "  failed closed, named blobs.db, and the manifest records INCOMPLETE"
else
  echo "  SKIPPED: blobs.db already existed by the time the library db did"
fi

say "2b. now wait for EVERY declared item"
for _ in $(seq 1 240); do
  [[ -s "$PMS/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db" ]] && break
  sleep 1
done
[[ -s "$PMS/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db" ]] \
  || { printf '%s\n' "$(docker logs "$CID" 2>&1 | tail -6 || true)"; fail "blobs.db never appeared"; }
dbls="$(ls -l "$PMS/Plug-in Support/Databases/" || true)"
sed -n '1,8p' <<< "$dbls" | sed 's/^/  /'
echo "  Preferences.xml mode: $(stat -c %a "$PMS/Preferences.xml")  bytes: $(stat -c %s "$PMS/Preferences.xml")"

say "3. the REAL capture -- three items, paths containing SPACES, Plex SQLite"
out="$(cap "$TMP/cap/plex")"
printf '%s\n' "$out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$out" || fail "the capture failed"

say "4. the manifest"
sed 's/^/  /' "$TMP/cap/plex/MANIFEST"
grep -q '^CAPTURE_MODE=consistent$' "$TMP/cap/plex/MANIFEST" || fail "mode is not consistent"
grep -q '^RESULT=COMPLETE$' "$TMP/cap/plex/MANIFEST" || fail "not COMPLETE"
grep -q '^ITEMS=3$' "$TMP/cap/plex/MANIFEST" || fail "expected 3 items"
grep -q "^IMAGE_ID=$PROD_IMG$" "$TMP/cap/plex/MANIFEST" || fail "wrong IMAGE_ID"
grep -q 'COLLISION' "$TMP/cap/plex/MANIFEST" && fail "a stored-name collision occurred"
echo "  stored files (names folded from paths containing spaces):"
ls -1 "$TMP/cap/plex/files" | sed 's/^/    /'
[[ "$(ls -1 "$TMP/cap/plex/files" | wc -l)" == "3" ]] || fail "not 3 stored files"

say "5. verify and restore"
out2="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
         CFG_FILE="$TMP/absent.conf"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID"; }
  service_state_verify "$TMP/cap/plex" 2>&1; echo "verify_rc=$?"
  service_state_restore "$TMP/cap/plex" "$TMP/restore" 2>&1; echo "restore_rc=$?"
)"
printf '%s\n' "$out2" | sed 's/^/  /'
grep -q 'verify_rc=0' <<< "$out2" || fail "verify failed"
grep -q 'restore_rc=0' <<< "$out2" || fail "restore failed"

say "6. the restored library database opens in PLEX's own sqlite, and the token is intact"
rdb="$(find "$TMP/restore" -name '*library.db' | head -1)"
[[ -n "$rdb" ]] || fail "no restored library database"
docker cp "$rdb" "$CID:/tmp/r.db" >/dev/null 2>&1 || fail "copy back failed"
ic="$(docker exec "$CID" "/usr/lib/plexmediaserver/Plex SQLite" /tmp/r.db 'PRAGMA integrity_check;' 2>&1 | head -1)"
tbl="$(docker exec "$CID" "/usr/lib/plexmediaserver/Plex SQLite" /tmp/r.db "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>&1 | head -1)"
docker exec "$CID" rm -f /tmp/r.db >/dev/null 2>&1 || true
echo "  integrity_check (Plex SQLite): $ic"
echo "  tables: $tbl"
[[ "$ic" == "ok" ]] || fail "the restored library database is not sound"
[[ "${tbl:-0}" -ge 20 ]] || fail "only $tbl tables"
rpref="$(find "$TMP/restore" -name 'Preferences.xml' | head -1)"
[[ -n "$rpref" ]] || fail "Preferences.xml was not restored -- a restored Plex would be a NEW server identity"
echo "  Preferences.xml restored, mode $(stat -c %a "$rpref"), $(stat -c %s "$rpref") bytes"
grep -q 'ProcessedMachineIdentifier\|MachineIdentifier' "$rpref" \
  || echo "  (note: no MachineIdentifier yet -- an unclaimed server writes it later)"

say "7. teardown, asserted"
docker compose -p "$PROJ" -f "$TMP/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "a disposable container remains"
rm -rf -- "$TMP" 2>/dev/null
left=0; [[ -d "$TMP" ]] && left=1
trap - EXIT
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect plex --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N  fixture left behind: $left"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production plex was replaced"
[[ "$left" == "0" ]] || fail "the fixture could not be removed -- root-owned litter"
echo "  production plex still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: plex consistent-capture rehearsal against the real image"
