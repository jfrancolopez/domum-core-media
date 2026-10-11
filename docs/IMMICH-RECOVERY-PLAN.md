# Immich recovery — what is proven, and the route to proving the rest

Measured 2026-10-11. Production checkout `86a1e80`.

---

## 1. The four claims

An original can satisfy any of these independently. They are not degrees of the
same thing.

| | Claim | How it is established | Status |
|---|---|---|---|
| 1 | **LOCAL** — the file the asset table names exists here | `immich_original_inventory` | **23,033 of 23,033**, 0 missing |
| 2 | **IN SNAPSHOT** — that path is in a real off-site snapshot | `verify-snapshot-coverage` (snapshot metadata, no download) | **NOT YET RUN** |
| 3 | **RESTORE TESTED** — restored and compared byte-for-byte | `verify-sample`, `verify-large` | **16 of 23,033** |
| 4 | **APP USABLE** — a recovered Immich served it | not built | **never attempted** |

Claim 2 was previously *inferred* from configuration. It is now observable and
cheap, and running it is the single largest increase in confidence available for
near-zero cost.

---

## 2. The PostgreSQL import: what the evidence does and does not prove

The 2026-10-11 production run recorded:

```
snapshot      : 05a6adb0
dump          : 28,067,272 bytes (restored from the repository)
image         : tensorchord/pgvecto-rs:pg14-v0.2.0
isolation     : --network none, tmpfs PGDATA, no published port, no bind mount
import        : COMPLETED under ON_ERROR_STOP=1 (0 stderr lines)
tables 61   extensions 7   assets 23,033   asset_files 41,450   exif_rows 23,033
originals_upload 22,975   originals_encoded_video 58   originals_elsewhere 0
null_original_path 0   duplicate_original_paths 0
orphan_asset_files 0   orphan_exif 0   assets_without_exif 0   null_checksums 0
```

**Independently confirmed afterwards:** every one of those counts matches the
live production database exactly, the import left **no container and no volume**
behind, and all eleven production containers remained running.

### What this proves

- A real PostgreSQL of the production version **read the backup**, strictly:
  `ON_ERROR_STOP=1` means psql did not skip a statement it could not run.
- The restored rows are **internally consistent** — no orphans of any kind, no
  null or duplicate original paths, every asset has an exif row.
- The schema is complete: 61 tables and all 7 extensions, including `vectors`,
  which only the pgvecto-rs image provides.

### What it does not prove

- That **Immich** can open it. Immich checks its own schema version and runs
  migrations on startup; a database PostgreSQL accepts is not necessarily one
  Immich will mount.
- That users, albums and relationships are **usable**, as opposed to present.
  Measured: this library has 23,033 assets but **0 albums, 0 people, 0 faces**,
  so album and face integrity are untestable here — there is nothing to test.
- That any **asset path resolves** from inside a recovered application.

So the honest level is `DATABASE IMPORT RESTORE TESTED`, which is what the tool
reports. It is not `FULL IMMICH RECOVERY VERIFIED` and the tool says so in its
own output.

---

## 3. Isolated Immich application recovery test — design

**Not built. Requires approval before any step that downloads the library.**

The goal is claim 4: a newly created Immich instance opens the recovered
database, resolves original paths, and serves recovered photos and videos.

### Isolation requirements (non-negotiable)

- A **separate compose project name**, so nothing reconciles the production
  stack. `docker compose up -d` recreates any container whose image changed, so
  a shared project name would be an image deployment vector.
- **No production path mounted.** The recovered library is bind-mounted from a
  scratch directory, read-only.
- **A disposable database** on tmpfs or a scratch volume, never
  `immich_postgres`.
- **No published port** that collides with production, and no attachment to the
  production network.
- **The same image set production runs**, read from `docker inspect`, never
  `:latest` — the point is to test recovery of what exists, not whatever is
  newest.
- Teardown in a trap that also fires on a signal.

### Phases, cheapest first

| Phase | What it proves | Library needed | Download |
|---|---|---|---:|
| **A — schema mount** | Immich starts against the recovered DB and accepts its schema version | none | 28 MB (dump only) |
| **B — representative serve** | Immich resolves and serves a *selected* set of real originals | the sampled + large-verified set | ~1.4 GiB (already local in scratch during a run) |
| **C — full serve** | every original resolves and serves | whole library | ~130 GiB |

**Phase A is the valuable next step** and costs almost nothing: it answers
"will Immich open this database at all", which is the question the PostgreSQL
import explicitly cannot answer. It needs no library download.

Phase B gives genuinely useful evidence — real paths, real bytes, a real
application — without claiming full recovery. It must be reported as
`REPRESENTATIVE RECOVERY VERIFIED (n of 23,033)`, never as full recovery.

Phase C is the only thing that earns claim 4 outright.

---

## 4. Full-library restore: storage, time, bandwidth

Derived from the observed 2026-10-11 run, which transferred 835,199,165 bytes
(dump + 12 sampled + 2 large) inside a 2m39s wall time that also contained a
20-second database import:

```
observed throughput  ~6.4 MB/s  (~54 Mbit/s)
130.4 GiB at that rate  ~5.8 hours
```

That is an **estimate from one sample**, not a measured sustained rate. It is
the right order of magnitude for planning and should not be quoted as a
guarantee.

| Resource | Requirement | Available | Headroom |
|---|---|---|---|
| Scratch disk for the restored library | ~131 GiB | `/srv/data` 716 GiB free | ample |
| Alternative scratch location | ~131 GiB | `/` 366 GiB free | ample |
| Transfer | ~130 GiB from Hetzner | — | ~5.8 h at observed rate |
| Hetzner egress | check the plan's allowance before starting | — | **unverified** |
| Local disk for a disposable Immich | a few GiB (DB + thumbnails it regenerates) | ample | — |
| Wall time including import and startup | allow a working day | — | — |

**Operational notes**

- The restore target must be outside every live data root; `verify-restore`
  already refuses otherwise, and the same guard applies here.
- A full restore competes with the nightly backup at 02:31 and with the weekly
  snapshot prune (Sun 04:30). Run it in a window that avoids both.
- Hetzner egress cost/allowance is the one input I cannot read from this host.
  **Confirm it before approving phase C.**

---

## 5. Recommended order

1. `verify-snapshot-coverage cloud` — establishes claim 2 for all 23,033
   originals. Downloads nothing. Do this first.
2. Continue `verify-large` — 13 files, 6.5 GiB, about 7 runs at the 1 GiB
   budget, accumulating.
3. **Phase A** of the application test — 28 MB, answers the question the
   database import cannot.
4. Phase B, then phase C only with approval and a confirmed egress allowance.

Nothing above changes production. Steps 1–3 are read-only with respect to the
running system.
