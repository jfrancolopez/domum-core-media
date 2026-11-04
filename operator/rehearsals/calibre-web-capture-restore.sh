#!/usr/bin/env bash
# calibre-web: the `consistent` capture path against the REAL image.
#
# Why this one exists separately from the plex and navidrome rehearsals:
#
#   * it is the only service of the five whose database is `journal_mode
#     delete` rather than WAL, so it proves the `.backup` path does not DEPEND
#     on there being a WAL to walk;
#   * it carries `config/.key` -- 44 bytes, a Fernet key -- and app.db stores
#     credentials ENCRYPTED with it (`settings.mail_password_e`,
#     `settings.config_ldap_serv_password_e`,
#     `settings.config_reverse_proxy_login_header_secret_e`; the `_e` suffix is
#     calibre-web's own convention). The declaration used to capture app.db and
#     gdrive.db and MISS the key, so a restore would have brought back those
#     values as undecryptable bytes and calibre-web would have come up and
#     silently failed to send mail. This rehearsal is what proves the key is
#     now captured and restored WITH ITS MODE.
#
# Production is never touched: a disposable compose project, the image pinned
# by ID, PUID/PGID as the invoking account, no network, teardown asserted.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ=domum-cwrehearse
TMP="$(mktemp -d)"
echo "fixture: $TMP"
SQ=/usr/bin/sqlite3

say "0. isolation, before anything is created"
PROD_CID="$(docker inspect calibre-web --format '{{.Id}}' 2>/dev/null)" \
  || fail "cannot read the production calibre-web container"
PROD_IMG="$(docker inspect calibre-web --format '{{.Image}}' 2>/dev/null)"
BEFORE_N="$(docker ps -q | wc -l)"
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "project name taken: $PROJ"
echo "  production ${PROD_CID:0:12}  image ${PROD_IMG:7:12}  containers=$BEFORE_N"

cleanup() {
  docker compose -p "$PROJ" -f "$TMP/c.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

say "1. a disposable calibre-web, image pinned by ID"
mkdir -p "$TMP/data/calibre-web/config" "$TMP/books" "$TMP/cap" "$TMP/restore"
# DOCKER_MODS is deliberately NOT passed: production uses it to add the calibre
# binaries, and it fetches the mod over the network. This rehearsal is about
# app.db and the key, and `network_mode: none` is the only honest guarantee
# that nothing leaves the host.
cat > "$TMP/c.yml" <<YML
services:
  calibre-web:
    image: $PROD_IMG
    network_mode: "none"
    environment:
      PUID: "$(id -u)"
      PGID: "$(id -g)"
      TZ: UTC
    volumes:
      - $TMP/data/calibre-web/config:/config
      - $TMP/books:/books:ro
YML
docker compose -p "$PROJ" -f "$TMP/c.yml" up -d >/dev/null 2>&1 || fail "it did not start"
CID="$(docker compose -p "$PROJ" -f "$TMP/c.yml" ps -q calibre-web)"
[[ -n "$CID" && "$CID" != "$PROD_CID" ]] || fail "resolved the production container"
scope="$(docker compose -p "$PROJ" -f "$TMP/c.yml" ps -qa || true)"
grep -q "^$PROD_CID" <<< "$scope" && fail "production is inside the disposable project's scope"
echo "  disposable ${CID:0:12}, production absent from scope"

say "2. every declared item appears, and the key is mode 600 on a fresh install"
CFG="$TMP/data/calibre-web/config"
for _ in $(seq 1 120); do
  [[ -s "$CFG/app.db" && -s "$CFG/.key" && -s "$CFG/gdrive.db" \
     && -e "$CFG/client_secrets.json" ]] && break
  sleep 1
done
for f in app.db gdrive.db .key client_secrets.json; do
  [[ -e "$CFG/$f" ]] || { printf '%s\n' "$(docker logs "$CID" 2>&1 | tail -6 || true)"; fail "$f never appeared"; }
  printf '  %-22s %s\n' "$f" "$(stat -c '%s bytes, mode %a' "$CFG/$f")"
done
jm="$(docker exec "$CID" "$SQ" /config/app.db 'PRAGMA journal_mode;' 2>&1 | head -1)"
echo "  app.db journal_mode: $jm   (delete = no WAL, unlike the other four services)"

say "3. the capture -- 4 items, including the encryption key"
cap_out="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/books" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
         CFG_FILE="$TMP/absent.conf"
  mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID"; }
  service_state_capture calibre-web "$TMP/cap/cw" 2>&1
  echo "rc=$?"
)"
printf '%s\n' "$cap_out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$cap_out" || fail "the capture failed"
sed 's/^/  /' "$TMP/cap/cw/MANIFEST"
grep -q '^CAPTURE_MODE=consistent$' "$TMP/cap/cw/MANIFEST" || fail "mode is not consistent"
grep -q '^RESULT=COMPLETE$' "$TMP/cap/cw/MANIFEST" || fail "not COMPLETE"
grep -q '^ITEMS=4$' "$TMP/cap/cw/MANIFEST" || fail "expected 4 declared items"
grep -q 'config/\.key|file-copy|44|600|' "$TMP/cap/cw/MANIFEST" \
  || fail "the encryption key was not captured as a 44-byte mode-600 file item --
without it the _e columns in app.db restore as undecryptable bytes"
echo "  4 items, consistent, and the key recorded with its mode"

say "4. restore, and the key comes back with its MODE intact"
res_out="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/books" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
         CFG_FILE="$TMP/absent.conf"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID"; }
  service_state_verify "$TMP/cap/cw" 2>&1; echo "verify_rc=$?"
  service_state_restore "$TMP/cap/cw" "$TMP/restore" 2>&1; echo "restore_rc=$?"
)"
printf '%s\n' "$res_out" | sed 's/^/  /'
grep -q 'verify_rc=0' <<< "$res_out" || fail "verify failed"
grep -q 'restore_rc=0' <<< "$res_out" || fail "restore failed"
rkey="$(find "$TMP/restore" -name '.key' | head -1)"
[[ -n "$rkey" ]] || fail "the key was not restored"
rmode="$(stat -c %a "$rkey")"
echo "  restored key: $(stat -c '%s bytes, mode %a' "$rkey")"
[[ "$rmode" == "600" ]] \
  || fail "the key restored as mode $rmode, not 600 -- a widened mode on a
Fernet key that decrypts stored credentials is a disclosure"
# Never print the key. Its SIZE and MODE are the claims; its value is not.
[[ "$(stat -c %s "$rkey")" == "44" ]] || fail "the restored key is not 44 bytes"

say "5. the restored app.db opens, and still has the ENCRYPTED columns"
rdb="$(find "$TMP/restore" -name 'app.db' | head -1)"
[[ -n "$rdb" ]] || fail "no restored app.db"
docker cp "$rdb" "$CID:/tmp/r.db" >/dev/null 2>&1 || fail "copy back failed"
ic="$(docker exec "$CID" "$SQ" /tmp/r.db 'PRAGMA integrity_check;' 2>&1 | head -1)"
enc="$(docker exec "$CID" "$SQ" /tmp/r.db \
  "SELECT count(*) FROM pragma_table_info('settings') WHERE name LIKE '%\\_e' ESCAPE '\\';" 2>&1 | head -1)"
docker exec "$CID" rm -f /tmp/r.db >/dev/null 2>&1 || true
echo "  integrity_check : $ic"
echo "  _e columns      : $enc   (each one is useless without the key above)"
[[ "$ic" == "ok" ]] || fail "the restored database is not sound"
[[ "${enc:-0}" -ge 1 ]] \
  || fail "no encrypted columns found -- then the key would not be needed, and
this rehearsal's premise is wrong"

say "6. teardown, asserted"
cleanup; trap - EXIT
[[ -z "$(docker ps -aq --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "a container remains"
[[ -z "$(docker volume ls -q --filter "name=^${PROJ}" 2>/dev/null)" ]] || fail "a volume remains"
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect calibre-web --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production calibre-web was replaced"
echo "  production calibre-web still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: calibre-web consistent-capture rehearsal against the real image"
