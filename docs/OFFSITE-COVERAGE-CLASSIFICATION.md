# Off-site recovery coverage, per service

What survives the total loss of the N100, classified per service rather than
asserted for the tree as a whole. Measured 2026-10-21 unless marked.

**Local Btrfs snapshots are not off-site protection.** `/srv/data` and
`/srv/snapshots` are subvolumes of one filesystem on one physical device
(`/dev/sda1`, a Samsung 870 EVO). A proof snapshot and a `.premigration` copy
are both on that device. They protect against a bad upgrade, a bad migration and
operator error; they do not survive the SSD failing. Nothing in this document
treats them as if they did.

## 1. The cloud target's real scope

Measured with the shipped resolver (`dr_target_roots cloud`):

```
/srv/data/immich/library
/srv/data/immich/backup-staging
/var/lib/domum-media/recovery-pack
```

Immich-only by design, so `/srv/media` is never swept off-site. A second target
`nas` is declared with `/srv/data` as its root; **whether it is enabled could
not be established** — the production config is `0600 root` and unreadable from
this account. `docs/NAS-INTEGRATION-ARCHITECTURE.md` records that no NAS mount
is configured, so it is presumed inert, but presumed is not measured and it is
listed as an open question rather than folded into the table.

## 2. The encrypted recovery pack's contents

Audited from `recovery_pack_create`, not by decrypting anything — the pack is
age-encrypted to a public key whose private half the operator holds, so its
contents are established from the code that builds it. No secret value appears
here.

| path in the pack | what it is |
|---|---|
| `config/domum-media.conf` | the production configuration |
| `secrets/<each>` | every file `recovery_pack_secret_files` lists |
| `state/backups/<target>-repo.env` | repository metadata, validated by `recovery_pack_repo_metadata_is_safe` before inclusion |
| `state/immich/db_password.sha256` | a fingerprint, not the password |
| `state/traefik/acme.json` | the Let's Encrypt account key and issued certificates |
| `state/uptime-kuma/kuma.db` | a validated dump, not a copy of a live file |
| `meta/git-revision.txt` | the revision that produced the pack |
| `meta/rendered-compose.yml` | the resolved compose configuration |
| restore instructions + manifest | generated |

The pack is correctly **not** inside the backup it would be needed to open, and
delivery off-host is by email. The whole chain rests on the age private key:
37 copies of the pack are equally useless without it.

## 3. Classification

| service | state model | off-site | restore-tested | local snapshot | re-acquirable elsewhere |
|---|---|---|---|---|---|
| **immich originals** | protected-tier | **yes** (23,155/23,155 observed in snapshot) | **partly** — 22 of 23,155 byte-compared, all 17 large originals proven | no (`immich` is still an ordinary directory) | **no — irreplaceable** |
| **immich database** | protected-tier | **yes** (`backup-staging` dump) | **yes** — imported into a disposable PostgreSQL under `ON_ERROR_STOP=1`, and a rebuilt Immich opened it | no | no |
| **traefik** | docker-volume | **yes** — `acme.json` in the pack | no | not possible (volume) | yes — certificates re-issue from Let's Encrypt |
| **uptime-kuma** | docker-volume | **yes** — validated `kuma.db` in the pack | no | not possible (volume) | partly — monitors would be re-created by hand |
| **plex** | protected-tier | **NO** | — | subvolume + proof snapshot | partly — watch history and curated metadata are not |
| **jellyfin** | protected-tier | **NO** | — | subvolume + proof snapshot | partly — same |
| **kavita** | protected-tier | **NO** | — | subvolume + proof snapshot | partly — reading progress is not |
| **navidrome** | protected-tier | **NO** | — | subvolume + proof snapshot | partly — play counts and playlists are not |
| **calibre-web** | protected-tier | **NO** | — | subvolume + proof snapshot | partly — 6 files, 255,729 bytes (measured 2026-10-09) |
| **image archives** (`/srv/data/backups/images`) | — | **NO** | — | on the protected tier | **no for three images** — see below |
| tailscale | stateless | n/a | n/a | n/a | yes — re-authenticate |
| restic-rest-server | stateless | n/a | n/a | n/a | yes |
| `/srv/media` (music, books) | — | deliberately absent | n/a | n/a | yes — that is the point |

### The image archives are the sharpest gap

A recovery point is *service + snapshot + the application that wrote it*.
Measured 2026-10-21 **three** running images were dangling — `RepoTags: []`
**and** `RepoDigests: []`. **Re-measured 2026-10-28 it is two**, because the
Plex upgrade gave its image a tag:

| service | running image | RepoTags | RepoDigest | prune-exposed |
|---|---|---|---|---|
| plex | `7f9a1d574958` | `lscr.io/linuxserver/plex:latest` | **= image Id** | no, since the upgrade |
| traefik | `9c3b91d5fb77` | **none** — tag moved to `9c2a54d87f76` | none | **yes** |
| uptime-kuma | `a8610b3b4c38` | **none** — tag moved to `3e24e96c89ef` | none | **yes** |

traefik's and uptime-kuma's images survive only because a container references
them, so a prune would remove the application half of their recovery points.
Plex's no longer would.

**That is not the same as Plex being recoverable, and the distinction is easy to
get backwards.** Its `RepoDigest` **equals its image Id** —
`sha256:7f9a1d574958…` for both — which this project already records as *not* an
independent registry reference. Measured, the equality holds for **all five**
tagged services:

| service | image Id | RepoDigest equals Id |
|---|---|---|
| plex | `7f9a1d574958…` | yes |
| calibre-web | `d5ad2aaf36f8…` | yes |
| jellyfin | `438e44330078…` | yes |
| kavita | `454f2a77ac74…` | yes |
| navidrome | `9012939114fb…` | yes |

So it is a property of how docker reports images on this host, not of Plex. For
**every** service the `docker save` archive remains the only *proven* copy of
the application half, and `/srv/data/backups/images` is not in the cloud target.
The snapshot half would survive the loss of the host; the application half would
not.

## 4. The minimal optional backup — the shape has CHANGED

**Still not proposed for activation.** No backup policy, target, include path or
exclusion has been changed, and the one measurement that gates the archives is
still outstanding (§5).

What changed since this section was first written: the candidate set is no
longer whole state directories. `domum-media storage capture-state <service>
<dir>` captures **8.90 MiB** of declared essential state across the five
services, against **352.28 MiB** of directories — 2.5%. So the two halves have
very different costs and very different arguments, and they are separated here.

### 4a. Service state — small, and the mechanism now exists

| | |
|---|---|
| what | the output of `storage capture-state`, per service |
| measured size | **8.90 MiB** total (plex 4.90, navidrome 2.14, kavita 1.13, jellyfin 0.46, calibre-web ~0.27) |
| excluded by the declaration | plex `Drivers/` (230.6 MiB, downloaded on demand), navidrome `cache/` (95.4 MiB), kavita `backups/` (3.5 MB — **3.1× the database it backs up**), every `logs/` |
| integrity | `.backup` + `integrity_check` through the service's own sqlite3 where one exists; jellyfin and kavita are recorded `unproven` and never claimed otherwise |
| what a restore proves | the bytes come back and the databases open. **Not** that the service runs against them |

Single-digit MiB per capture before compression, against 130 GiB already in the
repository, and restic stores only changed blocks — so the recurring cost is
bounded by actual database change. **This is no longer the expensive half.**

Two decisions remain, and both are the operator's:

1. **Where the captures live.** They must not be written inside a service
   subvolume, or they would duplicate into every per-service snapshot — the
   same reasoning that puts the image archives in
   `$DOMUM_DATA_ROOT/backups/images`.
2. **Which target carries them.** A third include root on the cloud target
   shares its retention and its password; a separate target keeps the
   immich-only guarantee textually intact and can have its own cadence. The
   cloud target's include set exists so `/srv/media` is never swept off-site,
   and widening it is the kind of change that should be deliberate rather than
   incidental.

### 4b. The image archives — the expensive half, and the one with a real policy question

The archives hold the only **proven** copy of the application half of every
recovery point on this host: no tagged image here has an independent registry
reference (every `RepoDigest` equals its image `Id`), and traefik's and
uptime-kuma's running images are dangling outright. Lose the SSD and the state
half is gone with it; lose the archives alone and the data survives with no
application that can open it.

**Not every archived image deserves permanent off-site retention**, and that is
the policy question — not the size. The proposed rule, all of which the CLI can
already answer:

| rule | why | how it is answered today |
|---|---|---|
| retain off-site only an archive a **still-valid recovery point names** | an archive whose point has been superseded is a local-only artefact; keeping it off-site forever is paying to store an application nothing pairs with | `storage archives` names the point per archive, and `cleanup images` computes the protected set |
| **verify the archive holds the image it claims** before counting it as coverage | the file checksum proves the FILE is intact, which is a different claim from "it restores that image" | `domum_archive_identity` — content-addressed, read-only, no `docker load` |
| **never** select by filename or mtime | the filename is a convenience; the metadata is the record, and this project has already been bitten by reasoning from mtime three times | the `IMAGE_ARCHIVE=` key in `<point>.recovery` |
| retain the **newest** valid point per service, not all of them | a rollback target is the point you would actually roll back to | `storage archives` + the per-service recovery metadata |
| an archive may be **dropped off-site but kept locally** | retention off-site and retention on disk are different decisions, and conflating them is how a local rollback artefact gets deleted to save cloud bytes | — |

**What is still missing is only the size.** `du -sb /srv/data/backups/images`
needs root. Until it is measured there is no recommendation, because
recommending coverage without a size is how a nightly window grows silently —
and a `docker save` of a media-server image runs to hundreds of MiB, so the
archives could plausibly be two orders of magnitude larger than §4a and
everything else in this document combined.

### 4c. Permanently excluded, either way

`/srv/media` in its entirety (music, books), every movie and TV library, Immich
derivatives (`thumbs/`, and the derivative `.mp4` files under `encoded-video/`
but **never** the 58 `-MP.mp4` originals the asset table names), and every
service's transcode, cache and thumbnail directory. No replaceable bulk media.

**Family photographs and videos keep priority.** Any new coverage is additive
and must not slow, displace or compete with the Immich paths. If a measured
size is large enough to affect the nightly window, the answer is a narrower
candidate set, not a longer backup.

Two risks to design around, both already recorded rules:

- Plex's and Jellyfin's state directories contain **large regenerable
  thumbnail and transcode trees**. Reasoning about them from directory names is
  forbidden; `service_essential_state` declares what is essential and the
  exclusions are asserted against it in both directions.
- An exclusion affects **new snapshots only** and applying one must never
  prune. Any saving is gradual by design.

## 5. Open questions requiring root

1. ~~Whether the `nas` backup target is enabled.~~ **Answered, 2026-11-02, and
   not from defaults.** `BACKUP_TARGETS="nas cloud archive"` and
   `backup_target_default_enabled` returns 1 for `nas`, so the defaults alone
   read as enabled — which is the trap. The evidence is the world-readable
   rotated log `/var/log/domum-media/backup.log.5.gz`: across **107
   consecutive nightly runs** (2026-06-09 to 09-26) it contains
   `restic backup -> cloud` 107 times and **zero** occurrences of `nas` or
   `archive` in any form, and `restic_backup_to` logs that line after its
   include-path check, so an enabled-but-broken target would have left either
   it or an `ERROR: no configured include path`. Neither exists. There is also
   no network mount of any kind on this host and no `/srv/nas*`. So `/srv/data`
   is **not** covered by a second enabled target and §4 still stands.
2. `du -sb /srv/data/backups/images` — **still open**, and now the only gate on
   §4b.
3. ~~SMART attributes for both disks.~~ **Answered, 2026-10-21**; see
   `docs/SSD-HEALTH-STATUS.md`. `/dev/sda` has used 0.52% of its 600 TBW;
   `/dev/sdb` reports placeholders, which is why no attribute threshold was
   added.
