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

## Revalidated 2026-09-28 21:55, after the image invariant

| | |
|---|---|
| inode / dev | 272 / 45 — **ordinary directory** |
| files / dirs / symlinks | 1,006 / 816 / **0** |
| bytes | 51,575,830 |
| nested subvolumes | 0 |
| leftovers | none |
| `navidrome.db` | 1,851,392 B, with `-wal` **20,632 B** and `-shm` 32,768 B |
| container | created 2026-08-02, running, 0 restarts |
| running image | `sha256:9012939114fb…`, `deluan/navidrome:latest`, built 2026-07-11, label `0.63.2` |
| tag resolves to | **the same image** — nothing staged |
| healthcheck | **none**; no published ports |

## What the image invariant changes

`compose start` restarts the container that was stopped, so the image cannot
change whichever service is migrated. Navidrome having no staged image is now a
convenience rather than a precondition — and its recovery point will carry the
image identity (`sha256:9012939114fb…`, version label `0.63.2`) in
`<recovery-point>.recovery`, which neither Jellyfin's nor Kavita's does.

Navidrome is also the first migration where the recorded runtime state matters in
a mundane way: it is **running**, so it will be running afterwards, and the
migration says so before and after.

## The one real weakness

**No healthcheck and no published port**, so application verification after the
restart is limited to "the container is running". That is strictly weaker than
Kavita, whose `/api/health` request was the point of choosing it — and it cannot
be improved without adding a health URL that is reachable from the host, which
means routing through Traefik with a hostname and TLS. Worth doing eventually;
not worth half-doing as part of a migration.

The compensating evidence is byte-level: 1,006 files hashed in full, 816
directories' metadata compared, `.premigration == proof snapshot`, and
`navidrome.db` opened and `integrity_check`ed from a copy of the snapshot.

## Before migrating navidrome

The WAL is the live variable and it is time-sensitive. `navidrome.db-wal` is
20,632 bytes right now, and this is the first migration where the post-quiesce WAL
gate has something real to refuse: if the clean shutdown does not checkpoint it,
the migration aborts before touching anything. Both previous services had an
empty WAL at stop time, so that gate has never fired in production.

A refusal there costs nothing and happens before anything moves. It is the
intended behaviour, not a setback.

Everything above must be re-checked by the migration itself, not trusted from this
document.
