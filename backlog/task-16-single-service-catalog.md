# Task 16 — FUTURE: Consolidate service definitions into one catalog  [shared-philosophy]

> **Future idea. Do not start without an explicit go decision.** This is the
> largest refactor in the backlog and the main pattern that should flow
> domum-core → domum-core-media.

## Objective
Replace the ~7 parallel places a service is currently defined with one
catalog table, so adding/removing a service is a one-row change (plus its
compose file), like domum-core's `service_catalog()`.

## Files involved
- `bin/domum-media` — `compose_files_for_enabled_services()` (hardcoded
  if-chain), `managed_image_specs()`, `service_lifecycle_specs()`,
  `service_data_path()` (case), `service_backup_required()` (case),
  `snapshot_subvolumes()` (hardcoded list), `ensure_dirs()` (hardcoded
  mkdirs), plus the per-service blocks in `export_env_for_compose()`
- `docs/add-new-service.md`, `docs/service-template.md` (simplify)

## Reason
Today a new service must be registered in up to seven code sites; forgetting
one produces exactly the silent-gap class of bug found in the sibling audit
(a service that deploys but is never snapshotted, or never backed up, or
invisible to updates). domum-core proved the single-table shape works:
`name|enable_var|image_var|class|delay|compose_rel|data_path|compose_svcs|health_url`
covers everything the seven sites need. Media-specific columns (snapshot
subvol, cache dir) extend the row; Immich keeps its bespoke bundle logic and
simply opts out of the generic image column.

Why future: high blast radius (every command reads these tables), zero
user-visible feature gain, and the current duplication is *consistent* today.
Do it when the next service addition is planned, so the refactor pays for
itself immediately.

## Implementation plan (when activated — split into 3 PRs)
1. **PR 1:** Introduce `service_catalog()` carrying the union of
   `service_lifecycle_specs` + `managed_image_specs`; rewrite those two
   functions as views over it. No behavior change; smoke test proves it.
2. **PR 2:** Derive `compose_files_for_enabled_services`, `service_data_path`,
   `service_backup_required`, and `snapshot_subvolumes` from the catalog.
   Assert old-vs-new output equality in a throwaway test before deleting the
   old code.
3. **PR 3:** Derive the `ensure_dirs` mkdir list; add a catalog-consistency
   smoke test (mirror of domum-core backlog task 08) to CI.
   `export_env_for_compose` defaults stay hand-written (values differ per
   service; a table would obscure them).

## Testing plan
Per PR: `docker compose ... config` output byte-identical before/after with
all services enabled (CI env); smoke test; shellcheck; on-host `apply` is a
no-op recreate.

## Rollback plan
Each PR independently revertable; PR 1 alone is harmless.

## Dependencies
Tasks 01–08 landed (touching the same functions); a planned new service as
the trigger.

## Risk / complexity / token size
Medium risk, large effort. ~10k tokens per PR.

## Suggested order
16 — future.
