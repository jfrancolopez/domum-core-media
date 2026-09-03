#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

key_file="$TMP_DIR/storage-box-key"
known_hosts_file="$TMP_DIR/known-hosts"
: > "$key_file"
: > "$known_hosts_file"

valid_repo='sftp:backup-user@storage.example:/domum-core-media-restic'
invalid_repos=(
  'sftp:backup-user@storage.example:23:/domum-core-media-restic'
  'sftp://backup-user@storage.example:23//domum-core-media-restic'
  'sftp:backup-user:password@storage.example:/domum-core-media-restic'
  'sftp:backup-user@storage.example:/./domum-core-media-restic'
  'sftp:backup-user@storage.example:/some path'
  'sftp:backup-user@storage.example:/'
)
invalid_ports=(0 65536 23x 'host:23')

for script in bin/domum-media bin/domum-media-backup; do
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/$script"

    mapfile -t parts < <(sftp_repo_user_host "$valid_repo")
    [[ "${parts[0]:-}" == backup-user ]] || fail "$script parsed the SFTP user incorrectly"
    [[ "${parts[1]:-}" == storage.example ]] || fail "$script parsed the SFTP host incorrectly"

    for repo in "${invalid_repos[@]}"; do
      if sftp_repo_user_host "$repo" >/dev/null; then
        fail "$script accepted malformed SFTP repository: $repo"
      fi
    done

    sftp_port_is_valid 23 || fail "$script rejected valid SFTP port"
    for port in "${invalid_ports[@]}"; do
      if sftp_port_is_valid "$port"; then
        fail "$script accepted invalid SFTP port: $port"
      fi
    done

    BACKUP_TARGET_CLOUD_REPOSITORY="$valid_repo"
    BACKUP_TARGET_CLOUD_SFTP_KEY_FILE="$key_file"
    BACKUP_TARGET_CLOUD_SFTP_KNOWN_HOSTS_FILE="$known_hosts_file"
    BACKUP_TARGET_CLOUD_SFTP_PORT=23
    option="$(sftp_command_option_for_target cloud)"
    [[ "$option" == *'-p 23'* ]] || fail "$script omitted the explicit SFTP port"
    [[ "$option" == *'backup-user@storage.example -s sftp'* ]] \
      || fail "$script generated the wrong SSH destination"
    [[ "$valid_repo" != *':23:'* ]] || fail "$script encoded the port in the repository path"
  )
done

# Plan output reports only a sanitized backend type, never the repository user or host.
(
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bin/domum-media-backup"
  load_cfg() { :; }
  BACKUP_TARGET_CLOUD_REPOSITORY="$valid_repo"
  BACKUP_TARGET_CLOUD_TYPE=repository
  BACKUP_TARGET_CLOUD_INCLUDE_PATHS="$TMP_DIR"
  DOMUM_DATA_ROOT="$TMP_DIR/data"
  REPO_META_DIR="$TMP_DIR/repo-meta"

  plan="$(do_plan_target cloud)"
  [[ "$plan" == *'Repository: configured (sftp)'* ]] || fail "plan omitted sanitized SFTP type"
  [[ "$plan" != *'backup-user'* && "$plan" != *'storage.example'* ]] \
    || fail "plan exposed the raw SFTP repository"
)

echo "PASS: Restic SFTP configuration smoke test"
