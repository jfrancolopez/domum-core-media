# Disaster recovery

Recovery is driven by three artefacts:

- git checkout
- restic backup
- encrypted recovery pack

## What of this is PROVEN, step by step

**No fresh host has ever been recovered.** This runbook has never been executed
end to end, and the parts that have been proven were proven in isolation, on
this host, against disposable targets. Read the table before relying on any
step; a runbook that reads as validated when it is not is the defect this
project exists to correct.

| step | status | evidence |
|---|---|---|
| 1 bootstrap | **never executed** | `install.sh` is in CI (`bash -n`, shellcheck) but has never run on a bare machine |
| 2 decrypt the pack | **partly proven** | 37 packs existed 2026-10-12, newest 0 days old, off-host delivery enabled, pack correctly **not** inside the backup needed to open it. The age private key is held by the operator and is **not** on this host, so the decrypt itself is unproven — and 37 copies are 37 unopenable files without it |
| 3 scratch restore | **proven** | the Immich dump restores from the repository and revalidates (`verify-restore`); a 12-file sample of originals restores and compares byte-for-byte, accumulating across runs |
| 4 restore to `/` | **never executed** | nothing has written a snapshot back to production paths |
| database import | **proven, disposable only** | `verify-db-restore`, 2026-10-11: 23,033 assets into 61 tables under `ON_ERROR_STOP=1`, in a `--network none` tmpfs instance |
| Immich opens it | **proven** | `immich-phase-a`, 2026-10-11: migrations ran, `No schema drift detected`, a recovered user authenticated, counts matched per media type |
| Immich serves originals | **proven for 8 of 23,033** | `immich-phase-b`, 2026-10-12: 8 restored originals served with **bytes identical**, across jpeg/heic/png/raw/video and a live-photo pair |
| 5-6 configure, init, apply | **never executed on a recovered host** | these are the normal production commands; nothing has run them against restored state |
| 7 validate | **partly** | `checkup` runs here routinely; it has never been run against a recovery |
| whole-library restore | **never executed** | ~130 GiB. Nothing on this host is `FULL RECOVERY VERIFIED`, and this runbook does not make it so |

So the honest summary: **the backup is proven readable, the database is proven
importable, and the application is proven able to open and serve what was
restored — on this machine.** The step that has never been taken is putting all
of it on a different machine.

The five recovery levels and what each requires:
`UNKNOWN < CONFIGURED < BACKED UP < RESTORE TESTED < FULL RECOVERY VERIFIED`
(`domum-media-backup dr-status`).

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

**Only `cloud` has snapshots. Measured, 2026-11-02.** `BACKUP_TARGETS` lists
`nas cloud archive`, and `backup_target_default_enabled` returns 1 for `nas` —
so `nas` reads as enabled from the defaults alone. It is not: across **107
consecutive nightly runs** the rotated backup log contains `restic backup ->
cloud` 107 times and **zero** occurrences of `nas` or `archive` in any form,
there is no network mount of any kind on this host, and no `/srv/nas*` exists.
`nas` is a placeholder for hardware that does not exist; `archive` has cadence
`none`.

During a recovery, restore from `cloud`:

```bash
sudo /usr/local/bin/domum-media-backup --restore latest / --repo cloud
```

Before trusting any other target, check that it has a snapshot at all:

```bash
sudo /usr/local/bin/domum-media-backup --snapshots      # latest per target
```

A target with no snapshot is not a fallback. Offering `nas` as the primary
example is how a recovery stalls on a repository that was never written.

**Note**: Restic backups are encrypted. You need the correct
`RESTIC_PASSWORD_FILE` from the recovery pack to restore. The password is saved
in `secrets/restic_password_<target>` on the recovered host.

### What the cloud target does NOT contain

This is the most important thing to know before starting, and it decides what
the recovered host will be missing. The cloud target is **immich-only by
design** — three roots:

```
/srv/data/immich/library
/srv/data/immich/backup-staging
<state root>/recovery-pack
```

So a fresh-host restore from `cloud` brings back **the photo library, the
validated PostgreSQL dump and the recovery pack, and nothing else**. In
particular these are **NOT COVERED**:

| not in the cloud target | consequence on a fresh host |
|---|---|
| `/srv/data/{plex,jellyfin,kavita,navidrome,calibre-web}` | all five media services come up as **fresh installs** — no libraries, no users, no watch state |
| `/srv/data/backups/images` (the exact-image archives) | the recorded image identity for every recovery point is unobtainable |
| `/srv/media` | deliberate: replaceable/reacquirable media |

That is a KNOWN, ACCEPTED limitation, not an oversight. It also means **the
five services' state exists on exactly one device** — the SSD that also holds
every snapshot and every `.premigration` copy — so losing that device loses it.
`domum-media storage capture-state` exists to capture the 8.90 MiB that
matters, and **no backup target includes those captures yet**; activating one
is an operator decision.

Read `docs/HIDDEN-RECOVERY-DEPENDENCIES.md` before step 4. It lists the twelve
things a recovery needs that no backup list mentions — among them the six
13-byte `.immich` markers without which Immich's microservices worker dies, the
deprecated `pgvecto.rs` extension the dump requires, and jellyfin's 0600
DataProtection keys.

### Btrfs layout on the recovered host

**FIVE services are real Btrfs subvolumes in production** — jellyfin
(2026-09-25), kavita and navidrome (2026-09-29), plex (2026-10-06) and
calibre-web (2026-10-09) — each with a verified read-only proof snapshot. A
fresh host restored from a backup has **ordinary directories**, because a
restic restore writes files, not subvolumes.

Recreate the top-level Btrfs layout (`/srv/data`, `/srv/snapshots`). Do **not**
improvise a service-directory migration during recovery:
`storage migrate-subvolume` is a separate, gated operation with its own proof
and `.premigration` retention, and running it under recovery pressure is how a
migration goes wrong. Per-service snapshot protection will read DEGRADED until
it is done deliberately, and that is the correct report.

### The PostgreSQL dump

There is no guided import into **production**. There is a proven import into a
**disposable** instance, and it is how to establish that the dump is usable
before Immich is allowed near it:

```bash
sudo /usr/local/bin/domum-media-backup verify-db-restore cloud
```

Measured 2026-10-11 against the real dump: 20 s, exit 0, zero stderr, 23,033
assets into 61 tables, under `ON_ERROR_STOP=1`. It uses the image production
uses, read from `docker inspect`, because the dump declares
`CREATE EXTENSION vectors WITH SCHEMA vectors` and only `pgvecto-rs` provides
it. It is `--network none`, tmpfs PGDATA, no bind mount, removed by a trap.

Do not start Immich against an empty or inconsistent database.

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
