# Btrfs snapshot model

Written to resolve a reported mismatch: `domum-media-btrfs-snapshot.service`
runs `domum-media snapshot prune`, and no scheduled snapshot *creation* exists.

**Conclusion: the behavior is intentional. The unit name and parts of the
documentation are misleading. No behavior was changed.**

## How snapshots are actually taken

Snapshot creation is **event-driven**, not scheduled. A snapshot is taken
immediately before a change that could need undoing:

| Trigger | Tag | Source |
|---|---|---|
| Before a stateful service image update | `pre-update` | `refresh_images` |
| Before an Immich bundle apply | `pre-immich-bundle` | `immich_refresh_bundle` |
| Before `domum-media apply` | `pre-apply` | `apply` |
| Before an Immich database reset | `pre-immich-reset` | `immich reset-db` |
| On request | operator-supplied | `domum-media snapshot create [tag]` |

Pruning is **time-driven**, because retention is a function of time rather than
of events. `domum-media-btrfs-snapshot.timer` runs weekly and keeps the most
recent `SNAPSHOT_KEEP_PER_SUBVOL` snapshots per subvolume.

This split is coherent. A nightly snapshot would not improve rollback: the
useful rollback point is the state immediately before the risky operation,
which is exactly what the event-driven hooks capture. A scheduled snapshot
would mostly add retention pressure.

## Evidence that this is intentional, not drift

- The `ExecStart` has been `domum-media snapshot prune` since the **initial
  commit** of the repository. It was never a creation command and was never
  edited.
- The unit's own `Description=` already reads *"btrfs snapshot prune
  (weekly)"*.
- The configuration key that drives its schedule is
  `SNAPSHOT_PRUNE_WEEKLY_AT`, and `sync_timer_overrides` maps that key to this
  timer.

So this is not historical drift, not an incomplete implementation, and not a
behavioral defect. It is a **naming and documentation defect**.

## What is actually misleading

1. **The unit name.** `domum-media-btrfs-snapshot.timer` reads as "take
   snapshots" when it only prunes them. A name such as
   `domum-media-snapshot-prune.timer` would be accurate.

   Renaming a systemd unit is a production-affecting operation: the old unit
   file persists on the host, enablement symlinks change, and a schedule
   override directory would need to move. It is therefore **not** done here. It
   belongs in a focused change with an operator runbook.

2. **Documentation implying scheduled snapshots exist.** Any statement that the
   host "takes btrfs snapshots" on a schedule is wrong. Snapshots are taken
   around changes.

## The larger caveat

None of the above makes snapshots usable on the current production host.

Both `snapshot_create` and `create_service_snapshot` gate on
`is_btrfs_subvol`. The service paths below `/srv/data` are ordinary
directories, so every service snapshot is skipped. `apply` calls
`snapshot_create "pre-apply"` and tolerates failure, so a run that protected
nothing still looks successful.

**Service-level snapshot protection is DEGRADED / NOT AVAILABLE**, independent
of anything in this document. See
[P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) and
[ROLLBACK.md](ROLLBACK.md). Restic backup protection is unaffected and remains
valid.

`domum-media report` probes each service path directly and reports
`unprotected` with a reason rather than inferring protection from `/srv/data`
being Btrfs — see [WEEKLY-REPORT.md](WEEKLY-REPORT.md).

## The safety gate

Because service snapshots silently skip on the current host, every operation
that depended on one for rollback was continuing as if protected. That is now
gated.

`snapshot_create` returns non-zero when it created no snapshot at all, and
reports how many it created and skipped. Operations that depend on a snapshot
for rollback refuse to run when none was created:

| Operation | Behaviour when no snapshot could be created |
|---|---|
| Stateful service image update | **Refuses.** The snapshot is the rollback mechanism; without it a failed health check leaves the service on the new image with no way back. |
| Immich bundle apply | **Refuses.** A bundle can migrate the database schema; re-pinning the old images against a migrated database is not a data rollback. |
| `immich reset-db` | **Refuses.** The snapshot is the only safety net before the `rm -rf` of the Immich state directory. |
| `domum-media apply` | **Warns loudly and continues.** Routine convergence does not itself depend on the snapshot, but it must not report protection it does not have. |
| `domum-media snapshot create` | **Exits non-zero.** An operator who asked for a snapshot and got none must not see success. |

`SNAPSHOT_POLICY` controls the refusing operations:

- `REQUIRED` (default) — refuse, and explain why.
- `WARN` — proceed deliberately with no rollback point, after a loud warning.

Setting `WARN` is an explicit operator decision to run without rollback
protection. It does not create protection.

`tests/snapshot-safety-gate-smoke.sh` proves the gate: a snapshot that cannot be
created cannot silently authorise a risky stateful operation.

## Follow-up work, not done here

- Rename the unit to reflect that it prunes (operator runbook required).
- Decide the subvolume layout for service paths — designed in
  [BTRFS-MIGRATION-PLAN.md](BTRFS-MIGRATION-PLAN.md); execution still requires
  explicit operator approval (backlog task 26).

## The snapshot gate must be service-scoped

`snapshot_create` returns success on a **global** count: it walks every
candidate subvolume and succeeds if at least one snapshot was created and none
failed. That is the right semantics for the scheduled fleet-wide snapshot. It is
the **wrong** semantics for a gate.

Today nothing under `/srv/data` is a subvolume, so the count is always zero and
every gate built on it refuses. That safety is accidental. The moment one
service path becomes a subvolume — which the Jellyfin pilot exists to do — a
*Jellyfin* snapshot satisfies the gate, and `immich reset-db` proceeds to
`rm -rf` the Immich PostgreSQL data directory with no Immich snapshot anywhere.

`immich reset-db` therefore gates on `assert_service_snapshot_covers`, which
takes a snapshot of the named service and then proves it covers each path about
to be destroyed. Two independent checks, because each has a blind spot the other
does not:

| check | catches | blind spot |
|---|---|---|
| `st_dev` differs from the snapshotted subvolume | a boundary crossed anywhere between the two paths, including deep inside | relies on btrfs giving nested subvolumes their own anonymous device |
| the path is itself inode 256 | the target *is* a nested subvolume root | a boundary further up, or deeper down |

**Evidence for the `st_dev` premise on this host:** `/srv/data` and
`/srv/snapshots` are two subvolumes of one filesystem — same device
(`/dev/sda1`), same UUID (`211e06b3-6aaf-40d8-8646-9361b8399eb2`), `subvol=/@data`
and `subvol=/@snapshots` — and their `st_dev` values differ (45 vs 46).

**The nested, unmounted case is now demonstrated too.** The real-Btrfs
integration test creates a subvolume nested inside another under `/srv/data`
and measures it: parent `st_dev` 45, nested child 75. The premise holds for the
exact topology the migration produces, not only for separately mounted
subvolumes. The inode-256 check remains as a second, independent signal.

Both checks fail closed: if either cannot establish coverage, the path counts as
unprotected and the operation refuses.

`tests/snapshot-safety-gate-smoke.sh` pins this, including the exact post-pilot
state — jellyfin a subvolume, immich not — in which the global helper succeeds
and the service-scoped gate must still refuse.

## A restore must prove the service stopped

`restore_snapshot_for_service` ran `compose_cmd stop … 2>/dev/null || true`,
discarding both stderr and the exit status. A container that kept running would
keep writing through its existing mount into the directory that was then renamed
aside, so the restore "succeeded", the application never experienced it, and the
operator was then told to delete the tree the live container was actually using.

The stop is now verified the same way the migration verifies it — non-zero exit
is fatal, and each container is confirmed absent from `docker ps` — and it
happens **before** anything is moved, so a refusal changes nothing.

## One answer to "is this a subvolume?"

There used to be three, and they could disagree:

| where | test | weakness |
|---|---|---|
| `snapshot_create`, `create_service_snapshot` | `btrfs subvolume show` | needs the btrfs tool **and root**; unprivileged it answers "no" for a real subvolume |
| migration path | inode == 256 | inode 256 is *necessary* for a btrfs subvolume root but not *sufficient* — it is ordinary on ext4, and `/srv/media` is ext4 |
| the report | `btrfs subvolume show`, inline again | a third copy to drift |

A detector that answers differently in the CLI and in the report is worse than
either answer alone: the report would claim "protected" while the gate refused,
or the reverse.

`domum_is_subvolume` is now the only implementation. It uses `btrfs subvolume
show` when the tool is present and we are root — authoritative — and otherwise
falls back to inode 256 **on a filesystem that `stat -f` says is btrfs**, which
removes the ext4 false positive. `is_btrfs_subvol` and `path_is_subvolume`
remain as names the call sites read well with, both delegating to it.

It is duplicated byte-identically into `bin/domum-media-report` for the same
reason the operation lock is (see `docs/OPERATION-LOCK.md`), and
`tests/subvolume-detection-smoke.sh` fails if the two copies differ.

## A snapshot that omits part of the tree is refused

Btrfs snapshots are not recursive. A snapshot of S contains an **empty
directory** wherever a nested subvolume used to be — measured on this host:

```
parent/nested contents : important.db
snap/nested contents   : []          <- EMPTY
snap/normal/deep       : file        <- ordinary directories copy fine
```

So "a snapshot of the service was created" does **not** mean "the service's
state is recoverable". If `/srv/data/immich/postgres` were ever a nested
subvolume, `create_service_snapshot` would have succeeded, the pre-update and
pre-bundle gates would both have passed, and the snapshot would hold an empty
database directory. A rollback from it would restore nothing.

`create_service_snapshot` now refuses **before creating anything** when the
service root contains a nested subvolume, and `snapshot_create` counts that as a
**failure** rather than a skip — a skip would let the aggregate gate pass on
some other service's snapshot, which is the same defect as the original
`reset-db` bug.

Detection is `find "$root" -xdev -mindepth 1 -type d -inum 256`. `-xdev` makes
it cheap: nested subvolumes have their own `st_dev`, so find reports the
boundary and never descends into it. Measured at **0.38 s** against the real
213 GB Immich tree.

There are no nested subvolumes under `/srv/data` today. This is a guard against
the topology becoming reachable, not a description of it.
