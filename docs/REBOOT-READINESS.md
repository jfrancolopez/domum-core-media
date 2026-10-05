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

## Scope: every bind source of all eleven containers, classified

The drop-in must match what containers need — no more, no less. Measured over
every bind mount of all eleven running containers (2026-10-05):

| bind source | backing device | fstype | mount unit | containers |
|---|---|---|---|---|
| `/srv/data/{calibre-web,immich/library,immich/postgres,jellyfin,kavita,navidrome,plex}/…` | `/dev/sda1[/@data]` | btrfs | **`srv-data.mount`** | 7 |
| `/srv/media`, `/srv/media/{books,music,.cache/jellyfin,.cache/plex-transcode}` | `/dev/sdb2` | ext4 | *(a directory on `/`)* | 3 |
| `/etc/localtime`, `/opt/domum-core-media/compose/proxy/traefik`, `/etc/domum-core-media/secrets/traefik_dashboard_users` | `/dev/sdb2` | ext4 | *(on `/`)* | 2 |
| `/var/run/docker.sock` | `tmpfs` | tmpfs | *(on `/run`)* | 1 |
| `/srv/snapshots` | `/dev/sda1[/@snapshots]` | btrfs | `srv-snapshots.mount` | **0** |

Named volumes (`immich-model-cache`, `traefik-letsencrypt`, `uptime-kuma-data`,
and two anonymous ones) live under `/var/lib/docker/volumes` on `/dev/sdb2`, the
root filesystem. A Btrfs snapshot can never cover them; that is the recovery-pack
question, not a mount-dependency one.

So `docker.service` requires exactly one path:

```
[Unit]
RequiresMountsFor=/srv/data
```

### Why the other three are deliberately absent

**`/srv/media` is not a mount.** `findmnt --target /srv/media` resolves to `/`.
It is a plain directory on the root filesystem, so there is no mount unit to
depend on. systemd resolves `RequiresMountsFor=` to the *enclosing* mountpoint —
measured on this host, `logrotate.service` declares
`RequiresMountsFor=/var/log` and systemd gives it `Requires=-.mount` — so naming
`/srv/media` would add nothing beyond the root filesystem every unit already has.
Do not invent a dependency for it.

**`/srv/snapshots` is a real mount that no container uses.** Zero of the eleven
containers bind any path under it. Requiring it on `docker.service` would mean a
failure of a filesystem no container touches stops all eleven containers. The
snapshot root is needed by the *domum-media units*, so the dependency lives
there instead:

| unit | `RequiresMountsFor=` | why |
|---|---|---|
| `domum-media-btrfs-snapshot.service` | `/srv/data /srv/snapshots` | `snapshot prune` **deletes** from the snapshot root |
| `domum-media-backup.service` | `/srv/data /srv/snapshots` | reads state, and does `mkdir -p "$DOMUM_SNAPSHOT_ROOT"` before the Immich pre-backup snapshot — unmounted, that creates `/srv/snapshots` on the OS disk |
| `domum-media-check.service` | `/srv/data /srv/snapshots` | same binary; a check over a phantom tree reports nonsense |
| `domum-media-image-refresh.service` | `/srv/data /srv/snapshots` | takes the per-service pre-update snapshot (disabled today; correctness must not depend on that) |
| `domum-media-host-update.service` | `/srv/data /srv/snapshots` | snapshots before touching the host |
| `domum-media-weekly-report.service` | `/srv/data /srv/snapshots` | would otherwise write a report claiming services are unprotected |
| `domum-media-dr-reminder.service` | *(none, deliberately)* | appends only to `/var/log/domum-media`. A storage failure must not silence the DR reminder |

An explicit `RequiresMountsFor=` does **not** displace the one systemd derives
from `CacheDirectory=`: measured, they accumulate, as do two separate
assignments. `domum-media-backup.service` keeps its implicit
`/var/cache/domum-media-restic` entry.

## Systemd semantics, measured rather than assumed

`RequiresMountsFor=` is documented to add both `Requires=` and `After=`. Verified
on *this* host and this systemd version, using units that already use it:

| unit | declares | resulting `Requires=` | resulting `After=` |
|---|---|---|---|
| `e2scrub_reap.service` | `RequiresMountsFor=/` | `-.mount` | `-.mount` |
| `logrotate.service` | `RequiresMountsFor=/var/log` | `-.mount` | `-.mount` |

`systemd-escape -p --suffix=mount /srv/data` → `srv-data.mount`, which is live
and `active mounted`. So `RequiresMountsFor=/srv/data` yields
`Requires=srv-data.mount` and `After=srv-data.mount`: Docker is ordered after the
mount *and* refuses to start if it fails.

One caveat worth recording, because it nearly produced a wrong conclusion: in the
**user** manager the same directive expands to `After=` only, with no `Requires=`,
because a user manager cannot require a system mount unit. A disposable
`systemctl --user` probe therefore proves the parsing but **not** the requirement
semantics. The system-manager units above are the real evidence.

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

## Timer catch-up: a reboot must not fire a deleting job

Every enabled timer sets `Persistent=true`, so systemd runs a *missed* job
immediately at boot. One of them deletes: `domum-media-btrfs-snapshot.service` is
`snapshot prune`.

Measured 2026-10-05 13:54 EDT — every enabled timer had already run for its
current period, so a reboot now triggers no catch-up:

| timer | last trigger | next elapse | catch-up at boot? |
|---|---|---|---|
| `domum-media-backup.timer` | Mon 2026-10-05 02:39 | Tue 2026-10-06 02:35 | no |
| `domum-media-check.timer` | Sun 2026-10-04 03:36 | Sun 2026-10-11 03:47 | no |
| `domum-media-btrfs-snapshot.timer` | Sun 2026-10-04 04:48 | Sun 2026-10-11 04:49 | no |
| `domum-media-host-update.timer` | Mon 2026-10-05 06:10 | Mon 2026-10-12 06:11 | no |
| `domum-media-dr-reminder.timer` | Thu 2026-10-01 09:00 | Fri 2027-01-01 09:00 | no |
| `domum-media-image-refresh.timer` | — | — | `disabled`/`inactive`; a disabled timer does not start at boot |

This is a point-in-time fact and it decays. Rebooting before Sunday 03:30 keeps
all of it true; a reboot after a long power-off, or on a Sunday morning, could
fire the backup, the restic check and the prune at once. The pre-reboot capture
records these stamps so the verifier can confirm afterwards what did and did not
run.

Two things make the catch-up safer than it was: the prune enforces a retention
floor of 1 and cannot remove a service's last recovery point, and as of this
change it declares `RequiresMountsFor=/srv/data /srv/snapshots`, so it cannot run
at all against an unmounted snapshot root.

`domum-media-weekly-report.{service,timer}` are intentionally **not installed** on
the host — opt-in, per `systemd/auto-enable.timers`. That is why
`systemctl is-enabled domum-media-weekly-report.timer` reports `not-found`, and it
is not drift.

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
