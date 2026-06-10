# Update policy

`domum-media` manages updates through delayed rollout windows, backup gates,
health checks, rollback metadata, and update-history logs.

## Classes

### Class A

- `traefik`
- `tailscale`
- `uptime-kuma`
- optional `restic-rest-server`

Default delay: 7-14 days.

### Class B

- `jellyfin`
- `plex`
- `navidrome`
- `calibre-web`
- `kavita`

Default delay: 21 days.
These services take a pre-update btrfs snapshot and honor `BACKUP_POLICY`.

### Class C

- `immich`

Immich is bundle-managed only. The server, machine-learning, Redis/Valkey, and
Postgres image refs move together.

### Class D

- Debian security patches via `unattended-upgrades`
- scheduled general package upgrades via `domum-media host-upgrade`

## Delay re-check logic

For Class A and B services:

1. pull the tracked image
2. compare it to the running image ID
3. if different, store the candidate and first-seen timestamp
4. once the delay expires, compare again
5. if upstream moved during the wait, reset the delay and log `delay_reset`
6. if unchanged, apply the update

Use:

```bash
sudo domum-media updates check
sudo domum-media updates apply
sudo domum-media updates history
```

## Backup policy

```bash
BACKUP_POLICY=BALANCED
BACKUP_REQUIRED_MAX_AGE_HOURS=48
AUTO_ROLLBACK_ENABLED=1
```

- `STRICT`: require a fresh backup for all stateful services
- `BALANCED`: require a fresh backup for Immich, warn-and-proceed for media apps
- `LENIENT`: warn-and-proceed for all stateful services

## Immich bundle

```bash
IMMICH_BUNDLE_AUTO_UPDATE=1
IMMICH_BUNDLE_DELAY_DAYS=21
IMMICH_BUNDLE_ROLLBACK_ENABLED=1
```

Useful commands:

```bash
sudo domum-media immich check-bundle
sudo domum-media immich apply-bundle
sudo domum-media immich rollback
```

## Host updates

Security patches are installed through Debian Security only. Docker packages are
excluded from unattended upgrades and remain in the manual/scheduled
`host-upgrade` tier.

See [SECURITY-PATCHES.md](SECURITY-PATCHES.md).
