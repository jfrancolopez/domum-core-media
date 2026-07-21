# Task 16 — Service catalog step 1: introduce the table  [shared-philosophy]

> Re-scoped 2026-07-21: no longer FUTURE-gated (Phase 5 of the roadmap is
> the go decision), and narrowed to the first of three slices. Steps 2 and 3
> are [task 33](task-33-catalog-step2-derivations.md) and
> [task 34](task-34-catalog-step3-ensure-dirs-ci.md).

## Objective
Introduce a single `service_catalog()` table in `bin/domum-media` and
rewrite `service_lifecycle_specs()` and `managed_image_specs()` as views
over it — zero behavior change, proven by a parity test. This is the
foundation the ~9 duplicated per-service code sites converge onto in the
following two tasks.

## Files involved
- `bin/domum-media` — new `service_catalog()` near the top of the service
  section; `managed_image_specs()` (~746) and `service_lifecycle_specs()`
  (~760) become views
- Porting source: `domum-core/bin/domum-core:747-764` (`service_catalog()`
  pipe-table with the column docs at :736-743, plus its `catalog_field()`
  accessor shape)

## Reason
Today a new service must be registered in up to ~9 code sites (image specs,
lifecycle specs, data path, backup flags, compose selection, env export,
ensure_dirs, snapshot list, backup include paths); forgetting one produces
the silent-gap bug class — a service that deploys but is never snapshotted
or backed up. domum-core proved the single-table shape works. The catalog
row carries the union of what all sites need:
`name|enable_var|image_var|class|delay|compose_rel|compose_svcs|data_path|backup|snapshot|health_url`.
Immich keeps its bespoke bundle logic and opts out of the generic image
column; media-specific columns extend the row.

Slicing rationale: each step is one reviewable agent session, each
independently revertable, and old code is deleted only after old-vs-new
parity is asserted.

## Implementation plan
1. Define `service_catalog()` as a heredoc pipe-table (domum-core shape)
   containing every current service with the union columns above, values
   transcribed exactly from the two existing spec tables.
2. Add a `catalog_field()` accessor (port from domum-core).
3. Rewrite `service_lifecycle_specs()` and `managed_image_specs()` to emit
   their current output format by projecting catalog columns — callers
   unchanged.
4. Parity check committed alongside: a small script that diffs the output
   of the two functions before/after (run against the pre-change git
   revision in CI-less local testing; keep it in `tests/` for tasks 33/34
   to extend).

## Testing plan
- Old vs new output of both spec functions byte-identical (all `ENABLE_*`
  combinations from `config/ci.env`).
- `docker compose ... config` byte-identical with all services enabled.
- On-host `apply` is a no-op recreate; smoke test + shellcheck pass.

## Rollback plan
Revert — the views collapse back into standalone tables. Harmless in
isolation.

## Dependencies
Phase 2 landed (tasks 22/23/24 touch `refresh_images` and the spec tables;
land the behavior changes before the refactor to avoid churn). Blocks tasks
33, 34, and 35.

## Risk / complexity / token size
Low for this slice (pure re-plumbing with parity proof). Medium. ~10k
tokens.

## Suggested order
Phase 5, first task of the phase.
