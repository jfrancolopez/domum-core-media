# Checkup

`domum-media checkup` is a read-only health sweep.

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

## Verifying backups in detail

To see exactly what would be backed up for a target:

```bash
sudo domum-media backup plan <target>
```

To verify repository health (connectivity, snapshots, metadata):

```bash
sudo domum-media backup verify <target>
```
