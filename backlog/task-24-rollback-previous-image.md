# Task 24 — Rollback restores the previous image

## Objective
Make rollback restore *both* halves of pre-update state: data (already
implemented via snapshots) and the exact previous image. Keep rollback
images from being garbage-collected while a rollback entry references them.

## Files involved
- `bin/domum-media` — `restore_snapshot_for_service` (~1297–1320, restarts
  via `compose_cmd up -d` at ~1319), rollback metadata writer (~1236–1243,
  records `IMAGE_BEFORE` from `tracked_service_image_id` /
  `docker inspect {{.Image}}`), auto-rollback path (~2084–2090),
  `rollback_apply_entry` (~2668), `cleanup_images_execute` (runs right
  after updates at ~2096–2098)
- `docs/ROLLBACK.md`

## Reason
Every configured tag is moving (`:release`, `:latest`), so after a failed
update the rollback restores the data snapshot and then `up -d` — which
resolves the same moving tag and restarts the *new, known-bad* image.
`IMAGE_BEFORE` is already recorded in the rollback env file but never used;
worse, `cleanup_images_execute` runs immediately after each update and may
delete the previous image, making restoration impossible even manually.
Image restore is independent of btrfs (image IDs live in `/var/lib/docker`),
so this lands before Phase 3.

## Implementation plan
1. Retention first: `cleanup_images_execute` must exempt any image ID
   referenced by an `available` (non-expired) rollback entry. Without this,
   the retag path is useless.
2. On rollback (auto and manual): retag `IMAGE_BEFORE` onto the compose tag
   the service uses (`docker tag <image_id> <configured_tag>`), then
   recreate the service so compose starts the pinned image. Record the
   image restore in the rollback history entry.
3. Suppress immediate re-candidacy: after an image rollback, mark the bad
   digest so the next refresh doesn't instantly re-promote it (a
   skip-digest note in the service's update state; cleared manually or by
   the next different upstream digest).
4. If `IMAGE_BEFORE` is missing from Docker despite retention (manual
   prune), fail the image half loudly and continue with the data half —
   never abort the data restore.

## Testing plan
- Fixture: update service, force health failure → auto-rollback restores
  the snapshot AND the container runs the exact previous image ID
  (`docker inspect` before/after comparison).
- `cleanup images` with an available rollback entry present → previous
  image survives; after the entry expires → image is reclaimed.
- Refresh after rollback → the bad digest is not immediately re-candidated.
- Missing previous image → data restore still completes, loud warning.

## Rollback plan
Revert; rollback returns to data-only restore. Retagged images are ordinary
tags — no cleanup needed beyond normal image cleanup.

## Dependencies
Task 01 (restore path must not `rm -rf` before anything exercises it more
often), task 20 (locking). Blocks task 32 (restore verification exercises
rollback paths).

## Risk / complexity / token size
Medium (retag semantics + retention interplay; mitigated by treating the
image half as best-effort relative to the data half). Medium. ~10k tokens.

## Suggested order
Phase 2, after task 23.
