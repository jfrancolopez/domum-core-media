# Service #4 — not yet, and here is why

Measured 2026-09-29, after Navidrome. Three services are migrated: Jellyfin,
Kavita, Navidrome. Two candidates remain before Immich, which is deliberately last
and outside this sequence.

| | files | bytes | dirs | symlinks | non-empty `-wal` | healthcheck | readiness log | image |
|---|---|---|---|---|---|---|---|---|
| calibre-web | 6 | 245 KB | 2 | 0 | 0 | none | **none found** | **staged newer** |
| plex | 121 | 272 MB | 171 | **7** | **2** | none | `[migrations] started` only | **staged newer** |

## Both are blocked on the same thing, and it is not a storage question

**Both have a newer image staged under their existing tag.** Under the current
invariant that is no longer dangerous — `compose start` restarts the container
that was stopped, so no image is resolved and nothing can be deployed. But the
preflight still refuses a staged image, deliberately: a migration is not the
moment to discover that an application upgrade is pending.

So for either service, the honest order is:

1. decide about the image upgrade **as an upgrade**, on its own merits
2. then migrate

Not the reverse, and not both at once.

## What each would actually prove

**calibre-web proves almost nothing new.** 6 files, 245 KB, no symlinks, no dirty
WAL, no healthcheck, and **no readiness line in its logs** — so its
post-restart evidence would be weaker than any migration so far: container running,
and nothing else. It is the smallest remaining risk and the smallest remaining
information.

**plex proves two genuinely new things**, and carries the most novelty at once:

- **7 symlinks, one of them absolute**, pointing at a container-internal path:
  ```
  Cache/va-dri-linux-x86_64/iHD_drv_video.so
    -> /config/Library/Application Support/Plex Media Server/Drivers/imd-…/dri/iHD_drv_video.so
  ```
  `cp -a --reflink` preserves symlinks and the metadata manifest compares targets,
  so this is the first migration where that comparison does real work. An absolute
  target that resolves only *inside* the container is exactly the case where a
  naive copy would silently dereference.
- **272 MB and two non-empty WALs** (`com.plexapp.plugins.library.db-wal` and
  `…blobs.db-wal`) — the WAL gate again, but this time with two databases that
  must both checkpoint, on a tree two orders of magnitude larger than Kavita's.

Its post-restart evidence is still weak: no healthcheck, and its logs offer
`[migrations] started` but nothing that reliably means *serving*. A readiness
pattern could be added, but it should be chosen from observed behaviour across a
restart, not guessed — and the only way to observe that is a restart, which is
what the migration would be doing.

## Recommendation: neither yet

Navidrome added three newly proven dimensions on the same day:

1. **non-empty running WAL → clean stop → checkpointed, sidecars removed**
2. **preserved container and image identity** (same container object, `Created`
   unchanged)
3. **complete recovery-point metadata**, the first production use

That is a lot of new machinery exercised once. The useful next step is to let
those three sit — in particular, to see one **nightly backup** and one **weekly
prune** run against a three-subvolume topology — before adding a fourth.

When it is time, **plex** is the more valuable pilot of the two, once its image
decision is made separately. calibre-web is the safer one and teaches less; it is
a reasonable choice if the goal is to finish the set rather than to learn
something.

Nothing here should be read as a decision. The next migration should be chosen
from measurements taken at the time, as this one was.
