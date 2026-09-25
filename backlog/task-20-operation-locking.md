# Task 20 — Operation locking (flock)

Status: **PARTIALLY DONE.** The lock exists and is enforced for the operations
that can destroy or move data. Three call sites in the original scope remain.

Landed (see `docs/OPERATION-LOCK.md`):

| operation | behaviour |
|---|---|
| `storage migrate-subvolume` | refuse immediately (attended) |
| `rollback apply` | refuse immediately (attended) |
| daily backup | wait 1800s (unattended, never retried by a human) |
| `snapshot prune` | wait 900s — it *deletes* snapshots |
| `snapshot create` | wait 900s |
| `host-upgrade` | wait 1800s — it upgrades `docker-ce`, restarting the daemon |

The lock is an open file descriptor held by `flock`, so the kernel releases it on
any exit including `SIGKILL`; there is no stale-lock reaper by design. The helper
is duplicated byte-identically between `bin/domum-media` and
`bin/domum-media-backup` and pinned by `tests/operation-lock-smoke.sh`, because
two copies computing different lock paths would exclude nothing and fail
silently.

`compose_cmd` closes the lock descriptor for the command it runs: every child
inherits it, and a service started under the lock would otherwise hold it
forever. That one was found by the real-Btrfs integration test, not by reasoning.

## Remaining scope

Three operations from the original objective still take no lock:

- **`apply`** — recreates containers. Racing a migration means the daemon brings
  a service up while its data directory is being copied or renamed.
- **image update / image refresh** — recreates containers *and* takes a
  pre-update snapshot. The timer is disabled, so this is reachable only by hand
  today, which is exactly when an operator might run it beside something else.
- **Immich bundle apply** — takes a pre-bundle snapshot and recreates the stack.

None of these can corrupt data *today*, because no service path is a subvolume
and every snapshot gate therefore refuses. All three become live the moment the
first migration lands. Treat as the next locking increment, not as done.

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
