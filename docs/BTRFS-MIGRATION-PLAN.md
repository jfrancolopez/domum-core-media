# Btrfs migration plan — design

Design only. **Nothing here has been executed.** No production data has been
moved and no subvolume has been created or deleted.

Service-level snapshot protection is DEGRADED because the service state paths
under `/srv/data` are ordinary directories rather than Btrfs subvolumes. This
document records the measured topology, the constraints that follow from it,
and the migration procedure — so the plan can be reviewed before any of it runs.

## 1. Measured topology

```
/dev/sda1  btrfs  UUID 211e06b3-6aaf-40d8-8646-9361b8399eb2   932G (214G used)
   subvolid 256  subvol=/@data       → /srv/data
   subvolid 257  subvol=/@snapshots  → /srv/snapshots
   opts: rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2

/dev/sdb2  ext4   UUID 54bf0182-ec08-4889-bafe-87476b87e4c6   460G (59G used)  → /
   /srv/media is a DIRECTORY on this filesystem, with no mount of its own
```

`/srv/data` and `/srv/snapshots` are **separate subvolumes of the same Btrfs
filesystem**. That is the precondition for `btrfs subvolume snapshot`, and it
means the architecture is viable without relocating data.

`/srv/media` was verified three independent ways — `findmnt -T /srv/media`
resolves to `/` on `/dev/sdb2`; `lsblk` shows `sdb2` mounted only at `/`; and
`stat -c %d` gives `/srv/media` the same device id as `/` (2066) versus 45 for
`/srv/data`. `sdb` also carries `/boot/efi` and swap. So `/srv/media` shares the
root filesystem and is **not Btrfs** — it can never be snapshotted, and it is
out of scope for this migration.

## 2. Service inventory

Subvolume detection without root: a Btrfs subvolume root has **inode 256**.

| Service | Path | inode | Size | Files | Database | Class |
|---|---|---|---|---|---|---|
| immich | `/srv/data/immich` | 273 | 213G | 64,190 | PostgreSQL | durable |
| plex | `/srv/data/plex` | 4373 | 256M | 121 | SQLite (WAL) | rebuildable |
| navidrome | `/srv/data/navidrome` | 272 | 51M | 1,006 | SQLite (WAL) | rebuildable |
| kavita | `/srv/data/kavita` | 4377 | 4.6M | 82 | SQLite (WAL) | rebuildable |
| jellyfin | `/srv/data/jellyfin` | 269 | 600K | 37 | SQLite | rebuildable |
| calibre-web | `/srv/data/calibre-web` | 4375 | 244K | 5 | SQLite | rebuildable |

All six are ordinary directories. `/srv/data` (256) and `/srv/snapshots` (256)
are the only subvolumes.

No hardlinks, extended attributes, ACLs or symlinks exist anywhere under
`/srv/data`, which removes the usual copy-fidelity hazards.

`uptime-kuma` and `traefik` are listed as snapshot candidates but have no state
directory. See *Known gaps*.

## 3. SQLite: why every service must be stopped before it is copied

Live evidence, taken with the containers running:

| Service | `-wal` | `-shm` | Meaning |
|---|---|---|---|
| plex | **169,808 bytes** | 32,768 | WAL mode, uncheckpointed transactions present |
| navidrome | **20,632 bytes** | 32,768 | WAL mode, uncheckpointed transactions present |
| kavita | 0 bytes | 32,768 | WAL mode, connection open, currently checkpointed |
| jellyfin | absent | absent | no WAL artefacts at this instant |
| calibre-web | absent | absent | no WAL artefacts at this instant |

A file copy walks files **one at a time**. For a WAL-mode database with a live
writer, `.db` and `.db-wal` are therefore captured at different instants, and
the copy can be torn in a way SQLite cannot recover. Plex has 169 KB of
uncheckpointed WAL *right now*, so this is not hypothetical.

Note the asymmetry that makes this a migration-only problem: a **Btrfs snapshot
is atomic across the whole subvolume**, so once a service is a subvolume its
snapshots are crash-consistent and SQLite recovers from them normally. During
migration the source is not yet a subvolume, so no atomic mechanism exists — the
only safe option is to stop the writer.

**Therefore: stop the service before copying. Every service, without exception.**
jellyfin and calibre-web show no WAL artefacts at this instant, but absence now
does not prove absence during the copy — a background scan can open a database
mid-migration, and the cost of stopping them is seconds.

**Pre-copy check after stopping:** no non-empty `*-wal` may remain. A clean
shutdown checkpoints and removes `-wal`/`-shm`. If a non-empty WAL survives the
stop, the application did not shut down cleanly and the cause should be
understood before copying.

The same reasoning applies more strongly to Immich's PostgreSQL: stop
`immich_postgres` and confirm `postmaster.pid` is gone before copying its data
directory. Note this does **not** affect the nightly backup, which uses
`pg_dump` — a logical dump that is consistent by construction, not a file copy.

## 4. Target architecture

**Nested subvolumes under `@data`, one per service** — the layout the existing
code already expects, requiring no fstab change and no new mounts.

Snapshots continue to land in `/srv/snapshots/<service>-<stamp>-<tag>`, which
works because source and destination are on the same filesystem.

### Immich is one subvolume, deliberately

`/srv/data/immich` becomes a single subvolume covering `postgres/`, `library/`
and `backup-staging/` together.

The database references assets by path. Rolling back the database without the
library, or the reverse, produces dangling references or orphaned files. One
subvolume means one atomic snapshot of both, which is the only consistent
rollback unit available.

The cost of that correctness: an Immich rollback reverts all 213G and loses any
photo uploaded since the snapshot. That is inherent — a consistent rollback
cannot also preserve post-snapshot writes. Immich rollback is therefore a last
resort; restic remains the primary path for the library and the validated dump
the primary path for the database.

Immich internals: `upload/` 130G (irreplaceable), `encoded-video/` 77G and
`thumbs/` 5.5G (both regenerable), `backups/` 385M, `backup-staging/` 27M.
Redis has no bind mount and is ephemeral; the machine-learning cache is a Docker
named volume. Splitting the 82.5G of regenerable transcodes into their own
subvolume would shrink the rollback unit, but introduces an inconsistency window
for little gain — copy-on-write snapshots cost nothing at creation. Not
recommended initially.

## 5. Migration procedure, per service

It is implemented as a guarded command rather than a sequence of pasted
shell — `domum-media storage migrate-subvolume <service>` — so that the guards
are reviewable and testable rather than depending on careful typing. It refuses
any service outside an explicit allowlist, any path outside the durable data
root, anything inside the media tier, a path that is already a subvolume, and a
leftover `.premigration` or `.new` from an earlier attempt.

Verification scales with the service: every file is hashed and the manifests
compared when the service has at most `MIGRATE_FULL_HASH_MAX_FILES` (20,000)
files — which covers all five small services — and a deterministic sample is
hashed above that, which is the Immich case at 64,190 files.


`cp --reflink=always` shares extents rather than duplicating them, so the copy
is metadata-bound and costs almost no additional space.

```
1. stop the service's containers
2. confirm no non-empty *-wal remains (and for Immich, no postmaster.pid)
3. btrfs subvolume create   /srv/data/<svc>.new
4. cp -a --reflink=always   /srv/data/<svc>/.  →  /srv/data/<svc>.new/
5. verify: file count, total bytes, ownership, permissions, sampled hashes
6. mv /srv/data/<svc>      → /srv/data/<svc>.premigration     (retained)
7. mv /srv/data/<svc>.new  → /srv/data/<svc>
8. start containers; verify health
9. prove protection: take a real snapshot, then confirm `domum-media report`
   moves that service from `unprotected` to `protected`
10. prove rollback: restore that snapshot and confirm the service still works
11. leave `.premigration` in place until an operator removes it
```

No `rm -rf` at any step. If anything fails, move `.premigration` back.

**Expected downtime:** seconds for jellyfin, calibre-web, kavita, navidrome and
plex. 5–15 minutes for Immich, dominated by verifying 64,190 files rather than
by the copy.

**Headroom:** 717G free against a 213G worst case, and reflink makes the real
cost near zero.

## 6. Order, and the pilot

Staged, with a pilot: **jellyfin first.**

It is 600K across 37 files, so downtime is seconds; it is fully rebuildable; it
exercises the real mechanics (a database, a container bind mount, the snapshot
and rollback cycle); and its valuable data — the media library — lives on
`/srv/media`, which this migration does not touch. calibre-web is smaller still
but so trivial it would prove less.

Then calibre-web → kavita → navidrome → plex → **Immich last**, and only after
the pilot has demonstrated both a real snapshot and a real rollback.

## 6b. Empirically proven on this filesystem

Measured on `/dev/sda1` with disposable fixtures under `/srv/data`, all removed
afterwards. No service data was used.

**Reflink works across the ordinary-directory → nested-subvolume boundary.**
A/B on the same 256 MB incompressible file:

| Copy | Free-space cost |
|---|---|
| `cp -a --reflink=always` into a nested subvolume | **0 KiB** |
| `cp -a --reflink=never` (same file) | **262,144 KiB** |

Content compared identical, permissions and mtime preserved, and the copy
remained valid after the source directory was renamed — which is exactly the
`.premigration` step.

**`btrfs subvolume snapshot` is NOT recursive.** A parent subvolume containing a
child subvolume was snapshotted read-only; the parent's own file appeared in the
snapshot, and the child appeared as an **empty directory**:

```
parent file present in snapshot : YES
child directory present         : YES
child FILE present              : NO    (child dir entry count: 0)
```

Consequence for this design: snapshotting each service subvolume individually —
which is what the code does — is correct. But anything that snapshots `@data`
itself would silently capture every service as an empty directory. That is a
landmine for any future "snapshot the whole data root" idea.

**Subvolumes report distinct device ids.** `/srv/data` is `st_dev=45`,
`/srv/snapshots` is `46`. Tooling that uses `--one-file-system` or compares
device ids would treat a nested service subvolume as a separate filesystem and
skip it. Verified that the backup wrapper does **not** pass
`--one-file-system`, so restic will continue to traverse into service
subvolumes after migration. Any future tooling must preserve that.

**Privilege boundary.** An unprivileged owner of `/srv/data` can *create* a
subvolume, but `btrfs subvolume delete` returns EPERM (the filesystem is not
mounted `user_subvol_rm_allowed`). An empty subvolume can be removed with
`rmdir`; a non-empty one cannot without root. A **read-only** snapshot cannot be
emptied at all until its `ro` property is cleared. The migration helper must
therefore run as root, and any failure that leaves a populated `.new` subvolume
needs root to clean up.

## 7. Known gaps this migration does not close

- **Two services keep writable state outside the durable tier**, so it is
  neither snapshottable nor backed up. A full container-mount inventory found
  one I had missed:

  | Container | Volume | Contents | Consequence if lost |
  |---|---|---|---|
  | traefik | `domum-media_traefik-letsencrypt` | `acme.json`, 116 KB, mode 0600 | ACME account key and all issued certificates; re-issuable but rate-limited |
  | uptime-kuma | `domum-media_uptime-kuma-data` | `kuma.db` 287 KB (+ 8 KB WAL) | monitor definitions and history |

  Neither is under `/srv/data`, and neither is inside any backup include path.
  Immich's Redis (`dump.rdb`, anonymous volume) and machine-learning cache are
  genuinely ephemeral/regenerable, and `immich_server`'s anonymous volume is
  empty.

  `domum-media report` now detects this class dynamically from the containers
  themselves rather than from a hand-written list, so a volume added later
  cannot hide — a static inventory is exactly what missed Traefik.
- **Pre-update snapshots are taken with containers running**, so they are
  crash-consistent rather than clean. PostgreSQL and SQLite both recover from
  that, but stopping the service first would be correct for stateful updates.
- `/srv/media` cannot be snapshotted at all; it is not Btrfs.

## 8. Full-library restore verification — design

Restoring 228G to prove recoverability is wasteful. A **deterministic
representative sample** is better: select assets by a stable rule (every k-th
path in sorted order, plus the largest and smallest, plus one per year-month
directory), restore exactly those from a known snapshot into scratch, and
compare byte-for-byte against hashes taken from the live library.

**Proves:** the repository is readable; the snapshot indexes those paths; stored
data decrypts and decompresses to bytes identical to the source; transport and
credentials work for bulk content rather than only the 27M dump.

**Does not prove:** that every file is intact — sampling cannot; that the
library restores at full scale within any time budget; or that a rebuilt Immich
can serve the restored files. Only a full restore plus an Immich import proves
those.
