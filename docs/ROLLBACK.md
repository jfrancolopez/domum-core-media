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

## Current production limitation

The current service paths are ordinary directories rather than individual
Btrfs subvolumes, so service-level snapshots are not available. The generic
rollback path also records `IMAGE_BEFORE` but does not yet restore that image
before Compose starts the service. Therefore rollback metadata is not proof of
a usable rollback point.

Do not run `rollback apply` against production until the snapshot exists and
the previous-image restoration path has been corrected. The current
plain-directory branch removes the live directory before restoration; that is
a data-risk boundary, not a safe fallback.

## Immich rollback

```bash
sudo domum-media immich rollback
```

This applies the newest available Immich rollback point.
