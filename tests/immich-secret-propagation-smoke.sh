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
FAKE_STATE="$TMP_DIR/docker-state"

mkdir -p "$SECRETS_DIR" "$STATE_DIR" "$DATA_DIR" "$HOT_DIR" "$LOG_DIR" "$SNAPSHOT_DIR" "$FAKE_BIN" "$FAKE_STATE"

cat > "$CFG_FILE" <<EOF
ENABLE_IMMICH=1
DOMUM_DATA_ROOT='$DATA_DIR'
DOMUM_STATE_ROOT='$STATE_DIR'
DOMUM_HOT_ROOT='$HOT_DIR'
DOMUM_LOG_DIR='$LOG_DIR'
DOMUM_SNAPSHOT_ROOT='$SNAPSHOT_DIR'
EOF

# Deliberately surround the secrets with leading/trailing whitespace and a
# leading blank line — this is the prod failure mode. A leading newline is
# non-empty, so it passes compose's ${VAR:?} guard and renders as "set", yet
# leaves the running container with an empty-looking value. read_secret_file_value
# must trim all surrounding whitespace so the runtime value is clean.
printf '\n  db-pass-123!@  \n' > "$SECRETS_DIR/immich_db_password"
printf '\n jwt-secret-456?= \n' > "$SECRETS_DIR/immich_jwt_secret"

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
  up)
    mkdir -p "${FAKE_DOCKER_STATE:?}"
    cat > "${FAKE_DOCKER_STATE}/immich_server.env" <<ENV
DB_PASSWORD=${IMMICH_DB_PASSWORD:-}
JWT_SECRET=${IMMICH_JWT_SECRET:-}
ENV
    cat > "${FAKE_DOCKER_STATE}/immich_postgres.env" <<ENV
POSTGRES_PASSWORD=${IMMICH_DB_PASSWORD:-}
ENV
    ;;
  ps)
    case "${3:-}" in
      immich_server) echo immich_server ;;
      immich_postgres) echo immich_postgres ;;
    esac
    ;;
  *)
    if [[ "${1:-}" == "inspect" ]]; then
      if [[ "${2:-}" == "--format" ]]; then
        cat "${FAKE_DOCKER_STATE:?}/${4}.env"
      else
        [[ -f "${FAKE_DOCKER_STATE:?}/${2}.env" ]]
      fi
    fi
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/docker"

export PATH="$FAKE_BIN:$PATH"
export FAKE_DOCKER_STATE="$FAKE_STATE"
export DOMUM_DIR="$REPO_ROOT"
export CFG_FILE
export SECRETS_DIR

# shellcheck disable=SC1090
source "$REPO_ROOT/bin/domum-media"

# Keep the smoke test working under older local bash while still exercising
# the same runtime env loading path used by the real compose wrapper.
compose_cmd() {
  export_env_for_compose
  docker compose "$@"
}

load_cfg
export_env_for_compose
validate_immich_secret_exports

[[ "${IMMICH_DB_PASSWORD:-}" == "db-pass-123!@" ]] || fail "IMMICH_DB_PASSWORD did not load trimmed from the secret file (got: $(printf '%q' "${IMMICH_DB_PASSWORD:-}"))"
[[ "${IMMICH_JWT_SECRET:-}" == "jwt-secret-456?=" ]] || fail "IMMICH_JWT_SECRET did not load trimmed from the secret file (got: $(printf '%q' "${IMMICH_JWT_SECRET:-}"))"

# Lock in the regression: no surrounding whitespace may survive the read.
[[ "${IMMICH_DB_PASSWORD}" == "${IMMICH_DB_PASSWORD#[[:space:]]}" ]] || fail "IMMICH_DB_PASSWORD has leading whitespace"
[[ "${IMMICH_DB_PASSWORD}" == "${IMMICH_DB_PASSWORD%[[:space:]]}" ]] || fail "IMMICH_DB_PASSWORD has trailing whitespace"
[[ "${IMMICH_JWT_SECRET}" == "${IMMICH_JWT_SECRET#[[:space:]]}" ]] || fail "IMMICH_JWT_SECRET has leading whitespace"
[[ "${IMMICH_JWT_SECRET}" == "${IMMICH_JWT_SECRET%[[:space:]]}" ]] || fail "IMMICH_JWT_SECRET has trailing whitespace"

RENDERED_FILE="$TMP_DIR/rendered.yml"
render_compose_config_file "$RENDERED_FILE"

SERVER_DB_PASSWORD="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_server DB_PASSWORD)")"
SERVER_JWT_SECRET="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_server JWT_SECRET)")"
POSTGRES_PASSWORD="$(yaml_scalar_plaintext "$(compose_rendered_env_value "$RENDERED_FILE" immich_postgres POSTGRES_PASSWORD)")"

[[ -n "$SERVER_DB_PASSWORD" ]] || fail "immich_server DB_PASSWORD rendered empty"
[[ -n "$SERVER_JWT_SECRET" ]] || fail "immich_server JWT_SECRET rendered empty"
[[ -n "$POSTGRES_PASSWORD" ]] || fail "immich_postgres POSTGRES_PASSWORD rendered empty"
[[ "$SERVER_DB_PASSWORD" == "$POSTGRES_PASSWORD" ]] || fail "DB_PASSWORD and POSTGRES_PASSWORD did not match"
[[ "$SERVER_DB_PASSWORD" == "db-pass-123!@" ]] || fail "immich_server DB_PASSWORD did not match the trimmed DB secret"
[[ "$POSTGRES_PASSWORD" == "db-pass-123!@" ]] || fail "immich_postgres POSTGRES_PASSWORD did not match the trimmed DB secret"
[[ "$SERVER_JWT_SECRET" == "jwt-secret-456?=" ]] || fail "immich_server JWT_SECRET did not match the JWT secret file"

validate_immich_compose_config
compose_cmd up -d immich_server immich_postgres
validate_immich_runtime_env

echo "PASS: Immich secret propagation smoke test"
