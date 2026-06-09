# Image and host update policy

The stack now separates three concerns:

1. `config/domum-media.conf` decides **which image ref** each service uses.
2. `*_AUTO_UPDATE` decides whether a service should automatically roll forward
   when that image ref points at something newer.
3. The systemd timers decide **when** to check for new container images or new
   apt packages on the host.

On top of that, services now belong to lifecycle classes:

- Class A: safe infrastructure (`traefik`, `tailscale`, `uptime-kuma`)
- Class B: stateful applications (`jellyfin`, `plex`, `navidrome`,
  `calibre-web`, `kavita`)
- Class C: bundle-managed applications (`immich`)

## Pinned vs moving tags

Pinned example:

```bash
TRAEFIK_IMAGE="traefik:v3.7.1"
TRAEFIK_AUTO_UPDATE=0
```

Moving-tag example:

```bash
TRAEFIK_IMAGE="traefik:latest"
TRAEFIK_AUTO_UPDATE=1
TRAEFIK_AUTO_UPDATE_DELAY_DAYS=7
```

For moving tags, the refresh job pulls the image daily. If the pulled image is
different from the one the container is currently running, the CLI records when
that newer image was first seen. Once the delay window expires, the service is
recreated during the next refresh run.

For Class B services, the rollout is gated by backup freshness:

- `BACKUP_POLICY="STRICT"` refuses the update if the last successful backup is
  older than `BACKUP_REQUIRED_MAX_AGE_HOURS`
- `BACKUP_POLICY="LENIENT"` warns and continues

Each rollout also takes a per-service btrfs snapshot and restores it if the
container comes back unhealthy.

## Timers

Container image refresh:

```bash
IMAGE_AUTO_UPDATE_ENABLED=1
IMAGE_AUTO_UPDATE_AT="05:15"
IMAGE_AUTO_UPDATE_RANDOMIZED_DELAY="30m"
```

Host package upgrades:

```bash
HOST_PACKAGE_AUTO_UPDATE_ENABLED=1
HOST_PACKAGE_AUTO_UPDATE_AT="Mon 05:45"
HOST_PACKAGE_AUTO_UPDATE_RANDOMIZED_DELAY="45m"
```

## Manual runs

Run the checks immediately:

```bash
sudo domum-media updates
sudo domum-media refresh-images --force
sudo domum-media host-upgrade --force
sudo domum-media immich refresh-bundle --force
```

Inspect or manually restore snapshots:

```bash
sudo domum-media rollback
```

Inspect or prune hot storage:

```bash
sudo domum-media hot status
sudo domum-media hot prune --dry-run
sudo domum-media hot prune
```

## Immich bundle management

Immich is intentionally not updated image-by-image.

Use:

```bash
sudo domum-media immich refresh-bundle
```

That command:

1. Fetches the latest Immich GitHub release metadata
2. Downloads the official release `docker-compose.yml`
3. Extracts the upstream server, ML, redis/valkey, and postgres image refs
4. Stores the candidate bundle under `/var/lib/domum-media/immich/`
5. Applies the bundle only after the delay window has passed
6. Verifies backup freshness
7. Takes a pre-update btrfs snapshot
8. Pulls and deploys the full bundle
9. Rolls back if health validation fails

## Operational advice

- Keep stateful services pinned unless you have read their release notes and
  understand the migration path.
- If you use moving tags, prefer a non-zero delay so somebody else finds the
  bad release first.
- For Immich, keep the individual image refs repo-managed and use the bundle
  refresh command instead of enabling independent image rollouts.
