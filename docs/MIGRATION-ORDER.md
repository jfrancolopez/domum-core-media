# Migration order — selected from evidence, not from the original plan

Measured 2026-09-25, after the Jellyfin pilot.

| service | files | bytes | `.db` | **non-empty `-wal` now** | symlinks | container healthcheck |
|---|---|---|---|---|---|---|
| jellyfin | 37 | 490 KB | 1 | 0 | 0 | none | ← **migrated** |
| calibre-web | 5 | 242 KB | 2 | **0** | 0 | none |
| **kavita** | **82** | **4.6 MB** | **2** | **0** | **0** | **yes (`healthy`)** |
| navidrome | 1,006 | 51 MB | 1 | **1** | 0 | none |
| plex | 121 | 270 MB | 2 | **2** | **7** | none |
| immich | 64,216 | 213 GB | — | 0 | 0 | (stack) |

## Selected: `kavita`

Not calibre-web, although it is smaller. At 5 files versus 82, and 242 KB versus
4.6 MB, both are trivial — the size difference does not change the risk. What does
differ is **how much the migration can prove afterwards.**

1. **It is the only candidate with a container healthcheck.** `service_is_healthy`
   fails only when Docker reports `unhealthy`, so for every other candidate the
   post-migration health gate means nothing more than "the process started".
   Jellyfin had no healthcheck, which is why its application verification had to
   be done by hand afterwards. Kavita gives the migration a real negative signal,
   and exercises a code path Jellyfin could not.
2. **No non-empty `-wal` right now**, so it should quiesce cleanly as Jellyfin did.
   Navidrome (1) and Plex (2) carry uncheckpointed WALs *at this moment*; whether
   a clean shutdown clears them is unknown, and if it does not the migration
   correctly refuses — after stopping the service. That is safe but avoidable.
3. **No symlinks.** Plex has 7, under `…/Drivers/` and `…/Cache/`. The metadata
   manifest compares symlink targets, so they are covered, but they are a
   copy-fidelity hazard worth meeting later rather than sooner.
4. **Rebuildable.** Worst case is re-scanning a comic/book library.

## Order from here

1. ~~jellyfin~~ — done
2. **kavita** — best verification, trivial size
3. **calibre-web** — trivially small, but weak verification; take it once the
   procedure is twice-proven
4. **navidrome** — first with a live WAL to clear; 1,006 files
5. **plex** — live WALs *and* symlinks; largest of the small ones
6. **immich** — last, and its own phase. 64,216 files, 213 GB, PostgreSQL rather
   than SQLite, and a `.premigration` that would not stay free (see
   `docs/PREMIGRATION-LIFECYCLE.md`).

Nothing here is fixed. Re-measure before each one; the table above is evidence
with a date on it, not a plan.

## What the operator script carries forward from Jellyfin

`/home/jfranco/domum-media-migrate-service.sh <service>` is parameterised so #3–#5
reuse it. It encodes every lesson from the first run:

- the pre-stop fingerprint is **observational**, printed and labelled as such;
- the integrity claim is `.premigration == proof snapshot`, both static;
- the live tree is **classified**, not compared — hard failure only on a *missing*
  file, and the database is never on the runtime allowlist;
- database state is recorded **before** the stop, so the operator can see what the
  clean shutdown had to deal with;
- application verification is a separate stage: container present, Docker health
  not `unhealthy` (waiting out `starting`), and `PRAGMA integrity_check` run on a
  **copy** of each SQLite database, never against the live one;
- the report must say `protected` — `snapshottable` is treated as a failure,
  because it means the data moved but no rollback point survived;
- day-aware scheduled-window guards, and the operation lock;
- `.premigration` is retained, and the script says what evidence should exist
  before anyone removes it.
