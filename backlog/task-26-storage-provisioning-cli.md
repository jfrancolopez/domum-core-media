# Task 26 — Storage provisioning CLI + doctor checks

## Objective
Add `domum-media storage` subcommands that make the subvolume promise true:
`storage status` shows which service data paths are btrfs subvolumes, and
`storage convert <service>` safely converts a plain directory into one
(stop → move aside → create subvolume → copy → verify → swap). `doctor`
flags non-subvolume data paths.

## Files involved
- `bin/domum-media` — new `storage` dispatch case (main case ~4056–4076),
  new functions near the snapshot helpers (`is_btrfs_subvol` ~1137,
  `snapshot_subvolumes` ~1141, `ensure_dirs` ~1099–1125), `doctor`
- `docs/CLI-CHEATSHEET.md`

## Reason
Snapshot code requires per-service btrfs subvolumes, but `ensure_dirs`
creates plain directories and no tool exists to convert them. Task 23 makes
the gap loud; this task provides the fix. Conversion must be a guarded,
repeatable command — not a hand-typed sequence in a doc — because it moves
live application data (including the Immich library and PostgreSQL data
dir) and a mistake is unrecoverable without backups.

## Implementation plan
1. `storage status`: for each enabled stateful service, print data path,
   subvolume yes/no, size. Read-only, no lock.
2. `storage convert <service>`:
   - Preconditions (abort with a clear message if unmet): path is on btrfs
     (`stat -f`), service containers stopped, free space ≥ path size,
     operation lock held (task 20), recent backup heartbeat exists (warn +
     typed confirm if stale).
   - Sequence: `mv "$path" "$path.pre-subvol"` →
     `btrfs subvolume create "$path"` → copy with
     `cp -a --reflink=always` (same-filesystem reflink = fast, atomicity
     irrelevant since service is stopped) → verify file count + du within
     tolerance → restart service → prompt to remove `"$path.pre-subvol"`
     only after the operator confirms the service works. Never auto-delete
     the moved-aside copy.
   - Idempotent: converting an already-subvolume path is a no-op with a
     friendly message.
3. `ensure_dirs`: when the data root is btrfs, create *new* service dirs as
   subvolumes from the start (`btrfs subvolume create` instead of
   `mkdir -p`); plain mkdir remains the fallback on non-btrfs roots.
4. `doctor`: add the subvolume check per enabled stateful service.

## Operator runbook
Per service, during the Phase 3 maintenance window (order: small services
first, Immich last; Immich requires the bundle stopped):
1. `domum-media backup` — fresh backup before touching anything.
2. `domum-media storage status` — pick the next plain-dir service.
3. Stop it, run `domum-media storage convert <service>`, verify the app
   works, then let the command remove the `.pre-subvol` copy.
4. After the last conversion: `domum-media storage status` all-green, run a
   manual snapshot (`btrfs-snapshot` timer unit or CLI) and verify
   snapshots now appear under `/srv/snapshots`.

## Testing plan
- Scratch btrfs loopback image: convert a fixture dir → subvolume exists,
  contents identical (diff -r), `.pre-subvol` retained until confirmed.
- Abort paths: non-btrfs filesystem, running container, insufficient space
  → clean refusal, nothing moved.
- Interrupt mid-copy (SIGINT) → original data intact at `.pre-subvol`,
  clear resume instructions printed.
- `doctor` and `storage status` on both plain and converted fixtures.

## Rollback plan
Per service, if the converted copy misbehaves:
`mv "$path" "$path.failed" && mv "$path.pre-subvol" "$path"` and restart.
The command prints exactly this in its failure output.

## Dependencies
Task 20 (locking), task 23 (the gate this resolves). Blocks tasks 27 and 28
(runbooks invoke this command).

## Risk / complexity / token size
Medium — moves live data, but always behind a stopped service, a preserved
moved-aside copy, and a fresh backup. Medium. ~12k tokens.

## Suggested order
Phase 3, after task 29.
