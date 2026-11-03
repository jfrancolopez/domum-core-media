# Selective off-site protection for media-service state

**Status: PHASE A measured, PHASE B IMPLEMENTED and tested, NOTHING ENABLED.**
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
| jellyfin | **490.5 KiB** | **~469 KiB** | ~17 KiB | complete |
| kavita | **5.83 MiB** | **~1.13 MiB** | 4.64 MiB | complete |
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

**Jellyfin and Kavita were re-measured 2026-11-02, and the figures above are
MEASUREMENTS rather than lower bounds.** They were labelled partial because
`config/` is owned `911:911` and `root:root` respectively — but both are
`drwxr-xr-x`, so `du` can traverse them, and a run with **stderr left visible**
emitted no permission errors at all. Checking stderr is what turns a lower
bound into a measurement; suppressing it is what made the first attempt
unsure.

**Jellyfin** — `config/` is 490.5 KiB in total:

| path | bytes | verdict |
|---|---|---|
| `data/data/jellyfin.db` | 466,944 | **irreplaceable** — library, users, playback positions |
| `system.xml` | 6,919 | **irreplaceable** — server configuration |
| `encoding.xml` | 2,645 | **irreplaceable** |
| `.aspnet/DataProtection-Keys/*.xml` | 2,000 (2 keys) | **irreplaceable** — these decrypt stored secrets; losing them invalidates saved credentials |
| `network.xml`, `database.xml` | 1,386 | irreplaceable, tiny |
| `log/` | 16,809 | regenerable |
| `data/transcodes/`, `cache/` | 0 | regenerable, currently empty |

**Kavita** — `config/` is 5.83 MiB in total:

| path | bytes | verdict |
|---|---|---|
| `kavita.db` | 1,114,112 | **irreplaceable** — library, users, reading progress |
| `templates/` | 68,438 | configuration, small |
| `backups/` | **3,497,442** | **regenerable** — Kavita's OWN dated dumps of `kavita.db` |
| `logs/` | 750,256 | regenerable |
| `cache-long/` | 620,878 | regenerable |
| `cache.db`, `temp/` | 25,983 | regenerable |
| `themes/`, `images/`, `fonts/` | 0 | empty |

`backups/` is **3.1x the size of the database it backs up** and the largest
single item in Kavita's tree. Taking it off-site would pay three times over for
the same data.

### The shape of the answer — all five services

| service | total | irreplaceable | share |
|---|---|---|---|
| plex | 248.10 MiB | 4.90 MiB | 2.0% |
| navidrome | 97.60 MiB | 2.14 MiB | 2.2% |
| kavita | 5.83 MiB | 1.13 MiB | 19.4% |
| jellyfin | 0.48 MiB | 0.46 MiB | 95.6% |
| calibre-web | 0.27 MiB | ~0.27 MiB | ~100% |
| **total** | **352.28 MiB** | **8.90 MiB** | **2.5%** |

**8.9 MiB of irreplaceable state across all five services**, against 352 MiB of
directories. The ratio is driven almost entirely by Plex's 230.6 MiB of
regenerable `Drivers/`, and it is the whole argument for selecting rather than
taking whole directories.

Jellyfin and calibre-web are small enough that selection buys nothing — take
them whole. Kavita's one exclusion that matters is its own `backups/`.

## Phase B — recovery design (the reasoning)

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

## Phase B — IMPLEMENTED, 2026-11-02 (nothing enabled)

The capture, its verification and its restore exist and are in CI. **No backup
target, include path, exclusion or schedule is touched**: the destination is a
directory the operator names, and that is where it stops.

```
domum-media storage capture-state <service> <dir>
domum-media storage verify-state  <dir>
domum-media storage restore-state <capture-dir> <scratch-dir>
```

### What is declared, and verified present in production

`service_essential_state <service>` emits `kind|relpath` lines, where kind is
`sqlite`, `file` or `dir`. Checked read-only against production on 2026-11-02 —
**all fifteen declared paths exist**, so a real capture would be `COMPLETE` for
all five services:

| service | declared |
|---|---|
| plex | `…/Plug-in Support/Databases/com.plexapp.plugins.library.db`, `…library.blobs.db`, `…/Preferences.xml` |
| navidrome | `navidrome.db` |
| jellyfin | `config/data/data/jellyfin.db`, `system.xml`, `encoding.xml`, `network.xml`, `database.xml`, `config/.aspnet/DataProtection-Keys` |
| kavita | `config/kavita.db`, `config/templates` |
| calibre-web | `config/app.db`, `config/gdrive.db` |

Excluded by name, with the measurement beside each: plex `Drivers/`
(230.6 MiB, downloaded on demand) and `Logs/`, navidrome `cache/` (95.4 MiB of
transcodes), kavita `backups/` (3.5 MB — **3.1× the database it backs up**) and
`logs/`, jellyfin `log/`. Tests assert both directions, so a future
declaration cannot quietly grow a regenerable subtree.

`service_container_path` derives the container path from the longest-matching
bind `Source` rather than assuming `/config`. **kavita's is `/kavita/config`**,
unlike the other four — assuming would have sent its `.backup` to a path that
does not exist in its container.

### Consistency is claimed only where it can be proven

`CAPTURE_MODE` is `consistent` only where the *image* ships an sqlite3:

| service | sqlite3 | mode |
|---|---|---|
| plex | `/usr/lib/plexmediaserver/Plex SQLite` 3.39.4 | `consistent` |
| navidrome | `/usr/bin/sqlite3` 3.45.3 | `consistent` |
| calibre-web | `/usr/bin/sqlite3` 3.45.1 | `consistent` |
| jellyfin | **none** | `unproven` |
| kavita | **none** | `unproven` |
| *the host* | **none** | — |

`.backup` and `PRAGMA integrity_check` run **inside the container**, which for
plex is the only SQLite that can read its `collating` FTS tables. For jellyfin
and kavita the capture falls back to a file copy and records
`file-copy-unproven`; it is never described as consistent. Neither has a `-wal`
on its database today, so the exposure is small — but the mode says what was
actually done rather than what was hoped.

### The manifest

```
SCHEMA_VERSION=2
SERVICE=<name>
CAPTURED_AT=<iso8601>
STATE_ROOT=<path>
CAPTURE_MODE=consistent|unproven
IMAGE_ID=sha256:…|unknown
ITEM=<kind>|<relpath>|<itemmode>|<bytes>|<octal mode>|<sha256>
RESULT=COMPLETE|INCOMPLETE
ITEMS=<n>
```

`IMAGE_ID` is recorded because a recovery point is state **+** the application
that wrote it; a capture is the state half.

A `dir` item's digest covers its sorted file list, those files' contents, and
the **mode of every entry including the directory itself** — jellyfin's
DataProtection keys are 0600 and they decrypt its stored secrets, so a restore
that widened them would be a disclosure while a contents-only digest verified
clean. A `file` item's digest covers contents only, so its mode is recorded
separately and compared (plex's `Preferences.xml` holds the server token).

### Fail-closed

A declared item that is missing, that could not be copied, or whose stored name
**collides** with another item's records `RESULT=INCOMPLETE`, names the item,
and exits 1. `verify-state` then refuses the capture outright. A partial
capture presented as a backup is the defect this project keeps correcting.

The collision case is real rather than defensive: the stored filename folds
`/` and ` ` to `_`, and plex's declared paths contain spaces, so `a/b` and
`a b` map to one name. Without the guard one item would have silently
overwritten the other and both recorded digests would have read the same file.

### Restore

`restore-state` never writes into live state. It refuses a target that equals,
contains or sits inside `service_data_path` — on **resolved** paths, because a
symlink or a `..` would otherwise walk straight into the running service's
tree — refuses a non-empty target, and refuses a capture that does not verify.

The proof is the restored bytes, not the copy's exit status: every item's
digest and mode are recomputed after it lands, and a restored database is
*opened*. Demonstrated in the suite — a database corrupted before capture
restores with a perfectly matching digest and still fails, because a digest
proves the bytes arrived, not that they are a usable database. "I could not
check it" is reported as not-checked, never as a pass.

The report states its own limit: **it proves the capture restores. It is not
evidence that the service runs against it.**

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

`tests/state-capture-smoke.sh`, in CI. 4 mutants, all killed, including the
overlap guard — with its comparison neutralised a restore must actually write
inside the live tree, which is what proves the guard is load-bearing.

A `docker` stub that exits non-zero is on `PATH`, so a code path that tried to
reach the real daemon fails rather than quietly succeeding. One section drives
capture, verify and restore in their own `set -euo pipefail` process, because
the suite's probe runs `set +e` and could not otherwise see an abort under the
options production actually uses.

**Still not done**: a rehearsal that starts a real disposable container against
a restored capture. That is the only thing that would turn "the bytes come
back" into "the application runs against them", and it is the same distinction
the five Immich recovery levels exist to keep apart.

## The one measurement still needed

Jellyfin and Kavita are now measured. Only the image archives remain, and
`/srv/data/backups/images` is `root 0750` so it cannot be read unprivileged.
Read-only, no modification:

```
sudo du -sb /srv/data/backups/images && sudo ls -l /srv/data/backups/images
```

That establishes the archive set's size and how many image tarballs exist. It
is the last input the cost estimate needs, and it changes nothing.

### Why the archive size is the one that could change the recommendation

The application state is **8.9 MiB** in total, which is negligible. A
`docker save` archive of a media-server image is typically several hundred MiB,
so the archives could plausibly be two orders of magnitude larger than
everything else in this proposal combined — and `cleanup images` already keeps
more than one. That is why the retention policy for archives (only images a
*still-valid* recovery point names) matters far more than any decision about
the databases.

## Phase E — the quiesced capture, REHEARSED against a real container

**Measured 2026-11-02.** Unprivileged, on this host, against a disposable
compose project. Production was untouched throughout and verified so afterwards.

This closes the gap Phase D left open: every earlier test of the quiesced path
stubbed `compose_cmd` and `migrate_assert_quiesced`, so nothing had shown the
real container lifecycle. It needed no root — the quiesced capture reads
`/srv/data/<service>`, a **bind mount**, not a Docker volume mountpoint. (The
root blocker measured for `docs/VOLUME-UPGRADE-REHEARSAL.md` is a different
code path: `dump_volume_to_file` tars `/var/lib/docker/volumes/...`, which is
`drwx--x--- root root`.) Conflating the two is what deferred this.

### Isolation, asserted through the real CLI before anything mutated

```
COMPOSE_PROJECT_NAME     domum-caprehearsal      (no such container/volume existed)
service_data_path kavita <tmp>/data/kavita       NOT /srv/data/kavita
compose files            <tmp>/repo/compose/base.yml  only
compose ps -qa           []                      my project held nothing
production kavita        fae6d10aa732            must never appear in my scope
```

The container that came up was `2c2a2e412d74`
(`domum-caprehearsal-kavita`), and the production id was checked absent from
the project's container list before the first stop.

### Case 1 — a non-empty WAL must REFUSE, and must restart the service

The fixture left `kavita.db-wal` at 4,152 bytes by skipping the clean close,
which is what an unclean shutdown looks like. Driving the real function:

```
[domum-media] quiesced capture of kavita (runtime before: running)
 Container domum-caprehearsal-kavita Stopping / Stopped
[domum-media] WARN: Non-empty SQLite write-ahead logs remain after stopping …
[domum-media] WARN: REFUSING: … is not quiesced after the stop. Nothing was captured.
rc=1
runtime after refusal : running
same container id     : YES
capture dir created   : no
```

So the refusal path works against a real stop: the service came back, **the
container id was unchanged** — proving `compose start` rather than a recreate —
and no capture directory was left behind.

### Case 2 — checkpointed WAL, the whole chain

After `pragma wal_checkpoint(TRUNCATE)`:

```
 quiesced        : no open handles, no non-empty WAL, no hot journal
 runtime         : running (unchanged)
[domum-media] quiesced capture complete

CAPTURE_MODE=quiesced
IMAGE_ID=sha256:fd7dc98638c8…            <- read from docker inspect, not invented
ITEM=sqlite|config/kavita.db|file-copy-quiesced|8192|644|4a09165d98…
ITEM=dir|config/templates|dir-copy|4|775|983409dc41…
RESULT=COMPLETE

capture verified: 2 item(s) match their recorded digests
restored 2 item(s) …, all matching their recorded digests
restored databases: 1 checked sound, 0 not checked
capture mode: quiesced -- … This is the strongest capture mode.
this proves the CAPTURE restores. It is not a proof that kavita runs against it.
```

And the restored file is a working database, not just matching bytes:

```
rows:      [(1, 'kavita-rehearsal'), (2, 'uncheckpointed')]
integrity: ok
```

Row 2 is the one that existed only in the WAL before the checkpoint, so the
capture carried the checkpointed state rather than a stale main file.

### Teardown, asserted

`compose down -v` removed the container and the project network; no
`domum-caprehearsal` container, volume or network remains. Production: 11
containers, `kavita` `Up 7 days (healthy)` — the same container, never stopped.

### What this does and does not prove

It proves the quiesced path's **real** behaviour: the stop happens, quiescence
is genuinely evaluated against files on disk, a refusal restarts the service
without recreating it, the capture records the running image's real id, and the
captured database restores and opens.

It does **not** prove the path against the production services. `kavita` here
was a `busybox` container holding a bind mount, not Kavita — so nothing here
shows how Kavita itself shuts down, or whether it checkpoints its WAL on stop.
That is the question the real run would answer, and it causes downtime.
`QUIESCED_CAPTURE_ENABLED` stays 0.

## Phase F — rehearsed against the REAL Kavita image

**Measured 2026-11-03.** Phase E used a `busybox` stand-in, so it proved the
mechanism and left one question open in its own words: *"nothing here shows how
Kavita itself shuts down or whether it checkpoints its WAL on stop."* That is
the question this answers, with the production image.

The image was pinned **by ID** — `sha256:454f2a77ac74…`, read from the running
container — not by `jvmilazz0/kavita:latest`, so a tag that moves cannot change
what was rehearsed. A disposable project, its own bind mount under a temp
directory, no external networks, no Traefik labels, production verified
untouched.

### Kavita checkpoints its WAL on a clean stop

```
running      kavita.db    430,080    kavita.db-wal  4,132,392
clean stop   kavita.db  1,114,112    kavita.db-wal  ABSENT
```

The main database **grew by almost exactly the WAL's content** and the `-wal`
file was removed outright. Verified a second time with the container stopped, to
isolate the claim from anything the restart does. So `migrate_assert_quiesced`
passed on its own terms rather than by luck:

```
 quiesced        : no open handles, no non-empty WAL, no hot journal
 runtime         : running (unchanged)
[domum-media] quiesced capture complete
rc=0   same container id: YES
```

### The capture is real Kavita state

```
CAPTURE_MODE=quiesced
IMAGE_ID=sha256:454f2a77ac740b70c58cc7300a11122fc9ce7b7e2161ef5b0d1df8f81067cc85
ITEM=sqlite|config/kavita.db|file-copy-quiesced|1114112|644|0f94e7429c25…
ITEM=dir|config/templates|dir-copy|68438|755|6bbb0ceaa900…
RESULT=COMPLETE
```

The captured database opens read-only with **84 tables** and
`integrity_check: ok`, and the table names are Kavita's own
(`AppUserAnnotation`, `AppUserBookmark`, `AppUserCollection`, …) — so this is
the application's real schema, not a fixture's.

### A measurement that is easy to misread

After the capture the service is restarted, and Kavita immediately creates a
**new** 41,232-byte `-wal`. Looking at the directory *after* a capture therefore
shows a non-empty WAL, which says nothing about the state the check saw. The
decisive evidence is the main database's growth and the WAL's absence **while
stopped**; the post-restart size is a different file in a different epoch. Both
were recorded here because reading the later one as the earlier one would have
inverted the conclusion.

### What is now settled, and what is not

Settled: Kavita's clean shutdown leaves no WAL, so the quiesced capture path
succeeds for it on its merits, and the captured database is sound and complete.

Not settled: **jellyfin**, the other service with no sqlite3 anywhere, has not
been rehearsed this way. And this remains a disposable Kavita with an empty
library — a production instance has 8 days of uptime, a populated library and
active scan tasks, so its shutdown has more to finish. The real run still
causes downtime and `QUIESCED_CAPTURE_ENABLED` stays 0.

## Phase F (continued) — Jellyfin, and the defect the real image exposed

**Jellyfin also checkpoints its WAL on a clean stop.** Measured 2026-11-03 with
the production image pinned by ID (`sha256:438e44330078…`): a
3,188,912-byte `jellyfin.db-wal` before the stop, and
`quiesced: no open handles, no non-empty WAL, no hot journal` after it. Both
services with no sqlite3 anywhere behave the same way, which is the result the
quiesced path needed.

Its six declared items appear in **stages** during startup —
`config/encoding.xml` is absent until Jellyfin finishes initialising — so a
capture taken mid-startup correctly reports `INCOMPLETE`. That is fail-closed
working, not a defect, and it is worth knowing before anyone schedules one.

### The capture failed, and it was right to — but it had already taken downtime

```
ITEM=dir|config/.aspnet/DataProtection-Keys|FAILED||
RESULT=INCOMPLETE          1 of 6 declared item(s) could not be captured
rc=1                       service restarted, same container id
```

The directory was present. The key inside is **`-rw------- root root`**, and the
rehearsal ran unprivileged, so `cp -a` could not read it. The one declared item
that is mode-restricted is exactly the one that decrypts Jellyfin's stored
secrets, so failing closed on it is the correct outcome — and no fixture could
have produced this, because a fixture's 0600 key is owned by the user running
the test.

**But the capture had already stopped the service.** `capture-state` did not
require root, while every other `storage` subcommand does. So an unprivileged
operator would take real downtime for a capture that could never succeed. "A
closed gate that still causes downtime is not a closed gate" applies to a
missing privilege exactly as it does to a feature flag.

Fixed: `need_root` is the **first** thing the quiesced path does — before the
gate, before the lock, and above all before the stop — and the ordering is
asserted both behaviourally (nothing locked, nothing stopped, no destination
created) and positionally in the source.

### `FAILED` now names its cause

`FAILED` alone sent nobody anywhere, and an unactionable failure trains the
operator to ignore it. An item that exists but cannot be read is recorded
`FAILED:UNREADABLE`, which is overwhelmingly a privilege problem.

Three readers examine an item mode — the capture's own tally, `verify-state`
and `restore-state` — and all three had to learn the labelled form. Matching
only the bare `FAILED` would have made a `FAILED:UNREADABLE` item look like
something to restore; that second site was caught by checking every match
rather than the first one.
