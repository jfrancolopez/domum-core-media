# Real-Btrfs integration test

Everything before this exercised the migration algorithm against **stubbed**
Btrfs primitives. The algorithm and the primitives had never run together —
which is exactly the gap that mattered before touching a production service.

`tests/integration/btrfs-migration-integration.sh` closes it.

## What is real

`btrfs subvolume create`, `btrfs subvolume snapshot -r`,
`cp -a --reflink=always`, `rename(2)`, `flock`, the `/proc` open-handle scan,
`migrate_verify`, `migrate_manifest`, `migrate_metadata_manifest`,
`migrate_assert_quiesced`, `migrate_assert_same_btrfs`, `domum_is_subvolume`,
`create_service_snapshot`, `restore_snapshot_for_service`, and
`storage_migrate_subvolume` itself.

## What is stubbed, and only this

`need_root`, `load_cfg`, `export_env_for_compose` — config plumbing — and the
container lifecycle. The lifecycle stub is not a no-op: it starts a **real**
background process in its own process group holding a **real** file descriptor
inside the service tree, so the quiesce check has something true to find.

## Running it

```bash
tests/integration/btrfs-migration-integration.sh
```

Unprivileged. It creates a disposable fixture under `BTRFS_TEST_ROOT`
(default `/srv/data/staging`, which is owned by the operator account and on the
same Btrfs filesystem as `/srv/data`, so the same-filesystem and reflink
requirements are genuinely exercised). **No production service directory is
touched.** It skips loudly where there is no Btrfs, so CI runs it as a skip.

Teardown needs no root: `btrfs subvolume delete` requires privilege, but an
**empty** subvolume can be removed with `rmdir(2)` by its owner, and a read-only
snapshot can be made writable with `btrfs property set -ts … ro false`. The
fixture is emptied depth-first and removed completely.

## What it proved

Ordinary directory → quiesce → real subvolume → reflink copy → verification →
`.premigration` preserved → cutover → proof snapshot **while quiesced** →
restart → protected-state detection. Then a deterministic mutation, a rollback
through the real implementation, and a byte-for-byte return to the original.

Two facts that were previously assumed are now measured on this host:

- **A nested, unmounted subvolume has its own `st_dev`** (parent 45, child 75).
  `path_covered_by_subvolume` depends on this, and `docs/SNAPSHOT-MODEL.md`
  had to record it as documented-but-undemonstrated. It is now demonstrated.
- **`cp -a --reflink=always` handles small inline-extent files.** The plan's
  reflink proof covered one 256 MB file; 31 of Jellyfin's 37 real files are
  under 2048 bytes and are likely inline extents, which `--reflink=always`
  cannot clone by the usual path and does not fall back from. The fixture
  deliberately straddles the boundary (2047 B and 2049 B) and the copy succeeds.

## Two real bugs it found that stubs could not

**1. `create_service_snapshot` returned a contaminated snapshot name.**
The function returns the name on stdout, and both its own progress line *and*
`btrfs subvolume snapshot`'s "Create readonly snapshot of …" also went to
stdout. Every caller captured all three lines. `restore_snapshot_for_service`
could then never find the snapshot — so the **auto-rollback after a failed
health check would refuse**, leaving the service on a broken image with a
perfectly good snapshot sitting unused, and `record_update_history` would store
the mangled name as the rollback pointer.

Unreachable while no service path was a subvolume, because the function returns
1 before printing anything. Armed by the first migration. The stubbed `btrfs`
printed nothing, which is precisely why only the real tool exposed the second
half of it.

`tests/captured-stdout-purity-smoke.sh` now scans every function whose output is
captured with `$(...)` and fails if it writes a human-readable line — or lets
`btrfs` write one — to stdout.

**2. The operation lock leaked to child processes.**
The lock lives in an open file descriptor, which every child inherits. A service
started by `compose_cmd up -d` **while the migration held the lock** kept holding
it after the migration exited. Because there is deliberately no stale-lock
reaper, the next nightly backup would wait its full 30-minute timeout and fail —
every night, until reboot.

`compose_cmd` now closes the lock descriptor for the command it runs.

## Failure boundaries exercised against real Btrfs

| boundary | outcome |
|---|---|
| repeated invocation | refused: already a subvolume |
| stale `.premigration` | refused, recovery copy untouched |
| non-Btrfs path (real tmpfs) | refused |
| operation-lock contention (real `flock`) | refused |
| external open file handle (real process, real `/proc`) | refused, offending pid named |
| non-empty SQLite WAL | refused, **service restarted** |
| failed copy | partial removed, original untouched |
| verification mismatch | unverified copy removed, original in place |
| proof-snapshot failure | migrated, data intact, non-zero exit |
| restart/health failure | `.premigration` preserved intact |
| failed rollback restore | live state put back intact |
| snapshot name collision | refused by Btrfs, existing snapshot untouched |
| rollback to a missing snapshot | refused |
| rollback to another service's snapshot | refused |
| lock leaked to a surviving child | detected |

The invariant held in every case: **a failed migration or rollback never
destroyed the last valid copy of state.**
