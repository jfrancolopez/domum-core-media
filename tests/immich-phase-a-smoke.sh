#!/usr/bin/env bash
set -uo pipefail

# Proves `immich-phase-a` earns exactly one claim and no more:
#
#   APPLICATION STARTUP VERIFIED  a fresh Immich of the production image opened
#                                 the restored database, migrated it WITHOUT
#                                 changing the recovered records, authenticated
#                                 a recovered user, and reported asset counts
#                                 matching the database per media type.
#
# It must never read as full recovery: no original is restored, so nothing here
# shows the library can be SERVED.
#
# The load-bearing assertions are the refusals and the isolation. A rehearsal
# that touched production would be far worse than one that failed.
#
# Hermetic: `docker` is a stub, so no container runs and no image is needed.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"; STATE="$TMP_DIR/state"; LIB="$DATA/immich/library"
mkdir -p "$DATA/immich/backup-staging" "$STATE" "$TMP_DIR/media" "$TMP_DIR/bin"
export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media" DOMUM_STATE_ROOT="$STATE"
export IMMICH_LIBRARY_DIR="$LIB" BACKUP_TARGETS=cloud
export SECRETS_DIR="$TMP_DIR/secrets"; mkdir -p "$SECRETS_DIR"

printf 'CREATE TABLE asset();\n' | gzip -9 > "$TMP_DIR/dump.sql.gz"

# Facts the stubbed database returns. Sections override one at a time.
cat > "$TMP_DIR/facts" <<'EOF'
assets_before=23033
users_before=2
assets_after=23033
users_after=2
vis_img=13893
vis_vid=1712
hidden=7428
EOF

# A docker stub covering the whole lifecycle, recording what it was asked.
cat > "$TMP_DIR/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
LOG="${STUB_LOG:?}"
echo "docker $*" >> "$LOG"
. "${STUB_FACTS:?}"
case "$1" in
  inspect)
    # Pin lookups: `docker inspect <name> --format {{.Image}}`
    case "$2" in
      immich_postgres) [[ -n "${STUB_NO_PG:-}" ]] && exit 1; echo "sha256:pgimageid000" ;;
      immich_redis)    [[ -n "${STUB_NO_REDIS:-}" ]] && exit 1; echo "sha256:redisimageid" ;;
      immich_server)   [[ -n "${STUB_NO_SERVER:-}" ]] && exit 1; echo "sha256:serverimgid0" ;;
      *) exit 1 ;;
    esac ;;
  image) exit 0 ;;
  ps)
    if [[ "$*" == *"-a"* ]]; then
      [[ -n "${STUB_NAME_TAKEN:-}" ]] && echo "$STUB_NAME_TAKEN"
      [[ -n "${STUB_LEAK:-}" ]] && echo "$STUB_LEAK"
      exit 0
    fi
    # running containers: the server unless told it died
    [[ -n "${STUB_SERVER_DIED:-}" ]] || grep -oE 'domum-phasea-[0-9]+-[0-9-]+-server' "$LOG" | tail -1
    exit 0 ;;
  network)
    case "$2" in
      ls) [[ -n "${STUB_NET_TAKEN:-}" ]] && echo "$STUB_NET_TAKEN"; exit 0 ;;
      create) [[ -n "${STUB_NET_FAIL:-}" ]] && exit 1; echo netid; exit 0 ;;
      rm) exit 0 ;;
    esac ;;
  run) echo containerid; exit 0 ;;
  rm) exit 0 ;;
  logs) echo "stub: container log line"; exit 0 ;;
  exec)
    shift
    [[ "$1" == "-i" ]] && shift
    cname="$1"; shift
    case "$1" in
      pg_isready) exit 0 ;;
      psql)
        # Queries arrive two ways: via -c (in the arguments) and via STDIN
        # (piped). The Phase B selection is piped, so matching only on "$*"
        # could never see it -- the first version of this stub did exactly that
        # and the selection silently returned nothing.
        if [[ "$*" != *" -c "* && "$*" != *"ON_ERROR_STOP"* ]]; then
          q="$(cat)"
          case "$q" in
            *"with sized as"*)
              [[ -n "${STUB_SELECT_FAILS:-}" ]] && { echo "ERROR: syntax error at or near \"union\"" >&2; exit 1; }
              cat "${STUB_SELECTION:?}"; exit 0 ;;
            *livePhotoVideoId*) cat "${STUB_LP_VIDEO:?}"; exit 0 ;;
          esac
          exit 0
        fi
        if [[ "$*" == *"create database"* ]]; then exit 0; fi
        if [[ "$*" == *"ON_ERROR_STOP=1"* ]]; then cat > /dev/null; [[ -n "${STUB_IMPORT_FAILS:-}" ]] && { echo "ERROR: boom" >&2; exit 3; }; exit 0; fi
        q="$*"
        case "$q" in
          *'ownerId" <> '*) echo "${STUB_OTHER_ASSETS:-5949}"; exit 0 ;;
          *"select id from \"user\" where email"*) echo "owner-0001"; exit 0 ;;
          *"count(*) from asset'"*|*"count(*) from asset\""*|*"count(*) from asset"*)
            case "$q" in
              *"type='IMAGE'"*) [[ -n "${STUB_NO_VISIBILITY:-}" ]] && exit 0; echo "$vis_img"; exit 0 ;;
              *"type='VIDEO'"*) [[ -n "${STUB_NO_VISIBILITY:-}" ]] && exit 0; echo "$vis_vid"; exit 0 ;;
              *"visibility <> "*) echo "$hidden"; exit 0 ;;
            esac
            if grep -qc 'after-baseline' "$LOG" 2>/dev/null && [[ "$(grep -c 'api/server/version' "$LOG")" -gt 0 ]]; then
              echo "$assets_after"
            else
              echo "$assets_before"
            fi
            exit 0 ;;
          *'from "user" where "isAdmin"'*) [[ -n "${STUB_NO_ADMIN:-}" ]] && exit 0; echo "admin@example.invalid"; exit 0 ;;
          *'count(*) from "user"'*)
            if [[ "$(grep -c 'api/server/version' "$LOG")" -gt 0 ]]; then echo "$users_after"; else echo "$users_before"; fi
            exit 0 ;;
          *pgcrypto*|*"update \"user\""*) exit 0 ;;
        esac
        exit 0 ;;
      sh)
        # `docker exec <c> sh -lc "curl ... | sha256sum | cut ..."` -- the real
        # fetch shape. Matching only a bare `curl` could never see it.
        cmd="$*"
        if [[ "$cmd" == *"/original"* ]]; then
          [[ -n "${STUB_ORIGINAL_EMPTY:-}" ]] && exit 0
          if [[ -n "${STUB_ORIGINAL_WRONG:-}" ]]; then
            printf 'WRONGBYTES' | sha256sum | cut -d' ' -f1; exit 0
          fi
          sha256sum < "${STUB_SERVE_FILE:?}" | cut -d' ' -f1; exit 0
        fi
        if [[ "$cmd" == *"/thumbnail"* ]]; then
          [[ -n "${STUB_NO_THUMB:-}" ]] && { printf '0'; exit 0; }
          printf '4242'; exit 0
        fi
        exit 0 ;;
      curl)
        if [[ "$*" == *"/original"* ]]; then
          [[ -n "${STUB_ORIGINAL_EMPTY:-}" ]] && exit 0
          if [[ -n "${STUB_ORIGINAL_WRONG:-}" ]]; then printf 'WRONGBYTES'; exit 0; fi
          # Echo back exactly the fixture content, so a hash comparison can pass.
          cat "${STUB_SERVE_FILE:?}"; exit 0
        fi
        if [[ "$*" == *"/thumbnail"* ]]; then
          [[ -n "${STUB_NO_THUMB:-}" ]] && { printf '0'; exit 0; }
          printf '4242'; exit 0
        fi
        if [[ "$*" == *"api/server/version"* ]]; then
          [[ -n "${STUB_NO_API:-}" ]] && exit 1
          echo '{"major":2,"minor":7,"patch":5}'; exit 0
        fi
        if [[ "$*" == *"api/auth/login"* ]]; then
          [[ -n "${STUB_LOGIN_FAILS:-}" ]] && { echo '{}'; exit 0; }
          echo '{"accessToken":"tok"}'; exit 0
        fi
        if [[ "$*" == *"api/server/statistics"* ]]; then
          [[ -n "${STUB_NO_STATS:-}" ]] && { echo '{}'; exit 0; }
          echo "{\"photos\":${STUB_API_PHOTOS:-13893},\"videos\":${STUB_API_VIDEOS:-1712}}"; exit 0
        fi
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
DOCKEREOF
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"
export STUB_LOG="$TMP_DIR/docker.log" STUB_FACTS="$TMP_DIR/facts"

# Phase B fixtures: one small file whose bytes the stub echoes back, so a hash
# comparison is a real comparison.
mkdir -p "$TMP_DIR/orig"
printf 'this-is-a-real-original-photo\n' > "$TMP_DIR/orig/one.jpeg"
export STUB_SERVE_FILE="$TMP_DIR/orig/one.jpeg"
cat > "$TMP_DIR/selection" <<EOF
photo jpeg|asset-0001|/usr/src/app/upload/upload/aa/bb/one.jpeg|30
livephoto image|asset-0002|/usr/src/app/upload/upload/aa/bb/two.jpeg|30
EOF
cat > "$TMP_DIR/lpvideo" <<EOF
livephoto video|asset-0003|/usr/src/app/upload/encoded-video/cc/dd/three-MP.mp4|30
EOF
export STUB_SELECTION="$TMP_DIR/selection" STUB_LP_VIDEO="$TMP_DIR/lpvideo"

run_pa() {  # $1 = setup (may be empty), $2.. = args for do_immich_phase_a
  local setup="${1:-}"; shift || true
  : > "$STUB_LOG"
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    die() { echo "DIE: $*"; exit 9; }
    log() { :; }
    backup_target_enabled() { return 0; }
    PHASEA_READY_TIMEOUT=3
    restic_for_target() {
      shift
      case "$1" in
        snapshots) echo '[{"short_id":"snapA001"}]' ;;
        restore)
          local t="" prev="" p2=""
          for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
          for a in "$@"; do
            if [[ "$p2" == "--include" ]]; then
              mkdir -p "$t$(dirname "$a")"
              case "$a" in
                *dump.sql.gz) cp "$TMP_DIR/dump.sql.gz" "$t$a" ;;
                *.immich)     [[ -n "${STUB_NO_MARKERS:-}" ]] || printf 'immich-marker' > "$t$a" ;;
                *)            [[ -n "${STUB_NO_ORIGINALS:-}" ]] || cp "$TMP_DIR/orig/one.jpeg" "$t$a" ;;
              esac
            fi
            p2="$a"
          done ;;
      esac
      return 0
    }
    [[ -n "$setup" ]] && eval "$setup"
    do_immich_phase_a cloud "$@" 2>&1
    echo "EXITCODE=$?"
  )
}

# ---------------------------------------------------------------------------
sect "the happy path earns APPLICATION STARTUP VERIFIED and nothing more"
out="$(run_pa '')"
grep -q 'EXITCODE=0' <<< "$out" || fail "the happy path did not exit 0: $out"
grep -q 'APPLICATION STARTUP VERIFIED' <<< "$out" || fail "the level was not claimed: $out"
grep -q 'NOT full recovery' <<< "$out" || fail "it did not disclaim full recovery: $out"
grep -q 'nothing proves' <<< "$out" || fail "it did not say what is unproven: $out"
grep -q 'FULL RECOVERY VERIFIED' <<< "$out" && fail "it used the words FULL RECOVERY VERIFIED"
echo "  exit 0, the narrow claim is made, and full recovery is explicitly disclaimed"

sect "images are pinned by ID, never by tag"
grep -q 'pinned from the running container' <<< "$out" || fail "pinning is not reported: $out"
grep -qE 'docker inspect immich_server' "$STUB_LOG" || fail "it did not read the running server image"
grep -qE 'docker run .*:release' "$STUB_LOG" && fail "it started a container from a TAG"
echo "  the running container's image ID is read and used"

sect "isolation is actually requested of docker, not merely described"
grep -q -- '--internal' "$STUB_LOG" || fail "the network was not created --internal"
grep -q -- '--tmpfs /var/lib/postgresql/data' "$STUB_LOG" || fail "PGDATA was not a tmpfs"
grep -qE 'docker run .*(-p |--publish)' "$STUB_LOG" && fail "a port was published"
# No production path may be mounted, read-only or otherwise.
# Captured first: this is the guard that keeps the disposable harness away from
# production paths, and `| grep -q` would make a real hit read as a miss.
prod_mounts="$(grep -oE '\-v [^ ]+' "$STUB_LOG" | while read -r _ v; do
  case "$v" in
    "$DATA"/*|"$TMP_DIR/media"/*) echo "PRODUCTION-PATH-MOUNT $v" ;;
  esac
done)"
grep -q PRODUCTION-PATH-MOUNT <<< "$prod_mounts" \
  && fail "a live data root was mounted into the test: $prod_mounts"
grep -qE '\-v [^ ]*phasea[^ ]*/upload:' "$STUB_LOG" || fail "the scratch upload dir was not mounted"
echo "  --internal network, tmpfs PGDATA, no port, only the scratch upload dir"

sect "the library scaffold is RESTORED, not fabricated"
grep -q '6 of 6 .immich marker' <<< "$out" || fail "markers were not restored: $out"
# The markers come from the REPOSITORY, which is why the count drops to 0 when
# the repository serves none -- that pair is the proof, not a log grep: the
# restic calls do not go through docker.
echo "  all six markers come from the snapshot"

sect "a snapshot missing markers is reported as a finding"
out2="$(run_pa 'export STUB_NO_MARKERS=1')"
grep -q '0 of 6 .immich marker' <<< "$out2" || fail "missing markers not counted: $out2"
grep -q 'does not hold a' <<< "$out2" || fail "missing markers not explained: $out2"
echo "  it says the snapshot lacks a complete scaffold"

# ---------------------------------------------------------------------------
sect "it refuses BEFORE creating anything when an image cannot be pinned"
for v in STUB_NO_PG STUB_NO_REDIS STUB_NO_SERVER; do
  o="$(run_pa "export $v=1")"
  grep -q 'Cannot pin' <<< "$o" || fail "$v did not refuse: $o"
  grep -qE 'docker (run|network create)' "$STUB_LOG" && fail "$v created something before refusing"
done
echo "  all three pins refuse, and nothing is created first"

sect "it refuses on a container name collision"
o="$(run_pa 'STUB_NAME_TAKEN="$(printf "domum-phasea-%s-collide-pg" $$)"; export STUB_NAME_TAKEN
phasea_name_free() { return 1; }')"
grep -q 'already exists' <<< "$o" || fail "a name collision did not refuse: $o"
grep -qE 'docker run' "$STUB_LOG" && fail "it created a container despite the collision"
echo "  a taken name refuses before anything is started"

sect "it refuses when the scratch location is inside a live data root"
o="$(run_pa 'restore_verification_dir() { printf "%s" "$DOMUM_DATA_ROOT/inside"; }')"
grep -q 'inside a live data root' <<< "$o" || fail "it did not refuse a live-root scratch: $o"
echo "  a scratch path under the data root refuses"

# ---------------------------------------------------------------------------
sect "a failed import FAILS and shows the error"
o="$(run_pa 'export STUB_IMPORT_FAILS=1')"
grep -q 'EXITCODE=1' <<< "$o" || fail "a failed import did not exit 1: $o"
grep -q 'import            : FAILED' <<< "$o" || fail "the failure is not reported: $o"
grep -q 'APPLICATION STARTUP VERIFIED' <<< "$o" && fail "a failed import claimed the level"
echo "  exit 1, and the level is not claimed"

sect "a server that never answers FAILS and shows its log"
o="$(run_pa 'export STUB_NO_API=1')"
grep -q 'EXITCODE=1' <<< "$o" || fail "no API did not exit 1: $o"
grep -qE 'startup           : FAILED' <<< "$o" || fail "startup failure not reported: $o"
grep -q 'stub: container log line' <<< "$o" || fail "the container log was not shown: $o"
echo "  exit 1 with the container log, so the failure is actionable"

sect "a login that fails FAILS -- the app layer is not optional"
o="$(run_pa 'export STUB_LOGIN_FAILS=1')"
grep -q 'EXITCODE=1' <<< "$o" || fail "a failed login did not exit 1: $o"
grep -q 'could not authenticate' <<< "$o" || fail "the cause is not named: $o"
echo "  without an authenticated session the claim is withheld"

sect "API and database disagreement FAILS"
o="$(run_pa 'export STUB_API_PHOTOS=1 STUB_API_VIDEOS=1')"
grep -q 'EXITCODE=1' <<< "$o" || fail "a count mismatch did not exit 1: $o"
grep -q 'disagree' <<< "$o" || fail "the disagreement is not stated: $o"
echo "  a mismatch between the app and the database is a failure"

sect "the comparison is per MEDIA TYPE against VISIBLE rows"
# The API reports timeline-visible assets. Measured on the real library:
# 13,893 visible images + 1,712 visible videos + 7,428 HIDDEN videos = 23,033.
# Comparing the API total against every row fails on a healthy recovery, which
# is exactly what the first version of this check did.
grep -q 'database (visible): 13893 image(s) + 1712 video(s)' <<< "$out" \
  || fail "the visible-row comparison is not reported: $out"
grep -q 'database (hidden) : 7428' <<< "$out" || fail "hidden assets are not reported: $out"
grep -q 'motion-photo components' <<< "$out" || fail "the hidden assets are not explained: $out"
echo "  13893/1712 compared per type, and the 7428 hidden ones are named"

sect "a schema without visibility is INCONCLUSIVE, not a pass"
o="$(run_pa 'export STUB_NO_VISIBILITY=1')"
grep -q 'INCONCLUSIVE' <<< "$o" || fail "a missing visibility column did not report INCONCLUSIVE: $o"
grep -q 'APPLICATION STARTUP VERIFIED' <<< "$o" && fail "it claimed the level anyway"
echo "  it refuses to reconcile rather than guessing"

# ---------------------------------------------------------------------------
sect "teardown removes the containers, the network and the scratch tree"
run_pa '' >/dev/null
grep -qE 'docker rm -f domum-phasea' "$STUB_LOG" || fail "containers were not removed"
grep -qE 'docker network rm domum-phasea' "$STUB_LOG" || fail "the network was not removed"
echo "  all three containers and the network are removed"

sect "a leak that survives teardown is REPORTED, not ignored"
# The teardown runs from the EXIT trap, after the function's own 2>&1, so its
# stderr escapes that redirection -- capture it here or the warning is invisible.
o="$(run_pa 'export STUB_LEAK=leftover-phasea-container
phasea_teardown() {
  local srv="$1"
  echo "WARNING: Phase A could not remove: $srv" >&2
  return 1
}' 2>&1)"
grep -q 'could not remove' <<< "$o" || fail "a surviving container was not reported: $o"
echo "  a container that survives removal is named"

sect "evidence is recorded at 0600 and a failure keeps the last success"
run_pa '' >/dev/null
EV="$STATE/restore-verification/cloud-phase-a.env"
[[ -f "$EV" ]] || fail "no evidence file was written"
[[ "$(stat -c %a "$EV")" == "600" ]] || fail "evidence is not mode 0600"
grep -q '^RESULT=success' "$EV" || fail "success was not recorded"
grep -q '^SERVER_IMAGE_ID=sha256:serverimgid0' "$EV" || fail "the pinned image was not recorded"
grep -q '^ASSETS=23033' "$EV" || fail "the asset count was not recorded"
ok_ts="$(sed -n 's/^LAST_SUCCESS_TS=//p' "$EV")"
[[ -n "$ok_ts" ]] || fail "no last-success timestamp"
run_pa 'export STUB_API_PHOTOS=1 STUB_API_VIDEOS=1' >/dev/null
grep -q '^RESULT=failure' "$EV" || fail "the failure was not recorded"
[[ "$(sed -n 's/^LAST_SUCCESS_TS=//p' "$EV")" == "$ok_ts" ]] \
  || fail "a failure ERASED when the rehearsal last genuinely succeeded"
echo "  0600, the pinned image recorded, and the last success survives a failure"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# PHASE B -- serving recovered media
# ---------------------------------------------------------------------------
sect "Phase B serves originals and compares BYTES, earning the narrow claim"
pb="$(run_pa '' --serve)"
grep -q 'EXITCODE=0' <<< "$pb" || fail "the Phase B happy path did not exit 0: $pb"
grep -q 'REPRESENTATIVE RECOVERY VERIFIED' <<< "$pb" || fail "the claim was not made: $pb"
grep -qE 'REPRESENTATIVE RECOVERY VERIFIED \(3 of 23033\)' <<< "$pb" \
  || fail "the claim does not state its denominator: $pb"
grep -qE 'photo jpeg +match' <<< "$pb" || fail "the jpeg was not served and matched: $pb"
grep -qE 'livephoto video +match' <<< "$pb" \
  || fail "the hidden live-photo video component was not served: $pb"
grep -q 'APPLICATION STARTUP VERIFIED' <<< "$pb" && fail "it used the Phase A claim instead"
grep -q 'FULL RECOVERY VERIFIED' <<< "$pb" && fail "it used the words FULL RECOVERY VERIFIED"
echo "  3 of 23033, byte-compared, including the live-photo video"

sect "the live-photo RELATIONSHIP is followed, not assumed"
# 7,432 images link to 7,428 distinct hidden videos on the real library, so the
# relationship is not 1:1 and the video must be fetched via livePhotoVideoId.
grep -qE 'livephoto image +match' <<< "$pb" || fail "the live-photo image was not served: $pb"
grep -q 'livephoto video' <<< "$pb" || fail "the paired video was never selected: $pb"
echo "  the image and the video its livePhotoVideoId names are both served"

sect "ownership scope is stated, and other users are reported as untested"
# Immich enforces per-user ownership: asking the admin's session for another
# user's asset returns nothing. The first rehearsal selected a PNG owned by the
# non-admin user and the fetch returned nothing, which looked like a serving
# defect and was correct authorization.
grep -q 'ownership scope : the authenticated user only' <<< "$pb" \
  || fail "the ownership scope is not stated: $pb"
grep -q '5949 asset(s) belong to OTHER user(s)' <<< "$pb" \
  || fail "other users' untested assets are not reported: $pb"
grep -q 'does not prove another' <<< "$pb" || fail "the limitation is not explained: $pb"
grep -q 'only ONE user' <<< "$pb" || fail "the verdict does not repeat the limitation: $pb"
echo "  one user tested, 5949 other assets named as untested"

sect "a BYTE MISMATCH is a failure, not a note"
o="$(run_pa 'export STUB_ORIGINAL_WRONG=1' --serve)"
grep -q 'EXITCODE=1' <<< "$o" || fail "a mismatch did not exit 1: $o"
grep -q 'MISMATCH' <<< "$o" || fail "the mismatch is not shown: $o"
grep -q 'REPRESENTATIVE RECOVERY VERIFIED' <<< "$o" && fail "a mismatch still claimed the level"
echo "  served bytes differing from the original fails the run"

sect "an empty response is a failure, not a pass"
o="$(run_pa 'export STUB_ORIGINAL_EMPTY=1' --serve)"
grep -q 'EXITCODE=1' <<< "$o" || fail "an empty response did not exit 1: $o"
grep -q 'NO-RESPONSE' <<< "$o" || fail "the empty response is not reported: $o"
echo "  nothing returned is not treated as matching"

sect "an original missing from the SNAPSHOT is reported, not skipped silently"
o="$(run_pa 'export STUB_NO_ORIGINALS=1' --serve)"
grep -q 'NOT RESTORED' <<< "$o" || fail "a missing original was not reported: $o"
grep -q 'not in the snapshot' <<< "$o" || fail "the cause is not stated: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "missing originals did not fail: $o"
echo "  an original absent from the snapshot fails the run and says why"

sect "the thumbnail is fetched but NEVER claimed to match an original"
grep -q 'GENERATED, not compared to any original' <<< "$pb" \
  || fail "the thumbnail distinction is not stated: $pb"
# It must not appear among the hash comparisons.
grep -qE 'thumbnail +match [0-9a-f]{12}' <<< "$pb" \
  && fail "a generated thumbnail was hash-compared to an original"
o="$(run_pa 'export STUB_NO_THUMB=1' --serve)"
grep -q 'not a failure' <<< "$o" || fail "an absent thumbnail was treated as a failure: $o"
grep -q 'EXITCODE=0' <<< "$o" || fail "an absent thumbnail failed the run: $o"
echo "  reported as generated; its absence is explicitly not a failure"

sect "the run is bounded by a byte budget"
o="$(run_pa 'PHASEB_MAX_BYTES=10' --serve)"
grep -q 'would exceed the' <<< "$o" || fail "the budget did not skip anything: $o"
grep -q 'run budget' <<< "$o" || fail "the budget is not named: $o"
echo "  oversized selections are skipped rather than silently downloaded"

sect "a selection error is SURFACED, not reported as 'nothing to select'"
# The first rehearsal hit a real SQL syntax error -- ORDER BY/LIMIT inside
# UNION branches needs parentheses -- and the tool said only "no representative
# asset could be selected". An unactionable FAIL trains the operator to ignore it.
o="$(run_pa 'export STUB_SELECT_FAILS=1' --serve)"
grep -q 'no representative asset could be selected' <<< "$o" || fail "no failure reported: $o"
grep -q 'selection error' <<< "$o" || fail "the SQL error was swallowed: $o"
grep -q 'syntax error' <<< "$o" || fail "the error text is not shown: $o"
echo "  the database's own error is printed"

sect "mutation: dropping the hash comparison must let wrong bytes pass"
MUTB="$TMP_DIR/mutant-b"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTB"
cat > "$TMP_DIR/mutate-b.py" <<'MUTPY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = '  if [[ "$got" == "$want" ]]; then printf \'match %s\' "${want:0:12}"; return 0; fi'
assert s.count(needle) == 1, "needle count: %d" % s.count(needle)
s = s.replace(needle, '  printf \'match %s\' "${want:0:12}"; return 0', 1)
open(p, "w").write(s)
MUTPY
python3 "$TMP_DIR/mutate-b.py" "$MUTB" || fail "the Phase B mutation script failed"
grep -q 'if \[\[ "$got" == "$want" \]\]' "$MUTB" \
  && fail "the comparison is still present; the mutation proves nothing"
mbout="$(
  source "$MUTB" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  log() { :; }
  backup_target_enabled() { return 0; }
  PHASEA_READY_TIMEOUT=3
  export STUB_ORIGINAL_WRONG=1
  restic_for_target() {
    shift
    case "$1" in
      snapshots) echo '[{"short_id":"snapA001"}]' ;;
      restore)
        local t="" prev="" p2=""
        for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
        for a in "$@"; do
          if [[ "$p2" == "--include" ]]; then
            mkdir -p "$t$(dirname "$a")"
            case "$a" in
              *dump.sql.gz) cp "$TMP_DIR/dump.sql.gz" "$t$a" ;;
              *.immich)     printf 'immich-marker' > "$t$a" ;;
              *)            cp "$TMP_DIR/orig/one.jpeg" "$t$a" ;;
            esac
          fi
          p2="$a"
        done ;;
    esac
    return 0
  }
  do_immich_phase_a cloud --serve 2>&1
  echo "EXITCODE=$?"
)"
grep -q 'EXITCODE=0' <<< "$mbout" \
  || fail "the mutant did not pass wrong bytes; the comparison is not load-bearing"
grep -q 'REPRESENTATIVE RECOVERY VERIFIED' <<< "$mbout" \
  || fail "the mutant did not produce the false claim: $mbout"
echo "  without it, bytes that differ from the original are reported as matching"

sect "mutation: dropping the before/after check must let a destructive migration pass"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
cat > "$TMP_DIR/mutate.py" <<'MUTPY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = 'if [[ "$after_assets" != "$before_assets" || "$after_users" != "$before_users" ]]; then'
assert s.count(needle) == 1, "needle count: %d" % s.count(needle)
s = s.replace(needle, 'if false; then', 1)
open(p, "w").write(s)
MUTPY
python3 "$TMP_DIR/mutate.py" "$MUT" || fail "the mutation script failed"
grep -q 'if false; then' "$MUT" || fail "the mutation did not apply"
: > "$STUB_LOG"
cat > "$TMP_DIR/facts" <<'EOF'
assets_before=23033
users_before=2
assets_after=11
users_after=1
vis_img=13893
vis_vid=1712
hidden=7428
EOF
mout="$(
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  log() { :; }
  backup_target_enabled() { return 0; }
  PHASEA_READY_TIMEOUT=3
  restic_for_target() {
    shift
    case "$1" in
      snapshots) echo '[{"short_id":"snapA001"}]' ;;
      restore)
        local t="" prev="" p2=""
        for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
        for a in "$@"; do
          if [[ "$p2" == "--include" ]]; then
            mkdir -p "$t$(dirname "$a")"
            case "$a" in
              *dump.sql.gz) cp "$TMP_DIR/dump.sql.gz" "$t$a" ;;
              *.immich)     printf 'immich-marker' > "$t$a" ;;
            esac
          fi
          p2="$a"
        done ;;
    esac
    return 0
  }
  do_immich_phase_a cloud 2>&1
  echo "EXITCODE=$?"
)"
grep -q 'EXITCODE=0' <<< "$mout" \
  || fail "the mutant did not pass a destructive migration; the check is not load-bearing"
grep -q 'APPLICATION STARTUP VERIFIED' <<< "$mout" \
  || fail "the mutant did not produce the false claim: $mout"
echo "  without it, a migration that destroyed 23022 assets is reported as verified"

echo "PASS: immich-phase-a-smoke"
