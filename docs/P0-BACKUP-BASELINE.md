# P0 backup and recovery baseline

This document records the production acceptance state established in September
2026. It is an operational record, not a generic installation guide.

## Why P0 was required

The historical cloud configuration encoded Hetzner's SFTP port in the remote
path. That addressed unintended remote directories rather than one stable
repository. Restic failures were also swallowed by the wrapper in one code
path, so repository probes could be misclassified as successful.

P0 separated port `23` into Restic's explicit `sftp.command`, selected one
canonical remote path, fixed exit-status propagation, and pinned the repository
identity. Historical repositories were deliberately preserved; no migration,
prune, repair, or deletion was performed.

## Accepted cloud repository

```text
Repository: sftp:u612125@u612125.your-storagebox.de:/home/domum-core-media-restic
Repository ID: c1d39ac9c8296eb6c7daae479bec239c79553be69383644cf25dccc5beb7c50d
SFTP port: 23, supplied separately by the explicit SSH command
```

The repository identity is pinned in
`/var/lib/domum-media/backups/cloud-repo.env`. The encrypted recovery pack
contains a validated copy of this metadata so a rebuilt host can verify that it
opened the intended repository.

The old remote locations `/home/23:/domum-core-media-restic` and
`/home/domum-core-restic` are historical evidence. They must not be adopted,
modified, or deleted without a separate operator-approved cleanup plan.

## Implemented safeguards

- Immich PostgreSQL dumps are written to a same-directory temporary file.
- Both `pg_dump` and gzip status are checked.
- gzip integrity, minimum size, and the PostgreSQL completion footer are
  validated before an atomic rename replaces the previous dump.
- Restic command failures retain their real exit status.
- SFTP uses a dedicated key, pinned host key, public-key-only authentication,
  explicit port, and the restricted SFTP subsystem.
- Recovery packs include config, required secrets, repository identity
  metadata, the Immich database-password fingerprint, rendered Compose output,
  a manifest, and restore instructions.
- Recovery-pack plaintext staging has interruption cleanup; encrypted output is
  written atomically with mode `0600`.
- Scheduled backup and check services share a systemd-managed Restic cache at
  `/var/cache/domum-media-restic`, mode `0700`.
- The scheduled backup timeout is 18 hours; the check timeout is 4 hours.

Relevant merged changes:

- PR #1: atomic dump, canonical SFTP validation, and recovery-pack corrections
- PR #2: Restic exit-status propagation
- PR #3: repository identity metadata in the recovery pack
- PR #4: scheduled Restic cache, backup timeout, and systemd CI validation

## Production acceptance evidence

The first accepted snapshot is:

```text
Snapshot ID: 18aa5de8dda2274e59e64dbb227f56b36ecff2c341eb668a4ce427f2325cf897
Snapshot time: 2026-09-04T15:57:22-04:00
Files processed: 63,547
Data processed: 210.371 GiB
Data stored: 201.809 GiB
```

Restic's metadata/integrity check found no errors. A scratch restore outside all
live paths restored and byte-verified:

- the validated Immich PostgreSQL dump;
- the encrypted recovery pack; and
- a representative Immich video.

The scratch directory was removed after validation. This proves repository
access and representative file recovery. It does not replace a full Restic
`--read-data` scan or a rehearsed PostgreSQL import.

The first unattended run using the deployed cache/timeout change is scheduled
for September 9, 2026. Its result remains the final scheduled-runtime
acceptance item and must be appended here after verification.

## Backup scope

The accepted cloud snapshot protects:

- `/srv/data/immich/library`;
- `/srv/data/immich/backup-staging`; and
- `/var/lib/domum-media/recovery-pack`.

It intentionally excludes `/srv/media`, live PostgreSQL storage, transcodes,
caches, and reacquirable media. Other Restic targets may have different include
profiles; never infer their coverage from the cloud profile.

## Known limitation: local snapshots

`/srv/data` and `/srv/snapshots` are Btrfs subvolumes, but the current service
paths below `/srv/data` are ordinary directories. The service snapshot code
requires each service path to be a subvolume and skips ordinary directories.

Therefore the current production truth is:

```text
Local service snapshot protection: DEGRADED / NOT AVAILABLE
```

Do not claim pre-update local rollback protection until a separately approved
migration or snapshot redesign has been completed and tested. Restic backup
protection remains valid and independent of this limitation.

## Update posture

`domum-media-image-refresh.timer` remains disabled and inactive. Image
discovery/staging must remain separate from deployment, and no staged image or
application update should be deployed until backup visibility and rollback
gates report truthfully.
