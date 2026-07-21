# Task 19 — Atomic Immich pg_dump

## Objective
Make the Immich PostgreSQL dump atomic: write to a temp file, validate it,
then `mv` into place — so an interrupted or failed dump can never truncate
or replace the previous good artifact.

## Files involved
- `bin/domum-media-backup` — the dump block (~line 300–307):
  `docker exec -i "$pg_cid" pg_dump ... | gzip -9 > "$dump_file"`

## Reason
The dump currently redirects straight onto the final filename
`$stage_dir/immich-postgres.dump.sql.gz`. A failed `pg_dump` (container
restart, OOM, disk full) leaves a truncated file with a valid-looking name,
which then gets shipped to every restic target and silently poisons the only
DR artifact for the photo metadata. The dump is the single most important
file this repo produces; it must be all-or-nothing.

## Implementation plan
1. Dump to `"$dump_file.tmp"`; capture the pipeline status of *both* stages
   (`pg_dump` and `gzip`) via `PIPESTATUS` — a gzip of an aborted stream
   still exits 0.
2. Validate: `gzip -t "$dump_file.tmp"` and a non-trivial minimum size
   check.
3. On success: `mv "$dump_file.tmp" "$dump_file"` (same filesystem, atomic).
   On failure: remove the temp file, log loudly, and return non-zero so the
   backup run records the failure (interaction with per-target isolation is
   task 30's concern; this task only guarantees no bad artifact lands).
4. Add a `trap` (or extend the existing cleanup path) so an interrupt also
   removes the temp file.

## Testing plan
- Normal run on the host: dump lands, `gzip -t` passes, no `.tmp` remains.
- Simulated failure (kill `pg_dump` mid-stream / point at a stopped
  container): previous dump file is untouched, no final artifact appears,
  exit code is non-zero.
- `bash -n`, shellcheck, smoke test.

## Rollback plan
Revert the commit; dumps return to direct-write behavior.

## Dependencies
None. Blocks task 31 (restore consumes dumps; dumps must be trustworthy
first).

## Risk / complexity / token size
Low (additive to one function). Small. ~5k tokens.

## Suggested order
Phase 1, after tasks 01 and 05.
