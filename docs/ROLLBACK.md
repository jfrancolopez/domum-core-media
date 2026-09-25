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

The current service paths are ordinary directories rather than individual Btrfs
subvolumes, so service-level snapshots are not available and rollback metadata is
not proof of a usable rollback point.

Once a service **is** migrated, the report distinguishes the cases rather than
calling them all `protected`: `snapshottable` means the path can be snapshotted
but nothing has been, and `degraded` means snapshots of it would silently omit a
nested subvolume. Only `protected` means a rollback is actually possible. See
`docs/SNAPSHOT-MODEL.md`.

`rollback apply` restores **data only.**

`restore_snapshot_for_service` restores the snapshot and then runs
`compose_cmd up -d`. It never re-pins `IMAGE_BEFORE`, so the service comes back
on whatever image it was already running. For the automatic rollback after a
failed health check that means it restarts on the **same image that just failed**.

That is now reported as `rolled_back_data_only` with result `partial`, and a
manual `rollback apply` warns when the entry records a different image. It used to
record an unqualified `success`, which said the opposite of what happened.
Restoring the image is `backlog/task-24-rollback-previous-image.md`.

**What this means in practice:**

| situation | safe to run? |
|---|---|
| rolling back *data* to a snapshot, image unchanged | yes — this is what the Jellyfin pilot drill does, and its entry records no image at all |
| rolling back after a stateful **image** update | data comes back; the image does **not**. Re-pin it yourself |

Earlier revisions of this document said *"do not run `rollback apply` against
production until the snapshot exists and the previous-image restoration path has
been corrected"*, while `docs/JELLYFIN-PILOT.md` step 3 instructs exactly that.
Both were right about their own case and contradicted each other. The pilot drill
is data-only by construction, so it is in scope; an image rollback is not.

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

## Is a destructive production rollback drill warranted? (assessed 2026-09-25)

**No, not now.** The reasoning, so it is not re-litigated:

### What a real drill would add

Exactly one fact: that `btrfs subvolume snapshot /srv/snapshots/<snap>
/srv/data/<service>` works across the two separately **mounted** subvolumes
(`st_dev` 45 and 46). Every existing rollback test — including the real-Btrfs
integration suite — puts both trees inside a single mount, so that direction is
genuinely untested.

### What it would cost

- Jellyfin stops and restarts (brief downtime).
- A **third** copy of the tree appears in `/srv/data` as `.rollback-<stamp>`,
  alongside `.premigration` and the live subvolume — all three in every nightly
  backup.
- The first real exercise of the restore path would be on the service we have just
  migrated, with the thing being tested (the cross-mount create) also being the
  thing that could fail.
- It reverts Jellyfin's post-migration runtime state. Harmless, but it is a
  production mutation for no data benefit.

### Why it is not needed for that one fact

The cross-mount direction can be proven **non-destructively**, with one root
command that never touches a service path:

```bash
sudo btrfs subvolume snapshot \
  /srv/snapshots/jellyfin-20260925-153317-post-migration \
  /srv/data/staging/xmount-probe
# then verify, and remove it:
sudo btrfs subvolume delete /srv/data/staging/xmount-probe
```

That exercises the identical kernel operation in the identical direction across
the identical mount boundary, with no downtime, no third copy, and nothing at risk.

### What we already have instead of a drill

- `.premigration` — a complete independent copy, verified identical to the proof
  snapshot on every field.
- the proof snapshot — read-only, verified.
- real-Btrfs integration coverage of `restore_snapshot_for_service`: successful
  rollback with byte-for-byte restoration, failed restore with the live state put
  back, missing snapshot refused, foreign-service snapshot refused, name collision
  refused, and the `rm -rf`/`mv`-nesting recovery path.
- a migrated service that is demonstrably healthy.

### When to revisit

Drill for real when either (a) a rollback is actually needed, or (b) a service of
**lower** value than Jellyfin has been migrated and can absorb the downtime — that
is the cheap moment to exercise the path end to end, not now.
