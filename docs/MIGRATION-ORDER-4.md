# Service #4 — what it would and would not buy

Measured 2026-10-05. Three services migrated: Jellyfin, Kavita, Navidrome. Two
routine candidates remain; Immich is deliberately last and excluded.

## Measured now, not remembered

| | calibre-web | plex |
|---|---|---|
| path | ordinary directory, inode 4375 | ordinary directory, inode 4373 |
| files / dirs | 6 / 2 | 121 / 171 |
| bytes | 250,850 | 263,117,420 |
| **symlinks** | 0 | **7** (6 relative incl. 2 chains, 1 absolute and broken on the host) |
| SQLite | `app.db` 118 KB, `gdrive.db` 24 KB | `…library.db` 421 KB, `…blobs.db` 365 KB |
| WAL / SHM | **none at all** | `library.db-wal` **76,536 B**, `blobs.db-wal` 0 B, both `-shm` 32,768 B |
| open handles under the tree | 0 | 0 |
| nested subvolumes / leftovers | 0 / 0 | 0 / 0 |
| runtime | running, no healthcheck | running, no healthcheck |
| container / image | `06c0695330023…` / `6cf7dab48a4a…` | `7a917ab1f387…` / `58f13a1df833…` |
| mutable ref | `lscr.io/linuxserver/calibre-web:latest` | `lscr.io/linuxserver/plex:latest` |
| **staged image** | **yes** → tag now `d5ad2aaf36f8…` | **yes** → tag now `7f9a1d574958…` |
| RepoDigests | **none** | **none** |
| recoverability | `identity,local` | `identity,local` |
| readiness signal | **none found** | `Connection to localhost (::1) 32400 port [tcp/*] succeeded!` |
| bind mounts | `config` + `/srv/media/books` (rw) | `config` + `/srv/media` (ro) + transcode cache |

Both would be **refused today**: each has a newer image staged under its tag, and
the migration refuses rather than bundle an application upgrade into a storage
move. That decision comes first, separately, on its own merits.

Neither has a RepoDigest, so both would record `identity,local` — the exact image
known and present today, with no immutable reference for later. Plex's running
image is `ls308`, built 2026-06-08, with several newer ones already pulled; its
upgrade is overdue as an upgrade.

## What has already been proven

| | proved by |
|---|---|
| real Btrfs conversion, quiesced copy, cutover | all three |
| read-only proof snapshot, `.premigration == snapshot` | all three |
| SQLite integrity of the recovery point | all three |
| **container healthcheck** verification | Kavita (`/api/health`) |
| **non-empty running WAL → clean stop → sidecars removed** | **Navidrome** |
| runtime-state preservation | Navidrome (`running` → `running`) |
| **same container object, same image** | Navidrome (`Created` unchanged) |
| complete recovery metadata + `verify-recovery` | Navidrome |
| three-service topology, independent retention | all three |
| survival of a host upgrade and fleet restart | all three, 2026-10-05 |

## What calibre-web would add: essentially nothing

6 files, 2 directories, 250 KB, no symlinks, no WAL, no sidecars, no healthcheck,
**no readiness line in its logs**. Its post-restart evidence would be weaker than
any migration so far — container running, and nothing else. Two databases, but
Kavita already proved two. It is the smallest remaining risk and the smallest
remaining information.

The honest answer: **migrating calibre-web would prove nothing.**

## What plex would add: symlinks, and a second dirty WAL

Two genuinely new dimensions:

**Symlinks.** The only remaining service with any — including an absolute one
pointing at a container-internal path that does not exist on the host:

```
Cache/va-dri-linux-x86_64/iHD_drv_video.so
  -> /config/Library/Application Support/Plex Media Server/Drivers/imd-…/dri/iHD_drv_video.so
```

and two **chains** (`libiga64.so → libiga64.so.2 → libiga64.so.2.16.0+0`).

That dimension is now covered by tests rather than by hope —
`tests/symlink-verification-smoke.sh`, built to the measured plex layout:

- symlinks are never hashed, and what they point at is never read: a 1 MiB file
  outside the tree, reachable only through a link, must not appear in the manifest
  or in the byte count
- a directory outside the tree, linked absolutely, is not traversed
- a symlink **chain** is not resolved to its eventual file
- dangling targets (absolute and relative) survive and compare
- a retarget to a name of the **same length** is caught — identical file count and
  byte count, so only the metadata manifest can see it
- a **count- and byte-preserving type swap** (symlink ↔ regular file) is caught,
  the one case the content manifest alone cannot see

Four mutants killed, including `find -L` (dereferencing) and `du -sbL` (counting
the target's bytes).

**A second dirty WAL, on a larger tree.** `library.db-wal` is 76,536 B while
`blobs.db-wal` is empty — so one database must checkpoint and the other is
already clean, across 263 MB. Navidrome proved one dirty WAL on 51 MB.

**Its readiness signal is weaker than Navidrome's**, and the difference matters.
Navidrome logs readiness *after* opening and migrating its database; plex's line
is the LinuxServer init script's own probe of port 32400, which proves the
listener came up and nothing about the databases. Those are covered instead by the
snapshot integrity check, which opens both. The pattern is observed from a real
restart on this host, not guessed, and pinned by a test — along with the benign
`Critical: libusb_init failed` that arrives 12s later and must not be read either
way.

## Recommendation: not yet, and not because of risk

Plex is clearly the more valuable of the two, and "because it is next" is no
longer a reason for either. But three things argue against doing it now:

1. **It needs an image decision first.** Running `ls308` from June with newer
   images staged is a pending upgrade, and the migration correctly refuses to
   bundle them. Deciding the upgrade is the higher-value action.
2. **The new machinery has run once.** Recovery metadata, `verify-recovery`,
   runtime-state preservation and the fail-closed restart each have exactly one
   production data point — plus one week of scheduled jobs and one host upgrade.
   A second is worth more after the first has been boring for a while.
3. **Its new dimension is already covered by tests.** Symlink handling was the
   reason to want plex; that is now proven against the measured layout, with
   mutants. A production run would confirm it rather than discover it.

So the next higher-value milestone is **not another migration**. In order:

- **Decide the plex and calibre-web image upgrades** as upgrades, through the
  update path, which is gated on backup age, health and a snapshot — and is the
  path that has never been exercised against a migrated subvolume.
- **Reboot.** `/var/run/reboot-required` is set after the 2026-10-05 host upgrade.
  A reboot is the one event none of the three migrated subvolumes has survived; a
  fleet restart is not the same thing.
- Then plex, with the image question already settled.

Immich stays last and outside this sequence.
