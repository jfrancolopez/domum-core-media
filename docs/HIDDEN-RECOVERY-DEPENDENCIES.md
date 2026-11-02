# Hidden recovery dependencies

Things a recovery needs that **no backup list mentions**, because they are not
files in an obvious place, not derivable from a directory name, or not on this
host at all.

Every entry here is a measurement already recorded in this repository, with the
document that holds the evidence. Nothing is inferred from configuration: this
file exists because each of these was discovered by *doing* something rather
than by reading a backup scope, and several were discovered only after a
reasonable-looking check had already given the wrong answer.

The failure mode they share: **the backup reports success and the restore
reports success, and the application still does not come up.**

---

## 1. The age private key — the whole chain rests on it

`37 encrypted recovery packs` existed on 2026-10-12, the newest 0 days old,
off-host delivery by email ENABLED, and the pack correctly **not** inside the
backup it would be needed to open. All of that is worth nothing without the age
private key, which is held by the operator and deliberately not on this host.

- **Why hidden**: it is the one input whose absence cannot be detected from the
  machine whose loss is being planned for. The audit's verdict is `UNPROVEN`
  rather than clean for exactly this reason.
- **Status**: the single highest remaining recovery risk. Open as P5.2.
- **Evidence**: `docs/RECOVERY-KEY-CUSTODY.md`.

Thirty-seven copies of an unopenable file are thirty-seven unopenable files.

---

## 2. Immich depends on a DEPRECATED PostgreSQL extension

The Immich dump declares `CREATE EXTENSION vectors WITH SCHEMA vectors`, which
only `pgvecto.rs` provides. A plain `postgres:14` fails to import for a reason
that has nothing to do with the backup — which is why
`verify-db-restore` reads the image from `docker inspect` and never hardcodes
it, and reports NOT ATTEMPTED rather than pulling.

Immich itself warns that `pgvecto.rs` support *"will be removed very soon"* in
favour of VectorChord.

- **Why hidden**: it is a property of the dump's **contents**, not of the
  backup. The dump is intact, restorable and verified; the set of Immich
  versions able to import it shrinks over time regardless of anything this host
  does.
- **Status**: a recovery risk independent of whether production is ever
  upgraded. Not mitigated.
- **Evidence**: `docs/IMMICH-RECOVERY-PLAN.md`, and §7 of `CLAUDE.md`.

---

## 3. Immich needs its library SCAFFOLD, not just the database

With an empty upload directory the microservices worker dies on

```
Failed to read "<UPLOAD_LOCATION>/encoded-video/.immich"
```

after reporting mountChecks for all six subtrees. Those `.immich` files are
Immich's own 13-byte integrity markers. **78 bytes in total** decide whether a
recovered Immich starts.

- **Why hidden**: six 13-byte files inside a 130 GiB library. A restore plan
  written around "restore the originals" misses them, and the symptom is a
  crash in a worker rather than a missing-file error.
- **Status**: `immich-phase-a` restores all six from the snapshot. Nothing is
  fabricated to make the application look healthy.
- **Evidence**: rehearsed 2026-10-11; `docs/IMMICH-RECOVERY-PLAN.md`.

---

## 4. 58 Immich originals live under `encoded-video/`

Measured against the live asset table: **58 assets keep their `originalPath`
under `encoded-video/`** — motion-photo parts named `<uuid>-MP.mp4`,
**218.9 MiB**, with no derivative rows of their own.

The obvious exclusion — "`thumbs/` and `encoded-video/` are derivatives" — would
have removed the only backed-up copy of all 58 and reported success. `thumbs/`
genuinely is 100% derivative (16,211 preview + 16,211 thumbnail + 1 marker =
the 32,423 files on disk, exactly). `encoded-video/` is not.

- **Why hidden**: **a filesystem walk of `upload/` cannot find them.** Only the
  database can. Never reason about what is regenerable from directory names.
- **Status**: the asset table is the only authority for what is an original;
  `immich_original_inventory` is built from `asset.originalPath`, and
  `exclusion-audit` checks the patterns against the live table.
- **Evidence**: `docs/BACKUP-EXCLUSION-PROPOSAL.md`.

---

## 5. 7,428 of the 23,033 originals are HIDDEN from the API

13,893 timeline images + 1,712 timeline videos + **7,428 hidden videos**. The
API reports only the 15,605 timeline-visible assets. The hidden ones are the
video halves of live photos: irreplaceable, backed up, never shown in a
timeline.

- **Why hidden**: a verification comparing the API's total against every
  database row **FAILS on a perfectly healthy recovery** — which the first
  version of that comparison did. And the relationship is **not 1:1**: 7,432
  images carry a `livePhotoVideoId` pointing at 7,428 distinct videos, so four
  videos are each shared by two images. Follow the column; never derive the
  pair.
- **Status**: the API total is compared per media type against the database.
- **Evidence**: `docs/IMMICH-RECOVERY-PLAN.md`.

---

## 6. Jellyfin's DataProtection keys decrypt its stored secrets

`config/.aspnet/DataProtection-Keys`, mode 0600, about 2 KB, inside a 490 KiB
state directory.

- **Why hidden**: a restore plan written around "the database" misses them, and
  the symptom is not a crash — it is stored credentials that silently no longer
  decrypt.
- **Status**: declared in the selective capture
  (`service_essential_state jellyfin`), and the capture's directory digest
  covers **modes** as well as contents, so a restore that widened 0600 to 0644
  fails verification instead of quietly becoming a disclosure.
- **Evidence**: `docs/SELECTIVE-STATE-PROTECTION.md`.

---

## 7. No image on this host has an independent registry reference

Measured 2026-10-28 and re-checked since: **every tagged image's `RepoDigest`
equals its image `Id`**, which is not an independent registry reference. And
traefik's and uptime-kuma's running images are dangling outright —
`RepoTags: []` **and** `RepoDigests: []` — surviving only because a container
references them.

- **Why hidden**: `docker images` shows a tag, and a tag reads as "I can pull
  this again". A recovery point is service + state + **the application that
  wrote it**, and restoring state without that application yields a museum
  piece.
- **Status**: the `docker save` archive is the only **proven** copy. Its
  identity is now provable read-only — an archive contains a blob whose digest
  equals the recorded image id — so "the file is intact" and "it holds the right
  image" are separate, reported claims. What is still unproven is that a loaded
  image **runs**.
- **Evidence**: `docs/RECOVERY-POINT-IDENTITY.md`.

### 7a. …and the archives are not off-site

`/srv/data/backups/images` is **not** in the cloud target, whose three roots are
`immich/library`, `immich/backup-staging` and the recovery pack. So the state
half of the five migrated media services survives losing the SSD and the
application half does not.

- **Status**: a KNOWN, ACCEPTED limitation, not an oversight. Expanding the
  scope needs a measured, selective proposal; `du -sb` on the archives needs
  root and has not been run.
- **Evidence**: `docs/OFFSITE-COVERAGE-CLASSIFICATION.md`.

---

## 8. Plex's databases can only be checked by Plex's own SQLite

Plex's databases carry FTS virtual tables built with its own `collating`
tokenizer, which only Plex's bundled SQLite registers. The host's SQLite raises
`unknown tokenizer: collating` on both `integrity_check` and `quick_check` for
a **perfectly sound file** — measured: `page_count`, `schema_version`,
`journal_mode` and all 254 `sqlite_master` rows read fine, exactly 2 objects use
that tokenizer, and Plex's own SQLite returns `ok` with zero foreign-key
violations.

- **Why hidden**: a recovery that validates the restored database with a generic
  `sqlite3` concludes the backup is **corrupt**. That exact thing happened: a
  migration reported those two databases as a failed recovery point.
- **Status**: an extension the local SQLite lacks is `unsupported:` → **not
  checked**, while a genuinely broken database still fails. Where the
  application ships its own SQLite (`service_sqlite_binary`) that is used
  instead. There is **no sqlite3 on this host at all**, so without those
  declarations every database would read as `not checked`.
- **Evidence**: §4 of `CLAUDE.md`; `tests/sqlite-unsupported-smoke.sh`.

Declared today: plex (`Plex SQLite` 3.39.4), calibre-web (3.45.1), navidrome
(3.45.3), uptime-kuma (3.40.1). **jellyfin and kavita have none**, and
declaring a path that does not exist would turn "not checked" into a check that
always fails — worse than admitting it cannot be done.

---

## 9. Two services keep irreplaceable state in Docker VOLUMES

Measured 2026-10-08:

| service | volume | what is in it |
|---|---|---|
| traefik | `domum-media_traefik-letsencrypt` | `acme.json`, 116,015 bytes, mode 0600 — the Let's Encrypt **account private key** plus 9 issued certificates |
| uptime-kuma | `domum-media_uptime-kuma-data` | `kuma.db`, 286,720 bytes **with a non-empty `-wal`** — a live SQLite database it forward-migrates on startup |

- **Why hidden**: there is no `/srv/data/<service>`, and the upgrade gate used
  to treat "no state path" as "stateless" and **allow** the upgrade. A volume
  holding a model cache and one holding a private key look identical in a mount
  list.
- **Status**: `service_state_models` **declares** a model per service, checks it
  against the live mounts, and fails closed. `docker-volume` is blocked — not
  because the state is unprotected, but because no pre-upgrade recovery point is
  *possible* for it yet. The recovery pack does capture both, but a pack is
  periodic, operator-driven, records **no image identity**, and is not created
  before an upgrade: disaster recovery and rollback are different artefacts.
- **Evidence**: `docs/STATE-CLASSIFICATION.md`, `docs/UPGRADE-PROTECTION.md`.

---

## 10. A container's config path is not always `/config`

Four of the five migrated services bind their state at `/config`. **kavita's is
`/kavita/config`.**

- **Why hidden**: four out of five agreeing is exactly the pattern that invites
  an assumption. A capture that assumed `/config` would have run its
  `sqlite3 .backup` to a path that does not exist inside kavita's container.
- **Status**: `service_container_path` derives it from the longest-matching bind
  `Source` via `docker inspect`, and the suite asserts kavita's specifically.
- **Evidence**: `docs/SELECTIVE-STATE-PROTECTION.md`.

---

## 11. A scrub DETECTS corruption in the photo library and cannot REPAIR it

Measured, without root:

```
Data,     single: total=218.01GiB, used=215.26GiB   <- ONE copy
Metadata, DUP:    total=1.00GiB,   used=313.98MiB   <- two copies, same SSD
System,   DUP:    total=8.00MiB,   used=48.00KiB
```

- **Why hidden**: "a scrub protects the data" is the natural reading, and it is
  half true. A **metadata** checksum error is repaired from the second copy; a
  **data** one is reported and cannot be repaired, because there is no second
  copy of the photo library. Both DUP copies are on the same physical SSD, so
  DUP protects against a bad block, not against the device failing.
- **Status**: the remedy for a data checksum error is restoring the named file
  from restic — and the kernel log is what names the file. Whether that restore
  is even possible depends on §7a: `immich/library` yes, the five migrated
  services and the image archives **not covered**.
- **Evidence**: `docs/BTRFS-SCRUB-PLAN.md`.

---

## 12. The recovery pack's own path was hardcoded in the backup scope

`immich_only_include_paths` contained the literal
`/var/lib/domum-media/recovery-pack`, while the pack is written to
`${RECOVERY_PACK_DEST:-$DOMUM_STATE_ROOT/recovery-pack}`. They were equal on
this host **by accident**.

- **Why hidden**: nothing fails. Move the state root or set `RECOVERY_PACK_DEST`
  and the backup would include a path that does not exist while the pack —
  holding the config, the secrets, Traefik's ACME private key and Uptime Kuma's
  database — silently stopped being backed up, **with the run still reporting
  success**.
- **Status**: derived now, and verified byte-identical for the production scope
  and that it follows a moved state root.
- **Evidence**: §7 of `CLAUDE.md`.

---

## What would close the remaining ones

| # | dependency | what would close it |
|---|---|---|
| 1 | age private key | an off-host copy in the operator's custody — **operator action, P5.2** |
| 2 | pgvecto.rs deprecation | a recorded import into a *current* Immich, repeated as Immich moves to VectorChord |
| 7 | image recoverability | proving a loaded archive **runs**, in a disposable container |
| 7a | archives not off-site | a measured, selective proposal — needs `sudo du -sb /srv/data/backups/images` |
| 11 | data-profile corruption | nothing on this host; the answer is the restore path, which §7a governs |

Items 3, 4, 5, 6, 8, 9, 10 and 12 are closed in code and covered by tests. They
remain listed because **each was closed after giving the wrong answer first**,
and a dependency that stops being written down is one that gets re-introduced.
