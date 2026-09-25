# Jellyfin pilot — result

Executed 2026-09-25 15:32 UTC against production, on revision `a5b1ea42`.

## Verdict: MIGRATION VERIFIED — the outer harness raised a false positive

`/srv/data/jellyfin` is a real Btrfs subvolume, the data is provably intact, and
Jellyfin is running normally. The pilot wrapper aborted afterwards because it
compared two states that are not required to be equal. That bug is fixed; see
`docs/MIGRATION-LIFECYCLE.md`.

## What the migration did

```
stop -> quiesce -> create subvolume -> reflink copy -> verify -> cutover -> proof -> restart
```

Its own verification, as root:

```
files: 37 -> 37, bytes: 501962 -> 501962
content manifest identical (37 of 37 file(s))
type, mode, owner, group and symlink targets identical
```

Exit status 0.

## The evidence

| artefact | files | bytes | note |
|---|---|---|---|
| `/srv/data/jellyfin.premigration` | 37 | 501,962 | the original, moved aside |
| `/srv/snapshots/jellyfin-20260925-153317-post-migration` | 37 | 501,962 | read-only, taken while quiesced |

Full manifests — type, mode, `uid:gid`, path, size, SHA-256 for every entry —
are **identical**. That is the integrity proof: the original against a snapshot of
the copy that replaced it, both static.

`/srv/data/jellyfin` is inode 256 with `st_dev` 51 against the parent's 45, so it
is a genuine nested subvolume.

### The database

`jellyfin.db` is byte-identical (`sha256 4ab756ca…`) across `.premigration`, the
proof snapshot, **and** the live tree. Checked on copies, never on production:

```
from-snapshot.db      integrity=ok  fk_violations=0  tables=34  journal=wal  users=1
from-live.db          integrity=ok  fk_violations=0  tables=34  journal=wal  users=1
from-premigration.db  integrity=ok
```

### The application

```
/health                 HTTP 200
/System/Info/Public     HTTP 200
{"ServerName":"domum-core-media","Version":"10.11.11","StartupWizardCompleted":true,...}
```

The existing configuration and database are recognised — not a fresh install.
Zero `[ERR]`/`[FTL]` lines since restart. All three bind mounts present, including
`/srv/data/jellyfin/config -> /config` now resolving through the new subvolume.

## Why the wrapper aborted, and the 743 bytes

The wrapper asserted the pre-stop fingerprint equalled the post-restart one.
Neither a clean shutdown nor a restart leaves a tree unchanged.

The operator spotted the clue: the pre-stop baseline was **501,219** bytes and the
quiesced source was **501,962**. Accounted for exactly — the shutdown sequence in
`config/log/log_20260925.log`, from `Sending shutdown notifications` to EOF, is
**743 bytes**, and 501,219 + 743 = 501,962. The log includes
`Running query planner optimizations in the database…`, so Jellyfin also runs a
SQLite optimize on the way down.

After the restart, exactly seven paths differ from the proof snapshot:

```
changed   config/log/log_20260925.log                4,842 -> 15,333 bytes
changed   config/data/data/ScheduledTasks/*.js       3 files, same size, new timestamps
added     config/log/.jellyfin-log
added     config/data/data/jellyfin.db-wal
added     config/data/data/jellyfin.db-shm
```

Every one is runtime state. The database is not among them.

## What is deliberately still on disk

- `/srv/data/jellyfin.premigration` — the only independent copy of the
  pre-migration state. **Not deleted.**
- `/srv/snapshots/jellyfin-20260925-153317-post-migration` — read-only proof
  snapshot, and now Jellyfin's first real rollback point. **Not deleted.**

Both are inside `BACKUP_INCLUDE_PATHS`, so they are in every nightly backup. The
report counts them and says so.

## Still unproven: the cross-mount restore direction

`/srv/data` and `/srv/snapshots` are separately **mounted** subvolumes of one
filesystem (`st_dev` 45 and 46). Every rollback test so far — including the
real-Btrfs integration suite — places both trees inside a *single* mount, so

```
btrfs subvolume snapshot /srv/snapshots/<snap> /srv/data/<service>
```

has never actually run on this layout. Attempting it unprivileged fails with
`Operation not permitted`, because the source lives in a root-owned mount.

This does **not** require a rollback drill to settle. See below.
