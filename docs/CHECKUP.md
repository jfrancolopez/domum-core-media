# Checkup

`domum-media checkup` is a non-destructive health sweep. It may create missing
runtime-state directories and test configured remote authentication; it does
not apply updates, alter application data, or run backup retention.

## Commands

```bash
sudo domum-media checkup
sudo domum-media checkup --json
```

## Checks

- config sanity
- backup-target presence
- required secret files (passwords, SSH keys)
- per-target authentication (SSH key status for SFTP)
- per-target repository initialization (repo ID stored)
- per-target encryption (restic client-side)
- recovery-pack age
- service health
- last backup freshness
- disk usage
- pending update candidates
- dangling images / exited containers
- reboot-required state
- available apt updates

The command exits with code `1` when any Critical item is present.

The current command does not prove that service paths are Btrfs subvolumes or
that local service snapshots are usable. Until that probe is implemented,
consult [P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) and treat local service
snapshot protection as degraded.

## Verifying backups in detail

To see exactly what would be backed up for a target:

```bash
sudo domum-media backup plan <target>
```

To verify repository health (connectivity, snapshots, metadata):

```bash
sudo domum-media backup verify <target>
```
