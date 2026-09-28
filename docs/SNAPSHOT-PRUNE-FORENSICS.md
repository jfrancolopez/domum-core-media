# The first weekly prune with something to prune — 2026-09-27

`domum-media-btrfs-snapshot.timer` has been enabled and firing weekly for months
against an empty snapshot root, so it had never deleted anything. The Jellyfin
migration on 2026-09-25 gave it a real snapshot. It then fired on **Sunday
2026-09-27 04:33:43 EDT**, before the retention floor added in `defe282` was
deployed.

**Verdict: it discovered the Jellyfin proof snapshot, used a retention of 14,
attempted no deletion, deleted nothing, and exited 0.** The proof snapshot and
`/srv/data/jellyfin.premigration` are byte-identical to each other and unchanged.

## Which code actually ran

Not the current revision. From the production checkout's reflog:

| installed | revision |
|---|---|
| 2026-09-24 12:52:37 | `f2c9d63` |
| **2026-09-25 11:32:54** | **`a5b1ea4`**  ← ran on Sunday |
| 2026-09-28 08:08:21 | `b762fe8` |

`a5b1ea4` predates `defe282`, so Sunday's run had **no retention floor** and the
**unanchored** base-name regex. Both matter, and one of them was a near miss.

## Evidence

### From systemd

```
LastTriggerUSec          = Sun 2026-09-27 04:33:43 EDT
ExecStart                = /usr/local/bin/domum-media snapshot prune
ExecMainStartTimestamp   = Sun 2026-09-27 04:33:43 EDT
ExecMainExitTimestamp    = Sun 2026-09-27 04:33:43 EDT
ExecMainCode             = 1   (CLD_EXITED)
ExecMainStatus           = 0
Result                   = success
NRestarts                = 0
NextElapseUSecRealtime   = Sun 2026-10-04 04:38:18 EDT
```

Start and exit in the same second — it did no work.

The journal is not readable without privilege from this session (`jfranco` is in
neither `adm` nor `systemd-journal`), so the run's own output was **not** read
directly. "No entries" from an unprivileged `journalctl` is a permissions
artefact, not evidence of silence: `a5b1ea4` already printed a summary line, and
what it must have printed is derived below.

### From the filesystem — independent of any code analysis

A directory's mtime changes whenever an entry is created, removed or renamed
inside it.

```
/srv/snapshots  mtime = 2026-09-25 11:33:17.300726326
/srv/data       mtime = 2026-09-25 11:33:17.288726193
```

Both are still the instant of the migration. **No entry has been added to or
removed from either directory since 2026-09-25 11:33:17** — so the prune two days
later created nothing and deleted nothing, and no unexpected snapshot appeared or
vanished. This holds whatever the code does.

### The snapshot itself, verified directly rather than via the report

```
/srv/snapshots/jellyfin-20260925-153317-post-migration
  ro          = true
  inode       = 256          (subvolume root)
  st_dev      = 57           (its own anonymous device)
  37 files, 22 dirs, 501962 bytes
```

Compared against `/srv/data/jellyfin.premigration` (st_dev 45, inode 269 — an
ordinary directory, the original tree renamed):

| | result |
|---|---|
| metadata manifest (type, mode, size, path) | **identical**, 37 files / 22 dirs |
| total bytes | **501962 == 501962** |
| content, 35 of 37 files | **identical**; combined digest `32a96283f6bc1050…` on both sides |
| the other 2 files | mode `0600`, owned by a container UID — unreadable unprivileged; size and mode identical on both sides. All 37 were hashed as root by the migration's own verification. |
| `config/data/data/jellyfin.db` | same SHA-256 on both sides: `4ab756cadbca2dd5…` |
| that database, opened read-only | `integrity_check = ok`, `quick_check = ok`, 34 tables, WAL mode |
| `-wal` / `-shm` / `-journal` anywhere | **none** — the stop was clean |

That is the `C == E` integrity claim of `docs/MIGRATION-LIFECYCLE.md`, still true,
and verified at the application level and not merely by checksum.

The live tree has diverged, as it must — Jellyfin has been running for three days:

```
38 files vs 37; only log churn
  gone : config/log/log_2026092{3,4,5}.log
  new  : config/log/.jellyfin-log, config/log/log_2026092{6,7,8}.log
```

`jellyfin.db` differs from the recovery point, which is expected and is why the
integrity claim is `.premigration == proof snapshot` (two static trees) and never
"live == snapshot".

### The lock

`snapshot prune` acquires the operation lock (`SNAPSHOT_LOCK_WAIT_SECONDS`,
default 900). The next nightly backup — which takes the same lock — ran
**Mon 2026-09-28 02:43:12 → 02:43:43, exit 0, `Result=success`**, and
`/var/log/domum-media/last-success` reads `2026-09-28T02:43:42-04:00`. The lock
was therefore released. No failed units.

## Replay: what `a5b1ea4` decides, given that inventory

The revision that ran was extracted from git and executed against a fixture
mirroring the real snapshot root exactly — one entry, named
`jellyfin-20260925-153317-post-migration`, with the mtime real Btrfs produces
(the *source* subvolume root's, `2026-06-05 15:13:09`, not a creation time). The
`btrfs` command was replaced with a recorder, so any deletion would be visible
without one happening.

```
=== as it actually ran (SNAPSHOT_KEEP_PER_SUBVOL=14) ===
DISCOVERED: jellyfin-20260925-153317-post-migration
[domum-media] Snapshot prune: 0 deleted, 0 failed (keeping 14 per subvolume).
PRUNE-RC: 0
btrfs invocations: 0

=== with the value unset (the built-in default, also 14) ===
identical
```

Step by step, `total=1`, `keep=14`, `drop = 1 - 14 = -13`, and the delete loop is
guarded by `(( drop > 0 ))`. `rc=0` matches `ExecMainStatus=0`; "0 deleted, 0
failed (keeping 14 per subvolume)" is what went to the journal.

The name also parses correctly under the *unanchored* regex that revision used —
`jellyfin-20260925-153317-post-migration` yields stamp `20260925153317` — so the
snapshot was counted, not silently ignored. Being ignored would have been just as
bad in the other direction: an unrecognised name is excluded from the listing, and
the report would then have had no latest snapshot to name.

## The near miss

The same replay, same revision, with the retention set to zero:

```
=== counterfactual: keep=0 on THAT revision (no floor yet) ===
[domum-media] Pruning snapshot: .../jellyfin-20260925-153317-post-migration
[domum-media] Snapshot prune: 1 deleted, 0 failed (keeping 0 per subvolume).
PRUNE-RC: 0
btrfs invocations: 1
BTRFS-CALL: subvolume delete .../jellyfin-20260925-153317-post-migration
```

The only recovery point, deleted — and `rc=0`, so systemd would have recorded a
clean weekly run. `drop=$(( total - keep ))` is honest arithmetic; that is exactly
the problem. Nothing in `a5b1ea4` stood between a mistyped config value and the
snapshot.

`defe282` added `snapshot_retention_keep`, which floors retention at 1 and falls
back to 14 for a non-numeric value, and it is now installed (`b762fe8`). Wholesale
removal remains available through `cleanup snapshots --confirm`, which is attended
and asks.

So Sunday's run was safe because the configured value happened to be 14 — and
after `b762fe8` it no longer depends on that.

## What this does not claim

- The journal line was **derived**, not read. Reading it needs privilege this
  session does not have. Every other fact here is from systemd properties, the
  filesystem, or executing the exact revision.
- The two container-owned key files were content-compared as root only at
  migration time. Today's re-verification covers 35 of 37 files plus metadata for
  the other two.
- `SNAPSHOT_KEEP_PER_SUBVOL=14` is from the operator's own `report` output; the
  production config is not readable unprivileged. The built-in default is also 14,
  so the outcome is the same either way.

## Next Sunday

2026-10-04 04:38:18, with `b762fe8` installed: one snapshot, retention floored at
1, still nothing to delete. It stays a no-op until a service accumulates 15
snapshots — and `snapshot create` is event-driven, not scheduled, so that requires
15 deliberate operations.
