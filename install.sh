#!/usr/bin/env bash
set -euo pipefail

# domum-core-media bootstrap
# Targets Debian 13 on an Intel N100. Mirrors domum-core/install.sh shape
# but pins Docker + Tailscale apt repos and installs restic + btrfs tooling.
#
# Idempotent: re-running converges the host. Does NOT format the data SSD —
# that procedure lives in docs/SETUP-N100.md.

REPO_URL_DEFAULT="https://github.com/jfrancolopez/domum-core-media.git"
INSTALL_DIR_DEFAULT="/opt/domum-core-media"
CONFIG_DIR_DEFAULT="/etc/domum-core-media"
LOG_DIR_DEFAULT="/var/log/domum-media"
BIN_PATH="/usr/local/bin/domum-media"
BACKUP_BIN_PATH="/usr/local/bin/domum-media-backup"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
INSTALL_DIR="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
CONFIG_DIR="${CONFIG_DIR:-$CONFIG_DIR_DEFAULT}"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"

require_debian_13() {
  if [[ ! -f /etc/os-release ]]; then
    echo "[domum-media] /etc/os-release missing — cannot verify OS."
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    echo "[domum-media] WARNING: expected Debian, found '${ID:-unknown}'. Proceeding."
  fi
  if [[ "${VERSION_ID:-}" != "13" ]]; then
    echo "[domum-media] WARNING: expected Debian 13, found '${VERSION_ID:-unknown}'. Proceeding."
  fi
}

require_network() {
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "[domum-media] No DNS for deb.debian.org — fix network before retrying."
    exit 1
  fi
}

install_prereqs() {
  echo "[domum-media] Installing prereqs (curl, git, gnupg, btrfs-progs, jq, apparmor, nfs-common, rclone, gettext-base, unattended-upgrades, age)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg lsb-release \
    btrfs-progs jq apparmor nfs-common rclone gettext-base \
    unattended-upgrades apt-listchanges age
}

install_docker() {
  echo "[domum-media] Installing/upgrading Docker from the official apt repo..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch codename
  arch="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  echo "[domum-media] Docker ready ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unavailable'))."
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    echo "[domum-media] Tailscale already installed."
    return 0
  fi

  echo "[domum-media] Installing Tailscale from pkgs.tailscale.com..."
  local codename
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list

  apt-get update -y
  apt-get install -y --no-install-recommends tailscale

  echo "[domum-media] Tailscale installed. Do NOT auto-tailscale-up — see next steps."
}

install_restic() {
  if command -v restic >/dev/null 2>&1; then
    echo "[domum-media] restic already installed ($(restic version 2>/dev/null | head -1))."
    return 0
  fi
  echo "[domum-media] Installing restic from Debian repos..."
  apt-get install -y --no-install-recommends restic
  echo "[domum-media] restic installed ($(restic version 2>/dev/null | head -1))."
  echo "[domum-media] If this version is too old, follow SETUP-RESTIC.md to pin a newer binary."
}

clone_or_update_repo() {
  echo "[domum-media] Syncing repo to ${INSTALL_DIR}..."
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" fetch --all --prune
    git -C "${INSTALL_DIR}" reset --hard origin/main
  else
    rm -rf "${INSTALL_DIR}"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
  fi
}

install_cli() {
  echo "[domum-media] Installing CLIs to /usr/local/bin..."
  install -m 0755 "${INSTALL_DIR}/bin/domum-media" "${BIN_PATH}"
  install -m 0755 "${INSTALL_DIR}/bin/domum-media-backup" "${BACKUP_BIN_PATH}"
}

install_systemd_units() {
  echo "[domum-media] Installing systemd units..."
  install -m 0644 "${INSTALL_DIR}"/systemd/*.service /etc/systemd/system/
  install -m 0644 "${INSTALL_DIR}"/systemd/*.timer   /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now \
    domum-media-backup.timer \
    domum-media-check.timer \
    domum-media-btrfs-snapshot.timer \
    domum-media-image-refresh.timer \
    domum-media-host-update.timer \
    domum-media-dr-reminder.timer
}

ensure_layout() {
  mkdir -p "${CONFIG_DIR}/secrets"
  chmod 0700 "${CONFIG_DIR}/secrets"
  mkdir -p "${LOG_DIR}"
}

print_next_steps() {
  cat <<EOF

[domum-media] Bootstrap done. Manual next steps:

  1. Bring up Tailscale (operator step — not auto-run by install.sh):
       sudo tailscale up --ssh

  2. Run the interactive config wizard (it can now create the common secrets too):
       sudo domum-media configure
       # or:
       cp ${INSTALL_DIR}/config/domum-media.conf.example ${INSTALL_DIR}/config/domum-media.conf
       \$EDITOR ${INSTALL_DIR}/config/domum-media.conf

  3. Bring up the host:
       sudo domum-media init
       sudo domum-media apply

  4. Initialise restic repos and run first backup — see docs/SETUP-RESTIC.md.

  5. Create the encrypted recovery pack:
       sudo domum-media recovery-pack create

  6. Run the disaster-recovery drill — see docs/disaster-recovery.md.

Re-run this curl command anytime to converge.
EOF
}

main() {
  require_debian_13
  require_network
  install_prereqs
  install_docker
  install_tailscale
  install_restic
  clone_or_update_repo
  ensure_layout
  install_cli
  install_systemd_units
  print_next_steps
}

main "$@"
