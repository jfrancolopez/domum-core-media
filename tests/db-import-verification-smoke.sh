#!/usr/bin/env bash
set -uo pipefail

# Proves `verify-db-restore` makes a claim the archive checks cannot:
#
#   ARCHIVE VALIDATED              gzip, size, footer -- the FILE is intact
#   DATABASE IMPORT RESTORE TESTED PostgreSQL actually read it, and the rows
#                                  that came back are self-consistent
#   FULL IMMICH RECOVERY VERIFIED  not attempted by this command, and it says so
#
# The load-bearing assertions are the refusals: a partial import must not pass,
# a consistency violation must fail and NAME itself, a check whose input key is
# missing must FAIL rather than abort, and an unavailable image must report NOT
# ATTEMPTED rather than success.
#
# Hermetic: `docker` is a stub, so no container runs, no image is pulled and no
# database exists. Every root is redirected into the fixture.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"; STATE="$TMP_DIR/state"
mkdir -p "$DATA/immich/backup-staging" "$STATE" "$TMP_DIR/bin" "$TMP_DIR/media"
export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media" DOMUM_STATE_ROOT="$STATE"
export SECRETS_DIR="$TMP_DIR/secrets"; mkdir -p "$SECRETS_DIR"
export BACKUP_TARGETS=cloud

# The facts a healthy restored database reports. Sections override one key at a
# time to prove each check is load-bearing.
GOOD_FACTS='tables=61
assets=23033
asset_files=41450
exif_rows=23033
extensions=7
originals_upload=22975
originals_encoded_video=58
originals_elsewhere=0
null_original_path=0
duplicate_original_paths=0
orphan_asset_files=0
orphan_exif=0
assets_without_exif=0
null_checksums=0'
printf '%s\n' "$GOOD_FACTS" > "$TMP_DIR/facts"

# A docker stub standing in for the whole container lifecycle. It records what
# it was asked to do so the test can assert on behaviour, not on wording.
cat > "$TMP_DIR/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
LOG="${STUB_LOG:?}"
echo "docker $*" >> "$LOG"
case "$1" in
  image)
    [[ -n "${STUB_NO_IMAGE:-}" ]] && exit 1
    exit 0 ;;
  inspect)
    printf '%s' "${STUB_PROD_IMAGE-tensorchord/pgvecto-rs:pg14-v0.2.0}" ;;
  run)
    [[ -n "${STUB_RUN_FAILS:-}" ]] && exit 1
    echo "containeridstub" ;;
  rm) exit 0 ;;
  exec)
    shift
    [[ "$1" == "-i" ]] && shift
    shift   # container name
    case "$1" in
      pg_isready) [[ -n "${STUB_NEVER_READY:-}" ]] && exit 1; exit 0 ;;
      psql)
        if [[ "$*" == *"create database"* ]]; then
          [[ -n "${STUB_CREATEDB_FAILS:-}" ]] && exit 1
          exit 0
        fi
        if [[ "$*" == *"ON_ERROR_STOP=1"* ]]; then
          cat > /dev/null            # consume the dump
          if [[ -n "${STUB_IMPORT_FAILS:-}" ]]; then
            echo 'ERROR:  missing data for column "ownerId"' >&2
            exit 3
          fi
          exit 0
        fi
        # the consistency query
        cat > /dev/null
        cat "${STUB_FACTS:?}"
        exit 0 ;;
    esac ;;
esac
exit 0
DOCKEREOF
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"
export STUB_LOG="$TMP_DIR/docker.log"
export STUB_FACTS="$TMP_DIR/facts"

# A plausible dump: real gzip, so the restore path is exercised honestly.
printf 'CREATE TABLE asset();\n' | gzip -9 > "$TMP_DIR/dump.sql.gz"

run_verify() {  # $1 = extra setup, evaluated after the source
  : > "$STUB_LOG"
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    die() { echo "DIE: $*"; exit 9; }
    log() { :; }
    backup_target_enabled() { return 0; }
    restic_for_target() {
      shift
      case "$1" in
        snapshots) echo '[{"short_id":"snap1234"}]' ;;
        restore)
          local t="" prev=""
          for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
          mkdir -p "$t$DOMUM_DATA_ROOT/immich/backup-staging"
          cp "$TMP_DIR/dump.sql.gz" \
             "$t$DOMUM_DATA_ROOT/immich/backup-staging/immich-postgres.dump.sql.gz"
          ;;
      esac
      return 0
    }
    [[ -n "${1:-}" ]] && eval "$1"
    do_verify_db_restore cloud 2>&1
    echo "EXITCODE=$?"
  )
}

# ---------------------------------------------------------------------------
sect "a clean import earns DATABASE IMPORT RESTORE TESTED"
out="$(run_verify '')"
grep -q 'EXITCODE=0' <<< "$out" || fail "clean import did not exit 0: $out"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$out" || fail "the level was not claimed: $out"
grep -q '23033 asset' <<< "$out" || fail "the imported asset count is not stated: $out"
grep -q 'FULL IMMICH RECOVERY VERIFIED' <<< "$out" \
  || fail "it must say which stronger claim it is NOT making: $out"
grep -q 'has not been done' <<< "$out" || fail "the stronger claim is not disclaimed: $out"
echo "  exit 0, the count is stated, and the stronger claim is explicitly disclaimed"

sect "isolation is stated AND actually requested of docker"
grep -q 'network none' <<< "$out" || fail "isolation is not reported: $out"
grep -q -- '--network none' "$STUB_LOG" || fail "docker run was NOT given --network none"
grep -q -- '--tmpfs /var/lib/postgresql/data' "$STUB_LOG" || fail "PGDATA was not a tmpfs"
grep -qE 'docker run .*-p |docker run .*--publish' "$STUB_LOG" && fail "a port was published"
grep -qE 'docker run .*(-v |--volume|--mount)' "$STUB_LOG" && fail "a volume/bind was mounted"
echo "  --network none and a tmpfs PGDATA were really passed; no port, no mount"

sect "the disposable container is ALWAYS removed"
grep -qE 'docker rm -f' "$STUB_LOG" || fail "the container was not removed on success"
echo "  removed on the success path"

# ---------------------------------------------------------------------------
sect "a failed import FAILS and shows the errors"
out="$(run_verify 'export STUB_IMPORT_FAILS=1')"
grep -q 'EXITCODE=1' <<< "$out" || fail "a failed import did not exit 1: $out"
grep -q 'import        : FAILED' <<< "$out" || fail "the failure is not reported: $out"
grep -q 'ownerId' <<< "$out" || fail "the psql error was not surfaced -- an unactionable FAIL: $out"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$out" && fail "a failed import claimed the level"
grep -qE 'docker rm -f' "$STUB_LOG" || fail "the container was not removed on failure"
echo "  exit 1, the real psql error is shown, the level is not claimed, container removed"

sect "the import is run with ON_ERROR_STOP=1"
# Without it psql reports success having skipped every statement it could not
# run -- the false pass this command exists to rule out.
out="$(run_verify '')" >/dev/null
grep -q 'ON_ERROR_STOP=1' "$STUB_LOG" || fail "the import did not use ON_ERROR_STOP=1"
echo "  the strict flag is really passed to psql"

# ---------------------------------------------------------------------------
sect "every consistency violation fails, and names itself"
viol() {  # $1 = key, $2 = bad value, $3 = expected text
  printf '%s\n' "$GOOD_FACTS" | sed "s/^$1=.*/$1=$2/" > "$TMP_DIR/facts.bad"
  local o
  o="$(run_verify "export STUB_FACTS=$TMP_DIR/facts.bad")"
  grep -q 'EXITCODE=1' <<< "$o" || fail "$1=$2 did not fail: $o"
  grep -q "$3" <<< "$o" || fail "$1=$2 did not report '$3': $o"
  grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$o" && fail "$1=$2 still claimed the level"
  printf '    %-28s -> %s\n' "$1=$2" "$3"
}
viol orphan_asset_files 5       "orphaned asset_file rows"
viol orphan_exif 2              "orphaned exif rows"
viol assets_without_exif 7      "assets with no exif row"
viol null_original_path 1       "assets with no originalPath"
viol duplicate_original_paths 3 "two assets share an originalPath"
viol originals_elsewhere 4      "originals outside"
viol null_checksums 9           "assets with no checksum"
viol assets 0                   "no assets"
viol tables 0                   "no tables"
viol extensions 0               "no extensions"
echo "  all ten checks are load-bearing and each states what it found"

# ---------------------------------------------------------------------------
sect "a MISSING fact key FAILS rather than aborting the run"
# `(( $(f missing) > 0 ))` with an empty substitution is a runtime syntax error,
# so under set -e a renamed key would ABORT the verification instead of failing
# it: the metadata-key family, where a key read but never written is silently
# empty. The sentinel -1 must fail every check instead.
grep -v '^orphan_asset_files=' <<< "$GOOD_FACTS" > "$TMP_DIR/facts.missing"
out="$(run_verify "export STUB_FACTS=$TMP_DIR/facts.missing")"
grep -q 'EXITCODE=1' <<< "$out" || fail "a missing fact key did not fail cleanly: $out"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$out" && fail "a missing fact still claimed the level"
grep -qi 'syntax error' <<< "$out" && fail "a missing fact caused a syntax error instead of a failure"
echo "  the sentinel makes an absent key fail, not abort"

sect "an empty consistency answer FAILS"
: > "$TMP_DIR/facts.empty"
out="$(run_verify "export STUB_FACTS=$TMP_DIR/facts.empty")"
grep -q 'EXITCODE=1' <<< "$out" || fail "an empty answer did not fail: $out"
grep -q 'answered nothing' <<< "$out" || fail "it did not say the database answered nothing: $out"
echo "  a database that answers nothing is a failure, not a pass"

# ---------------------------------------------------------------------------
sect "an absent image reports NOT ATTEMPTED, never success"
out="$(run_verify 'export STUB_NO_IMAGE=1')"
grep -q 'EXITCODE=2' <<< "$out" || fail "an absent image did not exit 2: $out"
grep -q 'NOT ATTEMPTED' <<< "$out" || fail "it did not say NOT ATTEMPTED: $out"
grep -q 'Refusing to pull' <<< "$out" || fail "it must refuse to pull during verification: $out"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$out" && fail "an absent image claimed the level"
grep -qE 'docker (run|pull)' "$STUB_LOG" && fail "it started or pulled something anyway"
echo "  exit 2, nothing was pulled or started, and no level was claimed"

sect "an undeterminable image reports NOT ATTEMPTED"
out="$(run_verify 'export STUB_PROD_IMAGE=')"
grep -q 'EXITCODE=2' <<< "$out" || fail "an unknown image did not exit 2: $out"
grep -q 'IMMICH_PG_IMAGE' <<< "$out" || fail "it does not say how to name the image: $out"
echo "  exit 2, and it names the override that would fix it"

sect "an instance that never becomes ready reports NOT ATTEMPTED, not success"
out="$(run_verify 'export STUB_NEVER_READY=1; sleep() { :; }')"
grep -qE 'EXITCODE=(2|9)' <<< "$out" || fail "a never-ready instance did not report NOT ATTEMPTED: $out"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$out" && fail "a never-ready instance claimed the level"
echo "  never-ready is not a pass"

# ---------------------------------------------------------------------------
sect "evidence records the result, and a failure keeps the last success"
out="$(run_verify '')" >/dev/null
EV="$STATE/restore-verification/cloud-dbimport.env"
[[ -f "$EV" ]] || fail "no evidence file was written"
[[ "$(stat -c %a "$EV")" == "600" ]] || fail "evidence is not mode 0600"
grep -q '^RESULT=success' "$EV" || fail "success was not recorded"
grep -q '^ASSETS_IMPORTED=23033' "$EV" || fail "the asset count was not recorded"
grep -q '^PG_IMAGE=' "$EV" || fail "the image was not recorded"
ok_ts="$(sed -n 's/^LAST_SUCCESS_TS=//p' "$EV")"
[[ -n "$ok_ts" ]] || fail "no last-success timestamp"
out="$(run_verify 'export STUB_IMPORT_FAILS=1')" >/dev/null
grep -q '^RESULT=failure' "$EV" || fail "the failure was not recorded"
[[ "$(sed -n 's/^LAST_SUCCESS_TS=//p' "$EV")" == "$ok_ts" ]] \
  || fail "a failure ERASED when the import last genuinely succeeded"
echo "  0600, result recorded, and the last success survives a later failure"

# ---------------------------------------------------------------------------
sect "mutation: dropping ON_ERROR_STOP=1 must let a partial import pass"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('-q -v ON_ERROR_STOP=1', '-q', 1)
open(p,'w').write(s)
PY
: > "$STUB_LOG"
mout="$(
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  log() { :; }
  backup_target_enabled() { return 0; }
  restic_for_target() {
    shift
    case "$1" in
      snapshots) echo '[{"short_id":"snap1234"}]' ;;
      restore)
        local t="" prev=""
        for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
        mkdir -p "$t$DOMUM_DATA_ROOT/immich/backup-staging"
        cp "$TMP_DIR/dump.sql.gz" \
           "$t$DOMUM_DATA_ROOT/immich/backup-staging/immich-postgres.dump.sql.gz"
        ;;
    esac
    return 0
  }
  export STUB_IMPORT_FAILS=1
  do_verify_db_restore cloud 2>&1
  echo "EXITCODE=$?"
)"
# The stub only fails when it is asked to be strict, so without the flag the
# mutant's import "succeeds" -- which is exactly the false pass.
grep -q 'EXITCODE=0' <<< "$mout" \
  || fail "the mutant did not pass a broken import; ON_ERROR_STOP is not load-bearing"
grep -q 'DATABASE IMPORT RESTORE TESTED' <<< "$mout" \
  || fail "the mutant did not produce the false claim"
grep -q 'ON_ERROR_STOP=1' "$STUB_LOG" && fail "the mutation did not remove the flag"
echo "  without the flag a broken import is reported as RESTORE TESTED"

echo "PASS: db-import-verification-smoke"
