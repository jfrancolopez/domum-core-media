# Task 34 — Service catalog step 3 — ensure_dirs + CI consistency test

## Objective
Final catalog slice (PR 3 of task 16's plan): derive `ensure_dirs` from the
catalog and add a catalog-consistency smoke test to CI so the table can
never drift from the compose fragments again.

## Files involved
- `bin/domum-media` — `ensure_dirs()` (~1099–1125, hardcoded mkdirs; after
  task 26 it also chooses subvolume-vs-mkdir creation)
- `tests/catalog-consistency-smoke.sh` (new; mirror the shape of
  domum-core's `tests/catalog-consistency-smoke.sh`)
- `.github/workflows/compose-validate.yml` (run the new test)
- `docs/add-new-service.md`, `docs/service-template.md` (simplify: adding a
  service = one catalog row + one compose fragment)

## Reason
After task 33, directory creation is the last hardcoded service list. The
CI consistency test is the piece that makes the whole refactor pay off
permanently: it asserts every catalog row's compose file exists, every
compose fragment has a catalog row, enable vars exist in the example
config, and data-path/backup/snapshot columns are internally consistent —
turning the old "forgot one of seven sites" bug class into a CI failure.
`export_env_for_compose` deliberately stays hand-written (per task 16:
values differ per service; a table would obscure them).

## Implementation plan
1. `ensure_dirs`: iterate catalog rows with a data path; create via the
   task-26 helper (subvolume on btrfs roots, mkdir fallback).
2. Write `tests/catalog-consistency-smoke.sh`: catalog ↔ compose-fragment
   bijection, enable/backup vars present in
   `config/domum-media.conf.example` and `config/ci.env`, no duplicate
   names, well-formed rows.
3. Wire it into the CI workflow next to the existing smoke test.
4. Update the add-a-service docs to the one-row workflow.

## Testing plan
- CI green on a clean checkout.
- Negative tests: delete a catalog row / add an unregistered fragment →
  test fails with a pointed message.
- Fresh-install fixture: `ensure_dirs` creates exactly the same set of
  paths as before (parity list from task 33's harness).

## Rollback plan
Revert; `ensure_dirs` returns hardcoded, CI drops the test. Independent of
steps 1–2.

## Dependencies
Tasks 33 and 26 (dir-creation helper), task 12 (CI workflow shape it
extends).

## Risk / complexity / token size
Low. Small–medium. ~7k tokens.

## Suggested order
Phase 5, after task 33.
