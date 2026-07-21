# Task 20 — Operation locking (flock)

## Objective
Add a single host-level operation lock so `apply`, image refresh/updates,
backup, rollback, and the Immich bundle manager can never run concurrently —
whether triggered by timers, by hand, or both at once.

## Files involved
- `bin/domum-media` — new `acquire_lock()` helper near the top; call sites
  in `apply` (~2487), `refresh_images`, rollback commands, and the Immich
  bundle subcommands
- `bin/domum-media-backup` — same helper (duplicated small, or sourced),
  wrapping the backup/prune/check entry points
- `systemd/*.service` — no unit changes needed if the lock lives in the CLI;
  verify timers simply block/skip cleanly

## Reason
`grep -rn flock` over the whole repo returns nothing. The backup timer can
fire mid-`apply`; an image refresh can race a manual rollback; two
overlapping snapshot/restore operations on the same subvolume are a
data-corruption class of bug. Every mutating entry point needs to hold the
same exclusive lock. Read-only commands (`status`, `checkup`, `doctor`,
`logs`) must NOT take it.

## Implementation plan
1. `acquire_lock()` using `exec {fd}>/run/domum-media.lock` +
   `flock -n "$fd"`; on contention print which operation holds it (write
   the operation name + pid into the lockfile) and exit with a distinct
   code. Add an optional `--wait` for timer-driven runs (bounded
   `flock -w <secs>`).
2. Wrap the mutating dispatch cases in `bin/domum-media` (main case at
   ~4056–4076): apply, updates/refresh, rollback, immich bundle, cleanup,
   host-upgrade, recovery-pack create.
3. Wrap `bin/domum-media-backup` main entry (backup, prune, restore) with
   the same lockfile so backup and apply exclude each other.
4. Document the lockfile path in `docs/CLI-CHEATSHEET.md`.

## Testing plan
- Two concurrent `apply` runs: second exits immediately with a clear message
  naming the holder.
- Backup started during a long `apply`: blocks (with `--wait`) or exits
  cleanly; never interleaves.
- Lock released on normal exit, error exit, and SIGINT (flock fd semantics
  guarantee this — verify with a killed process).
- Read-only commands run fine while the lock is held.

## Rollback plan
Revert; operations return to unlocked behavior. No state format involved.

## Dependencies
None. Blocks tasks 22 and 24 (no concurrency hardening on an unlocked
pipeline).

## Risk / complexity / token size
Low (additive guard; worst failure mode is an over-eager lock refusal).
Small–medium. ~8k tokens.

## Suggested order
Phase 1, after task 19.
