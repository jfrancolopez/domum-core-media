#!/usr/bin/env bash
# Does a restored Plex keep being the SAME SERVER?
#
# `Preferences.xml` is declared with this comment: "Preferences.xml holds the
# SERVER TOKEN. Without it a restored Plex is a new server identity and every
# client must re-pair -- 422 bytes that decide whether a restore is the same
# server or a different one."
#
# That is an argument. This measures it, in both directions, the same way the
# calibre-web key was measured:
#
#   WITH Preferences.xml     the restored server reports the SAME
#                            MachineIdentifier it had before
#   WITHOUT it               Plex starts just as happily and mints a NEW one --
#                            a restore that looks successful and is a different
#                            server to every client that was paired with it
#
# The negative control is the point. Without it, "the identifier matched" is
# equally consistent with Plex deriving it from something else entirely.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1=domum-plexida; P2=domum-plexidb
TMP="$(mktemp -d)"; chmod 0700 "$TMP"
echo "fixture: $TMP"
PSQL='/usr/lib/plexmediaserver/Plex SQLite'

say "0. isolation"
PROD_CID="$(docker inspect plex --format '{{.Id}}' 2>/dev/null)" || fail "no production plex"
PROD_IMG="$(docker inspect plex --format '{{.Image}}' 2>/dev/null)"
BEFORE_N="$(docker ps -q | wc -l)"
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "project name taken: $p"
done
echo "  production ${PROD_CID:0:12}  image ${PROD_IMG:7:12}  containers=$BEFORE_N"

cleanup() {
  for p in "$P1" "$P2"; do
    docker compose -p "$p" -f "$TMP/$p.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

mk() {  # $1 = project, $2 = config dir -> prints the container id
  mkdir -p "$2" "$TMP/media"
  cat > "$TMP/$1.yml" <<YML
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
      - $2:/config
      - $TMP/media:/media:ro
YML
  docker compose -p "$1" -f "$TMP/$1.yml" up -d >/dev/null 2>&1 || fail "$1 did not start"
  docker compose -p "$1" -f "$TMP/$1.yml" ps -q plex
}

PMSREL='Library/Application Support/Plex Media Server'
wait_plex() {  # $1 = config dir -- waits for ALL THREE declared items
  local d="$1/$PMSREL" _
  for _ in $(seq 1 240); do
    [[ -s "$d/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
       && -s "$d/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db" \
       && -s "$d/Preferences.xml" ]] && return 0
    sleep 1
  done
  return 1
}

machine_id() {  # $1 = Preferences.xml path -> the identifier, or empty
  sed -nE 's/.*[^a-zA-Z]MachineIdentifier="([^"]+)".*/\1/p' "$1" 2>/dev/null | sed -n '1p'
}

say "1. a disposable plex, and its server identity"
mkdir -p "$TMP/data/plex/config" "$TMP/cap"
CID_A="$(mk "$P1" "$TMP/data/plex/config")"
[[ -n "$CID_A" && "$CID_A" != "$PROD_CID" ]] || fail "resolved the production container"
wait_plex "$TMP/data/plex/config" \
  || { printf '%s\n' "$(docker logs "$CID_A" 2>&1 | tail -6 || true)"; fail "plex never finished initialising"; }
PREF_A="$TMP/data/plex/config/$PMSREL/Preferences.xml"
printf '  Preferences.xml: %s\n' "$(stat -c '%s bytes, mode %a' "$PREF_A")"
ID_A="$(machine_id "$PREF_A")"
echo "  MachineIdentifier: ${ID_A:-<none yet>}"
[[ -n "$ID_A" ]] \
  || fail "this Plex has no MachineIdentifier yet, so there is no identity to
test. An unclaimed server writes it during initialisation -- wait longer or
check the logs"

say "2. capture the three declared items"
out="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" CFG_FILE="$TMP/no.conf"
  mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID_A"; }
  service_state_capture plex "$TMP/cap/plex" 2>&1
  echo "rc=$?"
)"
grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "the capture failed"; }
grep -q '^ITEMS=3$' "$TMP/cap/plex/MANIFEST" || fail "expected 3 items"
grep -q '^CAPTURE_MODE=consistent$' "$TMP/cap/plex/MANIFEST" || fail "mode is not consistent"
grep -q 'Preferences.xml|file-copy|' "$TMP/cap/plex/MANIFEST" || fail "Preferences.xml not captured"
echo "  3 items, consistent, Preferences.xml among them"

restore_into() {  # $1 = target
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" CFG_FILE="$TMP/no.conf"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    tracked_service_container_id_any() { printf '%s' "$CID_A"; }
    service_state_restore "$TMP/cap/plex" "$1" >/dev/null 2>&1
    echo "rc=$?"
  )
}

say "3. destroy the source, restore, and start plex on what came back"
out="$(restore_into "$TMP/restored")"
grep -q 'rc=0' <<< "$out" || fail "restore failed: $out"
docker compose -p "$P1" -f "$TMP/$P1.yml" down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "$TMP/data"
[[ ! -d "$TMP/data" ]] || fail "the source data survived"
mkdir -p "$TMP/final/$PMSREL/Plug-in Support/Databases"
cp -a "$TMP/restored/config/." "$TMP/final/" || fail "could not stage the restored config"
PREF_B="$TMP/final/$PMSREL/Preferences.xml"
[[ -s "$PREF_B" ]] || fail "Preferences.xml was not restored"
printf '  restored Preferences.xml: %s\n' "$(stat -c '%s bytes, mode %a' "$PREF_B")"
[[ "$(stat -c %a "$PREF_B")" == "600" ]] \
  || fail "the restored Preferences.xml is mode $(stat -c %a "$PREF_B"), not 600 --
it holds the server token"
CID_B="$(mk "$P2" "$TMP/final")"
[[ -n "$CID_B" && "$CID_B" != "$PROD_CID" ]] || fail "bad second container"
wait_plex "$TMP/final" \
  || { printf '%s\n' "$(docker logs "$CID_B" 2>&1 | tail -8 || true)"; fail "plex did not come up on the restored state"; }
st="$(docker inspect -f '{{.State.Status}}' "$CID_B")"
echo "  plex status: $st"
[[ "$st" == "running" ]] || fail "plex is not running against the restored state"

say "4. THE CLAIM: it is the SAME SERVER -- same MachineIdentifier"
ID_B="$(machine_id "$PREF_B")"
echo "  before: $ID_A"
echo "  after : ${ID_B:-<none>}"
[[ -n "$ID_B" ]] || fail "the restored server has no MachineIdentifier"
[[ "$ID_A" == "$ID_B" ]] \
  || fail "the identifier CHANGED, so a restored Plex is a different server and
every paired client would have to re-pair -- which is the thing declaring
Preferences.xml is supposed to prevent"
echo "  identical -- the restore preserved the server identity"

say "5. and the restored library database opens in PLEX's own sqlite"
RDB="$TMP/final/$PMSREL/Plug-in Support/Databases/com.plexapp.plugins.library.db"
ic="$(docker exec "$CID_B" "$PSQL" "/config/$PMSREL/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
  'PRAGMA integrity_check;' 2>&1 | sed -n '1p')"
tb="$(docker exec "$CID_B" "$PSQL" "/config/$PMSREL/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
  "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>&1 | sed -n '1p')"
printf '  %s bytes   integrity_check: %s   tables: %s\n' "$(stat -c %s "$RDB")" "$ic" "$tb"
[[ "$ic" == "ok" ]] || fail "the restored library database is not sound"
[[ "${tb:-0}" -ge 20 ]] || fail "only $tb tables"

say "6. NEGATIVE CONTROL: without Preferences.xml, Plex becomes a NEW server"
# Simulating a capture that took "the databases" and left the token behind.
docker compose -p "$P2" -f "$TMP/$P2.yml" down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "$TMP/nopref"
out="$(restore_into "$TMP/nopref")"
grep -q 'rc=0' <<< "$out" || fail "the second restore failed: $out"
mkdir -p "$TMP/final2"
cp -a "$TMP/nopref/config/." "$TMP/final2/" || fail "could not stage"
rm -f "$TMP/final2/$PMSREL/Preferences.xml"
[[ ! -e "$TMP/final2/$PMSREL/Preferences.xml" ]] || fail "it is still there, so this control proves nothing"
CID_C="$(mk "$P2" "$TMP/final2")"
wait_plex "$TMP/final2" \
  || { printf '%s\n' "$(docker logs "$CID_C" 2>&1 | tail -8 || true)"; fail "plex did not come up without Preferences.xml"; }
ID_C="$(machine_id "$TMP/final2/$PMSREL/Preferences.xml")"
echo "  plex started fine and wrote a new Preferences.xml"
echo "  new MachineIdentifier: ${ID_C:-<none>}"
[[ -n "$ID_C" ]] || fail "no identifier at all, so the control is about the wrong thing"
[[ "$ID_C" != "$ID_A" ]] \
  || fail "the identifier is the SAME without Preferences.xml, so declaring it
buys nothing and the premise of that declaration was wrong"
echo "  different -- a restore without the token is a different server, and Plex"
echo "  gives no sign of it"

say "7. teardown, asserted"
cleanup; trap - EXIT
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "$p left a container"
done
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect plex --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production plex was replaced"
echo "  production plex still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: plex STARTS against a restored capture and remains the SAME SERVER."
echo
echo "The negative control is the evidence: without Preferences.xml it starts"
echo "just as happily as a DIFFERENT server, which no client would be paired to."
echo "Not proven: that it SERVES a library -- no media, no clients, nothing played."
