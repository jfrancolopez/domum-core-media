# Service #3, selected from current evidence

Measured 2026-09-28, after Kavita. Not taken from the earlier ordering.

| | files | bytes | dirs | symlinks | non-empty `-wal` | healthcheck | image |
|---|---|---|---|---|---|---|---|
| **navidrome** | 1,006 | 51.6 MB | 816 | 0 | **1** (20.6 KB) | none | **current** |
| plex | 121 | 271.6 MB | 171 | **7** | **2** (926 KB, 376 KB) | none | **staged newer** |
| calibre-web | 6 | 244 KB | 2 | 0 | 0 | none | **staged newer** |

None has a nested subvolume. None has a container healthcheck, so none can give
the application-level signal Kavita did — that advantage is spent.

## navidrome

**Because its image is current.** `plex` and `calibre-web` both have a newer image
staged under their existing tag, so migrating either today would deploy it — which
is exactly the defect found in the Kavita run, and which the migration now
refuses. Choosing one of them would mean bundling an application upgrade into a
storage move, or overriding a guard added hours earlier.

It also proves things nothing has proved yet:

- **1,006 files across 816 directories** — an order of magnitude more than
  Jellyfin (37) or Kavita (79), and the first tree where the full-hash manifest
  and the metadata manifest do real work. Still far under
  `MIGRATE_FULL_HASH_MAX_FILES` (20,000), so every file is hashed.
- **A non-empty WAL that must clear.** `navidrome.db-wal` is 20,632 bytes right
  now. This is the first migration where the quiesce check has something real to
  refuse: if the clean shutdown does not checkpoint it, the migration must abort
  before touching anything. Both previous services had an empty WAL at stop time,
  so that gate has never actually fired in production.
- **816 directories** exercises directory metadata — mode, ownership — at a scale
  where an error would be easy to miss by eye and is caught only by the manifest.

## Why not plex

The largest tree (271 MB) and the only one with symlinks, including an absolute
one pointing at a container-internal path:

```
.../Cache/va-dri-linux-x86_64/iHD_drv_video.so -> /config/Library/.../iHD_drv_video.so
```

Worth proving eventually — `cp -a --reflink` preserves symlinks and the metadata
manifest compares targets — but it should not be combined with an image
deployment, and 271 MB plus two large dirty WALs is more novelty at once than the
next step should carry.

## Why not calibre-web

6 files and 244 KB. It proves nothing new, and it too has a staged image.

## Before migrating navidrome

The WAL is the live variable and it is time-sensitive. The migration re-checks it
after quiescence, which is the check that counts — but `navidrome.db-wal` being
non-empty *now* is the reason this service was chosen, and it is also the most
likely cause of a legitimate refusal. That is the intended behaviour: a refusal
there costs nothing and happens before anything is moved.

Its image status must also be re-checked immediately before, not trusted from
this document: a `docker pull` between now and then turns navidrome into the same
case as plex, and the guard will refuse it.
