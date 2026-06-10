# CLI cheat sheet

## Daily operations

```bash
sudo domum-media status
sudo domum-media status --counts
sudo domum-media logs <service>
sudo domum-media checkup
```

## Updates

```bash
sudo domum-media updates summary
sudo domum-media updates check
sudo domum-media updates apply
sudo domum-media updates history
sudo domum-media host-upgrade --force
```

## Immich

```bash
sudo domum-media immich check-bundle
sudo domum-media immich apply-bundle
sudo domum-media immich rollback
sudo domum-media doctor immich
```

## Rollback

```bash
sudo domum-media rollback list
sudo domum-media rollback show <id>
sudo domum-media rollback apply <id>
sudo domum-media rollback apply <id> --dry-run
```

## Backups

```bash
sudo /usr/local/bin/domum-media-backup
sudo /usr/local/bin/domum-media-backup --check
sudo /usr/local/bin/domum-media-backup --check-deep [target]
sudo /usr/local/bin/domum-media-backup --restore <snapshot> <target> [--repo target]
sudo domum-media doctor backups
```

## Recovery pack

```bash
sudo domum-media recovery-pack create
sudo domum-media recovery-pack create --no-email
sudo domum-media recovery-pack status
sudo domum-media doctor secrets
```

## Cleanup

```bash
sudo domum-media cleanup summary
sudo domum-media cleanup images --dry-run
sudo domum-media cleanup images --confirm
sudo domum-media cleanup hot --dry-run
sudo domum-media cleanup snapshots --dry-run
sudo domum-media cleanup snapshots --confirm
```
