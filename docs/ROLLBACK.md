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
the previous-image restoration path has been corrected.

The restore itself no longer deletes live state. Whatever is at the service
path is **moved aside** to `<path>.rollback-<timestamp>` first, whatever its
type, and if the restore then fails it is **put back**. The preserved copy is
deliberately not removed automatically — it is the only way back if the
restored state turns out to be wrong. Remove it once satisfied.

The snapshot model itself — event-driven creation, time-driven pruning, and
why the weekly unit only prunes — is described in
[SNAPSHOT-MODEL.md](SNAPSHOT-MODEL.md).

## Immich rollback

```bash
sudo domum-media immich rollback
```

This applies the newest available Immich rollback point.
