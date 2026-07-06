# Task 01 — Fix `rm -rf` branch in snapshot restore

## Objective
Make `restore_snapshot_for_service()` never destroy the current data without
keeping a copy, regardless of whether the live path is a btrfs subvolume.

## Files involved
- `bin/domum-media` — `restore_snapshot_for_service()` (~line 1297)

## Reason
The restore path branches on the live data dir:
- If it **is** a subvolume: `mv "$data_path" "${data_path}.rollback-<ts>"` — safe,
  the pre-restore state is preserved.
- If it exists but is **not** a subvolume: `rm -rf "$data_path"` — the current
  live data is destroyed with no copy, before the snapshot is restored.

The non-subvol case is reachable in practice: a service dir created by
`ensure_dirs` as a plain directory (operator skipped the subvolume step in
SETUP-N100.md), or a previous restore/migration that left a plain dir. A
rollback command that can itself cause data loss is the worst place for this
edge. The fix is one line: `mv` aside in both branches.

## Implementation plan
1. Replace the `rm -rf "$data_path"` branch with the same
   `mv "$data_path" "${data_path}.rollback-$(date +%Y%m%d-%H%M%S)"` used in
   the subvol branch (a plain dir can be mv'd identically).
2. Note in `docs/ROLLBACK.md` that `.rollback-*` siblings are kept and can be
   deleted manually once the restore is verified (one sentence; the doc
   already describes the flow).

## Testing plan
- `bash -n` + shellcheck pass; smoke test passes.
- Sandbox test (no btrfs needed): point `DOMUM_DATA_ROOT`/`DOMUM_SNAPSHOT_ROOT`
  at a temp dir, create a fake snapshot dir and a plain data dir, stub
  `compose_cmd`/`btrfs`; verify the plain dir ends up as `.rollback-*`, not
  deleted. (The `btrfs subvolume snapshot` restore step will fail in the
  sandbox — assert the mv happened before that point.)

## Rollback plan
Revert the commit; behavior returns to prior (dangerous) form.

## Dependencies
None.

## Risk / complexity / token size
Low risk. Trivial. ~4k tokens.

## Suggested order
1.
