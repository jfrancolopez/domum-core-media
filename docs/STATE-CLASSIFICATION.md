# Classifying state outside the protected tier

`/srv/data` is the protected tier: snapshotted (once migrated) and backed up.
Anything a container writes **outside** it is listed in the report — but not all
of it matters equally, and treating it as if it did is how a real gap stays
unnoticed.

## The five classes

| class | meaning | finding |
|---|---|---|
| `irreplaceable` | no one can recreate it | **critical** |
| `reconstructable` | durable and worth protecting, but recoverable by re-issuing, re-scanning, or re-entering it | **warning** |
| `media` | replaceable/reacquirable by design (`CLAUDE.md` §2) | none |
| `cache` | regenerated automatically; losing it costs CPU, not data | none |
| `ephemeral` | no meaning across a restart | none |

Two earlier versions of this were both wrong in opposite directions. Flagging
every writable mount produced a warning on a transcode cache, which is alert
fatigue. Flattening everything durable into one severity put a re-issuable
certificate and an irreplaceable photo library in the same bucket.

An unrecognised non-empty mount defaults to **`reconstructable`**: it must be
visible, but an unknown volume is not evidence of irreplaceable data, and crying
wolf is how real findings get ignored.

A *declared* class wins over any inference, for bind mounts as well as volumes.
Previously only volumes could be declared, so there was no way to say what a
bind mount held.

## Production today

```
[reconstructable] traefik: /letsencrypt          covered_by=recovery-pack
[reconstructable] uptime-kuma: /app/data         covered_by=NOTHING
[cache]           jellyfin: /cache
[cache]           plex: /transcode
[cache]           immich_machine_learning: /cache
[media]           calibre-web: /books
[ephemeral]       immich_server: /data
[ephemeral]       immich_redis: /data
```

Nothing outside the protected tier is `irreplaceable`. The Immich library is
*inside* it, so it is not listed here at all.

## "Covered by" — protection that is not a snapshot or a backup target

The Traefik ACME store is copied into the recovery pack on every run. Reporting
it as *"neither snapshotted nor backed up"* was therefore **false**, and a false
warning standing next to a true one devalues both.

`covered_by` names the mechanism. The claim is only made when that mechanism is
**actually present**: the finding is evaluated against the live
`recovery_pack.state`, so a missing or stale pack cannot launder an uncovered
gap into a covered one. When the pack is unavailable the warning comes back and
says why:

> traefik keeps durable state outside the protected tier: … (normally covered by
> the recovery-pack, but that is not available)

Both branches are driven deterministically by the tests. An `if` on the
fixture's own state left whichever branch did not run untested — and two
mutations of the coverage logic survived until that was split apart.

## Uptime Kuma — closed without moving any data

`/app/data` is a Docker volume holding the entire Uptime Kuma configuration:
monitor definitions, notification targets, status pages and the admin account.
Nothing snapshotted it and no backup target included it.

The obvious fix — move it to a bind mount under `/srv/data` — is a production
data move, and therefore an operator boundary. It also carries an ordering
hazard: the compose change must not land before the data move, or a container
restarted against an empty bind mount comes up as a fresh install while the
volume still holds the only copy.

It did not need that. The whole thing is **one 344 KB SQLite database**, and it
is now captured into the recovery pack on every run — no data move, no compose
change, no downtime.

**It is not captured by copying the files.** `kuma.db` runs in WAL mode with an
uncheckpointed `-wal` beside it (8 KB live, measured), so a file copy is a torn
database. The dump uses SQLite's backup API via `sqlite3 .backup`, which takes a
read lock and walks the committed state including the WAL, **without stopping the
service**. Verified against the live database: `integrity_check` → `ok`.

Same discipline as the Immich artefact (`CLAUDE.md` §7): the backup is a
*validated* dump, not raw live storage. Validation happens **inside the
container, before the copy out**, so a corrupt dump never reaches the pack — and
a failure to capture a *running* Uptime Kuma is reported rather than swallowed,
because silently shipping a pack without it is how the gap the pack exists to
close stays open.

The restore instructions delete the stale `-wal`/`-shm` alongside the restored
`kuma.db`. Leaving them beside a *different* database corrupts it.

### What the data is worth today

Measured on this host: **0 monitors, 0 notifications, 0 status pages, 0
heartbeats, 1 user.** Uptime Kuma is deployed but not configured, so the state
being protected is currently just the admin account. The protection matters
because it now applies automatically the moment the operator does configure
monitors — but the report should not be read as guarding significant data yet,
and Uptime Kuma is not in fact monitoring anything.

---

## Two different questions, and the one that was being answered wrongly

The five classes above answer **"how bad is it if this is lost?"**. That is a
*reporting* question, and the classification is good at it.

The upgrade gate asks something else entirely: **"can a pre-upgrade recovery
point exist for this service at all?"** It was answering that by looking at
whether `/srv/data/<service>` exists — and emitting `NOSTATE` when it did not.

`NOSTATE` conflated three states that are not equivalent:

| actually the case | what NOSTATE said | what should happen |
|---|---|---|
| nothing durable at all | no state | report, allow |
| durable state in a Docker volume | no state | **block** — no recovery point is possible |
| declared to have tier state, but the path is missing | no state | **block** — the mount is gone or the declaration is wrong |

Measured on this host 2026-10-08, with a staged image waiting for both:

```
traefik      volume domum-media_traefik-letsencrypt -> /letsencrypt
             acme.json 116,015 bytes mode 0600
             resolver cf: 9 certificates + the ACME ACCOUNT PRIVATE KEY
             (status, traefik-media, plex, kavita, books, media, music,
              photos, status-media -- all .ladomum.com)
             staged: v3.7.10 -> v3.7.12

uptime-kuma  volume domum-media_uptime-kuma-data -> /app/data
             kuma.db 286,720 bytes + a NON-EMPTY -wal (8,272 b) + -shm
             contents: 0 monitors, 0 notifications, 0 status pages,
                       0 heartbeats, 0 maintenance, 1 user
             staged: a8610b3b4c38 -> 3e24e96c89ef
```

Both were reported and **allowed**.

### Why "the recovery pack covers it" was not the answer

It is true — `traefik_acme_source` and `uptime_kuma_dump` both put this state in
the pack, and the sections above are right that this is real coverage. It is the
wrong *kind* of coverage for an upgrade:

* a pack is **periodic and operator-driven**, so it may be arbitrarily stale at
  the moment an upgrade runs;
* it records **no image identity**, so it cannot pair state with the application
  that wrote it — which is the entire content of a rollback point
  (`docs/RECOVERY-POINT-IDENTITY.md`);
* it is **not created before an upgrade**, so it cannot be "the state as the old
  application left it".

Disaster recovery and rollback are different artefacts answering different
questions. Having one is not having the other.

## The upgrade-gate state model

`service_state_models` declares, per service, one of:

| model | meaning | gate |
|---|---|---|
| `protected-tier` | durable state under `$DOMUM_DATA_ROOT`; `report_snapshot_protection` then decides whether it is *actually* protected | allow only when `protected` |
| `docker-volume` | durable state in a Docker volume, which no Btrfs snapshot can reach | **block** |
| `stateless` | no durable state at all | allow, reported |
| *(undeclared)* | — | **block** as `unknown` |

**Declared, because durability cannot be inferred from a mount list.** A volume
holding an ML model cache and one holding a private key are indistinguishable
from the outside. So the project states it.

**Then checked, because a declaration can be wrong or go stale.** The declared
model is verified against what the containers actually mount, and a
*contradiction fails closed*:

* declared `stateless` or `protected-tier` but mounting an **undeclared rw
  volume** → `unknown`, with the destination named;
* declared `stateless` but writing to an **rw bind under the protected root** →
  `unknown` (a different mechanism, the same consequence — the volume check
  alone would miss it);
* declared `protected-tier` but the path is **absent** → blocked as
  `missing-state-path`.

That second property is the one that matters over time: a volume added to a
service later cannot quietly inherit a permissive classification.

Benign destinations may be declared, and immich's are: `/cache` is an ML model
cache (4 KiB, refetched) and `/data` is redis's `dump.rdb` (1.1 MiB of queue
state, rebuilt from the database) plus an empty server scratch directory.
Immich's primary state is on the protected tier. **Never add a destination to
that list to make a gate pass.**

`domum-media storage protection <service>` now reports the model, and exits 0
**only** for genuinely protected state — so `stateless` cannot read as
`protected` to a script testing the exit status.

## Consequence: two services are now correctly blocked

```
plex          protected        exit 0
calibre-web   unprotected      exit 1
traefik       docker-volume    exit 1
uptime-kuma   docker-volume    exit 1
tailscale     stateless        exit 1
```

Neither traefik nor uptime-kuma can be upgraded until a pre-upgrade recovery
point is possible for volume-backed state. That is a **missing capability**, not
a policy to relax: the honest state is "blocked, for a stated reason", and
`APPLY_ALLOW_IMAGE_CHANGE=1` remains the documented, loud override if the
operator decides the risk is acceptable for a patch bump.

---

## Calibre-Web — the decision, and why it is not "because Plex was migrated"

Re-measured 2026-10-08:

```
/srv/data/calibre-web            260 KB, 6 files, inode 4375 (ordinary directory)
  config/app.db              118,784 b   21 tables: users, settings, shelves
  config/gdrive.db            24,576 b   2 tables
  config/.key                     44 b   secret key
  config/calibre-web.log.1    99,969 b   log
  config/calibre-web.log      11,308 b   log
  config/client_secrets.json       3 b
staged                           0.6.26-ls386 -> 0.6.27-ls399
app.db                           integrity_check -> ok
                                 journal_mode -> DELETE  (no WAL, unlike Plex)
```

So the durable configuration is about **145 KB across three files**; the 111 KB
of logs is most of the apparent size. The book library and Calibre's own
`metadata.db` (409,600 b) live on `/srv/media/books`, the media tier.

The three options, against the recovery requirement rather than against symmetry:

**A. Migrate it to a Btrfs subvolume.** *Chosen.*

Calibre-Web is the one remaining service whose durable state is **already on the
protected tier** — it is an ordinary directory in the right place, not state in
the wrong place. Migration is therefore the natural fix rather than a data
relocation, and it is the only change that makes the *proven* upgrade pipeline
available to it: `storage migrate-subvolume` → `updates apply --service`, the
exact path validated end to end on Plex.

It is also the easiest migration yet attempted: 6 files, 260 KB, `journal_mode
DELETE` so there is no WAL to quiesce, and no symlinks — strictly simpler than
Plex, which had 7 symlinks (one absolute into the container namespace) and a
649,792-byte live WAL and still migrated cleanly.

**B. A smaller application-aware backup/recovery mechanism**, like
`uptime_kuma_dump`. *Rejected for this purpose.*

It would work, and it is the right answer for state that cannot move. But a pack
dump is **disaster recovery, not a rollback point**: periodic, no image
identity, not created before an upgrade. It would leave Calibre-Web exactly as
blocked as it is now, while looking like progress. The distinction is the whole
content of the section above.

**C. Leave it blocked.** *Rejected*, but note that this is the honest status quo
and costs nothing except the pending 0.6.27 upgrade. It is the correct answer
for traefik and uptime-kuma today.

**Explicitly not the reasoning:** "Plex was migrated, so migrate this too."
Jellyfin, Kavita, Navidrome and Plex were migrated because their state is on the
protected tier and they hold data worth a rollback point. Calibre-Web qualifies
on the same grounds, measured. Uptime Kuma does **not** qualify and must not be
migrated by analogy — its state is in a volume, moving it carries the ordering
hazard described above, and it currently holds one user account and nothing else.

Migrating `/srv/data` is an operator boundary (`CLAUDE.md` §11), so this is a
decision recorded here, not an action taken.

## Traefik and Uptime Kuma — what they actually need

Not migration. A **pre-upgrade recovery point for volume-backed state**, which
does not exist yet: stop the service, prove quiescence, dump the volume to the
protected tier with a checksum, archive the exact old image, and bind the three
together — the same shape as `storage pre-upgrade-point`, with a volume dump
where the Btrfs snapshot goes.

Until that exists they are correctly blocked, and the blocking is the useful
outcome: before this change a `domum-media apply` would have upgraded both.

Risk notes for when it does exist:

* **traefik** is the one that matters. `acme.json` holds the ACME *account*
  private key plus 9 certificates; losing it means re-issuing under Let's
  Encrypt rate limits, with a TLS outage window. The staged change is a patch
  bump (v3.7.10 → v3.7.12) which almost certainly does not touch the file
  format — but "almost certainly" is exactly the judgement the framework exists
  so that nobody has to make. A v3 → v4 bump is the dangerous shape.
* **uptime-kuma** holds 1 user and nothing else: 0 monitors, 0 notifications,
  0 status pages, 0 heartbeats, 0 maintenance windows. Its database is live and
  WAL-mode, so it must still be quiesced rather than copied, but the data at
  risk today is an admin account. That is a reason to sequence it second, not a
  reason to exempt it.
