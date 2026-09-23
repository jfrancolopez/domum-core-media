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
