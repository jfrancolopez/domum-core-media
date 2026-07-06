# Task 11 — Add dry-run paths to domum-media-backup  [shared-philosophy]

## Objective
Port the sibling repo's dry-run discipline: `domum-media backup --dry-run`
(plan + `restic backup --dry-run`) and `--prune-dry-run` (preview retention),
so the operator can see what a backup/prune will do before it does it.

## Files involved
- `bin/domum-media-backup` — `do_daily_backup()`, `restic_backup_to()`,
  `restic_forget_for()`, `main()` dispatch, `--help` text
- `bin/domum-media` — `usage()` (backup subcommand line)
- `docs/SETUP-RESTIC.md`

## Reason
domum-core's backup wrapper supports `--dry-run` and `--prune-dry-run`;
this repo's daily path has neither — the only way to see what restic would
do is to run it for real. The shared philosophy is "dry-run before
destructive action"; retention (`forget --prune`) is the destructive one and
has zero preview here. restic natively supports `--dry-run` on both `backup`
and `forget`, so this is plumbing, not new machinery.

## Implementation plan
1. Thread a `dry` flag (mirroring domum-core's `restic_backup_to`/
   `restic_forget_for` signatures) through `do_daily_backup`,
   `restic_backup_to`, and `restic_forget_for`; append `--dry-run` to the
   restic opts when set.
2. On dry runs: skip `quiesce_immich_postgres` side effects (log what it
   *would* do — snapshot + pg_dump), skip `heartbeat`, and skip the
   recovery-pack refresh.
3. Add dispatch entries `--dry-run` and `--prune-dry-run`; update `--help`
   and the CLI `usage()` line.
4. Keep flag names identical to domum-core's for sibling symmetry.

## Testing plan
- `domum-media backup --dry-run` on the host: restic reports would-add data,
  heartbeat file mtime unchanged, no new pg dump, no new recovery pack.
- `--prune-dry-run`: restic prints retention plan, snapshot count unchanged.
- shellcheck + bash -n pass.

## Rollback plan
Revert; additive flags disappear.

## Dependencies
None.

## Risk / complexity / token size
Low (additive). Small. ~7k tokens.

## Suggested order
11.
