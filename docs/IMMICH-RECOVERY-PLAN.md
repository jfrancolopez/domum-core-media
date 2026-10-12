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

## 3b. Phase A RESULT — rehearsed 2026-10-11

`immich-phase-a` is implemented and was rehearsed end to end against real
production data. Only the repository fetch was stubbed; the pinned images, the
internal network, the disposable containers, the strict import, the real Immich
startup and the API queries all ran for real.

```
server image      : sha256:c15bff75068e (pinned from the running container)
network           : INTERNAL -- no route off this host
library scaffold  : 6 of 6 .immich marker(s) restored from the snapshot
import            : COMPLETED under ON_ERROR_STOP=1
restored records  : 23033 asset(s), 2 user(s) before startup
startup           : API answered -- version 2.7.5
after migrations  : 23033 asset(s), 2 user(s)
application layer : authenticated as the recovered admin user
API asset counts  : 13893 photo(s) + 1712 video(s) = 15605 visible
database (visible): 13893 image(s) + 1712 video(s)
database (hidden) : 7428 -- motion-photo components
result            : APPLICATION STARTUP VERIFIED
```

Immich's own log settles the central question:

```
Running migrations -> Finished running migrations
Checking for schema drift -> No schema drift detected
```

**Immich v2.7.5 opens the recovered database, accepts its schema, and serves its
own API over the recovered users and asset records.** The record counts are
identical before and after startup, so migrations did not alter what was
recovered.

### Three findings from the rehearsal

**1. Recovery depends on a DEPRECATED PostgreSQL extension.** Immich printed:

> DEPRECATION WARNING: The pgvecto.rs extension is deprecated and support for it
> will be removed very soon. See .../upgrading#migrating-to-vectorchord in order
> to switch to the VectorChord extension instead.

This is a real, dated risk to *future* recovery: once Immich drops pgvecto.rs,
today's dump will no longer import into a current Immich. Migrating production
to VectorChord is a separate, approved project, but the recovery consequence
belongs on the record now: **the longer this waits, the narrower the window in
which an old backup can be restored into a contemporary application.**

**2. Immich requires its library scaffold, not just the database.** With an
empty upload directory the microservices worker dies:

```
mountChecks {thumbs, upload, backups, library, profile, encoded-video}
Failed to read "<UPLOAD_LOCATION>/encoded-video/.immich"
```

Those `.immich` files are Immich's own 13-byte integrity markers, which exist to
detect a wrong or unmounted volume. They are real backed-up files, so Phase A
**restores all six from the snapshot** (78 bytes) rather than creating them.
Nothing on the filesystem is fabricated to make the application look healthy.

**3. 7,428 of the 23,033 originals are HIDDEN motion-photo components.**
Measured: 13,893 timeline images + 1,712 timeline videos + 7,428 hidden videos.
The API reports only the 15,605 timeline-visible assets, and matches the
database exactly per media type. The hidden ones are the video halves of live
photos — irreplaceable originals that are backed up but never shown in a
timeline. A check comparing the API total against every row fails on a
perfectly healthy recovery, which is what the first version of this comparison
did.

### What Phase A does not establish

No original was restored, so **nothing here shows the library can be served.**
`APPLICATION STARTUP VERIFIED` is deliberately narrow. Phase B (serve the
already-verified subset) and Phase C (serve everything) remain.

### Isolation, as actually enforced

| Control | Mechanism |
|---|---|
| no external side effects | **internal** docker network — measured: container DNS works, `curl https://…` returns 000 |
| right application version | images pinned by **ID** read from the running containers, never the `:release` tag |
| no production database | a fresh container with tmpfs PGDATA |
| no production files | only a scratch upload directory is mounted; no live root at all |
| no name collisions | unique names, refused if taken, network refused if taken |
| nothing left behind | one teardown in a trap that also fires on a signal, and the removal is **asserted** |

The disposable admin password is set with the database's own `pgcrypto` inside
the throwaway container, so no credential tooling or network access is needed
and production credentials are never touched.

---

## 3c. Phase B RESULT — rehearsed 2026-10-12

`immich-phase-b` restores a small representative set of ORIGINALS from the
snapshot and asks the recovered Immich for them through its own API, comparing
the returned bytes by hash.

```
selected        : 8 asset(s), 41.0 MiB to restore
ownership scope : the authenticated user only
                  5949 asset(s) belong to OTHER user(s) and were not tested
restored        : 8 of 8 original(s), 41.0 MiB
photo jpeg         match 00a5580b3641
photo heic         match f6cfdf63d4f2
photo png          match e97e1a3e6298
photo raw          match 59b92d971ff7
video ordinary     match 7d75e232d405
video larger       match 06900c4b5a28
livephoto image    match 9c23bdbf6992
livephoto video    match 2ca5c2fa13a1
thumbnail        : none returned (derivatives were not restored; not a failure)
result            : REPRESENTATIVE RECOVERY VERIFIED (8 of 23033)
```

**A fresh Immich served eight recovered originals with bytes identical to the
restored files**, across every requested media type including the hidden
motion-photo video component of a live photo. 41.0 MiB transferred; no leftover
containers or networks; all eleven production containers untouched.

### What is compared, and what is not

| Endpoint | Treatment |
|---|---|
| `/api/assets/<id>/original` | returns the stored file; bytes **hash-compared** to the restored original |
| `/api/assets/<id>/thumbnail` | **generated** preview; fetched to show the app works, never claimed to match an original |

No thumbnail was returned because derivatives were not restored — reported
explicitly as *not* a failure. That is also useful evidence for the exclusion
question: **serving originals did not require the generated derivatives.**

### Three findings from the rehearsal

**1. Immich enforces per-user ownership, and the first run looked like a bug.**
The selection picked a PNG owned by the non-admin user while authenticating as
the admin; Immich returned nothing and the run reported
`photo png  ERROR no-response`. That was correct authorization, not a serving
defect. Selection is now scoped to the authenticated user's `ownerId`.

**2. A multi-user library needs per-user verification.** Measured: **17,084
assets owned by the admin, 5,949 by the other user.** Proving one user's assets
serve says nothing about the other's, so the report states the ownership scope
and names the untested count.

**3. The live-photo relationship is not 1:1.** Measured: **7,432 images carry a
`livePhotoVideoId`, pointing at 7,428 distinct hidden videos** — four videos are
each shared by two images. The paired video must be followed through the column
rather than derived, and a query assuming a one-to-one mapping would be wrong.

### What Phase B does not establish

**23,025 originals were never restored or served, and only one user was
tested.** A subset proves the path from repository to application works for
these media types; it cannot speak for the whole library. `FULL RECOVERY
VERIFIED` still requires the full ~130 GiB exercise.

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
