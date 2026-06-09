#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CFG_FILE="$TMP_DIR/domum-media.conf"
SECRETS_DIR="$TMP_DIR/secrets"
STATE_DIR="$TMP_DIR/state"
DATA_DIR="$TMP_DIR/data"
HOT_DIR="$TMP_DIR/hot"
LOG_DIR="$TMP_DIR/log"
SNAPSHOT_DIR="$TMP_DIR/snapshots"
FAKE_BIN="$TMP_DIR/bin"

mkdir -p "$SECRETS_DIR" "$STATE_DIR" "$DATA_DIR" "$HOT_DIR" "$LOG_DIR" "$SNAPSHOT_DIR" "$FAKE_BIN"

cat > "$CFG_FILE" <<EOF
ENABLE_IMMICH=1
DOMUM_DATA_ROOT='$DATA_DIR'
DOMUM_STATE_ROOT='$STATE_DIR'
DOMUM_HOT_ROOT='$HOT_DIR'
DOMUM_LOG_DIR='$LOG_DIR'
DOMUM_SNAPSHOT_ROOT='$SNAPSHOT_DIR'
EOF

printf 'db-pass-123!@\n' > "$SECRETS_DIR/immich_db_password"
printf 'jwt-secret-456?=\n\n' > "$SECRETS_DIR/immich_jwt_secret"

cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" ]]; then
  shift
fi

while [[ "${1:-}" == "-f" ]]; do
  shift 2
done

case "${1:-}" in
  config)
    cat <<YAML
services:
  immich_server:
    environment:
      DB_PASSWORD: "${IMMICH_DB_PASSWORD:-}"
      JWT_SECRET: "${IMMICH_JWT_SECRET:-}"
  immich_postgres:
    environment:
      POSTGRES_PASSWORD: "${IMMICH_DB_PASSWORD:-}"
YAML
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

export PATH="$FAKE_BIN:$PATH"
export DOMUM_DIR="$REPO_ROOT"
export CFG_FILE
export SECRETS_DIR

# shellcheck disable=SC1090
source "$REPO_ROOT/bin/domum-media"

# The host CLI's compose_cmd uses mapfile, which is fine on the Debian target
# host. Override it here so the smoke test also runs under older local bash.
compose_cmd() {
  docker compose "$@"
}

load_cfg
export_env_for_compose
validate_immich_secret_exports

[[ "${IMMICH_DB_PASSWORD:-}" == "db-pass-123!@" ]] || fail "IMMICH_DB_PASSWORD did not load from the secret file"
[[ "${IMMICH_JWT_SECRET:-}" == "jwt-secret-456?=" ]] || fail "IMMICH_JWT_SECRET did not load from the secret file"

RENDERED_FILE="$TMP_DIR/rendered.yml"
render_compose_config_file "$RENDERED_FILE"

SERVER_DB_PASSWORD="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_server DB_PASSWORD)")"
SERVER_JWT_SECRET="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_server JWT_SECRET)")"
POSTGRES_PASSWORD="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_postgres POSTGRES_PASSWORD)")"

[[ -n "$SERVER_DB_PASSWORD" ]] || fail "immich_server DB_PASSWORD rendered empty"
[[ -n "$SERVER_JWT_SECRET" ]] || fail "immich_server JWT_SECRET rendered empty"
[[ -n "$POSTGRES_PASSWORD" ]] || fail "immich_postgres POSTGRES_PASSWORD rendered empty"
[[ "$SERVER_DB_PASSWORD" == "$POSTGRES_PASSWORD" ]] || fail "DB_PASSWORD and POSTGRES_PASSWORD were not sourced from the same secret"
[[ "$SERVER_DB_PASSWORD" == "db-pass-123!@" ]] || fail "immich_server DB_PASSWORD did not match the DB secret file"
[[ "$POSTGRES_PASSWORD" == "db-pass-123!@" ]] || fail "immich_postgres POSTGRES_PASSWORD did not match the DB secret file"
[[ "$SERVER_JWT_SECRET" == "jwt-secret-456?=" ]] || fail "immich_server JWT_SECRET did not match the JWT secret file"

validate_immich_compose_config

echo "PASS: Immich secret propagation smoke test"
