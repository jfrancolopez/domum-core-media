#!/usr/bin/env bash
# ALL FIVE services: capture -> encrypted pack -> a FRESH ENVIRONMENT that has
# nothing but the packs and an age identity -> unpack -> restore -> verify ->
# start one application on what came back.
#
# The per-service rehearsals each prove one service deeply. This proves the set
# RECONSTRUCTS: five independent artefacts, opened somewhere that never saw the
# originals, every declared item's digest and mode re-verified.
#
# WHAT "FRESH ENVIRONMENT" MEANS HERE, precisely: a second directory tree whose
# only inputs are the five packs, their .sha256 files and an identity file. The
# source captures, the source data directories and the source containers are
# destroyed and asserted gone first. It is NOT a different machine -- that is
# P5.3 and needs hardware -- and it is NOT the operator's real key, which is
# deliberately not on this host.
#
# Sequential on purpose: five media servers at once on an N100 would make the
# timings meaningless and could disturb production's share of the machine.
set -uo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo; echo "== $* =="; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"; chmod 0700 "$TMP"
echo "fixture: $TMP"
SERVICES="navidrome calibre-web kavita jellyfin plex"

say "0. isolation, before anything is created"
BEFORE_N="$(docker ps -q | wc -l)"
declare -A PROD_CID PROD_IMG
for s in $SERVICES; do
  PROD_CID[$s]="$(docker inspect "$s" --format '{{.Id}}' 2>/dev/null)" || fail "no production $s"
  PROD_IMG[$s]="$(docker inspect "$s" --format '{{.Image}}' 2>/dev/null)"
  [[ -z "$(docker ps -aq --filter "name=^domum-five-${s}" 2>/dev/null)" ]] || fail "project name taken: $s"
done
HELPER_IMG="${PROD_IMG[navidrome]}"
echo "  containers=$BEFORE_N; five project names free; helper ${HELPER_IMG:7:12}"

cleanup() {
  for s in $SERVICES; do
    docker compose -p "domum-five-$s" -f "$TMP/$s.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  docker compose -p domum-five-restored -f "$TMP/restored.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$TMP:/t" busybox sh -c 'rm -rf /t/* /t/.[!.]* 2>/dev/null' >/dev/null 2>&1 || true
  rm -rf -- "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

say "1. a disposable age keypair -- the real private key is NOT on this host"
mkdir -p "$TMP/keys"; chmod 0700 "$TMP/keys"
age-keygen -o "$TMP/keys/ident" 2>/dev/null || fail "age-keygen failed"
chmod 0600 "$TMP/keys/ident"
age-keygen -y "$TMP/keys/ident" > "$TMP/keys/pub" 2>/dev/null || fail "no public key"
echo "  recipient: $(cat "$TMP/keys/pub")"

cli() {  # $1 = extra shell, $2 = expression
  (
    cd "$REPO" || exit 1
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" \
           DOMUM_MEDIA_ROOT="$TMP/media" SECRETS_DIR="$TMP/sec" \
           DOMUM_SNAPSHOT_ROOT="$TMP/snap" DOMUM_LOG_DIR="$TMP/log" \
           CFG_FILE="$TMP/absent.conf" \
           STATE_PACK_AGE_PUBKEY_FILE="$TMP/keys/pub" \
           SQLITE_HELPER_IMAGE="$HELPER_IMG"
    mkdir -p "$TMP/state" "$TMP/sec" "$TMP/snap" "$TMP/log" "$TMP/media"
    # shellcheck disable=SC1090
    source "$REPO/bin/domum-media" >/dev/null 2>&1
    set +e
    eval "$1"
    eval "$2"
    echo "rc=$?"
  ) 2>&1
}

mount_for() {  # $1 = service -> the container path its /config-equivalent uses
  case "$1" in
    navidrome)   printf '/data' ;;
    kavita)      printf '/kavita/config' ;;
    *)           printf '/config' ;;
  esac
}
hostdir_for() {  # $1 = service -> the host dir that mount maps to
  case "$1" in
    navidrome) printf '%s/data/navidrome' "$TMP" ;;
    kavita)    printf '%s/data/kavita/config' "$TMP" ;;
    *)         printf '%s/data/%s/config' "$TMP" "$1" ;;
  esac
}
# The declared items whose arrival means initialisation has finished.
ready_probe() {  # $1 = service, $2 = host dir
  local s="$1" d="$2"
  case "$s" in
    navidrome)   [[ -s "$d/navidrome.db" ]] ;;
    kavita)      [[ -s "$d/kavita.db" && -s "$d/appsettings.json" && -d "$d/templates" ]] ;;
    calibre-web) [[ -s "$d/app.db" && -s "$d/.key" && -s "$d/gdrive.db" && -e "$d/client_secrets.json" ]] ;;
    jellyfin)    [[ -s "$d/data/data/jellyfin.db" && -s "$d/system.xml" && -s "$d/encoding.xml" \
                    && -s "$d/network.xml" && -s "$d/database.xml" && -s "$d/data/data/device.txt" \
                    && -d "$d/.aspnet/DataProtection-Keys" ]] ;;
    plex)        local pms="$d/Library/Application Support/Plex Media Server"
                 [[ -s "$pms/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
                    && -s "$pms/Plug-in Support/Databases/com.plexapp.plugins.library.blobs.db" \
                    && -s "$pms/Preferences.xml" ]] ;;
  esac
}

say "2. capture and PACK each service in turn, from its own live instance"
mkdir -p "$TMP/packs" "$TMP/cap" "$TMP/media"
for s in $SERVICES; do
  hd="$(hostdir_for "$s")"; mkdir -p "$hd"
  cat > "$TMP/$s.yml" <<YML
services:
  $s:
    image: ${PROD_IMG[$s]}
    network_mode: "none"
    environment:
      PUID: "$(id -u)"
      PGID: "$(id -g)"
      TZ: UTC
      VERSION: docker
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /media
      ND_LOGLEVEL: error
      ND_SCANSCHEDULE: "0"
    volumes:
      - $hd:$(mount_for "$s")
      - $TMP/media:/media:ro
YML
  docker compose -p "domum-five-$s" -f "$TMP/$s.yml" down -v >/dev/null 2>&1 || true
  docker compose -p "domum-five-$s" -f "$TMP/$s.yml" up -d >/dev/null 2>&1 || fail "$s did not start"
  cid="$(docker compose -p "domum-five-$s" -f "$TMP/$s.yml" ps -q "$s")"
  [[ -n "$cid" && "$cid" != "${PROD_CID[$s]}" ]] || fail "$s resolved the PRODUCTION container"
  ok=0
  for _ in $(seq 1 240); do ready_probe "$s" "$hd" && { ok=1; break; }; sleep 1; done
  (( ok == 1 )) || { printf '%s\n' "$(docker logs "$cid" 2>&1 | tail -5 || true)"; fail "$s never finished initialising"; }
  out="$(cli "tracked_service_container_id_any() { printf '%s' '$cid'; }" \
    "service_state_capture $s '$TMP/cap/$s'")"
  grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "$s capture failed"; }
  mode="$(sed -nE 's/^CAPTURE_MODE=(.*)$/\1/p' "$TMP/cap/$s/MANIFEST")"
  items="$(sed -nE 's/^ITEMS=(.*)$/\1/p' "$TMP/cap/$s/MANIFEST")"
  out="$(cli '' "service_state_pack '$TMP/cap/$s' '$TMP/packs/$s.tar.age'")"
  grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "$s pack failed"; }
  printf '  %-12s %-11s %s items   pack %7s bytes\n' \
    "$s" "$mode" "$items" "$(stat -c %s "$TMP/packs/$s.tar.age")"
  docker compose -p "domum-five-$s" -f "$TMP/$s.yml" down -v --remove-orphans >/dev/null 2>&1 || true
done

say "3. FRESH ENVIRONMENT: destroy every source, keep only packs + identity"
# Removed through a disposable container, because not every image honours
# PUID/PGID: kavita's runs as root regardless, so its tree is root-owned and
# `rm -rf` from the development account fails. The same tool that created the
# problem removes it -- the lesson from the Jellyfin rehearsal that left 39
# root-owned entries behind.
docker run --rm -v "$TMP:/t" busybox sh -c 'rm -rf /t/cap /t/data' >/dev/null 2>&1 || true
rm -rf "$TMP/cap" "$TMP/data" 2>/dev/null || true
[[ ! -d "$TMP/cap" && ! -d "$TMP/data" ]] \
  || fail "a source survived: $(ls -ld "$TMP/cap" "$TMP/data" 2>/dev/null | tr '\n' ' ')"
for s in $SERVICES; do
  [[ -z "$(docker ps -aq --filter "name=^domum-five-${s}" 2>/dev/null)" ]] || fail "$s container survived"
done
echo "  remaining inputs:"
( cd "$TMP" && find packs keys -type f | sort | sed 's/^/    /' )

say "4. verify every pack WITHOUT decrypting -- the only claim a host can make"
for s in $SERVICES; do
  out="$(cli '' "service_state_pack_verify '$TMP/packs/$s.tar.age'")"
  grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "$s pack did not verify"; }
  printf '  %-12s %s\n' "$s" "$(grep 'file integrity' <<< "$out" | sed 's/.*: //')"
done

say "5. unpack and RESTORE all five in the fresh environment"
mkdir -p "$TMP/fresh"
for s in $SERVICES; do
  out="$(cli '' "service_state_unpack '$TMP/packs/$s.tar.age' '$TMP/keys/ident' '$TMP/fresh/$s-unpacked'")"
  grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "$s unpack failed"; }
  grep -q 'matches its recorded sha256' <<< "$out" || fail "$s: the checksum was not checked"
  out="$(cli '' "service_state_restore '$TMP/fresh/$s-unpacked' '$TMP/fresh/$s-restored'")"
  grep -q 'rc=0' <<< "$out" || { printf '%s\n' "$out"; fail "$s restore failed"; }
  n="$(grep -c '^ITEM=' "$TMP/fresh/$s-unpacked/MANIFEST")"
  printf '  %-12s unpacked + restored, %s item(s), digests and modes re-verified\n' "$s" "$n"
done

say "6. the credentials and identities are all THERE, with their modes"
chk() {  # $1 = label, $2 = path, $3 = expected mode (empty to skip)
  [[ -e "$2" ]] || fail "$1 is missing from the restored set: $2"
  local m; m="$(stat -c %a "$2")"
  if [[ -n "${3:-}" && "$m" != "$3" ]]; then
    fail "$1 restored as mode $m, expected $3"
  fi
  printf '  %-44s %s bytes, mode %s\n' "$1" "$(stat -c %s "$2" 2>/dev/null || echo dir)" "$m"
}
chk "calibre-web Fernet key"       "$TMP/fresh/calibre-web-restored/config/.key" 600
chk "kavita JWT TokenKey"          "$TMP/fresh/kavita-restored/config/appsettings.json" ""
chk "jellyfin DataProtection-Keys" "$TMP/fresh/jellyfin-restored/config/.aspnet/DataProtection-Keys" ""
chk "jellyfin device identity"     "$TMP/fresh/jellyfin-restored/config/data/data/device.txt" ""
chk "plex server token"            "$TMP/fresh/plex-restored/config/Library/Application Support/Plex Media Server/Preferences.xml" 600
grep -q 'TokenKey' "$TMP/fresh/kavita-restored/config/appsettings.json" \
  || fail "the restored kavita settings carry no TokenKey"

say "7. and one application STARTS on what came out of the fresh environment"
mkdir -p "$TMP/final"
cp "$(find "$TMP/fresh/navidrome-restored" -name navidrome.db | head -1)" "$TMP/final/navidrome.db" \
  || fail "no restored navidrome database"
cat > "$TMP/restored.yml" <<YML
services:
  navidrome:
    image: ${PROD_IMG[navidrome]}
    network_mode: "none"
    user: "$(id -u):$(id -g)"
    environment:
      ND_DATAFOLDER: /data
      ND_MUSICFOLDER: /media
      ND_LOGLEVEL: info
      ND_SCANSCHEDULE: "0"
    volumes:
      - $TMP/final:/data
      - $TMP/media:/media:ro
YML
docker compose -p domum-five-restored -f "$TMP/restored.yml" up -d >/dev/null 2>&1 \
  || fail "navidrome did not start on the restored state"
rcid="$(docker compose -p domum-five-restored -f "$TMP/restored.yml" ps -q navidrome)"
ready=""
for _ in $(seq 1 90); do
  logs="$(docker logs "$rcid" 2>&1 || true)"
  grep -qF 'Navidrome server is ready!' <<< "$logs" && { ready=yes; break; }
  [[ "$(docker inspect -f '{{.State.Status}}' "$rcid" 2>/dev/null)" == "running" ]] || break
  sleep 1
done
logs="$(docker logs "$rcid" 2>&1 || true)"
sed -n '$p' <<< "$logs" | sed 's/^/    /'
[[ "$ready" == "yes" ]] || fail "navidrome never reported ready"
grep -qiE 'panic|fatal' <<< "$logs" && fail "navidrome logged a fatal error"
echo "  navidrome is ready against state that came from an encrypted pack"

say "8. teardown, asserted, and production untouched"
cleanup; trap - EXIT
for s in $SERVICES restored; do
  [[ -z "$(docker ps -aq --filter "name=^domum-five-${s}" 2>/dev/null)" ]] || fail "domum-five-$s left a container"
done
AFTER_N="$(docker ps -q | wc -l)"
echo "  containers before=$BEFORE_N after=$AFTER_N"
[[ "$BEFORE_N" == "$AFTER_N" ]] || fail "container count changed"
for s in $SERVICES; do
  now="$(docker inspect "$s" --format '{{.Id}}' 2>/dev/null)"
  [[ "$now" == "${PROD_CID[$s]}" ]] || fail "production $s was replaced"
done
echo "  all five production containers unchanged"
echo
echo "PASS: five services captured, encrypted, and reconstructed in a fresh"
echo "      environment from nothing but packs and a key -- one of them started."
echo
echo "What this does NOT prove, stated because it is what matters next:"
echo "  * that the OPERATOR'S key opens a pack -- this used a disposable one;"
echo "  * that a pack exists anywhere but this SSD -- none has been transferred;"
echo "  * that any service SERVES its library."
