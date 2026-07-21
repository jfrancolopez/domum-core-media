# Task 30 — Per-target backup isolation + heartbeats  [shared-philosophy]

## Objective
One failing backup target must not abort the remaining targets, and each
target gets its own last-success heartbeat file so `checkup` can say
exactly which copy is stale.

## Files involved
- `bin/domum-media-backup` — the target loop in the daily backup path,
  retention/check paths, heartbeat writing
- `bin/domum-media` — `checkup` (read per-target heartbeats),
  `verify_backup_freshness` (~831) if it reads the aggregate file

## Reason
Today a failed target (e.g. Hetzner unreachable) can stop the whole run,
and the success heartbeat is global — so "backups are fresh" can mean "the
NAS copy is fresh, the cloud copy has silently been failing for a month."
Porting source: `domum-core/bin/domum-core-backup` — `do_daily_backup`
(:318-358) collects targets into an array, records succeeded/failed per
target, logs "failed — continuing", runs retention only for succeeded
targets, and exits non-zero at the end if any failed; `heartbeat()`
(:282-292) writes the aggregate `last-success` plus one
`last-success-<target>` each, and pings the external heartbeat URL only
when *every* target succeeded. Also port its `collect_enabled_targets`
shape (:311-316) — it exists to avoid a `grep -q` SIGPIPE-under-pipefail
bug.

## Implementation plan
1. Restructure the daily-backup target loop to the domum-core pattern:
   per-target try, record result, continue; aggregate exit code at the end.
2. Write `$DOMUM_STATE_ROOT/backups/last-success` (aggregate, back-compat
   for existing checkup logic) plus `last-success-<target>` per succeeded
   target.
3. Apply the same isolation to `--check` and prune/retention paths.
4. `checkup`: report age per target; flag any target stale beyond its
   expected cadence.
5. Keep interaction with task 19 strict: a failed Immich dump fails every
   target that is expected to protect Immich (no target ships a run whose
   dump failed).

## Testing plan
- Fixture with one bad target (bogus repo URL): good target completes,
  heartbeat written only for it, run exits non-zero, checkup names the
  stale target.
- All-good run: aggregate + per-target heartbeats all updated.
- Dry-run (task 11) unaffected: no heartbeats written.

## Rollback plan
Revert; behavior returns to sequential-abort. Per-target heartbeat files
are additive — stale ones are ignored by the old code.

## Dependencies
Task 11 (dry-run plumbing in the same functions — land first to avoid
conflicts), task 19. Blocks task 32.

## Risk / complexity / token size
Low-medium (restructures the main backup loop; the pattern is proven in the
sibling). Medium. ~9k tokens.

## Suggested order
Phase 4, after task 11.
