#!/usr/bin/env bash
# ONE COMPLETE WORKFLOW, end to end:
#
#   live service -> capture -> ENCRYPTED pack -> independent restore ->
#   the application STARTS against what came back
#
# The operator asked for this rather than more tests that inspect manifests,
# and the reasoning is right: every step before the last one can pass while the
# application still fails to come up.
#
# WHAT MAKES THE RESTORE "INDEPENDENT". The second half is given ONLY the
# encrypted pack and an age identity. It never reads the original capture, the
# original data directory, or the service that produced them -- the fixture
# asserts those paths are gone before the restore starts, so there is nothing
# for it to fall back on.
#
# THE KEY IS DISPOSABLE, AND THAT IS NOT A SHORTCUT. Production packs are
# encrypted to the recovery pack's recipient, whose PRIVATE key is deliberately
# not on this host -- so this host cannot decrypt what it writes, by design. A
# round trip therefore has to use a keypair generated for the rehearsal. What
# that proves is the MECHANISM; whether a production pack can be opened rests
# on the operator's key custody, which this project already calls its single
# point of failure.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P1=domum-rtsrc; P2=domum-rtdst
TMP="$(mktemp -d)"; chmod 0700 "$TMP"
echo "fixture: $TMP"

say "0. isolation, before anything is created"
PROD_CID="$(docker inspect navidrome --format '{{.Id}}' 2>/dev/null)" || fail "no production navidrome"
PROD_IMG="$(docker inspect navidrome --format '{{.Image}}' 2>/dev/null)"
BEFORE_N="$(docker ps -q | wc -l)"
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "project name taken: $p"
done
echo "  production ${PROD_CID:0:12}  containers=$BEFORE_N  both project names free"

cleanup() {
  for p in "$P1" "$P2"; do
    docker compose -p "$p" -f "$TMP/$p.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

mk() {  # $1 = project, $2 = data dir -> prints the container id
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

cli() {  # $1 = extra shell, $2 = expression
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/music" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
           CFG_FILE="$TMP/absent.conf" \
           STATE_PACK_AGE_PUBKEY_FILE="$TMP/keys/pub"
    mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    eval "$1"
    eval "$2"
    echo "rc=$?"
  ) 2>&1
}

say "1. a DISPOSABLE age keypair -- production's private key is not on this host"
mkdir -p "$TMP/keys"; chmod 0700 "$TMP/keys"
age-keygen -o "$TMP/keys/ident" 2>/dev/null || fail "age-keygen failed"
chmod 0600 "$TMP/keys/ident"
age-keygen -y "$TMP/keys/ident" > "$TMP/keys/pub" 2>/dev/null || fail "could not derive the public key"
echo "  recipient: $(cat "$TMP/keys/pub")"
echo "  (public material -- the identity file is 0600 and never printed)"

say "2. a live navidrome, with content in the WAL"
mkdir -p "$TMP/data/navidrome" "$TMP/cap"
CID_A="$(mk "$P1" "$TMP/data/navidrome")"
[[ -n "$CID_A" && "$CID_A" != "$PROD_CID" ]] || fail "resolved the production container"
for _ in $(seq 1 90); do [[ -s "$TMP/data/navidrome/navidrome.db" ]] && break; sleep 1; done
[[ -s "$TMP/data/navidrome/navidrome.db" ]] || fail "no database"
sleep 6
MAIN_SZ="$(stat -c %s "$TMP/data/navidrome/navidrome.db")"
WAL_SZ="$(stat -c %s "$TMP/data/navidrome/navidrome.db-wal" 2>/dev/null || echo 0)"
printf '  main %s   -wal %s\n' "$MAIN_SZ" "$WAL_SZ"

say "3. capture, then PACK it -- encrypted, and the capture must verify first"
out="$(cli "tracked_service_container_id_any() { printf '%s' '$CID_A'; }" \
  "service_state_capture navidrome '$TMP/cap/nav'")"
grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "capture failed"; }
MARK="roundtrip-$(date -u +%s)"
# A marker, so "the application started" cannot be confused with "it made a new
# database". Written through navidrome's own sqlite3, into the CAPTURE.
docker cp "$TMP/cap/nav/files/navidrome.db" "$CID_A:/tmp/m.db" >/dev/null 2>&1 || fail "copy in failed"
docker exec "$CID_A" /usr/bin/sqlite3 /tmp/m.db \
  "CREATE TABLE IF NOT EXISTS domum_roundtrip(k TEXT); INSERT INTO domum_roundtrip VALUES('$MARK');" \
  >/dev/null 2>&1 || fail "could not write the marker"
docker cp "$CID_A:/tmp/m.db" "$TMP/cap/nav/files/navidrome.db" >/dev/null 2>&1 || fail "copy out failed"
docker exec "$CID_A" rm -f /tmp/m.db >/dev/null 2>&1 || true
# The marker changed the bytes, so the capture no longer matches its manifest.
# That is exactly what the pack gate exists for -- assert it REFUSES.
out="$(cli '' "service_state_pack '$TMP/cap/nav' '$TMP/packs/nav.tar.age'")"
grep -q 'rc=0' <<< "$out" && fail "a capture that no longer matches its manifest was PACKED.
The gate exists so an artefact cannot have provable integrity and unprovable
contents"
grep -q 'does not match its own manifest' <<< "$out" || fail "wrong refusal: $out"
echo "  refused a capture whose bytes had changed -- the gate works"
# Re-capture cleanly, then put the marker in the LIVE database instead, so the
# capture is honest and the marker still proves identity downstream.
docker exec "$CID_A" /usr/bin/sqlite3 /data/navidrome.db \
  "CREATE TABLE IF NOT EXISTS domum_roundtrip(k TEXT); INSERT INTO domum_roundtrip VALUES('$MARK');" \
  >/dev/null 2>&1 || fail "could not write the marker into the live database"
rm -rf "$TMP/cap/nav"
out="$(cli "tracked_service_container_id_any() { printf '%s' '$CID_A'; }" \
  "service_state_capture navidrome '$TMP/cap/nav'")"
grep -q 'rc=0' <<< "$out" || fail "re-capture failed"
out="$(cli '' "service_state_pack '$TMP/cap/nav' '$TMP/packs/nav.tar.age'")"
printf '%s\n' "$out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$out" || fail "the pack failed"
[[ -s "$TMP/packs/nav.tar.age" ]] || fail "no pack was written"
printf '  pack: %s bytes, mode %s\n' \
  "$(stat -c %s "$TMP/packs/nav.tar.age")" "$(stat -c %a "$TMP/packs/nav.tar.age")"
[[ "$(stat -c %a "$TMP/packs/nav.tar.age")" == "600" ]] || fail "the pack is not 0600"
[[ "$(stat -c %a "$TMP/packs")" == "700" ]] || fail "the pack directory is not 0700"

say "4. the pack is genuinely ENCRYPTED, and no plaintext was left behind"
hdr64="$(head -c 64 "$TMP/packs/nav.tar.age" || true)"
grep -q 'age-encryption.org' <<< "$hdr64" \
  || fail "the pack does not carry age's header, so it may not be encrypted"
# The marker is in the capture; it must NOT be readable in the pack.
grep -qaF "$MARK" "$TMP/packs/nav.tar.age" \
  && fail "the marker is readable in the ENCRYPTED pack -- it is not encrypted"
stray="$(find "$TMP/packs" -name '.pack.*' -o -name '*.age.age' || true)"
[[ -z "$stray" ]] || fail "a plaintext staging file was left behind: $stray"
echo "  age header present, marker not readable, no staging file left"

say "5. INDEPENDENCE: destroy the source, keep only the pack and the identity"
docker compose -p "$P1" -f "$TMP/$P1.yml" down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf "$TMP/cap" "$TMP/data"
[[ ! -d "$TMP/cap" && ! -d "$TMP/data" ]] || fail "the source survived"
[[ -z "$(docker ps -aq --filter "name=^${P1}" 2>/dev/null)" ]] || fail "the source service survived"
echo "  capture, data directory and source service all gone"
echo "  remaining inputs: $(cd "$TMP" && find packs keys -type f | sort | tr '\n' ' ')"

say "6. unpack with the identity, then RESTORE the capture"
out="$(cli '' "service_state_unpack '$TMP/packs/nav.tar.age' '$TMP/keys/ident' '$TMP/unpacked'")"
printf '%s\n' "$out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$out" || fail "unpack failed"
grep -q 'matches its recorded sha256' <<< "$out" || fail "the pack's checksum was not checked"
[[ -f "$TMP/unpacked/MANIFEST" ]] || fail "no manifest after unpack"
out="$(cli '' "service_state_restore '$TMP/unpacked' '$TMP/restored'")"
printf '%s\n' "$out" | sed 's/^/  /'
grep -q 'rc=0' <<< "$out" || fail "restore failed"

say "7. a WRONG identity must FAIL, or decryption proves nothing"
age-keygen -o "$TMP/keys/wrong" 2>/dev/null || fail "age-keygen failed"
chmod 0600 "$TMP/keys/wrong"
out="$(cli '' "service_state_unpack '$TMP/packs/nav.tar.age' '$TMP/keys/wrong' '$TMP/unpacked-wrong'")"
grep -q 'rc=0' <<< "$out" && fail "the pack decrypted with the WRONG identity"
grep -q 'could not decrypt' <<< "$out" || fail "the refusal does not say what happened: $out"
echo "  the wrong key cannot open it"

say "8. THE CLAIM THAT MATTERS: navidrome STARTS against the restored state"
mkdir -p "$TMP/final"
cp "$(find "$TMP/restored" -name navidrome.db | head -1)" "$TMP/final/navidrome.db" \
  || fail "no restored database to start against"
CID_B="$(mk "$P2" "$TMP/final")"
[[ -n "$CID_B" && "$CID_B" != "$PROD_CID" ]] || fail "bad second container"
ready=""
for _ in $(seq 1 90); do
  logs="$(docker logs "$CID_B" 2>&1 || true)"
  grep -qF 'Navidrome server is ready!' <<< "$logs" && { ready=yes; break; }
  [[ "$(docker inspect -f '{{.State.Status}}' "$CID_B" 2>/dev/null)" == "running" ]] || break
  sleep 1
done
logs="$(docker logs "$CID_B" 2>&1 || true)"
sed -n '$p' <<< "$logs" | sed 's/^/    /'
echo "  status: $(docker inspect -f '{{.State.Status}}' "$CID_B")   ready line: ${ready:-no}"
[[ "$ready" == "yes" ]] || fail "navidrome never reported ready against the restored state"
grep -qiE 'panic|fatal' <<< "$logs" && fail "navidrome logged a fatal error"
mk2="$(docker exec "$CID_B" /usr/bin/sqlite3 /data/navidrome.db \
  "SELECT k FROM domum_roundtrip;" 2>&1 | sed -n '1p')"
echo "  marker read back: $mk2"
[[ "$mk2" == "$MARK" ]] \
  || fail "the marker is gone -- navidrome did not open the database that came
out of the encrypted pack, or replaced it with a fresh one"

say "9. teardown, asserted"
cleanup; trap - EXIT
for p in "$P1" "$P2"; do
  [[ -z "$(docker ps -aq --filter "name=^${p}" 2>/dev/null)" ]] || fail "$p left a container"
done
AFTER_N="$(docker ps -q | wc -l)"
AFTER_CID="$(docker inspect navidrome --format '{{.Id}}' 2>/dev/null)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
[[ "$AFTER_CID" == "$PROD_CID" ]] || fail "production navidrome was replaced"
echo "  production navidrome still ${AFTER_CID:0:12}, untouched"
echo
echo "PASS: capture -> ENCRYPTED pack -> independent restore -> the application STARTS"
echo
echo "What this does NOT prove: that navidrome SERVES a library from it (no"
echo "music, no users, nothing fetched), and that a PRODUCTION pack can be"
echo "opened -- that rests on the operator's private key, which is deliberately"
echo "not on this host."
