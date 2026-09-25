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
| `snapshot prune` | **wait**, default 900s (`SNAPSHOT_LOCK_WAIT_SECONDS`) | weekly timer; it *deletes* snapshots, and a rollback checks its snapshot exists and then creates from it — a prune landing between those turns a routine restore into a failure |
| `snapshot create` | **wait**, default 900s | same timer family; snapshotting a tree a migration is renaming is the race the lock exists for |
| `host-upgrade` | **wait**, default 1800s (`HOST_UPGRADE_LOCK_WAIT_SECONDS`) | upgrading `docker-ce`/`containerd` **restarts the Docker daemon**, which restarts containers a migration has deliberately stopped — and this unit can go on to reboot the host |
| `cleanup snapshots --confirm` | refuse immediately | attended, and it *deletes snapshots* — the second deleter after `snapshot prune`, and the last one without the lock |

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

### The `host-upgrade` case is the sharpest

`domum-media-host-update.timer` fires Mondays at 05:45 (+45m) and runs:

```
apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io … btrfs-progs …
```

Upgrading `docker-ce` restarts the Docker daemon, which restarts containers. A
migration has those containers **deliberately stopped** while it copies and then
renames their data directory — so the daemon would bring a service back up onto
a half-copied `.new`, or during the cutover rename itself. `btrfs-progs` is in
the same package list, and the unit can then `shutdown -r +1`.

05:45 does not overlap the 02:30 backup. It very much can overlap an **attended**
migration, which is exactly when an operator is not expecting the Docker daemon
to restart underneath them.

The lock is taken *after* the `HOST_PACKAGE_AUTO_UPDATE_ENABLED` gate, so a
disabled upgrade stays a cheap no-op that cannot block anything. The test pins
that ordering.

## The descriptor is not inheritable by design

The lock lives in an open file descriptor, and **every child process inherits
it**. A service started under the lock and left running keeps holding it after
the acquiring process is gone — and since there is deliberately no stale-lock
reaper, the next backup would wait its full timeout and fail, every night, until
reboot.

`compose_cmd` therefore closes the descriptor for the command it runs, which is
the one place a locked operation execs something that starts long-lived
processes. This was found by the real-Btrfs integration test, not by reasoning:
see `docs/BTRFS-INTEGRATION-TEST.md`.
