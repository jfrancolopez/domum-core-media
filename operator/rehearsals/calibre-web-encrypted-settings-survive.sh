#!/usr/bin/env bash
# Does declaring calibre-web's `config/.key` actually BUY anything?
#
# The declaration was app.db + gdrive.db, and `.key` was added because app.db
# stores credentials Fernet-encrypted with it (`settings.mail_password_e` and
# friends -- the `_e` suffix is calibre-web's own convention). The argument was
# that a restore without the key brings those values back as undecryptable
# bytes. That is an argument. This measures it, in both directions:
#
#   WITH the key     a known plaintext encrypted before the capture must
#                    decrypt to the same plaintext after the restore
#   WITHOUT the key  the same restore, key deleted, must FAIL to decrypt
#
# The negative control is the point. Without it, "the value decrypted" could
# just as well mean calibre-web never encrypted anything.
#
# Everything runs in disposable compose projects on the production image pinned
# by ID, PUID/PGID as the invoking account, no network, production untouched.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1=domum-cwkeya; P2=domum-cwkeyb
TMP="$(mktemp -d)"; chmod 0700 "$TMP"
echo "fixture: $TMP"
SECRET='domum-rehearsal-smtp-password-7Q4w'

say "0. isolation"
PROD_CID="$(docker inspect calibre-web --format '{{.Id}}' 2>/dev/null)" || fail "no production calibre-web"
PROD_IMG="$(docker inspect calibre-web --format '{{.Image}}' 2>/dev/null)"
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
  mkdir -p "$2" "$TMP/books"
  cat > "$TMP/$1.yml" <<YML
services:
  calibre-web:
    image: $PROD_IMG
    network_mode: "none"
    environment:
      PUID: "$(id -u)"
      PGID: "$(id -g)"
      TZ: UTC
    volumes:
      - $2:/config
      - $TMP/books:/books:ro
YML
  docker compose -p "$1" -f "$TMP/$1.yml" up -d >/dev/null 2>&1 || fail "$1 did not start"
  docker compose -p "$1" -f "$TMP/$1.yml" ps -q calibre-web
}

wait_cfg() {  # $1 = config dir
  local d="$1" _
  for _ in $(seq 1 150); do
    [[ -s "$d/app.db" && -s "$d/.key" && -s "$d/gdrive.db" && -e "$d/client_secrets.json" ]] && return 0
    sleep 1
  done
  return 1
}

# Fernet, run INSIDE the image so the test uses the same library calibre-web
# does. The key is read from the mounted file and never printed.
fernet() {  # $1 = cid, $2 = mode (enc|dec), $3 = payload
  docker exec "$1" /lsiopy/bin/python3 -c '
import sys
from cryptography.fernet import Fernet
mode, payload = sys.argv[1], sys.argv[2]
key = open("/config/.key","rb").read().strip()
f = Fernet(key)
if mode == "enc":
    sys.stdout.write(f.encrypt(payload.encode()).decode())
else:
    sys.stdout.write(f.decrypt(payload.encode()).decode())
' "$2" "$3" 2>&1
}

say "1. a disposable calibre-web, and a REAL Fernet-encrypted setting in app.db"
mkdir -p "$TMP/data/calibre-web/config" "$TMP/cap"
CID_A="$(mk "$P1" "$TMP/data/calibre-web/config")"
[[ -n "$CID_A" && "$CID_A" != "$PROD_CID" ]] || fail "resolved the production container"
wait_cfg "$TMP/data/calibre-web/config" || { printf '%s\n' "$(docker logs "$CID_A" 2>&1 | tail -6 || true)"; fail "config never completed"; }
printf '  .key: %s\n' "$(stat -c '%s bytes, mode %a' "$TMP/data/calibre-web/config/.key")"
CIPHER="$(fernet "$CID_A" enc "$SECRET")"
grep -q '^gAAAAA' <<< "$CIPHER" || fail "that does not look like a Fernet token: $CIPHER"
echo "  encrypted a known plaintext with calibre-web's own key and library"
docker exec "$CID_A" /usr/bin/sqlite3 /config/app.db \
  "UPDATE settings SET mail_password_e='$CIPHER' WHERE id=1;" >/dev/null 2>&1 \
  || fail "could not write the encrypted setting"
stored="$(docker exec "$CID_A" /usr/bin/sqlite3 /config/app.db \
  "SELECT mail_password_e FROM settings WHERE id=1;" 2>&1 | sed -n '1p')"
[[ "$stored" == "$CIPHER" ]] || fail "the setting did not persist"
grep -qF "$SECRET" <<< "$stored" \
  && fail "the stored value is PLAINTEXT, so this rehearsal would prove nothing"
echo "  stored in settings.mail_password_e, and it is not the plaintext"

say "2. capture all four declared items"
out="$(
  cd "$REPO" || exit 1
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
         DOMUM_MEDIA_ROOT="$TMP/books" SECRETS_DIR="$TMP/sec" \
         DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" CFG_FILE="$TMP/no.conf"
  mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
  # shellcheck disable=SC1090
  source "$REPO/bin/domum-media" >/dev/null 2>&1
  set +e
  tracked_service_container_id_any() { printf '%s' "$CID_A"; }
  service_state_capture calibre-web "$TMP/cap/cw" 2>&1
  echo "rc=$?"
)"
grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "the capture failed"; }
grep -q '^ITEMS=4$' "$TMP/cap/cw/MANIFEST" || fail "expected 4 items"
grep -q 'config/\.key|file-copy|44|600|' "$TMP/cap/cw/MANIFEST" || fail "the key was not captured 44|600"
echo "  4 items, key recorded 44 bytes / mode 600"

restore_into() {  # $1 = target
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/books" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" CFG_FILE="$TMP/no.conf"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    tracked_service_container_id_any() { printf '%s' "$CID_A"; }
    service_state_restore "$TMP/cap/cw" "$1" >/dev/null 2>&1
    echo "rc=$?"
  )
}

say "3. destroy the source, restore WITH the key, and start calibre-web on it"
out="$(restore_into "$TMP/restored")"
grep -q 'rc=0' <<< "$out" || fail "restore failed: $out"
docker compose -p "$P1" -f "$TMP/$P1.yml" down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "$TMP/data"
[[ ! -d "$TMP/data" ]] || fail "the source data survived"
mkdir -p "$TMP/final"
cp -a "$TMP/restored/config/." "$TMP/final/" || fail "could not stage the restored config"
printf '  restored config: %s\n' "$(cd "$TMP/final" && find . -maxdepth 1 -type f | sort | tr '\n' ' ')"
[[ "$(stat -c %a "$TMP/final/.key")" == "600" ]] \
  || fail "the restored key is mode $(stat -c %a "$TMP/final/.key"), not 600"
CID_B="$(mk "$P2" "$TMP/final")"
[[ -n "$CID_B" && "$CID_B" != "$PROD_CID" ]] || fail "bad second container"
wait_cfg "$TMP/final" || { printf '%s\n' "$(docker logs "$CID_B" 2>&1 | tail -6 || true)"; fail "calibre-web did not come up"; }
st="$(docker inspect -f '{{.State.Status}}' "$CID_B")"
echo "  calibre-web status: $st"
[[ "$st" == "running" ]] || fail "calibre-web is not running against the restored state"

say "4. THE CLAIM: the encrypted setting still DECRYPTS to the known plaintext"
stored2="$(docker exec "$CID_B" /usr/bin/sqlite3 /config/app.db \
  "SELECT mail_password_e FROM settings WHERE id=1;" 2>&1 | sed -n '1p')"
[[ -n "$stored2" ]] || fail "the encrypted setting did not survive the restore"
plain="$(fernet "$CID_B" dec "$stored2")"
echo "  decrypted: ${plain:0:22}... (${#plain} chars)"
[[ "$plain" == "$SECRET" ]] \
  || fail "the setting did not decrypt to the original plaintext.
got: $plain"
echo "  it matches -- the capture carried everything needed to USE the value"

say "5. NEGATIVE CONTROL: the same restore WITHOUT the key must FAIL to decrypt"
# Simulating the declaration as it was before `.key` was added. Without this,
# section 4 could pass against a calibre-web that never encrypted anything.
docker compose -p "$P2" -f "$TMP/$P2.yml" down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "$TMP/nokey"
out="$(restore_into "$TMP/nokey")"
grep -q 'rc=0' <<< "$out" || fail "the second restore failed: $out"
mkdir -p "$TMP/final2"
cp -a "$TMP/nokey/config/." "$TMP/final2/" || fail "could not stage"
rm -f "$TMP/final2/.key"
[[ ! -e "$TMP/final2/.key" ]] || fail "the key is still there, so this control proves nothing"
CID_C="$(mk "$P2" "$TMP/final2")"
wait_cfg "$TMP/final2" || { printf '%s\n' "$(docker logs "$CID_C" 2>&1 | tail -6 || true)"; fail "calibre-web did not come up without the key"; }
# calibre-web regenerates a key it cannot find -- which is exactly the problem:
# the service looks healthy and the stored secret is now unreadable.
newkeysz="$(stat -c %s "$TMP/final2/.key" 2>/dev/null || echo 0)"
echo "  calibre-web regenerated a key: ${newkeysz} bytes (it starts up fine)"
stored3="$(docker exec "$CID_C" /usr/bin/sqlite3 /config/app.db \
  "SELECT mail_password_e FROM settings WHERE id=1;" 2>&1 | sed -n '1p')"
[[ -n "$stored3" ]] || fail "the encrypted setting vanished, so the control is about the wrong thing"
dec_out="$(fernet "$CID_C" dec "$stored3" || true)"
echo "  decrypt attempt: $(sed -n '$p' <<< "$dec_out" | cut -c1-60)"
grep -qF "$SECRET" <<< "$dec_out" \
  && fail "it decrypted WITHOUT the captured key, so declaring config/.key buys
nothing and the premise of that change was wrong"
echo "  it cannot be decrypted -- the key is what makes the value usable"

say "6. teardown, asserted"
cleanup; trap - EXIT
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "$p left a container"
done
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect calibre-web --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production calibre-web was replaced"
echo "  production calibre-web still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: calibre-web STARTS against a restored capture, and its encrypted"
echo "      settings are still USABLE -- which is what declaring config/.key buys."
echo
echo "The negative control is the evidence that matters: with the key deleted,"
echo "calibre-web starts just as happily and the stored secret cannot be read."
