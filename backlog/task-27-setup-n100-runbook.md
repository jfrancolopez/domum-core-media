# Task 27 — SETUP-N100 rewrite + migration runbook

## Objective
Make `docs/SETUP-N100.md` describe a storage setup that actually satisfies
the snapshot architecture, and add the migration runbook that takes the
existing live host from plain directories to per-service subvolumes.

## Files involved
- `docs/SETUP-N100.md` — top-level subvolume creation (~236–237) and the
  per-service `mkdir -p /srv/data/containers/{immich,postgres,…}` block
  (~297–301)
- `docs/disaster-recovery.md` (storage-layout references)

## Reason
The doc has two fictions. First, it only creates the top-level `@data` /
`@snapshots` subvolumes, so a documented install never satisfies the
per-service subvolume prerequisite the snapshot code enforces. Second, it
documents `/srv/data/containers/<service>` paths that the CLI has never
used — the CLI expects `/srv/data/<service>` (`service_data_path`, ~774).
Anyone rebuilding the host from this doc gets a broken layout. Docs-only
task: the commands it documents come from task 26.

## Implementation plan
1. Rewrite the storage section: fstab/UUID mounts, top-level subvolumes,
   then per-service subvolumes created via `domum-media storage` (or
   `btrfs subvolume create /srv/data/<service>` on first install), matching
   `service_data_path` exactly. Delete the `/srv/data/containers` block.
2. Reference `${DOMUM_DATA_ROOT}` as the variable root (task 29) rather
   than literal `/srv/data` where the doc speaks about configurable paths.
3. Add a "Migrating an existing host" section: the per-service conversion
   runbook from task 26's Operator runbook, expanded with the recommended
   order (small services first, Immich last) and the post-migration
   verification (`storage status`, one manual snapshot, one restore drill
   of a throwaway file).
4. Cross-link from `docs/disaster-recovery.md` so a rebuild lands on the
   corrected layout.

## Operator runbook
This task *is* the runbook (docs). Executing it on the live host is the
task-26 runbook; this doc is where it permanently lives.

## Testing plan
- Every path in the doc greps against `service_data_path` output — no
  mismatches.
- Every command in the doc exists (`domum-media storage …` from task 26).
- A dry read-through as if provisioning a fresh VM: no step depends on
  undocumented state.

## Rollback plan
Docs revert cleanly; no runtime behavior.

## Dependencies
Task 26 (the commands documented here), task 29 (paths described as
configurable).

## Risk / complexity / token size
None (docs only). Small. ~6k tokens.

## Suggested order
Phase 3, after task 26.
