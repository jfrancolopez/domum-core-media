# domum-core-media

Self-hosted media stack for Debian 13 with:

- Compose-managed services
- delayed container updates
- Immich bundle management
- btrfs snapshots + rollback metadata
- restic multi-target backups
- unattended Debian security patches
- encrypted recovery-pack generation

## Bootstrap

```bash
curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash
sudo domum-media configure
sudo domum-media init
sudo domum-media apply
sudo domum-media recovery-pack create
```

The installer manages `/opt/domum-core-media` as a resettable git checkout and
installs `domum-media` plus the systemd timers.

## Architecture

- Git repo: `/opt/domum-core-media`
- Live config: `/opt/domum-core-media/config/domum-media.conf`
- Secrets: `/etc/domum-core-media/secrets`
- Durable data: `/srv/data`
- Media libraries: `/srv/media`
- Snapshots: `/srv/snapshots`
- Runtime state: `/var/lib/domum-media`
- Logs: `/var/log/domum-media`

Workloads are grouped into update classes:

- Class A: Traefik, Tailscale, Uptime Kuma
- Class B: Jellyfin, Plex, Navidrome, Calibre-Web, Kavita
- Class C: Immich bundle
- Class D: host OS packages

## Update model

- `domum-media refresh-images` tracks candidate digests and enforces delay windows.
- If upstream moves during the delay, the timer resets and the event is logged.
- Stateful services honor `BACKUP_POLICY`:
  `STRICT`, `BALANCED`, or `LENIENT`.
- Successful updates write rollback metadata and update-history entries.
- Immich is updated only through the matched upstream release bundle.

## Core commands

See [docs/CLI-CHEATSHEET.md](docs/CLI-CHEATSHEET.md) for the full list.

```bash
sudo domum-media status --counts
sudo domum-media updates check
sudo domum-media updates apply
sudo domum-media updates history
sudo domum-media immich check-bundle
sudo domum-media immich apply-bundle
sudo domum-media rollback list
sudo domum-media checkup
sudo domum-media cleanup images --dry-run
sudo domum-media recovery-pack status
```

## Recovery posture

Recovery depends on:

- this git repo
- restic backup targets
- the encrypted recovery pack

The recovery pack contains only small critical files: config, secrets, rendered
manifests, and restore instructions. It does not include photo, media, or
database payloads.

Use the runbook in [docs/disaster-recovery.md](docs/disaster-recovery.md).

## Additional docs

- [docs/SETUP-UPDATES.md](docs/SETUP-UPDATES.md)
- [docs/SETUP-IMMICH.md](docs/SETUP-IMMICH.md)
- [docs/SETUP-RESTIC.md](docs/SETUP-RESTIC.md)
- [docs/ROLLBACK.md](docs/ROLLBACK.md)
- [docs/CHECKUP.md](docs/CHECKUP.md)
- [docs/SECURITY-PATCHES.md](docs/SECURITY-PATCHES.md)
