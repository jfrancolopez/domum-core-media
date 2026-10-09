# Disaster recovery status — what is actually proven

Measured 2026-10-09 by read-only inspection. `domum-media-backup dr-status`
reports this from recorded evidence; this document explains the levels and
records what could not be determined without root.

---

## 1. The five levels

They are deliberately not collapsible into a boolean. "A backup exists" and
"recovery works" are different claims, and every reporting defect in this
project's history was the weaker claim stated in the stronger claim's words.

| Level | Means |
|---|---|
| `UNKNOWN` | No evidence either way. **Never** a pass. |
| `CONFIGURED` | The path is in the backup set and not matched by an exclusion. |
| `BACKED UP` | A successful run recorded a snapshot covering it. |
| `RESTORE TESTED` | Some of it was restored and compared, **with a stated denominator**. |
| `FULL RECOVERY VERIFIED` | All of it was restored and the owning application confirmed the result. |

The verdict follows the **weakest** tier, not the strongest. Promoting one tier
does not promote the report.

---

## 2. Current state

### Backup target: `cloud` (Hetzner) — the only enabled target

From `/var/log/domum-media/backup.log.2.gz` (the one world-readable rotation)
and `systemctl`:

```
domum-media-backup.timer   last trigger 2026-10-09 02:31:06 EDT, Result=success
domum-media-backup.service ExecMainStatus=0

per run: pg_dump immich -> backup-staging, then  restic backup -> cloud
         processed 64,237 files, 212.358 GiB
         daily incremental added 9.9-59.0 MiB
         elapsed 14-16 s
         then: refresh recovery-pack
```

Only `cloud` appears. `nas` is a configured target name with no NAS behind it.

### Per tier

| Tier | Level | Evidence / gap |
|---|---|---|
| Immich originals (22,975 files, 130.2 GiB) | **BACKED UP** | Covered by the daily snapshot. No sample restore proof with a stated population exists on this host. |
| Immich database | **BACKED UP** | The validated atomic dump is staged and covered. Whether it has ever been restored and revalidated is **UNKNOWN** — the record lives in a root-only directory. |
| Motion-photo originals (58 files, 218.9 MiB) | **BACKED UP** | Covered today. They would have been **lost** under the naive exclusion proposal; see `docs/BACKUP-EXCLUSION-PROPOSAL.md`. |
| Immich derivatives (82.5 GiB) | **BACKED UP** | Regenerable. Proposed for exclusion, not applied. |
| Service state on the protected tier | **BACKED UP** | ~0.66 GiB total across six services. |
| Docker-volume state (traefik, uptime-kuma) | **BACKED UP** by the recovery pack | The pack records **no image identity** and is not taken before an upgrade, so it is disaster-recovery material, not a rollback point. Upgrades of both remain correctly blocked. |
| Image archives (`/srv/data/backups/images`) | **CONFIGURED** | The directory exists and was written 2026-10-09 10:44 by the Calibre-Web upgrade. Its contents are root-only; the archive set was **not** independently confirmed to be inside the snapshot. |

**Nothing is `FULL RECOVERY VERIFIED`.** No run has ever restored a whole tier
and had the owning application confirm it.

---

## 3. Storage picture

`/srv/data` — `/dev/sda1`, btrfs, 931.51 GiB:

```
Device allocated   220.02 GiB
Used               214.74 GiB      (24%)
Free (estimated)   715.36 GiB
```

| Tree | Logical (du) | GiB |
|---|---:|---:|
| `immich` | 228,981,511,583 | **213.26** |
| `plex` + `plex.premigration` | 516,479,455 | 0.48 |
| `navidrome` + `.premigration` | 103,098,260 | 0.10 |
| `media`, `kavita`, `jellyfin`, `calibre-web` and their `.premigration` copies | ~102,113,000 | 0.10 |

Immich is **99.3%** of the protected tier. Everything else, including every
`.premigration` copy, is under 0.7 GiB.

The logical sum (~213.9 GiB) is within ~0.8 GiB of the btrfs `Used` figure
(214.74 GiB), which is the useful result: the reflinked `.premigration` copies
and all retained snapshots share extents with the live trees and cost almost
nothing exclusive. **Retaining them is not a space problem** and no space
argument justifies deleting them.

Headroom is ample: 715 GiB free, and the library grows by tens of MiB a day.

---

## 4. Immich storage layout, measured

Host `/srv/data/immich/library` → container `/usr/src/app/upload`.

| Subtree | Files | GiB | Nature |
|---|---:|---:|---|
| `upload/` | 22,976 | 130.2 | originals (+1 marker) |
| `encoded-video/` | 9,087 | 77.3 | 9,028 derivatives **+ 58 originals** |
| `thumbs/` | 32,423 | 5.4 | 100% derivative |
| `backups/` | 15 | 0.4 | Immich's own DB dumps |
| `library/`, `profile/` | 1 each | 0 | markers only — no external library |

`select count(*) from library` → 0, so every asset is Immich-managed. 23,033
assets (13,893 image, 9,140 video), 0 trashed, 23,033 distinct original paths.

---

## 4b. Original-asset inventory, reconciled (2026-10-09)

The database is the only authority for what counts as an original. Reconciled
completely, with nothing assumed:

| Bucket | Assets |
|---|---:|
| originals under `upload/` | 22,975 |
| originals under `encoded-video/` (motion-photo parts) | 58 |
| originals under `thumbs/`, `library/`, `profile/`, `backups/` | 0 |
| originals anywhere else, or outside the library | 0 |
| **total `asset` rows** | **23,033** |

```
distinct originalPath values : 23,033   (so no two assets share a path)
null or empty originalPath   :      0
soft-deleted assets          :      0
paths NOT present on disk    :      0
total bytes on disk          : 139,989,935,700  (130.4 GiB)
over the 256 MiB sample cap  : 17 files, 7.9 GiB
```

So the earlier figure of 22,976 was wrong in two directions at once: it
**included** one 13-byte `.immich` marker and **excluded** the 58 motion-photo
originals. The marker was not merely counted — because selection picks the
median-sized file of each extension, it became the representative of extension
"immich" and was reported as a restored original:

```
match     immich           13  .immich
```

Coverage is now computed from `asset.originalPath`. The first consequence is
visible immediately: a `-MP.mp4` motion-photo original is now sampleable, and
one was selected on the first run — the first time any of those 58 files has
ever been restore-tested.

---

## 4c. Database import: what the archive checks never proved

`verify-restore` checks gzip, size and footer. Those prove the **file** is
intact and say nothing about whether PostgreSQL can read it.

`verify-db-restore` imports the restic-restored dump into a disposable
PostgreSQL. Measured against the real production dump (28,066,699 bytes):

```
image      : tensorchord/pgvecto-rs:pg14-v0.2.0   (production's own image)
isolation  : --network none, tmpfs PGDATA, no port, no bind mount
import     : 20 s, exit 0, ZERO stderr, under ON_ERROR_STOP=1
tables     : 61            extensions : 7  (incl. vectors 0.2.0)
assets     : 23,033        asset_file : 41,450        exif rows : 23,033
orphans    : 0 asset_file, 0 exif, 0 album_asset, 0 face
assets without exif : 0    null originalPath : 0    duplicate paths : 0
originals  : 22,975 upload/ + 58 encoded-video/ + 0 elsewhere
checksums  : 23,033 non-null (22,282 distinct)
```

Every count matches production exactly, and the path reconciliation holds
inside the restored copy.

The image matters: the dump declares `CREATE EXTENSION vectors WITH SCHEMA
vectors`, which only the pgvecto-rs image provides. A plain `postgres:14` would
fail for a reason that has nothing to do with the backup, so the image is read
from `docker inspect immich_postgres` rather than hardcoded, and an absent image
reports NOT ATTEMPTED rather than pulling during a verification run.

A deliberately truncated dump fails, naming the column it died on — so the
check is not vacuous.

### The three claims, kept apart

| Claim | Means | Status |
|---|---|---|
| ARCHIVE VALIDATED | gzip, size and footer of the restored file | **YES**, 2026-10-09 |
| DATABASE IMPORT RESTORE TESTED | a real PostgreSQL imported it strictly and the rows are self-consistent | **YES**, rehearsed against the real dump |
| FULL IMMICH RECOVERY VERIFIED | a rebuilt Immich served the restored library | **NO** — never attempted |

`dr-status` previously promoted the first to `RESTORE TESTED`. It no longer
does: archive checks are reported and the level stays `BACKED UP` until an
import has actually happened.

---

## 5. The exact missing piece

Priority 1 asked whether family photo and video recovery from Hetzner is
verified. It is **not**, and the gap is now precisely stated rather than
estimated:

1. **No sample restore proof exists on this host** — or if one does, it is in
   `/var/lib/domum-media/restore-verification`, which is `0700 root`, so an
   unprivileged check cannot tell the difference between "never run" and
   "cannot read". That ambiguity is reported as UNKNOWN, not as absence.

2. **Even a passing sample proof would not have covered the largest files.**
   The per-file sampling cap is 256 MiB and 17 originals totalling 7.9 GiB
   exceed it. Before the coverage change those files were silently outside the
   candidate set and the report said only "12 sampled, 12 matched". The
   coverage artefact now states the denominator and names the never-sampled
   set. Raising `SAMPLE_MAX_FILE_BYTES` is the remedy, and it is a deliberate
   cost decision, not a default.

3. **The Immich dump has never been proven restorable here**, as far as can be
   determined without root.

None of this is evidence of a *broken* backup. The backup runs daily, succeeds,
and covers 212.358 GiB. It is evidence that **recovery has not been
demonstrated**, which is a different and currently unresolved thing.

---

## 5b. The large originals, proven progressively

17 originals exceed the 256 MiB per-file sample cap: **15 `.mov` and 2 `.mp4`,
from 274 MB to 1.38 GB, 7.9 GiB in total.** They are the home videos — the
least replaceable files in the library and the least represented by a sample of
photos.

Raising the cap is the wrong fix: it would fetch 7.9 GiB from Hetzner on every
run to move a reported percentage. `verify-large` accumulates coverage instead:

| Mechanism | Effect |
|---|---|
| smallest unproven file of each container format first | a run covers a new format before a second copy of a proven one |
| `LARGE_MAX_RUN_BYTES` (default 1 GiB) | caps one run, names itself when it defers, always allows one file so it cannot deadlock |
| durable history (`<target>-large-verified.jsonl`, 0600) | a proven file is never fetched again |
| `--revalidate` | the only way to re-prove something |
| `--plan` | states the exact byte cost and contacts nothing |

A default run against the real library is **2 files, 524.4 MiB** — one `.mov`
and one `.mp4` — against the 2.2 GiB an unbounded "verify 3" would have cost.
Nine runs at that rate would cover the whole set.

A mismatch is recorded as `MISMATCH` and is **not** counted as proven
afterwards, so a corrupted large original cannot quietly become part of the
coverage figure.

---

## 5c. What goes off-site, and what must not

Hetzner should hold the irreplaceable things and nothing whose recovery plan is
"download it again". `dr-status` now states the scope rather than leaving it to
be inferred:

```
BACKUP SCOPE (what goes off-site)
  included                           /srv/data
  excluded                           /srv/data/immich/backup-staging/*.tmp
  excluded                           /srv/media/.cache/*
  replaceable media tier             not in the backup set (correct: /srv/media is reacquirable)
  image archives                     N in /srv/data/backups/images (in the backup set)
```

| Should be off-site | Status |
|---|---|
| family originals (23,033 / 130.4 GiB) | **in** |
| Immich PostgreSQL dump | **in** |
| application state on the protected tier | **in** |
| small databases (traefik `acme.json`, uptime-kuma `kuma.db`) | in, via the recovery pack |
| recovery metadata and image archives | **in** (`/srv/data/backups/images`) |

| Should NOT be off-site | Status |
|---|---|
| films, television | none exist on this host yet |
| music (975 MiB), books (496 KiB) | **out** — `/srv/media` is not under the include root |
| regenerable thumbnails (5.4 GiB) | **in** — the proposal would remove them |
| transcodes (77.1 GiB) | **in** — the proposal would remove them |
| caches | **out** — `/srv/media/.cache/*` excluded |

So the distinction is already correct for the replaceable *media* tier, and the
remaining 82.5 GiB of regenerable Immich derivatives is the one deliberate
overpayment — gated, measured, and not yet applied.

### How history is preserved when an exclusion takes effect

A restic exclusion affects **new snapshots only**. Existing snapshots keep their
own file lists and the data they reference: restic is content-addressed, so a
blob stays in the repository while any snapshot still references it. Switching
`BACKUP_EXCLUDE_IMMICH_DERIVATIVES` on would therefore:

- leave every existing snapshot complete and restorable, derivatives included;
- stop *adding* derivative blobs from the next run onward;
- free nothing until retention eventually forgets those older snapshots **and**
  a `prune` runs.

That is why the saving is gradual rather than immediate, and why **no snapshot
is pruned as part of applying an exclusion.** Old snapshots are the fallback if
the exclusion ever turns out to be wrong.

---

## 6. What one root run would settle

```
sudo domum-media-backup dr-status
sudo domum-media-backup exclusion-audit --proposed
sudo domum-media-backup verify-restore cloud
sudo domum-media-backup verify-db-restore cloud
sudo domum-media-backup verify-sample cloud 12
sudo domum-media-backup verify-large cloud
sudo domum-media-backup dr-status
```

- `dr-status` first, to record the starting point and resolve the UNKNOWNs that
  are only unknown because of permissions.
- `exclusion-audit --proposed` to re-confirm, as root and against live data,
  that the proposed patterns reach no original.
- `verify-restore` restores the Immich dump into an isolated scratch directory
  (asserted to be outside every live data root) and revalidates it.
- `verify-db-restore` imports the restored dump into a disposable PostgreSQL,
  which is the only thing that proves PostgreSQL can read it.
- `verify-sample` restores a deterministic, diverse sample of real originals
  and compares them byte-for-byte, now recording the population from the asset
  table.
- `verify-large` proves two of the 17 over-cap home videos (524 MiB) and
  records them, so later runs continue rather than repeat.
- `dr-status` again, to show what the run actually earned.

All five are read-only with respect to production: they restore into scratch,
mutate no service, and run no restic `forget`, `prune` or `repair`.

After that run, the honest claim becomes `RESTORE TESTED` for both Immich tiers,
with a stated fraction. `FULL RECOVERY VERIFIED` remains unearned and will stay
so until a whole tier is restored and Immich itself confirms the result.

---

## 7. Claim status

| Claim | Status |
|---|---|
| The backup runs daily and succeeded 2026-10-09 02:31 | MEASURED (systemd) |
| `cloud` is the only enabled target | MEASURED (backup log) |
| 64,237 files / 212.358 GiB per run | MEASURED (backup log) |
| Immich is 99.3% of the protected tier | MEASURED |
| `.premigration` copies and snapshots cost ~0.8 GiB exclusive | MEASURED (btrfs `Used` vs logical sum) |
| 58 originals live under `encoded-video/` | MEASURED (live asset table) |
| 17 originals exceed the sampling cap | MEASURED |
| Immich originals are restorable from Hetzner | **NOT VERIFIED** |
| The Immich dump is restorable from Hetzner | **UNKNOWN** (root-only evidence) |
| Image archives are inside the snapshot | **UNKNOWN** (root-only directory) |
| Any tier is fully recoverable | **NOT VERIFIED** — no such run has been performed |
