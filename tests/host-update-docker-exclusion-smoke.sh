#!/usr/bin/env bash
set -uo pipefail

# The weekly host-update must never upgrade Docker Engine.
#
# Production, 2026-11-23: domum-media-host-update.timer ran `host-upgrade`,
# which upgraded docker-ce 29.9.3 -> 29.10.0 at 05:50. dockerd restarted, every
# container restarted with it, and traefik came back on a bind-mounted static
# config that had changed since it last started -- all seven HTTPS routes
# returned 404 for eleven hours. unattended-upgrades already blacklisted these
# packages; host-upgrade installed them BY NAME.
#
# Drives the real host_upgrade with apt-get recorded, never run.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PRISTINE="$TMP/cli.pristine"; cp "$CLI" "$PRISTINE"

# A simulation in which Docker Engine AND an ordinary package are upgradable.
SIM='Inst docker-ce [5:29.10.0-1] (5:29.10.1-1 Docker:stable [amd64])
Inst containerd.io [2.1.0-1] (2.1.1-1 Docker:stable [amd64])
Inst tailscale [1.90.0] (1.90.1 tailscale:stable [amd64])
Inst docker-ce-rootless-extras [5:29.10.0-1] (5:29.10.1-1 Docker:stable [amd64])'

# Global, not set inside drive(): drive runs in $( ), so an assignment there
# would never reach the assertions.
APT_LOG="$TMP/apt.log"
drive() {  # $1 = CLI to source
  : > "$APT_LOG"
  ( set -euo pipefail
    DOMUM_DIR="$REPO_ROOT"; export DOMUM_DIR
    # shellcheck disable=SC1090
    source "$1"
    need_root() { :; }
    load_cfg() { HOST_PACKAGE_AUTO_UPDATE_ENABLED=1; }
    export_env_for_compose() { :; }
    domum_acquire_lock() { return 0; }
    record_update_history() { :; }
    apt-get() {
      printf '%s\n' "$*" >> "$APT_LOG"
      [[ "${1:-}" == "-s" ]] && printf '%s\n' "$SIM"
      return 0
    }
    host_upgrade
  ) 2>&1
}

sect "host-upgrade installs NO Docker Engine package"
out="$(drive "$CLI")" || fail "host_upgrade failed: $out"
install_line="$(grep -- '--only-upgrade' "$APT_LOG" || true)"
[[ -n "$install_line" ]] || fail "no install was attempted at all; the test has no subject: $(cat "$APT_LOG")"
engine="$(bash -c 'source "$1"; docker_engine_packages' _ "$CLI")"
[[ "$(wc -l <<< "$engine")" -eq 5 ]] || fail "expected 5 engine packages, got: $engine"
while IFS= read -r p; do
  grep -qw -- "$p" <<< "$install_line" && fail "host-upgrade installs $p: $install_line"
done <<< "$engine"
grep -qw tailscale <<< "$install_line" || fail "ordinary host tooling stopped being upgraded: $install_line"
echo "  install line carries none of the 5, and still upgrades tailscale"

sect "what was held back is REPORTED, so silence never means 'Docker is current'"
grep -q 'HELD BACK' <<< "$out" || fail "held-back engine packages are not reported: $out"
grep -q 'docker-ce containerd.io' <<< "$out" || fail "it does not name them: $out"
grep -q 'rootless-extras' <<< "$out" && fail "a non-engine package was reported as held: $out"
grep -q 'restarts the Docker daemon and EVERY container' <<< "$out" \
  || fail "it does not say why they are held: $out"
echo "  names docker-ce and containerd.io, and why"

sect "the unattended blacklist is the SAME list"
# `^}$`, not `^}`: the heredoc inside it has `};` lines at column 0.
fn="$(awk '/^sync_unattended_upgrades\(\) \{/,/^\}$/' "$CLI")"
[[ -n "$fn" ]] || fail "could not extract sync_unattended_upgrades"
fn="${fn//\/etc\/apt\/apt.conf.d/$TMP}"
( set -euo pipefail
  # shellcheck disable=SC1090
  source "$CLI"
  systemctl() { :; }
  # If the redefinition fails the REAL function would run and write /etc/apt.
  eval "$fn" || exit 1
  grep -q '/etc/apt' <<< "$(declare -f sync_unattended_upgrades)" && exit 1
  sync_unattended_upgrades
) || fail "sync_unattended_upgrades failed with redirected paths"
[[ -f "$TMP/50domum-unattended-upgrades" ]] || fail "the redirected config was not written"
while IFS= read -r p; do
  grep -qxF "  \"$p\";" "$TMP/50domum-unattended-upgrades" || fail "$p is missing from the unattended blacklist"
done <<< "$engine"
echo "  all 5 blacklisted"

sect "MUTATION: putting docker-ce back in the install list must fail"
MUT="$TMP/cli.mut"; cp "$CLI" "$MUT"
python3 - "$MUT" <<'PY' || fail "mutation did not apply"
import sys
p = sys.argv[1]; s = open(p).read()
old = "    tailscale restic btrfs-progs jq apparmor nfs-common rclone gettext-base \\\n"
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, "    docker-ce " + old.lstrip(), 1))
PY
drive "$MUT" >/dev/null || true
mut_line="$(grep -- '--only-upgrade' "$APT_LOG" || true)"
grep -qw docker-ce <<< "$mut_line" \
  || fail "the mutant did not install docker-ce; the assertion above has nothing to catch"
echo "  mutant installs docker-ce -- the first section would reject it"

cmp -s "$CLI" "$PRISTINE" || fail "the tracked CLI was modified by this suite"
echo "PASS: host-update-docker-exclusion"
