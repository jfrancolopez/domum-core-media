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
Measured 2026-10-21, **three** running images are dangling — `RepoTags: []`
**and** `RepoDigests: []`:

| service | running image | the tag now points elsewhere |
|---|---|---|
| plex | `identity,local` | yes |
| traefik | `9c3b91d5…` | `9c2a54d87f76` |
| uptime-kuma | `a8610b3b…` | `3e24e96c89ef` |

Each survives only because a container references it. For these three the
`docker save` archive is the **only** obtainable copy of the application half,
and `/srv/data/backups/images` is not in the cloud target. So the snapshot half
would survive the loss of the host and the application half would not.

## 4. The minimal optional backup — designed, NOT recommended yet

**Deliberately not yet proposed for activation.** The brief requires measured
bytes first, and `du` on these paths needs root; the sizes are the open item in
§5. No backup policy, target or exclusion has been changed.

Shape, if the measurement supports it:

- **Candidates**: `/srv/data/{plex,jellyfin,kavita,navidrome,calibre-web}` —
  application configuration and small SQLite databases — and
  `/srv/data/backups/images`, for the three dangling images above.
- **Explicitly excluded, permanently**: `/srv/media` in its entirety (music,
  books), every movie and TV library, Immich derivatives (`thumbs/`, and the
  derivative `.mp4` files under `encoded-video/` but **never** the 58
  `-MP.mp4` originals the asset table names), and every service's transcode,
  cache and thumbnail directory. No replaceable bulk media.
- **Family photographs and videos keep priority.** Any new coverage is additive
  and must not slow, displace or compete with the Immich paths. If the measured
  size is large enough to affect the nightly window, the answer is a narrower
  candidate set, not a longer backup.
- **Mechanism**: a third include root on the existing cloud target, or a
  separate target. Which one depends on whether the retention policy should
  differ, and that is a decision for after the measurement.

Two risks that must be designed around, both already recorded rules:

- Plex's and Jellyfin's state directories contain **large regenerable
  thumbnail and transcode trees**. Reasoning about them from directory names is
  forbidden; the exclusion has to be verified against what is actually there.
- An exclusion affects **new snapshots only** and applying one must never
  prune. Any saving is gradual by design.

## 5. Open questions requiring root

1. Whether the `nas` backup target is enabled. If it is, `/srv/data` is already
   covered and most of §4 is unnecessary.
2. `du -sb` on the five service paths and `/srv/data/backups/images`, which is
   the gate on §4.
3. SMART attributes for both disks, for the separate disk-health work.
