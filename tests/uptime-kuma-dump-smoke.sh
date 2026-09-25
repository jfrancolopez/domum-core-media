#!/usr/bin/env bash
set -uo pipefail

# Uptime Kuma keeps its entire configuration -- monitors, notification targets,
# status pages, the admin account -- in one SQLite database inside a Docker
# volume that nothing snapshots and no backup target includes.
#
# It cannot be captured by copying files. kuma.db runs in WAL mode with an
# uncheckpointed -wal beside it, so a file copy is a torn database. The dump uses
# the SQLite backup API and is VALIDATED before it is accepted -- a recovery pack
# containing a corrupt database is worse than one that admits it has none.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
UPTIME_KUMA_CONTAINER=uptime-kuma
LOG="$TMP_DIR/docker.log"
EOF
}

# A docker stub that records what it was asked to do. Behaviour is driven by
# plain environment variables rather than nested substitutions, so the stub is
# readable and its failure modes are obvious.
#
#   KUMA_INTEGRITY   what PRAGMA integrity_check returns   (default: ok)
#   KUMA_BACKUP_FAIL non-empty -> sqlite3 .backup fails
#   KUMA_NO_CONTAINER non-empty -> docker ps lists nothing
cat > "$TMP_DIR/stub.sh" <<'STUB'
docker() {
  printf '%s\n' "$*" >> "$LOG"
  case "${1:-}" in
    ps)
      [[ -n "${KUMA_NO_CONTAINER:-}" ]] || printf 'uptime-kuma\n'
      return 0 ;;
    exec)
      case "$*" in
        *integrity_check*)
          printf '%s\n' "${KUMA_INTEGRITY:-ok}"; return 0 ;;
        *.backup*)
          [[ -z "${KUMA_BACKUP_FAIL:-}" ]] || return 1
          return 0 ;;
        *)
          return 0 ;;
      esac ;;
    cp)
      # The destination is the last argument.
      printf 'DUMPBYTES\n' > "${@: -1}"
      return 0 ;;
  esac
  return 0
}
STUB

run() { bash -c "$(harness)
source '$TMP_DIR/stub.sh'
$1"; }

# ---------------------------------------------------------------------------
# 1. The happy path: dump taken, validated, copied out, mode 0600.
# ---------------------------------------------------------------------------
: > "$TMP_DIR/docker.log"
out="$(run "uptime_kuma_dump '$TMP_DIR/out.db' && echo RC=0 || echo RC=1")"
grep -q 'RC=0' <<< "$out" || fail "the happy path failed: $out"
[[ -s "$TMP_DIR/out.db" ]] || fail "no dump file was produced"
[[ "$(stat -c %a "$TMP_DIR/out.db")" == "600" ]] \
  || fail "the dump must be mode 0600, got $(stat -c %a "$TMP_DIR/out.db")"

# It must use the SQLite backup API, not a file copy.
grep -q '\.backup' "$TMP_DIR/docker.log" \
  || fail "the dump did not use sqlite3 .backup; a file copy of a WAL database is torn"
grep -q 'integrity_check' "$TMP_DIR/docker.log" \
  || fail "the dump was not validated before being accepted"

# Validation must happen BEFORE the copy out, so a corrupt dump never leaves the
# container.
ic="$(grep -n 'integrity_check' "$TMP_DIR/docker.log" | head -1 | cut -d: -f1)"
cp="$(grep -n '^cp ' "$TMP_DIR/docker.log" | head -1 | cut -d: -f1)"
[[ -n "$ic" && -n "$cp" && "$ic" -lt "$cp" ]] \
  || fail "the dump was copied out before it was validated (check=$ic copy=$cp)"

# The in-container temp file must be cleaned up.
grep -q 'rm -f /tmp/kuma-recovery' "$TMP_DIR/docker.log" \
  || fail "the in-container dump was not removed"

# ---------------------------------------------------------------------------
# 2. A failed integrity check must be fatal, and must not produce a file.
#
# This is the assertion that matters: an unvalidated dump is not evidence, and a
# recovery pack containing a corrupt database is worse than one without it.
# ---------------------------------------------------------------------------
rm -f "$TMP_DIR/out.db"; : > "$TMP_DIR/docker.log"
out="$(KUMA_INTEGRITY='malformed disk image' run "uptime_kuma_dump '$TMP_DIR/out.db' && echo RC=0 || echo RC=1" 2>&1)"
grep -q 'RC=1' <<< "$out" || fail "a dump that failed its integrity check was accepted: $out"
grep -qi 'integrity check' <<< "$out" || fail "the integrity failure was not reported: $out"
[[ ! -e "$TMP_DIR/out.db" ]] || fail "a dump file was produced despite failing validation"
grep -q '^cp ' "$TMP_DIR/docker.log" \
  && fail "a dump that failed validation was still copied out of the container"

# ---------------------------------------------------------------------------
# 3. A failed .backup must be fatal.
# ---------------------------------------------------------------------------
rm -f "$TMP_DIR/out.db"; : > "$TMP_DIR/docker.log"
out="$(KUMA_BACKUP_FAIL=1 run "uptime_kuma_dump '$TMP_DIR/out.db' && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" || fail "a failed .backup was treated as success: $out"
[[ ! -e "$TMP_DIR/out.db" ]] || fail "a dump file was produced despite .backup failing"

# ---------------------------------------------------------------------------
# 4. A container that is not running must fail cleanly, not hang or half-succeed.
# ---------------------------------------------------------------------------
rm -f "$TMP_DIR/out.db"
out="$(KUMA_NO_CONTAINER=1 run "uptime_kuma_dump '$TMP_DIR/out.db' && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" || fail "a dump succeeded with no running container: $out"
[[ ! -e "$TMP_DIR/out.db" ]] || fail "a dump file was produced with no running container"

# ---------------------------------------------------------------------------
# 5. The recovery pack must call it, and must not fail silently when it cannot.
# ---------------------------------------------------------------------------
grep -q 'uptime_kuma_dump "\$stage_dir/state/uptime-kuma/kuma.db"' "$REPO_ROOT/bin/domum-media" \
  || fail "the recovery pack does not capture the Uptime Kuma database"
grep -q 'the recovery pack will NOT contain it' "$REPO_ROOT/bin/domum-media" \
  || fail "a failed Uptime Kuma capture must be reported, not swallowed"

# The restore instructions must remove -wal/-shm: leaving them beside a
# different kuma.db corrupts it.
grep -q 'kuma.db-wal' "$REPO_ROOT/bin/domum-media" \
  || fail "the restore instructions do not remove the stale -wal file"

# The report must credit the coverage, so the operator is not warned about state
# that is in fact protected.
grep -q 'uptime-kuma:/app/data) printf .recovery-pack' "$REPO_ROOT/bin/domum-media-report" \
  || fail "the report does not record that Uptime Kuma is covered by the recovery pack"

echo "PASS: uptime kuma dump smoke test"
