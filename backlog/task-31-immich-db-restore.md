# Task 31 — Guided Immich DB restore

## Objective
Add `domum-media immich restore-db <dump.sql.gz>` — the missing import half
of the Immich PostgreSQL dump: stop the Immich server, load the dump into a
fresh database, sanity-check the schema, restart the bundle, and probe the
API.

## Files involved
- `bin/domum-media` — new subcommand under the `immich` dispatch; helpers
  near the bundle manager
- `docs/disaster-recovery.md` — the restore flow (currently restores
  `/srv/data` files only and just starts Immich, losing all metadata
  semantics if the postgres data dir wasn't restored byte-for-byte)
- `docs/SETUP-IMMICH.md`

## Reason
The backup produces `immich-postgres.dump.sql.gz` on every run
(`bin/domum-media-backup` ~300–307), but no import path exists anywhere —
no `psql`/`pg_restore` in bin/ or docs/. The dump is write-only: in a real
disaster the operator would be improvising `docker exec` piping against the
production photo metadata under stress. The dump exists precisely for the
case where the postgres data directory is gone or unusable; it needs a
rehearsed, guarded import.

## Implementation plan
1. Preconditions: dump file exists, `gzip -t` passes (atomic dumps from
   task 19), operation lock held, typed confirmation naming the target
   database.
2. Sequence: stop immich-server + machine-learning (keep postgres up) →
   if a non-empty database exists, require an explicit `--replace` flag and
   rename the old DB aside (`ALTER DATABASE ... RENAME`) rather than drop →
   create fresh DB with the configured owner → `gunzip -c | docker exec -i
   <pg> psql` with `ON_ERROR_STOP=1` → verify: expected core tables exist
   (`users`, `assets`, `albums`), row counts non-zero, extensions present
   (vector/vchord per the deployed bundle) → write/refresh the DB password
   fingerprint state (`immich_db_password_fingerprint_file`, ~379–381) so
   the `apply` guard (~629–633) passes → restart the bundle → probe the
   API (server ping + login page).
3. Failure at any step: leave the renamed old DB in place, print exact
   recovery instructions (rename back).
4. Rewrite the `docs/disaster-recovery.md` Immich section around this
   command: restic-restore files → `immich restore-db` → verify.

## Testing plan
- Scratch instance (CI env or throwaway compose project): create data via
  the API, dump, destroy DB, `restore-db`, verify users/albums/assets
  intact through the API.
- `--replace` guard: refuses on existing DB without the flag; old DB
  recoverable after a failed import.
- Corrupt dump: refused up front by `gzip -t` / `ON_ERROR_STOP`.

## Rollback plan
The command never drops the previous database (rename-aside); reverting the
commit removes the subcommand, dumps remain importable manually using the
documented sequence.

## Dependencies
Task 19 (atomic dumps), task 20 (locking). Blocks task 32 (restore
verification exercises this import).

## Risk / complexity / token size
Medium (touches the production DB engine, mitigated by rename-aside and
stop-server-first). Medium. ~12k tokens.

## Suggested order
Phase 4, after task 30.
