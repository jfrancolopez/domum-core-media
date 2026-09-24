# Operation locking

Until now there was no locking anywhere in this codebase. `grep -rn 'flock' bin/`
returned nothing.

## The collision that motivated it

`domum-media-backup.timer` fires at **02:30 with `RandomizedDelaySec=15m`**. The
nas and archive targets back up all of `/srv/data`, with **no exclude** for
`.new`, `.premigration`, or `.rollback-*`.

A migration overlapping that window has restic walking a tree that is being
renamed underneath it. It captures a half-copied `.new`, hits vanished paths,
and exits non-zero. Nothing is corrupted — the last-success marker is simply not
refreshed, and under `BACKUP_POLICY=STRICT` updates are then refused for 48
hours. Fail-safe, but the operator gets a failed backup with no visible cause.

The Immich case is worse and is called out separately in
`BTRFS-MIGRATION-PLAN.md`: the backup **writes** into
`/srv/data/immich/backup-staging` while it runs, i.e. inside the tree a future
Immich migration would be copying.

## What takes the lock

| operation | behaviour | why |
|---|---|---|
| `storage migrate-subvolume` | refuse immediately | attended; the right answer is "come back later", not a silent wait |
| `rollback apply` | refuse immediately | attended; stops containers and moves live state |
| daily backup | **wait**, default 1800s (`BACKUP_LOCK_WAIT_SECONDS`) | unattended and never retried by a human — giving up would silently skip a night |

`rollback apply --dry-run` takes no lock: it changes nothing.

## How it works

The lock lives in an **open file descriptor** held by `flock`, not in the
contents of a file. The kernel releases it when the process exits for any
reason, `SIGKILL` included. There is no stale lock to detect and no reaper to
write — which matters, because a stale-lock reaper is usually the thing that
eventually causes the outage.

`operation.lock.holder` records who holds it, for an operator reading a refusal:

```
Another domum-media operation holds the lock: 21847 2026-09-24T02:31:06+01:00 daily backup
```

That file is **diagnostic only**. It is never consulted to decide whether the
lock is held; that decision belongs to `flock` alone, and the file may be stale
or missing without consequence.

## Why the helper is duplicated

The same helper appears in `bin/domum-media` and `bin/domum-media-backup`,
byte-identical, between `# BEGIN SHARED LOCK HELPER` and `# END SHARED LOCK
HELPER`.

Sourcing it from a new file would be tidier, but it would add an artefact a
partial deployment can leave missing — and the failure mode there is a CLI that
will not start at all. Two files that already exist and are already installed is
the smaller risk.

That trade is only safe while the copies agree: two scripts computing *different*
lock paths would take different locks, exclude nothing, and fail **silently** —
the worst possible outcome for a lock. This repository has already shipped one
bug of exactly that shape (two `backup_target_names` with divergent defaults), so
`tests/operation-lock-smoke.sh` fails if the two blocks differ by a single byte.

## Test coverage

`tests/operation-lock-smoke.sh` is hermetic and covers: byte-identical helpers,
identical resolved lock paths, genuine mutual exclusion, the holder being named
in a refusal, a bounded wait that really waits and then fails, automatic release
after `SIGKILL`, and that each operation takes the lock with the intended
blocking behaviour. Five mutants, five killed.

## Not covered

Scheduled snapshot creation and pruning (`domum-media-btrfs-snapshot.service`,
Sundays 04:30) do not yet take the lock. They neither move nor delete service
data, so they cannot corrupt a migration — but a snapshot taken mid-migration
would capture a transient state. Worth revisiting; not a blocker.
