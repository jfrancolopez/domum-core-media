# Immich on domum-core-media

This page covers everything specific to running Immich here: how the database
is bootstrapped, where the secrets live, why the DB password is locked after
the first apply, how bundle-managed upgrades work, and how to rotate or reset
it cleanly.

For the underlying compose definition see `compose/photos/immich.yml`. For the
CLI internals see `bin/domum-media`.

---

## 1. Initial bootstrap

On a host with no prior Immich state:

1. `sudo domum-media configure` walks you through the wizard. When it reaches
   the Immich section it generates `immich_db_password` and `immich_jwt_secret`
   in `/etc/domum-core-media/secrets/` (mode 0600, owned by root) unless you
   type values explicitly.
2. `sudo domum-media apply` reads those file-backed secrets, trims only trailing
   newlines, exports them into the compose environment as `IMMICH_DB_PASSWORD`
   and `IMMICH_JWT_SECRET`, and validates `docker compose config` before it
   ever calls `docker compose up`.
3. The `immich_postgres` container starts with no existing data directory at
   `/srv/data/immich/postgres`, so Postgres runs `initdb` and bakes
   `POSTGRES_PASSWORD` (= the secret you just generated) into the database.
4. Once the container reports healthy and `/srv/data/immich/postgres/PG_VERSION`
   exists, `apply` records the SHA-256 of the password secret to
   `/var/lib/domum-media/immich/db_password.sha256`. That file is the
   "fingerprint" used to detect drift on every subsequent apply.

That is the only path where Immich's DB password is allowed to be chosen.

---

## 2. Bundle-managed updates

Immich is treated as a Class C workload. The app server, machine-learning,
database, and redis/valkey images move together from the official upstream
release bundle.

Use:

```bash
sudo domum-media immich refresh-bundle
```

That command fetches the latest release metadata from GitHub, downloads the
official release `docker-compose.yml`, extracts the candidate image set,
stores it under `/var/lib/domum-media/immich/bundle-candidate.env`, respects
the configured delay window, verifies backup freshness, snapshots the Immich
subvolume, deploys the bundle, and restores the previous snapshot if health
validation fails.

---

## 3. Secret lifecycle

| File | Owner | Purpose |
| --- | --- | --- |
| `/etc/domum-core-media/secrets/immich_db_password` | root, 0600 | Source of truth for `POSTGRES_PASSWORD` and Immich's `DB_PASSWORD`. |
| `/etc/domum-core-media/secrets/immich_jwt_secret` | root, 0600 | Immich session signing key. Rotating only invalidates sessions; no DB-side coupling. |
| `/var/lib/domum-media/immich/db_password.sha256` | root, 0600 | Fingerprint of the secret as it was at first apply. Used by `apply` to detect drift. |
| `/srv/data/immich/postgres/` | postgres uid (container) | Postgres data directory. Presence of `PG_VERSION` here = "already initialized". |
| `/srv/data/immich/library/` | container uid | Photo blobs. Untouched by `reset-db`, but unusable without a matching database. |

`domum-media configure` is the only thing that writes the password file unless
you deliberately edit the file yourself as root. `domum-media apply` reads the
files, exports the values into the compose environment, and refuses deployment
if either secret resolves empty or if the rendered compose config does not show
`immich_server.DB_PASSWORD`, `immich_server.JWT_SECRET`, and
`immich_postgres.POSTGRES_PASSWORD` as set. The CLI never logs the raw secret
values.

These secrets are intentionally **not** committed anywhere in git. The repo is
reset-managed; the host secret directory is not.

---

## 4. Why the DB password is locked after the first boot

Postgres applies `POSTGRES_PASSWORD` exactly once — during the very first
`initdb`. From then on every container restart logs:

> PostgreSQL Database directory appears to contain a database; Skipping
> initialization

…and keeps the password Postgres was born with. If you change
`/etc/domum-core-media/secrets/immich_db_password` after that point, Immich
reads the *new* value, Postgres still expects the *old* one, and the Immich
server container loops on:

> PostgresError: password authentication failed for user "postgres"

To prevent the silent breakage, `apply` computes the SHA-256 of the current
secret and compares it to the fingerprint recorded at first successful boot. If
they disagree, `apply` refuses to run and prints a recovery checklist instead
of restarting services into a broken state.

(`apply` does not try to rotate the DB password against a running Postgres.
That dance — `ALTER USER` while the app is online — is intentionally not in
scope. Recovery is by restoration or by wipe, both spelled out below.)

---

## 5. Password rotation procedure

There is no in-place rotation. To adopt a new password you wipe Postgres's
data directory and let `apply` bootstrap a fresh database against the new
secret.

```bash
# 1. Sanity: confirm you have working restic backups (photos are in
#    /srv/data/immich/library; Immich's DB sidecar dump rides along).
sudo domum-media backup --check

# 2. Destructive: tear down Immich Postgres + drop the fingerprint.
sudo domum-media immich reset-db
# Type exactly: wipe immich

# 3. Pick the new password.
sudo domum-media configure
# Type a new value at the "Immich database password" prompt.

# 4. Re-bootstrap.
sudo domum-media apply
```

`reset-db` calls `apply` for you at the end. That last manual `apply` is only
needed if you ran `configure` again after `reset-db` to change the password.

**The photo library at `/srv/data/immich/library` is not deleted by
`reset-db` unless you pass `--wipe-uploads`.** The blobs survive, but Immich's
database has no record of them until you re-import (Immich UI →
Administration → Jobs → External Library re-scan, or `immich-cli` upload).
Plan accordingly.

---

## 6. Destructive reset (for test environments)

Same command, different framing. When you are iterating on the install and
just want a clean slate:

```bash
sudo domum-media immich reset-db
# wipe immich
```

What it does, in order:

1. Loads config and exports compose env.
2. Refuses if `ENABLE_IMMICH != 1`.
3. Prompts for the literal string `wipe immich`. Anything else aborts with no
   side effects.
4. `compose stop` + `compose rm -f` against `immich_server`,
   `immich_machine_learning`, `immich_postgres`, `immich_redis` (best-effort —
   ignores errors so a half-started stack still resets cleanly).
   `immich_redis` has no persisted host data in this stack, so container
   removal is the only cache cleanup needed.
5. Takes a `pre-immich-reset` btrfs snapshot of the data subvolumes.
6. `rm -rf /srv/data/immich/postgres`.
7. Optionally `rm -rf /srv/data/immich/library` if you passed
   `--wipe-uploads`.
8. `rm -f /var/lib/domum-media/immich/db_password.sha256`.
9. `exec domum-media apply` — runs through validation and brings the stack
   back up; Postgres re-runs `initdb` with whatever value
   `/etc/domum-core-media/secrets/immich_db_password` holds at that moment.

The btrfs snapshot from step 5 is your local undo button. To restore:

```bash
ls /srv/snapshots/ | grep pre-immich-reset
# pick the matching snapshot dir
sudo btrfs subvolume snapshot \
    /srv/snapshots/postgres-YYYYMMDD-HHMMSS-pre-immich-reset \
    /srv/data/immich/postgres
sudo domum-media apply
```

## 7. Doctor / diagnostics

Run:

```bash
sudo domum-media doctor immich
```

It checks, without printing any raw secret value:

- secret files exist
- secret files are non-empty after trimming trailing newlines
- rendered compose receives non-empty `DB_PASSWORD`, `POSTGRES_PASSWORD`, and
  `JWT_SECRET`
- `DB_PASSWORD` and `POSTGRES_PASSWORD` come from the same secret file
- the DB password fingerprint matches the current secret
- Immich containers exist and report healthy/running status
- current container image refs
- current bind mounts / mounted paths

Use this first when debugging auth failures or after changing secret files.

---

## 8. Troubleshooting

### `PostgresError: password authentication failed for user "postgres"` on `immich_server`

This is the symptom this page exists to prevent. `domum-media apply` should
have refused before it got here. If it didn't (e.g. you ran `docker compose
up` directly), `apply` will catch it on the next run with:

```
[domum-media] ERROR: Immich Postgres password mismatch.
```

Follow the on-screen checklist: either restore the previous password via
`configure` or run `immich reset-db`.

### `apply` refuses with `Immich Postgres data exists ... but the secret ... is missing.`

Someone deleted `/etc/domum-core-media/secrets/immich_db_password` while the
database was still alive. Recover the file from your secret manager / DR
escrow and re-run `apply`. If you genuinely lost it, the only path forward is
`immich reset-db` (you will lose Immich's database — photo blobs stay).

### `apply` refuses because the fingerprint file is missing

The Postgres data directory already exists, but there is no trustworthy record
of which password initialized it. `apply` now refuses instead of guessing.
Restore the original fingerprint from backup, or run `sudo domum-media immich
reset-db` and re-bootstrap cleanly.

---

## 9. Related files

- `bin/domum-media` — `load_immich_secret_exports`,
  `validate_immich_compose_config`, `validate_immich_db_password_state`,
  `doctor_immich`, `immich_reset_db`, `write_immich_db_password_fingerprint`.
- `compose/photos/immich.yml` — service definitions and the postgres bind
  mount.
- `config/domum-media.conf.example` — `IMMICH_DB_USERNAME` /
  `IMMICH_DB_DATABASE_NAME` (the password is *not* in this file — it lives in
  the secret file).
- `docs/disaster-recovery.md` — the higher-level recovery drill that this
  page slots underneath.
