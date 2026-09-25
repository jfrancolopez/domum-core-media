# Task 43 — Pre-migration hardening: what landed and why

Status: **DONE** for the migration/snapshot/rollback chain. This task is a record,
not work. It exists so the next agent does not re-derive the reasoning or
re-litigate the fixes.

## The bug class

Every fix below shares one shape:

> An assumption that is harmless while every service path under `/srv/data` is an
> ordinary directory, and becomes reachable the moment the first real Btrfs
> subvolume and the first real snapshot exist.

`/srv/snapshots` has been empty since installation, and every snapshot gate has
therefore been refusing — **accidentally**. The first migration arms all of it at
once. That is why this work had to land before Jellyfin, not after.

## Fixed

| what | why it was dormant |
|---|---|
| `immich reset-db` gated on `snapshot_create`'s **global** count, so a Jellyfin snapshot could authorise `rm -rf` of the Immich database | the count was always 0 |
| `create_service_snapshot` returned a **contaminated** snapshot name (its own log line, and `btrfs`'s own stdout), so the auto-rollback after a failed health check could never find its snapshot | the function returned 1 before printing anything |
| the rollback path **discarded its stop result** (`2>/dev/null \|\| true`), so a restore could run under a live container and report success the application never experienced | rollback was never reached |
| `migrate_verify`'s sampling branch selected `NR % step == 1`, never true at step 1 — it could **pass having hashed nothing** | only reachable between `MIGRATE_FULL_HASH_MAX_FILES` and 400 files |
| `migrate_verify` compared content but not **ownership, permissions, symlink targets or empty directories**, which the plan claimed it did | nothing had been migrated |
| the quiesce check could not see a **non-container writer** holding a file open | ditto |
| a failed quiesce check left the service **stopped**, because `die` made the recovery branch unreachable | ditto |
| **no operation locking anywhere** — the nightly backup reads all of `/srv/data` with no exclude for `.new` / `.premigration` / `.rollback-*` | no migration had ever run |
| the operation lock **leaked to child processes**, so a service started under it held it forever | the lock did not exist |
| `snapshot prune` (enabled, weekly) ignored delete failures and took no lock | the snapshot root was empty, so it had never deleted anything |
| `host-upgrade` (Mondays) upgrades `docker-ce`, **restarting the Docker daemon**, and can reboot — with no lock | ditto |
| **three** different subvolume detectors that could disagree, one of which false-positives on ext4 | they agreed while everything was an ordinary directory |
| a **nested subvolume** is an empty directory in its parent's snapshot, and nothing checked | no nested subvolumes existed |
| rollback entries could name a **traversing path** or **another service's snapshot**, and advertised themselves `available` after being pruned | no entries existed |
| a trailing slash on a config value resolved the **config subdirectory** as the service root | nothing read it for a migration |

## Proven on the real filesystem

`tests/integration/btrfs-migration-integration.sh` runs the real primitives —
`btrfs subvolume create`/`snapshot`, `cp -a --reflink=always`, `rename(2)`,
`flock`, `/proc` — against a disposable fixture on the same Btrfs filesystem as
`/srv/data`. Unprivileged, self-cleaning, no production path touched.

Two previously-assumed facts are now measured:

- a nested **unmounted** subvolume has its own `st_dev` (parent 45, child 75),
  which `path_covered_by_subvolume` depends on;
- `cp --reflink=always` handles small **inline-extent** files — 31 of Jellyfin's
  37 real files are under 2048 bytes, which the plan's single-256MB-file proof
  did not cover.

Fifteen failure boundaries are exercised there. The invariant held in every one:
**a failed migration or rollback never destroyed the last valid copy of state.**

## Still open

- Task 20's remaining three lock call sites (`apply`, image update, Immich bundle).
- The Jellyfin pilot itself — an operator boundary.
