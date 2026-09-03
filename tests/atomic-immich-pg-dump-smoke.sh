#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA_DIR="$TMP_DIR/data"
SNAPSHOT_DIR="$TMP_DIR/snapshots"
LOG_DIR="$TMP_DIR/log"
FAKE_BIN="$TMP_DIR/bin"
FAKE_PAYLOAD="$TMP_DIR/pg-dump.sql"

mkdir -p \
  "$DATA_DIR/immich/postgres" \
  "$DATA_DIR/immich/backup-staging" \
  "$SNAPSHOT_DIR" \
  "$LOG_DIR" \
  "$FAKE_BIN"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  ps)
    echo immich-postgres-container
    ;;
  exec)
    cat "${FAKE_PG_DUMP_PAYLOAD:?}"
    exit "${FAKE_PG_DUMP_RC:-0}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

export PATH="$FAKE_BIN:$PATH"
export FAKE_PG_DUMP_PAYLOAD="$FAKE_PAYLOAD"

# shellcheck disable=SC1090
source "$REPO_ROOT/bin/domum-media-backup"

DOMUM_DATA_ROOT="$DATA_DIR"
DOMUM_SNAPSHOT_ROOT="$SNAPSHOT_DIR"
DOMUM_LOG_DIR="$LOG_DIR"
LOG_FILE="$LOG_DIR/backup.log"

dump_file="$DATA_DIR/immich/backup-staging/immich-postgres.dump.sql.gz"
known_good="$TMP_DIR/known-good.gz"
printf '%s\n' 'known-good-dump' | gzip -9 > "$known_good"
cp "$known_good" "$dump_file"

assert_no_temp_dump() {
  if compgen -G "$DATA_DIR/immich/backup-staging/*.tmp" >/dev/null \
    || compgen -G "$DATA_DIR/immich/backup-staging/.*.tmp" >/dev/null; then
    fail "temporary dump artifact remains"
  fi
}

write_sql_body() {
  local i
  for ((i = 0; i < 2000; i++)); do
    printf "INSERT INTO backup_test VALUES (%d, 'row-%08d-value-%08d');\n" \
      "$i" "$i" "$((i * 7919))"
  done
}

# A failed pg_dump must not replace the previous known-good artifact.
printf '%s\n' 'partial dump' > "$FAKE_PAYLOAD"
export FAKE_PG_DUMP_RC=42
if quiesce_immich_postgres; then
  fail "failed pg_dump was accepted"
fi
cmp -s "$known_good" "$dump_file" || fail "failed pg_dump replaced the prior dump"
assert_no_temp_dump

# A successful but incomplete SQL stream must also be rejected.
{
  write_sql_body
  printf '%s\n' '-- footer missing'
} > "$FAKE_PAYLOAD"
export FAKE_PG_DUMP_RC=0
if quiesce_immich_postgres; then
  fail "dump without PostgreSQL completion footer was accepted"
fi
cmp -s "$known_good" "$dump_file" || fail "invalid dump replaced the prior dump"
assert_no_temp_dump

# A complete valid stream replaces the canonical dump atomically.
{
  printf '%s\n' '-- PostgreSQL database dump'
  write_sql_body
  printf '%s\n' '-- PostgreSQL database dump complete'
} > "$FAKE_PAYLOAD"
quiesce_immich_postgres

gzip -t "$dump_file" || fail "canonical dump failed gzip validation"
cmp -s <(gzip -cd "$dump_file") "$FAKE_PAYLOAD" \
  || fail "canonical dump does not match the completed pg_dump stream"
cmp -s "$known_good" "$dump_file" && fail "successful dump did not replace prior dump"
assert_no_temp_dump

echo "PASS: atomic Immich pg_dump smoke test"
