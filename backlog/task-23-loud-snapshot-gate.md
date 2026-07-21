# Task 23 — Loud snapshot gate for stateful updates

## Objective
Make snapshot failures visible and policy-gated. When a service's data path
is not a btrfs subvolume, `create_service_snapshot` must fail loudly — and
the update pipeline must honor `BACKUP_POLICY`: STRICT aborts the update,
BALANCED warns and continues.

## Reason
On a documented install, per-service data dirs are plain directories
(`ensure_dirs` uses `mkdir -p`, ~1099–1125), and the snapshot code
(`is_btrfs_subvol` gate at ~1137–1139, `snapshot_create` ~1156–1174,
`create_service_snapshot` ~1247–1268) silently skips them. The update
pipeline's whole safety story — snapshot before update, auto-rollback on
health failure — is therefore an illusion on such hosts: updates proceed
with zero rollback capability and nobody is told. Converting the dirs is
Phase 3 (tasks 26/27); this task converts the silent hole into a visible
blocker now, which is exactly the pressure that gets the maintenance window
scheduled.

Deliberate consequence: after this lands, a STRICT host with plain
directories stops auto-updating stateful services until Phase 3 is
executed. That is intended.

## Files involved
- `bin/domum-media` — `create_service_snapshot` (~1247–1268),
  `snapshot_create` (~1156–1174), the update path in `refresh_images` that
  requests pre-update snapshots, `checkup` (surface the condition)

## Implementation plan
1. `create_service_snapshot`: on a non-subvolume data path, log an explicit
   error naming the path and the fix (`domum-media storage convert`, task
   26) and return non-zero — never silently skip.
2. In the stateful-update path: on snapshot failure consult
   `BACKUP_POLICY` (defaults aligned by task 08) — STRICT: abort that
   service's update and record it in update history; BALANCED: warn loudly
   and continue.
3. `checkup`: add a line flagging any enabled stateful service whose data
   path is not a subvolume ("snapshots inactive — see task 26").
4. Scheduled snapshot timer runs report the same error instead of
   succeeding vacuously.

## Testing plan
- Fixture: plain dir + STRICT → update aborted, history entry written,
  clear message. BALANCED → update proceeds with warning.
- Real subvolume (scratch btrfs file image) → snapshot succeeds, update
  unaffected.
- `checkup` on a plain-dir host shows the new finding.

## Rollback plan
Revert; snapshots return to silent-skip. No data-format changes.

## Dependencies
Task 08 (supplies the shared STRICT default this gate reads). Blocks
nothing, but tasks 26/27 are its resolution path.

## Risk / complexity / token size
Low (fails closed; the risky part is operator surprise, which is the
point — documented in the abort message). Small. ~6k tokens.

## Suggested order
Phase 2, after task 22.
