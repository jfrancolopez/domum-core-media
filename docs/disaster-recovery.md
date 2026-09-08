# Disaster recovery

Recovery is driven by three artefacts:

- git checkout
- restic backup
- encrypted recovery pack

## 1. Bootstrap the host

```bash
curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash
```

## 2. Decrypt the latest recovery pack

The pack contains:

- `config/domum-media.conf`
- required `secrets/*` for enabled services and backup targets
- `state/backups/*-repo.env` repository identity metadata
- `state/immich/db_password.sha256`
- rendered compose manifest
- restore notes

Decrypt it with your age private key and restore:

- `config/domum-media.conf` to `/opt/domum-core-media/config/domum-media.conf`
- `secrets/*` to `/etc/domum-core-media/secrets/`
- `state/backups/*-repo.env` to `/var/lib/domum-media/backups/`
- `state/immich/db_password.sha256` to `/var/lib/domum-media/immich/db_password.sha256`

Set restored secrets to `0600 root:root`.

## 3. Prove the restore in scratch space

The Restic credentials and transport files from the recovery pack are
sufficient to run the backup wrapper without applying the Compose stack first.
Restore the selected snapshot into an empty scratch directory first:

```bash
sudo mkdir -p /var/lib/domum-media/restore-staging
sudo /usr/local/bin/domum-media-backup --restore latest \
  /var/lib/domum-media/restore-staging --repo cloud
```

Inspect the restored paths, validate the PostgreSQL dump with `gzip -t`, and
compare representative file hashes before selecting any live restore target.
Delete only this scratch directory after validation.

## 4. Restore persistent data

Restoring to `/` writes the snapshot's absolute paths back to their production
locations. Treat that as a deliberate disaster-recovery operation, not an
inspection command. Keep all application containers stopped while it runs.

Do not restore live PostgreSQL files as a substitute for the validated
`immich-postgres.dump.sql.gz`.

Restore from your preferred backup target. Example (NAS):

```bash
sudo /usr/local/bin/domum-media-backup --restore latest / --repo nas
```

Or from cloud:

```bash
sudo /usr/local/bin/domum-media-backup --restore latest / --repo cloud
```

Or archive:

```bash
sudo /usr/local/bin/domum-media-backup --restore latest / --repo archive
```

**Note**: Restic backups are encrypted. You need the correct `RESTIC_PASSWORD_FILE` from the recovery pack to restore. The password is saved in `secrets/restic_password_<target>` on the recovered host.

The cloud profile contains the Immich library, validated dump staging, and
encrypted recovery pack; it does not contain every path below `/srv/data`.
Other targets may have different include profiles.

The current CLI does not provide a guided PostgreSQL import command. The P0
scratch drill proves that the dump restores byte-for-byte and passes structural
validation, but a rehearsed import remains separate work. Do not start Immich
against an empty or inconsistent database.

Service-level Btrfs rollback is not currently available on production because
service paths are ordinary directories. Recreate only the existing top-level
Btrfs layout; do not improvise a service-directory migration during recovery.

## 5. Sync local config/state

Only after persistent data and the Immich password fingerprint are restored:

```bash
sudo domum-media configure --non-interactive
sudo domum-media init
```

## 6. Bring the stack up

```bash
sudo domum-media apply
```

## 7. Validate

```bash
sudo domum-media checkup
sudo domum-media doctor immich
sudo domum-media rollback list
```

## 8. Refresh the DR artefacts

```bash
sudo /usr/local/bin/domum-media-backup
sudo domum-media recovery-pack create
```

## What the recovery pack does not contain

- photos
- media libraries
- postgres data files
- restic repositories

Those remain in the backup tier only.

The accepted September 2026 repository and restore evidence are recorded in
[P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md).
