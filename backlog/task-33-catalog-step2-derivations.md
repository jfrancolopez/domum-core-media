# Task 33 — Service catalog step 2 — derive the read paths

## Objective
Second slice of the catalog consolidation (PR 2 of task 16's plan): derive
`compose_files_for_enabled_services`, `service_data_path`,
`service_backup_required`, `service_strict_backup_required`, and
`snapshot_subvolumes` from `service_catalog()`, plus the include-path
functions in `domum-media-backup` — asserting old-vs-new output equality
before deleting any old code.

## Files involved
- `bin/domum-media` — `compose_files_for_enabled_services()` (~898,
  if-chain), `service_data_path()` (~774, case),
  `service_backup_required()` (~793) / `service_strict_backup_required()`
  (~800, cases), `snapshot_subvolumes()` (~1141, hardcoded array)
- `bin/domum-media-backup` — `immich_only_include_paths()` (~45),
  `backup_target_include_paths()` (~201), the `do_plan_target` prose
  (~686–690, whose hardcoded list is the task-04 bug class)

## Reason
Task 16 (step 1) introduces the catalog and rewrites the two spec tables as
views — no behavior change. This step makes the catalog authoritative for
every *read* path, which is where the silent-gap bug class lives: a service
that deploys but is never snapshotted, or never backed up, because one of
five lists was forgotten. Kept separate from step 1 so each slice is a
reviewable, revertable session.

## Implementation plan
1. Extend the catalog rows (from task 16) with the columns these functions
   need: `data_path` (or `-`), `backup` (`required|strict|-`),
   `snapshot` (`yes|-`), `compose_rel`.
2. Rewrite each listed function as a catalog query. Immich stays a bundle:
   its row(s) carry the bundle marker and the bundle-specific code keeps
   its bespoke path.
3. Parity harness before deletion: a throwaway script that runs old and new
   implementations side by side across every `ENABLE_*` combination in
   `config/ci.env` and diffs outputs; commit only the green result (the
   harness itself can land in `tests/` for step 3 to reuse).
4. `domum-media-backup`: derive include paths from the same catalog
   (sourced or duplicated table per current code-sharing convention between
   the two CLIs — follow whatever task 16 established); replace the
   `do_plan_target` hardcoded prose with a catalog-driven list.

## Testing plan
- Parity harness: byte-identical outputs old vs new for all functions, all
  enable combinations.
- `docker compose config` (CI env) byte-identical before/after.
- On-host `apply` is a no-op recreate; `backup plan` output now matches
  reality per target.
- Smoke test + shellcheck.

## Rollback plan
Single revert returns all derived functions to their hardcoded forms (old
code is deleted only in this commit, so the revert is clean).

## Dependencies
Task 16 (catalog exists). Blocks task 34.

## Risk / complexity / token size
Medium (touches every list the pipeline trusts; fully mitigated by the
parity harness). Medium. ~10k tokens.

## Suggested order
Phase 5, after task 16.
