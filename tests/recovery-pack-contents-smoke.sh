#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SECRETS_DIR="$TMP_DIR/secrets"
DOMUM_STATE_ROOT="$TMP_DIR/state"
RECOVERY_PACK_DEST="$DOMUM_STATE_ROOT/recovery-pack"
CFG_FILE="$TMP_DIR/domum-media.conf"
FAKE_BIN="$TMP_DIR/bin"
EXTRACT_DIR="$TMP_DIR/extracted"

mkdir -p \
  "$SECRETS_DIR" \
  "$DOMUM_STATE_ROOT/backups" \
  "$DOMUM_STATE_ROOT/immich" \
  "$RECOVERY_PACK_DEST" \
  "$FAKE_BIN" \
  "$EXTRACT_DIR"

cat > "$FAKE_BIN/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''
input=''
while (( $# )); do
  case "$1" in
    -r) shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
[[ -n "$out" && -n "$input" ]]
cp "$input" "$out"
EOF
chmod +x "$FAKE_BIN/age"
export PATH="$FAKE_BIN:$PATH"

cat > "$CFG_FILE" <<EOF
ENABLE_IMMICH=1
BACKUP_TARGETS=cloud
BACKUP_TARGET_CLOUD_ENABLED=1
EOF

printf '%s\n' 'age1testrecipient' > "$SECRETS_DIR/recovery_pack_pubkey"
printf '%s\n' 'db-password' > "$SECRETS_DIR/immich_db_password"
printf '%s\n' 'jwt-secret' > "$SECRETS_DIR/immich_jwt_secret"
printf '%s\n' 'restic-password' > "$SECRETS_DIR/restic_password_cloud"
printf '%s\n' '# no overrides' > "$SECRETS_DIR/restic_cloud_env"
printf '%s\n' 'ssh-private-key' > "$SECRETS_DIR/storage-box-key"
printf '%s\n' 'known-host-entry' > "$SECRETS_DIR/storage-box-known-hosts"
printf '%s\n' 'old-password' > "$SECRETS_DIR/restic_password_cloud.pre-p0-20260903"
printf '%s\n' 'not-required' > "$SECRETS_DIR/unrelated_secret"
printf '%s\n' 'fingerprint' > "$DOMUM_STATE_ROOT/immich/db_password.sha256"
cat > "$DOMUM_STATE_ROOT/backups/cloud-repo.env" <<'EOF'
TARGET="cloud"
REPOSITORY_ID="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
INIT_TS="2026-09-04T08:43:37-04:00"
EOF
printf '%s\n' 'NOT_REQUIRED="unrelated"' > "$DOMUM_STATE_ROOT/backups/nas-repo.env"

# shellcheck disable=SC1090
source "$REPO_ROOT/bin/domum-media"

recovery_pack_repo_metadata_is_safe \
  "$DOMUM_STATE_ROOT/backups/cloud-repo.env" cloud \
  || fail "valid repository identity metadata was rejected"
cp \
  "$DOMUM_STATE_ROOT/backups/cloud-repo.env" \
  "$DOMUM_STATE_ROOT/backups/unsafe-repo.env"
printf '%s\n' 'RESTIC_PASSWORD="must-not-be-archived"' \
  >> "$DOMUM_STATE_ROOT/backups/unsafe-repo.env"
if recovery_pack_repo_metadata_is_safe "$DOMUM_STATE_ROOT/backups/unsafe-repo.env" cloud; then
  fail "unexpected repository metadata content was accepted"
fi

DOMUM_DIR="$REPO_ROOT"
ENABLE_IMMICH=1
ENABLE_TRAEFIK=0
BACKUP_TARGETS=cloud
BACKUP_TARGET_CLOUD_ENABLED=1
BACKUP_TARGET_CLOUD_TYPE=repository
BACKUP_TARGET_CLOUD_REPOSITORY='sftp:backup-user@storage.example:/domum-core-media-restic'
BACKUP_TARGET_CLOUD_PASSWORD_FILE="$SECRETS_DIR/restic_password_cloud"
BACKUP_TARGET_CLOUD_ENV_FILE="$SECRETS_DIR/restic_cloud_env"
BACKUP_TARGET_CLOUD_SFTP_KEY_FILE="$SECRETS_DIR/storage-box-key"
BACKUP_TARGET_CLOUD_SFTP_KNOWN_HOSTS_FILE="$SECRETS_DIR/storage-box-known-hosts"
RECOVERY_PACK_ENABLED=1
RECOVERY_PACK_ENCRYPTION=age
RECOVERY_PACK_AGE_PUBKEY_FILE="$SECRETS_DIR/recovery_pack_pubkey"
RECOVERY_PACK_EMAIL_ENABLED=0
compose_cmd() { printf '%s\n' 'services: {}'; }

recovery_pack_create 1

archive="$(compgen -G "$RECOVERY_PACK_DEST/recovery-pack-*.tar.age")"
[[ -f "$archive" ]] || fail "recovery pack was not created"
[[ "$(stat -c %a "$archive")" == 600 ]] || fail "recovery pack mode is not 0600"
tar -xzf "$archive" -C "$EXTRACT_DIR"

required=(
  recovery_pack_pubkey
  immich_db_password
  immich_jwt_secret
  restic_password_cloud
  restic_cloud_env
  storage-box-key
  storage-box-known-hosts
)
for name in "${required[@]}"; do
  [[ -f "$EXTRACT_DIR/secrets/$name" ]] || fail "required secret missing from pack: $name"
done

[[ ! -e "$EXTRACT_DIR/secrets/unrelated_secret" ]] || fail "unrelated secret was archived"
[[ ! -e "$EXTRACT_DIR/secrets/restic_password_cloud.pre-p0-20260903" ]] \
  || fail "rollback password was archived"
cmp -s \
  "$DOMUM_STATE_ROOT/immich/db_password.sha256" \
  "$EXTRACT_DIR/state/immich/db_password.sha256" \
  || fail "Immich password fingerprint missing or changed"
cmp -s \
  "$DOMUM_STATE_ROOT/backups/cloud-repo.env" \
  "$EXTRACT_DIR/state/backups/cloud-repo.env" \
  || fail "cloud repository identity metadata missing or changed"
[[ ! -e "$EXTRACT_DIR/state/backups/nas-repo.env" ]] \
  || fail "unrelated repository metadata was archived"
grep -qF 'state/immich/db_password.sha256' "$EXTRACT_DIR/MANIFEST.txt" \
  || fail "fingerprint missing from manifest"
grep -qF 'state/backups/cloud-repo.env' "$EXTRACT_DIR/MANIFEST.txt" \
  || fail "repository identity metadata missing from manifest"

restore_line="$(grep -nF 'Restore /srv/data' "$EXTRACT_DIR/RESTORE.txt" | cut -d: -f1)"
repo_meta_line="$(grep -nF 'Restore state/backups/' "$EXTRACT_DIR/RESTORE.txt" | cut -d: -f1)"
apply_line="$(grep -nF 'sudo domum-media apply' "$EXTRACT_DIR/RESTORE.txt" | cut -d: -f1)"
(( repo_meta_line < restore_line )) || fail "restore instructions restore repository metadata too late"
(( restore_line < apply_line )) || fail "restore instructions run apply before data restoration"

if compgen -G "$RECOVERY_PACK_DEST/.recovery-pack-*.tmp" >/dev/null; then
  fail "temporary encrypted artifact remains"
fi

echo "PASS: recovery-pack contents and restore ordering smoke test"
