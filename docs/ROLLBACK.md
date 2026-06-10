# Rollback

Each snapshot-backed update writes a rollback entry under
`/var/lib/domum-media/rollback/`.

## Inspect rollback points

```bash
sudo domum-media rollback list
sudo domum-media rollback show <id>
```

Fields include:

- logical service
- event type
- snapshot path
- image before / after
- timestamp
- status

## Apply a rollback

```bash
sudo domum-media rollback apply <id>
sudo domum-media rollback apply <id> --dry-run
```

Applying a rollback:

1. stops the affected compose services
2. restores the recorded snapshot
3. starts the services again
4. marks the rollback entry as consumed
5. writes an update-history event

## Immich rollback

```bash
sudo domum-media immich rollback
```

This applies the newest available Immich rollback point.
