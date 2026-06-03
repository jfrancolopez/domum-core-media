# domum-core-media

Self-updating media + backup stack for an Intel N100 mini-PC running Debian 13.
Sibling of [`domum-core`](https://github.com/solosoyfranco/domum-core), same
philosophy, different host. Production-only — Immich (irreplaceable family
photos) lives here, so the operational rules are stricter than on the Pi.

The host is managed through a single re-runnable command:

    curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash

That command:

- Installs Docker + Tailscale + restic from pinned apt repos
- Clones or hard-resets `/opt/domum-core-media`
- Installs the `domum-media` CLI and the systemd timers (backup, check, snapshot)
- Prints the manual follow-up checklist (secrets, `init`, `apply`)

It deliberately does **not** format the data SSD — see `docs/SETUP-N100.md`.

---

## Architecture Philosophy

- Git = source of truth (`/opt/domum-core-media` is `git reset --hard`-managed)
- Host config in `/opt/domum-core-media/config/domum-media.conf`
- Secrets in `/etc/domum-core-media/secrets/` (plain files, `chmod 600`, root)
- Per-service compose fragments + an interactive `domum-media configure` wizard
- Single host Traefik with Cloudflare DNS-01 — no inbound ports
- Tailscale for remote access
- restic to multiple targets (REST/B2/NFS/FTP via rclone), with at least two copies
- btrfs subvolumes on the live tier — atomic snapshots before each `apply`,
  checksums surface bitrot loudly. Snapshots are *not* a substitute for restic;
  they protect against operator error, not disk death.

The single-disk live tier is an accepted risk. Recovery is backup-driven, not
RAID-driven — see `docs/disaster-recovery.md` for the drill (and run it before
declaring the host production).

---

## Directory Layout

Repo (managed by git, never edited on the host):

    /opt/domum-core-media/

Host config (sourced by the CLI):

    /opt/domum-core-media/config/domum-media.conf

Secrets:

    /etc/domum-core-media/secrets/

Live data (btrfs, one subvolume per service):

    /srv/data/immich/{library,postgres}
    /srv/data/jellyfin/
    /srv/data/uptime-kuma/
    /srv/data/traefik/

btrfs snapshots (read-only):

    /srv/snapshots/

Backup + check logs:

    /var/log/domum-media/

---

## First-Time Setup

Walk through these in order — they are *not* automated because they are
one-shots that are too destructive to retry safely.

1. **Provision the host.** Install Debian 13, partition + format the SSD as
   btrfs with the subvolumes documented in `docs/SETUP-N100.md`. Apply the
   power tuning in the same doc.
2. **Place secrets.** Create `/etc/domum-core-media/secrets/` and drop in
   each file listed in `docs/SETUP-CLOUDFLARE.md` and `docs/SETUP-RESTIC.md`.
   `chmod 600`, root-owned.
3. **Bootstrap.**

       curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash

4. **Configure.** Run the interactive wizard to toggle services, choose backup
   schedules, and define backup targets:

       sudo domum-media configure

   You can still hand-edit `config/domum-media.conf` if you prefer.
5. **Bring up the host.**

       sudo domum-media init
       sudo domum-media apply

6. **Initialise restic repos.** Follow `docs/SETUP-RESTIC.md` and run the
   first backup manually before trusting the timer.
7. **Run the DR drill.** Do not skip — `docs/disaster-recovery.md`. A backup
   you have not restored is a hope, not a backup.

Re-running the same curl command updates everything.

---

## CLI Cheatsheet

| Command | What it does |
| --- | --- |
| `domum-media init` | Verify host state, create dirs, validate secrets |
| `domum-media configure` | Interactive wizard for service toggles, backup targets, and schedule overrides |
| `domum-media apply` | btrfs pre-apply snapshot then `docker compose up -d --remove-orphans` |
| `domum-media status` | `docker compose ps`, last restic snapshot, btrfs snapshot list |
| `domum-media update` | `git fetch && git reset --hard origin/main && apply` |
| `domum-media logs <svc>` | `docker compose logs -f <svc>` |
| `domum-media backup [--check\| --check-deep [target] \| --restore]` | Ad-hoc backup, integrity check, or restore |
| `domum-media snapshot {create\ | list\ | prune}` | btrfs subvolume snapshot management |

---

## What Lives Where on Disk

- `compose/base.yml` — declares the shared `domum-proxy` and `domum-internal`
  networks and named volumes
- `compose/proxy/traefik.yml` + `compose/proxy/traefik/` — Traefik service +
  static & dynamic config (Cloudflare DNS-01 resolver, security headers,
  dashboard with basic auth)
- `compose/security/tailscale.yml` — Tailscale userspace-off, host networking
- `compose/photos/immich.yml` — Immich server, microservices, machine-learning,
  Redis, Postgres (pgvecto.rs). Pinned via `IMMICH_VERSION`. Library and
  Postgres data bind-mount to `/srv/data/immich/`.
- `compose/media/jellyfin.yml` — Jellyfin, pinned via `JELLYFIN_VERSION`, with
  config/cache on `/srv/data/jellyfin/` and a read-only media mount.
- `compose/monitoring/uptime-kuma.yml` — status board
- `compose/backups/restic-rest-server.yml` — **optional**; only enable if the
  NAS lives on this box. Default off.

---

## Backups in One Paragraph

`domum-media-backup` (a) takes a fresh btrfs snapshot of
`/srv/data/immich/postgres`, (b) `pg_dump`s Immich's Postgres into a staging
file alongside the immutable photo library, (c) runs `restic backup
/srv/data` to every enabled backup target, whether that target is a plain
restic repo string, an NFS-mounted repo, or an FTP archive via rclone, (d)
applies retention according to each target's configured cadence, (e) writes a
one-line status to `/var/log/domum-media/backup.log` and pings Uptime Kuma.
`domum-media-check.timer` does the weekly metadata checks and weekly-retention
pass; deep checks remain manual via `domum-media backup --check-deep`.

Restic password escrow is **not optional**: see `docs/SETUP-RESTIC.md`.

---

## Non-Goals

- No Kubernetes, no Nomad, no Portainer-as-source-of-truth
- No sops/age/Vault for secrets (gold-plating at this scale)
- No multi-host orchestration; Pi and N100 stay independent
- No experimental services on this box (production-only)
- No RAID, no ZFS — accepted single-disk live tier with backup-as-recovery
