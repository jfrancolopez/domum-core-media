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

## 6. What one root run would settle

```
sudo domum-media-backup dr-status
sudo domum-media-backup exclusion-audit --proposed
sudo domum-media-backup verify-restore cloud
sudo domum-media-backup verify-sample cloud 12
sudo domum-media-backup dr-status
```

- `dr-status` first, to record the starting point and resolve the UNKNOWNs that
  are only unknown because of permissions.
- `exclusion-audit --proposed` to re-confirm, as root and against live data,
  that the proposed patterns reach no original.
- `verify-restore` restores the Immich dump into an isolated scratch directory
  (asserted to be outside every live data root) and revalidates it.
- `verify-sample` restores a deterministic, diverse sample of real originals
  and compares them byte-for-byte, now recording the population.
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
