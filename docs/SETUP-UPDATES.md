# Update policy

The stack uses delayed automatic updates with backup gating and automatic
rollback. The goal: stay current without reckless changes. You intervene only
when something goes wrong.

## Update classes

Services are classified by risk. The class controls the default delay and
whether a snapshot + backup is required before updating.

### Class A — infrastructure (low-risk)

Services: `traefik`, `tailscale`, `uptime-kuma`

- Auto-update allowed
- Delay: 7–14 days
- Health check required
- No data snapshot required

### Class B — stateful media apps

Services: `jellyfin`, `plex`, `navidrome`, `calibre-web`, `kavita`

- Auto-update allowed
- Delay: 21 days
- btrfs snapshot before update (automatic)
- Backup freshness gate (BACKUP_POLICY=STRICT by default)
- Health check required
- Automatic rollback if health check fails

### Class C — bundle-managed

Service: `immich`

Immich is updated only as a matched release bundle. The bundle manager fetches
the official release compose file, extracts the server, machine-learning,
Redis/Valkey, and Postgres image refs, and deploys them atomically.

**Never update Immich Postgres or Redis/Valkey independently outside the
bundle.** Doing so risks breaking migrations.

- Single delay: `IMMICH_BUNDLE_DELAY_DAYS` (default: 21 days)
- Snapshot before update (automatic)
- Backup freshness gate
- Full health check (HTTP + DB + Redis)
- Automatic rollback if health check fails

### Class D — host OS / packages

Two tiers:

1. **Security patches (automatic)**: `unattended-upgrades` applies Debian
   Security updates immediately. Docker CE is excluded — it is in tier 2.
2. **General upgrades (scheduled, optional)**: `domum-media host-upgrade`
   upgrades Docker CE, Tailscale, restic, rclone, and other host tooling on a
   configured schedule.

See `docs/SECURITY-PATCHES.md` for details.

---

## How the delay window works

For Class A and B services, the image refresh timer runs daily:

1. Pull the image. If the digest matches the running container → no-op.
2. If different → record the new image and the current timestamp.
3. On subsequent runs, check if the delay window has elapsed.
4. When the delay window expires, **re-pull** to confirm upstream hasn't moved
   again. If a newer image appeared during the wait → reset the delay (new
   delay period starts). If same → proceed to apply.
5. Backup gate: refuse update if last successful backup is older than
   `BACKUP_REQUIRED_MAX_AGE_HOURS` (when `BACKUP_POLICY=STRICT`).
6. Create a btrfs snapshot (Class B services).
7. Apply the update.
8. Health check: if the container comes back unhealthy, automatically restore
   the snapshot.

For Immich (Class C), the same re-check logic applies to the bundle release
date. See below.

---

## Config reference

### Class A / B per-service image policy

```bash
# Use a moving tag (auto-update will track it):
TRAEFIK_IMAGE=traefik:latest
TRAEFIK_AUTO_UPDATE=1
TRAEFIK_AUTO_UPDATE_DELAY_DAYS=14

# Pin to a specific version (auto-update disabled):
TRAEFIK_IMAGE="traefik:v3.7.1"
TRAEFIK_AUTO_UPDATE=0
```

All Class B services follow the same pattern with their respective prefix.

### Class C — Immich bundle

```bash
IMMICH_UPDATE_MODE=bundle
IMMICH_BUNDLE_AUTO_UPDATE=1
IMMICH_BUNDLE_DELAY_DAYS=21
IMMICH_BUNDLE_ROLLBACK_ENABLED=1
```

The four image ref vars below are written automatically by the bundle manager
after each successful apply. Do not edit them manually:

```bash
IMMICH_SERVER_IMAGE=...
IMMICH_MACHINE_LEARNING_IMAGE=...
IMMICH_REDIS_IMAGE=...
IMMICH_POSTGRES_IMAGE=...
```

### Backup gate

```bash
BACKUP_POLICY=STRICT           # STRICT | LENIENT
BACKUP_REQUIRED_MAX_AGE_HOURS=48
```

`STRICT` refuses stateful updates if the last successful backup is older than
`BACKUP_REQUIRED_MAX_AGE_HOURS`. `LENIENT` warns and continues.

### Update scheduler

```bash
IMAGE_AUTO_UPDATE_ENABLED=1
IMAGE_AUTO_UPDATE_AT="05:15"
IMAGE_AUTO_UPDATE_RANDOMIZED_DELAY="30m"
```

---

## Manual runs

```bash
# Check all candidates without applying
sudo domum-media updates check

# Force immediate evaluation + apply all due updates
sudo domum-media refresh-images --force

# Immich bundle — check and apply
sudo domum-media immich check-bundle
sudo domum-media immich apply-bundle

# Host packages
sudo domum-media host-upgrade --force
```

---

## Rollback

If an update fails health validation, the stack automatically restores the
pre-update btrfs snapshot.

To manually roll back after a successful update:

```bash
sudo domum-media rollback list
sudo domum-media rollback apply <id>
```

For Immich specifically:

```bash
sudo domum-media immich rollback
```

See `docs/ROLLBACK.md` for the full rollback reference.
