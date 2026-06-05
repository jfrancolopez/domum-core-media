# Disaster Recovery Runbook

> **A backup you have not restored is a hope, not a backup.**

This procedure assumes the N100 is dead and you are rebuilding on new
hardware (or the same hardware after a wipe).

**Target wall-clock: ≤ 4 hours**, dominated by the photo library restore from
the NAS repo. Cloud-only restore will be much longer (depends on B2 bandwidth
and dataset size).

## Pre-requisites you must have outside the burning house

- The repo URL: `https://github.com/jfrancolopez/domum-core-media`
- Both restic passwords (sealed envelope + cloud password manager)
- Cloudflare API token (or the ability to mint a new one)
- Immich DB password and JWT secret (regenerate JWT secret if lost; **DB
  password must match what's in the dump**)
- Tailscale auth or operator login
- Tested NAS reachability OR a working B2 account

## Procedure

### 1. New host basics

Install Debian 13 + follow `SETUP-N100.md` to format the SSD and lay out the
btrfs subvolumes. **Do not** reuse the old disk image — start clean.

### 2. Bootstrap

```
curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash
```

This installs Docker, Tailscale, restic, the CLI, and the systemd timers.

### 3. Re-create config and secrets

Run `sudo domum-media configure` first if you want the wizard to rebuild the
common secrets, image refs, and timer settings. Otherwise, manually restore
`config/domum-media.conf` plus every file listed in `SETUP-RESTIC.md`,
`SETUP-CLOUDFLARE.md`, and `SETUP-TRAEFIK.md`.

### 4. Restore the data tier from restic

Try NAS first; cloud is the fallback.

```
sudo /usr/local/bin/domum-media-backup --restore latest /srv/data --repo nas
# OR if NAS is also dead:
sudo /usr/local/bin/domum-media-backup --restore latest /srv/data --repo cloud
```

The restore lands under `/srv/data/<original-path>` because restic preserves
absolute paths. Move files into place if your subvolume layout has changed.

Verify the photo library directory contents look right:

```
ls /srv/data/immich/library | wc -l
du -sh /srv/data/immich
```

### 5. Restore the Postgres dump

The restic backup contains the `pg_dump` at
`/srv/data/immich/backup-staging/immich-postgres.dump.sql.gz`. The bind-mount
`/srv/data/immich/postgres` is empty (or a stale snapshot we ignore).

Start *only* Postgres + Redis, then load the dump:

```
sudo /usr/local/bin/domum-media apply
sudo docker compose -f /opt/domum-core-media/compose/photos/immich.yml stop immich_server immich_machine_learning
gunzip -c /srv/data/immich/backup-staging/immich-postgres.dump.sql.gz | \
  sudo docker compose -f /opt/domum-core-media/compose/photos/immich.yml exec -T immich_postgres \
    psql -U postgres -d immich
sudo docker compose -f /opt/domum-core-media/compose/photos/immich.yml start immich_server immich_machine_learning
```

### 6. Bring everything up

```
sudo /usr/local/bin/domum-media apply
```

### 7. Validate

- Immich web UI loads over Tailscale (`https://photos.<DOMUM_DOMAIN>`)
- Login works
- Photo count is what you expect (compare to the last `du -sh` you remember)
- Recent uploads (last 7 days) are present — these prove the dump was fresh
- `restic check` still passes on both repos

### 8. Run a fresh backup

Don't trust the next scheduled timer. Force one immediately so you have a
known-good post-restore snapshot:

```
sudo /usr/local/bin/domum-media-backup
```

## Drill schedule

Run this end-to-end on a scratch VM **before** declaring the system
production, and **annually** thereafter. The
`domum-media-dr-reminder.timer` pings you quarterly — treat at least one of
those four pings per year as a real drill, not a snooze.

Log the drill results below.

### Drill log

| Date | Outcome | Notes |
| --- | --- | --- |
| YYYY-MM-DD | | |
