# Reboot readiness

`/var/run/reboot-required` has been set since the 2026-10-05 host upgrade:

```
linux-image-6.12.111+deb13-amd64
running: 6.12.107+deb13-amd64      installed: 6.12.107, 6.12.111
```

A kernel upgrade, nothing more. A reboot neither changes an application image nor
touches application data, which is what makes it a cleaner next experiment than
an upgrade.

## The failure worth preventing

Every service's state is a bind mount from `/srv/data`, and all eleven containers
are `restart: unless-stopped` — so the **Docker daemon** starts them at boot,
without compose. If `/srv/data` were not mounted at that moment, Docker would
**create** the missing bind-mount sources under the empty mountpoint, on the OS
disk, and every service would come up as a fresh install writing there. The mount
landing later would hide that data underneath a running service: two divergent
copies, no obvious symptom.

## The mount topology, measured

```
/srv              /dev/sdb2  ext4   mountpoint=no    <- the OS disk
/srv/data         /dev/sda1[/@data]       btrfs  mountpoint=yes   subvol=/@data
/srv/snapshots    /dev/sda1[/@snapshots]  btrfs  mountpoint=yes   subvol=/@snapshots
/srv/media        /dev/sdb2  ext4   mountpoint=no    <- a directory, NOT a mount
```

`/etc/fstab` carries `/srv/data` and `/srv/snapshots` with
`subvol=…,noatime,compress=zstd:3,ssd` and **no `nofail` and no `noauto`**, so
both are part of `local-fs.target`. `/srv/media` is not in fstab at all.

## The dependency was real but incidental

```
docker.service  RequiresMountsFor = (empty)
docker.service  After = network-online.target nss-lookup.target docker.socket
                        firewalld.service containerd.service time-set.target
                        -> ZERO mount-related entries
```

The protection came only from transitive target ordering:

```
srv-data.mount  Before=local-fs.target
local-fs.target Before=sysinit.target  ->  basic.target  ->  multi-user.target
docker.service  WantedBy=multi-user.target
```

That holds today. Nothing recorded the requirement, so adding `nofail` to an
fstab line, or moving the data to a device that appears late, would have removed
the protection silently — and the symptom would have been a fresh-looking Plex.

**Now explicit**, via `systemd/docker.service.d/10-domum-require-mounts.conf`:

```
[Unit]
RequiresMountsFor=/srv/data /srv/snapshots
```

`RequiresMountsFor` adds both `Requires=` and `After=` on the mount units. If the
storage cannot be mounted, **Docker does not start** — the right failure: no
containers beats containers writing to the wrong filesystem. `/srv/media` is
deliberately absent; it is not a mount, so requiring it would wait for a unit that
never appears.

`converge_local_installation` installs `systemd/*.service.d/*.conf` with
`install -D`, so it survives a reinstall. It changes nothing until the next boot
and does **not** restart Docker.

`tests/boot-mount-dependency-smoke.sh` also checks every bind source in every
compose fragment against the required mounts, so the drop-in stays honest as
fragments change. Five mutants killed.

## Nothing at boot deploys anything

| | |
|---|---|
| units that run `apply`, `update` or `compose up` at boot | **none** |
| `domum-media-image-refresh.timer` | not enabled (`WantedBy=` empty) |
| the other five timers | `WantedBy=timers.target`, fire on schedule, not at boot |
| how containers return | Docker's `unless-stopped`, restarting existing container objects |

So no image reference is resolved at boot. **Observed**, not argued: the
2026-10-05 fleet restart at `10:10:24Z` brought all eleven containers back with
every `Created` timestamp and every image ID unchanged — including Plex and
Calibre-Web, which both had newer images staged. A daemon restart does not deploy.

A reboot is a stronger event than a daemon restart, which is exactly why it is
worth verifying rather than assuming.

## Other reboot-time concerns

| concern | state |
|---|---|
| operation lock | an open fd under `flock`; the kernel releases it when the process dies, so a reboot cannot leave it held. The `.holder` file is diagnostic only and never consulted |
| timers | all five enabled and `WantedBy=timers.target`; they resume |
| image refresh | `disabled/inactive`, and nothing at boot enables it |
| proof snapshots and `.premigration` | on `/srv/data` and `/srv/snapshots`; they persist by definition once mounted |
| recovery evidence | `/var/lib/domum-media/snapshots/*.recovery`, on the OS disk, persists |
| SSH / Tailscale | SSH is a host service; Tailscale is `ENABLE_TAILSCALE`-gated and not running here |
| Traefik | `unless-stopped`, same as the rest; its ACME store is a Docker volume |
| database ordering | Immich's four containers have compose `depends_on`, and Docker restores them with their restart policies |

## The drop-in is not reverted by a rollback

The deployment that installs `systemd/docker.service.d/10-domum-require-mounts.conf`
has a rollback script, and that script deliberately **leaves the drop-in in place**
while it restores the three CLI files and rewinds the production checkout.

That asymmetry is the decision, not an omission:

- The drop-in is independent of the CLI. It constrains only the order in which
  systemd starts Docker at boot, and it is correct under every revision of
  `bin/domum-media` — including the one being rolled back to.
- A rollback exists to undo a defect in the CLI. Removing a boot-ordering safety
  constraint on the way out would silently restore the ability to start Docker
  before `/srv/data` is mounted, which is the split-brain this whole change
  prevents. A rollback must not widen the blast radius of the thing it is
  recovering from.
- So the rollback *reports* what it did not revert rather than reverting it. Its
  last section prints the drop-in's path and the live `RequiresMountsFor`, and
  warns if the file is absent.

Removing it is therefore an explicit operator action:

```
rm /etc/systemd/system/docker.service.d/10-domum-require-mounts.conf
rmdir --ignore-fail-on-non-empty /etc/systemd/system/docker.service.d
systemctl daemon-reload
```

Note that `apply`, `init` and `configure` reinstall it, because
`converge_local_installation` installs `systemd/*.service.d/*.conf`. That is
intended: convergence should restore it, and it changes nothing until the next
boot.

### One behavioural consequence worth knowing

`RequiresMountsFor=` adds `Requires=` as well as `After=`. Once it is loaded, an
**unmount of `/srv/data` stops `docker.service`**, and with it all eleven
containers. That is the correct direction — containers stopped beats containers
writing to the OS disk — but it means a future `umount /srv/data` for maintenance
is no longer a quiet operation. Stop the stack first, deliberately.

## Acceptance

Two scripts, both read-only, both feature-gated against the **installed** CLI:

```
sudo bash /home/jfranco/domum-media-capture-prereboot.sh    # before
sudo bash /home/jfranco/domum-media-verify-postboot.sh      # after
```

The capture writes `/var/lib/domum-media/prereboot-state` — on the OS disk,
deliberately, since `/srv/data`'s mount is the thing in question. It records the
boot id, running and newest-installed kernel, production HEAD, mount sources and
mountpoint status for all three paths, every container's image id / created time /
restart policy, the topology digest, per-service protection, every
`.premigration` file count and byte total, every recovery-evidence digest, every
snapshot's read-only flag and file count, and the timer list.

The verifier checks all of it, and three things that only matter after a reboot:

- **the boot id actually changed** — otherwise the verification is of a system
  that never rebooted
- **nothing was written beneath an unmounted mountpoint**: it bind-mounts `/srv`
  elsewhere and looks *underneath* `/srv/data` and `/srv/snapshots` for entries on
  the OS disk. That is the direct test for the split-brain above, and it is the
  one check that cannot be done any other way once the mount is in place
- **`RequiresMountsFor` is still in effect**, so the *next* boot is protected too

Container ids are expected to change where Docker recreates runtimes; **image ids
must not**, because nothing at boot resolves a tag.

## Why reboot before the Plex upgrade

The upgrade needs Plex migrated first, because its state has no recovery point
([UPGRADE-PROTECTION.md](UPGRADE-PROTECTION.md)). The reboot needs nothing, mutates
no application data, changes no image, and clears a pending kernel update that has
been outstanding since 2026-10-05.

It is also the one event none of the three migrated subvolumes has survived. A
fleet restart is not the same thing: the mounts were already in place. Proving the
subvolumes come back correctly from a cold boot is a prerequisite for trusting
them under anything more disruptive.
