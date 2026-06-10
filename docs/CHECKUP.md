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
- required secret files
- recovery-pack age
- service health
- last backup freshness
- disk usage
- pending update candidates
- dangling images / exited containers
- reboot-required state
- available apt updates

The command exits with code `1` when any Critical item is present.
