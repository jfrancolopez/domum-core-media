# Selective off-site protection for media-service state

**Status: PHASE A measured in part, PHASE B designed, NOTHING ENABLED.**
No backup target, include path, exclusion or schedule is changed by this
document.

## The gap this addresses

The cloud restic target is immich-only by design — three roots:
`immich/library`, `immich/backup-staging`, and the encrypted recovery pack. So
`/srv/data/{plex,jellyfin,kavita,navidrome,calibre-web}` and
`/srv/data/backups/images` exist on exactly one device: the Samsung 870 EVO that
also holds every snapshot and every `.premigration` copy.

**A local Btrfs snapshot is not a backup against losing that SSD.** All five
services are confirmed subvolumes (inode 256, distinct `st_dev`: plex 56,
jellyfin 73, navidrome 68, kavita 74, calibre-web 55), and their snapshots live
on the same filesystem.

## Phase A — inventory

### Measured, 2026-10-30

Read-only, as the unprivileged development account. **Where permissions blocked
a subtree the figure is a LOWER BOUND, and is labelled as one** — a partial
`du` is not a measurement.

| service | visible total | irreplaceable | regenerable | notes |
|---|---|---|---|---|
| plex | **248.1 MiB** | **~4.9 MiB** | 243.2 MiB | complete |
| navidrome | **97.6 MiB** | **2.1 MiB** | 95.4 MiB | complete |
| calibre-web | **272 KiB** | ~all | negligible | complete |
| jellyfin | ≥489 KiB | unknown | unknown | **partial** — `config/` is `911:911` |
| kavita | ≥5.8 MiB | unknown | unknown | **partial** — `config/` is `root:root` |
| `/srv/data/backups/images` | unknown | — | — | **unreadable** — `root 0750` |

### What is irreplaceable, per service

**Plex** — `Library/Application Support/Plex Media Server/`:

| path | bytes | verdict |
|---|---|---|
| `Plug-in Support/Databases/com.plexapp.plugins.library.db` | 414,720 | **irreplaceable** — the library, watch state, collections |
| `…library.db-wal` | 752,496 | irreplaceable (uncommitted pages) |
| `…library.blobs.db` + `-wal` | ~740,000 | irreplaceable |
| `…library.db-2026-10-{19,22,25,28}` | ~415,000 each | Plex's OWN rotation — useful, not essential |
| `Preferences.xml` | 422 | **irreplaceable** — holds the server token; without it the server is a new identity and clients must re-pair |
| `.LocalAdminToken` | 42 | regenerated on start |
| `Drivers/` | **241,843,505** | **regenerable** — downloaded tuner/transcoder drivers, **93% of the whole tree** |
| `Logs/` | 13,151,654 | regenerable |
| `Cache/`, `Crash Reports/`, `Codecs/` | <15 KB | regenerable |

**Navidrome** — `/srv/data/navidrome/`:

| path | bytes | verdict |
|---|---|---|
| `navidrome.db` | 2,199,552 | **irreplaceable** — users, playlists, play counts, ratings |
| `navidrome.db-wal` / `-shm` | 20,632 / 32,768 | irreplaceable (uncommitted) |
| `cache/` | **100,039,592** | **regenerable** — transcode cache, 98% of the tree |
| `artwork/`, `plugins/` | 0 | empty |

**Calibre-Web** — 272 KiB in total, essentially all configuration and its small
SQLite database. Nothing worth excluding; take it whole.

**Jellyfin and Kavita** need root to inventory. Their application layouts put
the irreplaceable part in a known place, so the *design* does not block on the
measurement — only the sizing does:

- jellyfin: `config/data/*.db` (library, users, display preferences) and
  `config/config/*.xml`; `config/metadata/`, `config/transcodes/`, `cache/` are
  regenerable.
- kavita: `config/kavita.db` plus `config/config/`; `config/covers/`,
  `config/cache/`, `config/temp/`, `config/backups/` are regenerable.

### The shape of the answer

For the two services measurable in full, **98% of the bytes are regenerable**:

```
plex        4.9 MiB of 248.1 MiB    = 2.0%
navidrome   2.1 MiB of  97.6 MiB    = 2.2%
```

That is the whole argument for a selective set rather than whole directories.

## Phase B — recovery design

### The compatibility chain

A restored service needs four things to agree, and this project already records
why:

1. **application state** — the SQLite database and configuration;
2. **application version** — the binary that reads that schema;
3. **database schema version** — forward-migrated on startup, and **an older
   image cannot read a newer schema**. This is the defect class recorded for
   Kavita (migrated on startup, leaving a proof snapshot older than the running
   binary) and for Uptime Kuma;
4. **the exact image** — recoverable only if obtainable, and measured
   2026-10-28: every tagged image on this host has a `RepoDigest` **equal to
   its image Id**, which is not an independent registry reference. So the
   `docker save` archive is the only *proven* copy.

A recovery point is therefore **state + version + image**, and restoring state
without the image that wrote it yields a museum piece.

### Application-consistent capture

A running service's SQLite file plus its `-wal` is **crash-consistent at best**.
Measured above: plex has a 752 KB WAL and navidrome a 20 KB WAL right now, so
this is not hypothetical.

Two mechanisms already exist in this repository and should be reused rather
than reinvented:

- `service_sqlite_binary <service>` — declares an in-image `sqlite3`, which is
  what turned calibre-web and uptime-kuma from `unsupported: not checked` into a
  real integrity check. Plex ships its own SQLite (and **must** be used for Plex,
  whose FTS tables use a `collating` tokenizer the host's SQLite cannot open).
- the per-service snapshot/quiesce path used by `storage pre-upgrade-point`.

The capture should be `sqlite3 .backup` **inside the container** (or a stop →
copy → start under the operation lock), never a raw `cp` of a live database.

### Proposed scope

**A separate target, not an expansion of the immich-only one.** The cloud
target's include set exists so `/srv/media` is never swept off-site, and
widening it would put that guarantee at risk for an unrelated reason. A second
target with its own root, password file and retention keeps the existing
recovery guarantees intact and makes the new scope auditable on its own.

Candidate include set:

```
<staging>/plex/Databases/            # sqlite3 .backup output + Preferences.xml
<staging>/navidrome/navidrome.db     # sqlite3 .backup output
<staging>/jellyfin/                  # *.db + *.xml
<staging>/kavita/kavita.db           # + config/
<staging>/calibre-web/               # whole, it is 272 KiB
```

Deliberately **excluded, permanently**: `Drivers/`, `Logs/`, `cache/`,
`transcodes/`, `metadata/`, `covers/`, `artwork/`, every movie, TV and music
file, and Immich derivatives. None is irreplaceable and together they are
roughly 98% of the bytes.

### The image archives

`/srv/data/backups/images` is unreadable without root, so its size is unknown.
The policy question is separate from the size: **not every archived image
deserves permanent cloud retention.** Retain off-site only the images that a
*still-valid* recovery point names — `cleanup images --json` already computes
exactly that set and protects it locally. An archive whose recovery point has
been superseded is a local-only artefact.

This matters most for the images with no registry copy at all. Measured
2026-10-28: **traefik and uptime-kuma** run images with `RepoTags: []` **and**
`RepoDigests: []`, so for those two the archive is the only obtainable copy in
existence.

## Phase C — cost and risk

**Not yet quantifiable, and deliberately not guessed.** The two services that
can be measured in full come to **7.0 MiB of irreplaceable state**. If jellyfin
and kavita are of the same order, the whole selective set is single-digit MiB
per capture before compression and deduplication — negligible against the
130 GiB already in the repository, and restic stores only changed blocks, so
churn is bounded by actual database change.

The sizing that is still missing is jellyfin, kavita, and the image archives.
**No recommendation is made until those three are measured**, because
recommending coverage without a size is how a nightly window grows silently.

Family photographs keep priority: any new coverage is additive, must never
displace or slow the Immich paths, and no replaceable bulk media enters the set.

## Phase D — rehearsal

Not yet performed. It must use disposable fixtures and a scratch restore
location, never live application state, and a synthetic fixture must never be
presented as proof of production recovery.

## The one measurement still needed

Read-only, root, no modification:

```
sudo du -sb /srv/data/jellyfin /srv/data/kavita /srv/data/backups/images
sudo du -b --max-depth=2 /srv/data/jellyfin/config /srv/data/kavita/config | sort -rn | head -20
sudo ls -l /srv/data/backups/images
```

This establishes the two unmeasured services and the archive set. It changes
nothing.
