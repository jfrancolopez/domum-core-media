#!/usr/bin/env bash
set -uo pipefail

# Docker must not start before /srv/data is mounted.
#
# Every service's state is a bind mount from /srv/data, and all eleven containers
# are `restart: unless-stopped`, so the Docker daemon starts them itself at boot --
# without compose, which is why the 2026-10-05 fleet restart preserved every image
# ID. But if /srv/data were not mounted at that moment, Docker would CREATE the
# missing bind-mount sources under the empty mountpoint, on the OS disk, and every
# service would come up as a fresh install writing there. The later mount would
# hide that data underneath a running service.
#
# Measured before this was added:
#
#   docker.service RequiresMountsFor = (empty)
#   docker.service After             = network-online.target nss-lookup.target
#                                      docker.socket firewalld.service
#                                      containerd.service time-set.target
#                                      -> zero mount-related entries
#
# The protection existed only transitively: srv-data.mount is Before=local-fs.target,
# local-fs.target is Before=sysinit.target, docker.service is
# WantedBy=multi-user.target. True today, and nothing recorded it -- so `nofail` on
# an fstab line, or moving the data to a device that appears late, would have
# removed it silently.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DROPIN="$REPO_ROOT/systemd/docker.service.d/10-domum-require-mounts.conf"

[[ -r "$DROPIN" ]] || fail "the docker.service drop-in is missing: $DROPIN"

# A drop-in systemd will actually read: [Unit] section, RequiresMountsFor set.
grep -qE '^\[Unit\]$' "$DROPIN" || fail "the drop-in has no [Unit] section, so systemd ignores it"
req="$(sed -nE 's/^RequiresMountsFor=(.*)$/\1/p' "$DROPIN" | head -1)"
[[ -n "$req" ]] || fail "the drop-in does not set RequiresMountsFor"

# Both btrfs mountpoints. /srv/media is deliberately NOT here: it is a directory
# on the OS disk, not a mount, so there is no mount unit to require.
for p in /srv/data /srv/snapshots; do
  grep -qF -- "$p" <<< "$req" || fail "RequiresMountsFor does not cover $p: '$req'"
done
grep -qF -- "/srv/media" <<< "$req" \
  && fail "RequiresMountsFor names /srv/media, which is not a mount; systemd would wait for a unit that never appears"

# Every path a service binds from must be covered by one of the required mounts.
# This is the check that keeps the drop-in honest as compose fragments change.
uncovered=()
while IFS= read -r src; do
  case "$src" in
    /srv/data/*|/srv/data)        continue ;;   # covered by /srv/data
    /srv/snapshots/*|/srv/snapshots) continue ;;
    /srv/media/*|/srv/media)      continue ;;   # not a mount; always present
    /opt/domum-core-media/*|/etc/domum-core-media/*|/var/run/*|/run/*) continue ;;
    *) uncovered+=("$src") ;;
  esac
done < <(grep -hoE '^\s+- \$\{?[A-Z_]*\}?[^:]*:' "$REPO_ROOT"/compose/*/*.yml "$REPO_ROOT"/compose/*.yml 2>/dev/null \
          | sed -E 's/^\s+- //; s/:$//' | grep '^/' | sort -u)
(( ${#uncovered[@]} == 0 )) \
  || { printf '  %s\n' "${uncovered[@]}" >&2
       fail "${#uncovered[@]} bind source(s) are outside every required mount and outside the OS disk"; }

# The installer must actually place it, or the file is decoration.
conv="$(awk '/^converge_local_installation\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'service.d/\*.conf' <<< "$conv" \
  || fail "converge_local_installation does not install systemd drop-ins, so the file never reaches /etc"
# Scoped to the drop-in LOOP. Grepping the whole function matched the unrelated
# `install -D -m 0644 ... logrotate` line, so dropping -D from the drop-in
# survived.
dropin_loop="$(awk '/for dropin in /,/^  done$/' <<< "$conv")"
[[ -n "$dropin_loop" ]] || fail "the drop-in install loop is gone"
grep -q 'install -D -m 0644' <<< "$dropin_loop" \
  || fail "the drop-in install does not create the parent directory (-D), so it would fail on a clean host:
$dropin_loop"
grep -q 'systemctl daemon-reload' <<< "$conv" \
  || fail "no daemon-reload after installing units"
# And the ordinary unit glob must not swallow the drop-in directory.
grep -q 'systemd/\*.service /etc/systemd/system/' <<< "$conv" \
  || fail "the unit install line changed; check that *.service does not match docker.service.d"

# It must not restart Docker. A drop-in takes effect at the next start; restarting
# the daemon here would bounce all eleven containers during a routine convergence.
grep -qE 'systemctl (restart|try-restart) docker' <<< "$conv" \
  && fail "converge restarts Docker, which would bounce every container on a routine apply"

echo "PASS: boot mount dependency smoke test"
