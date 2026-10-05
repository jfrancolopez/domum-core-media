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

# SCOPE. Docker's dependency must match what CONTAINERS need, no more and no less.
#
# Measured on this host, over every bind source of all eleven containers:
#
#   /srv/data/...   /dev/sda1[/@data]  btrfs   srv-data.mount   <- 7 containers
#   /srv/media...   /dev/sdb2          ext4    (a DIRECTORY on /, not a mount)
#   /srv/snapshots  /dev/sda1[/@snaps] btrfs   srv-snapshots.mount  <- ZERO containers
#   /etc/..., /opt/..., /var/run/docker.sock    on / and /run
#
# So: /srv/data is required, and the other three are deliberately absent.
#
# /srv/media would be a dependency on a unit that never appears. systemd resolves
# RequiresMountsFor to the ENCLOSING mountpoint -- proven on this host, where
# `RequiresMountsFor=/var/log` on logrotate.service yields `Requires=-.mount` --
# so naming it would add nothing beyond the root filesystem everything already has.
#
# /srv/snapshots is a real mount, but no container binds anything under it.
# Requiring it HERE would mean a failure of a filesystem no container uses takes
# down all eleven containers. The snapshot root is needed by the domum-media
# units that create, prune or read snapshots, so the dependency belongs on those
# units -- asserted separately below.
grep -qF -- "/srv/data" <<< "$req" || fail "RequiresMountsFor does not cover /srv/data: '$req'"
grep -qF -- "/srv/media" <<< "$req" \
  && fail "RequiresMountsFor names /srv/media, which is not a mount; systemd would resolve it to -.mount, which adds nothing"
grep -qF -- "/srv/snapshots" <<< "$req" \
  && fail "RequiresMountsFor names /srv/snapshots on docker.service, but ZERO containers bind a path under it.
A failure of that filesystem would then stop all eleven containers for no reason.
Put the dependency on the units that actually use the snapshot root instead."

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

# ---------------------------------------------------------------------------
# The other half of the invariant: every unit that touches the protected storage
# must declare it, and the one that does not touch it must not.
#
# domum-media-backup does `mkdir -p "$DOMUM_SNAPSHOT_ROOT"` before the Immich
# pre-backup snapshot. With /srv/snapshots unmounted that CREATES the snapshot
# root on the OS disk, and `snapshot prune` would then survey an empty tree and
# report that it pruned nothing.
needs_storage=(
  domum-media-btrfs-snapshot.service
  domum-media-backup.service
  domum-media-check.service
  domum-media-image-refresh.service
  domum-media-host-update.service
  domum-media-weekly-report.service
)
for u in "${needs_storage[@]}"; do
  f="$REPO_ROOT/systemd/$u"
  [[ -r "$f" ]] || fail "unit not found: $f"
  ureq="$(sed -nE 's/^RequiresMountsFor=(.*)$/\1/p' "$f" | tr '\n' ' ')"
  [[ -n "$ureq" ]] || fail "$u reads or writes the protected storage but declares no RequiresMountsFor"
  for p in /srv/data /srv/snapshots; do
    grep -qF -- "$p" <<< "$ureq" || fail "$u does not require $p (has '$ureq')"
  done
  # It must be in [Unit], not [Service], or systemd ignores it.
  sect="$(awk '/^\[/{s=$0} /^RequiresMountsFor=/{print s; exit}' "$f")"
  [[ "$sect" == "[Unit]" ]] || fail "$u puts RequiresMountsFor in $sect; it only has meaning in [Unit]"
done

# The negative control: a unit that writes only /var/log must NOT acquire a
# dependency on the data tier, or a storage failure would suppress the DR
# reminder -- exactly when it matters most.
drr="$REPO_ROOT/systemd/domum-media-dr-reminder.service"
grep -q '^RequiresMountsFor=' "$drr" \
  && fail "domum-media-dr-reminder.service requires the protected storage, but it only appends to /var/log.
A storage failure would then silence the disaster-recovery reminder."

# An explicit RequiresMountsFor must not displace the one systemd derives from
# CacheDirectory=. Measured: they accumulate (and two assignments accumulate too).
for u in domum-media-backup.service domum-media-check.service; do
  grep -q 'CacheDirectory=domum-media-restic' "$REPO_ROOT/systemd/$u" \
    || fail "$u lost CacheDirectory=domum-media-restic, which is where its implicit /var/cache dependency comes from"
done

# ---------------------------------------------------------------------------
# Install safety. The drop-in lives beside units this project does not own.
conv2="$conv"
# Per-file install, so an unrelated docker.service.d drop-in is left alone.
grep -qE 'rm -rf[^\n]*service\.d' <<< "$conv2" \
  && fail "converge removes a .service.d directory; an unrelated drop-in placed by the operator or a package would be destroyed"
# Idempotent: install(1) overwrites in place, so a second run is a no-op. Assert
# there is no "create only if absent" guard that would let a stale drop-in persist.
grep -qE '\[\[ ! -e .*dropin|\[ ! -f .*dropin' <<< "$conv2" \
  && fail "the drop-in is installed only when absent, so a corrected version would never replace a stale one"

echo "PASS: boot mount dependency smoke test"
