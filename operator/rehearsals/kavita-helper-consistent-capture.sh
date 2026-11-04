#!/usr/bin/env bash
# kavita: an application-CONSISTENT capture with NO DOWNTIME, through a helper
# image that ships sqlite3.
#
# This rehearsal exists because the project concluded the opposite. jellyfin
# and kavita ship no sqlite3 and this host has none, so their captures were
# recorded `file-copy-unproven` -- a copy of a WAL-mode database taken while
# the service may be writing -- and the stated remedy was to STOP the service.
# The operator pushed back, and the measurement says they were right.
#
# What this drives is the real `service_state_capture`, not a hand-rolled
# docker command: the point is that the CLI now reaches `consistent` for kavita
# without stopping it.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ=domum-kvhelper
TMP="$(mktemp -d)"
echo "fixture: $TMP"

say "0. isolation"
PROD_CID="$(docker inspect kavita --format '{{.Id}}' 2>/dev/null)" || fail "no production kavita"
PROD_IMG="$(docker inspect kavita --format '{{.Image}}' 2>/dev/null)"
HELPER_IMG="$(docker inspect navidrome --format '{{.Image}}' 2>/dev/null)" || fail "no helper source"
BEFORE_N="$(docker ps -q | wc -l)"
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "project name taken"
echo "  production kavita ${PROD_CID:0:12}  helper image ${HELPER_IMG:7:12}  containers=$BEFORE_N"

cleanup() {
  docker compose -p "$PROJ" -f "$TMP/c.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$TMP:/t" busybox sh -c 'rm -rf /t/* /t/.[!.]* 2>/dev/null' >/dev/null 2>&1 || true
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

say "1. a disposable kavita on the production image, pinned by ID"
mkdir -p "$TMP/data/kavita/config" "$TMP/cap"
cat > "$TMP/c.yml" <<YML
services:
  kavita:
    image: $PROD_IMG
    network_mode: "none"
    volumes:
      - $TMP/data/kavita/config:/kavita/config
YML
docker compose -p "$PROJ" -f "$TMP/c.yml" up -d >/dev/null 2>&1 || fail "kavita did not start"
CID="$(docker compose -p "$PROJ" -f "$TMP/c.yml" ps -q kavita)"
[[ -n "$CID" && "$CID" != "$PROD_CID" ]] || fail "resolved the production container"
scope="$(docker compose -p "$PROJ" -f "$TMP/c.yml" ps -qa || true)"
grep -q "^$PROD_CID" <<< "$scope" && fail "production is inside the disposable scope"
CFG="$TMP/data/kavita/config"
for _ in $(seq 1 150); do [[ -s "$CFG/kavita.db" && -d "$CFG/templates" ]] && break; sleep 1; done
[[ -s "$CFG/kavita.db" ]] || { printf '%s\n' "$(docker logs "$CID" 2>&1 | tail -6 || true)"; fail "no kavita.db"; }
sleep 10
say "2. the database is LIVE and WAL-mode, with content only in the WAL"
main_sz="$(stat -c %s "$CFG/kavita.db")"
wal_sz="$(stat -c %s "$CFG/kavita.db-wal" 2>/dev/null || echo 0)"
hdr="$(dd if="$CFG/kavita.db" bs=1 skip=18 count=2 2>/dev/null | od -An -tu1 | tr -s ' ')"
printf '  main %s   -wal %s   shm %s   header 18/19:%s\n' "$main_sz" "$wal_sz" \
  "$([[ -e "$CFG/kavita.db-shm" ]] && echo present || echo absent)" "$hdr"
[[ "${wal_sz:-0}" -gt 0 ]] || fail "no WAL content, so this proves nothing about WAL capture"

say "3. the REAL capture -- and it must reach CONSISTENT without stopping kavita"
cap_out="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
         CFG_FILE="$TMP/absent.conf" SQLITE_HELPER_IMAGE="$HELPER_IMG"
  mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log" "$TMP/media"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID"; }
  echo "mode=$(service_state_capture_mode kavita)"
  service_state_capture kavita "$TMP/cap/kv" 2>&1
  echo "rc=$?"
)"
printf '%s\n' "$cap_out" | sed 's/^/  /'
grep -q 'mode=consistent' <<< "$cap_out" \
  || fail "kavita's capture mode is still not consistent -- the helper was not used"
grep -q 'rc=0' <<< "$cap_out" || fail "the capture failed"
sed 's/^/  /' "$TMP/cap/kv/MANIFEST"
grep -q '^CAPTURE_MODE=consistent$' "$TMP/cap/kv/MANIFEST" || fail "manifest mode is not consistent"
grep -q 'config/kavita.db|sqlite-backup-helper|' "$TMP/cap/kv/MANIFEST" \
  || fail "the database was not captured via the helper. 'sqlite-backup' would
mean the application's own binary answered, which kavita has none of -- two
claims must not wear one label"

say "4. kavita was NEVER STOPPED, and nothing was written into its data dir"
st="$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null)"
echo "  kavita status: $st   (same container id: ${CID:0:12})"
[[ "$st" == "running" ]] || fail "kavita is not running -- this path must cause no downtime"
logs="$(docker logs "$CID" 2>&1 || true)"
grep -qiE 'database is locked|disk I/O error|malformed' <<< "$logs" \
  && fail "kavita logged a database error while the helper read its database"
stray_all="$(find "$CFG" -maxdepth 1 \( -name '*.helper' -o -name '*backup*.db' \) || true)"
stray="$(sed -n '1,3p' <<< "$stray_all")"
[[ -z "$stray" ]] || fail "the helper left files in the live data dir: $stray"
echo "  no database error; no helper artefact in the live directory"

say "5. the captured database is SOUND and carries the WAL's content"
cap_db="$TMP/cap/kv/files/config_kavita.db"
[[ -s "$cap_db" ]] || fail "no captured database"
# Mounted READ-WRITE on purpose, and this is worth knowing: `.backup` of a
# WAL database produces a database that is ITSELF in WAL mode, so opening it
# read-only fails with "unable to open database file" because SQLite must
# create the -shm. The first version of this check mounted :ro and reported a
# perfectly sound capture as unsound. Verifying a capture therefore needs a
# writable copy -- which is exactly what service_state_restore does, by
# `docker cp`ing the file into the container before checking it.
ic_raw="$(docker run --rm --network none --user 0:0 --entrypoint /usr/bin/sqlite3 \
  -v "$TMP/cap/kv/files:/f" "$HELPER_IMG" /f/config_kavita.db 'PRAGMA integrity_check;' 2>&1 || true)"
ic="$(sed -n '1p' <<< "$ic_raw")"
tb_raw="$(docker run --rm --network none --user 0:0 --entrypoint /usr/bin/sqlite3 \
  -v "$TMP/cap/kv/files:/f" "$HELPER_IMG" /f/config_kavita.db \
  "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>&1 || true)"
tb="$(sed -n '1p' <<< "$tb_raw")"
printf '  captured %s bytes (main was %s, -wal %s)\n' "$(stat -c %s "$cap_db")" "$main_sz" "$wal_sz"
printf '  integrity_check: %s   tables: %s\n' "$ic" "$tb"
[[ "$ic" == "ok" ]] || fail "the captured database is not sound"
[[ "${tb:-0}" -ge 10 ]] || fail "only $tb tables -- that is not kavita's schema"
[[ "$(stat -c %s "$cap_db")" -gt "$main_sz" ]] \
  || fail "the capture is no larger than the main file, so it may not have
included the WAL -- which is the whole claim"

say "6. teardown, asserted"
cleanup; trap - EXIT
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "a container remains"
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect kavita --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production kavita was replaced"
echo "  production kavita still ${AFTER_CID:0:12}, untouched and never stopped"
echo
echo "PASS: kavita captured CONSISTENTLY with no downtime, via a helper sqlite3"
