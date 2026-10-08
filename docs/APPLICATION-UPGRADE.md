# Upgrading an application, recoverably

An image upgrade changes the program that owns the data. A storage migration
moves the data and keeps the program. The two need different protection, and the
update path this project started with provided neither for a single service.

## What `updates apply` does, and why it is not a Plex upgrade

`updates apply` is `refresh_images --apply-now --force`. Measured:

| | |
|---|---|
| service argument | **none** — `refresh_images` dies on any positional |
| scope | every service with `ENABLE_*=1` **and** `*_AUTO_UPDATE=1` |
| per service | `compose_cmd pull`, then `compose up -d` |
| pre-update snapshot | `create_service_snapshot` **while the service runs** |
| recovery metadata | **none** — zero references in that function |

Four consequences:

1. **It cannot upgrade one service.** With staged images for `plex`,
   `calibre-web`, `traefik` and `uptime-kuma`, a "Plex upgrade" could deploy four.
2. **Its snapshot is crash-consistent, not application-consistent.** Plex holds a
   live non-empty WAL; the migration path stops and proves quiescence first.
3. **Its snapshot is data-only.** Which application wrote the state is unrecorded.
4. **So the old image is unprotected.** `cleanup images` protection keys off
   `.recovery` files, so the image that snapshot depends on would be a deletion
   candidate the moment the upgrade made it unreferenced.

## `updates apply --service <s>`

A different operation, not a filter. The `--service` branch cannot reach
`refresh_images` at all.

```
validate the name          exact whole-line match against managed_image_specs; dies on a typo
capture scope baseline     every other container's id and image, via `ps -a`
target image               read from the LOCAL staged object; never pulls
─────────────────────────  lock acquired
phase 1  pre-upgrade point  stop → prove quiescence → read-only snapshot
                            → archive the exact image → bind .recovery metadata
                            → `compose start` the same container on the same image
phase 2  verify archive     sha256 against the record; refuses if it differs
phase 3  deploy             `compose up -d` for THIS service's compose services only
phase 4  verify             intended image running; every other container
                            byte-identical; health; endpoint; subvolume intact;
                            snapshot still read-only; archive still verifies
         cleanup dry run    the old image must be withheld (no `--confirm`)
```

Phases 1 and 2 are not optional and not a separate operator step: the staged
image cannot start unless both succeeded.

**The scope proof** is the before/after comparison of every non-upgraded
container's id *and* image. `ps -a`, not `ps`: a stopped container that got
recreated would otherwise be invisible.

**Never pulls.** Pulling at upgrade time re-resolves a mutable tag, so what runs
need not be what was reviewed.

## Rollback: both halves, or refuse

The pre-existing auto-rollback restored the snapshot and used `compose start` —
onto the container the upgrade had created, i.e. the **new** image. Old data under
a newer application is the pairing failure the recovery evidence exists to
prevent; for Plex it means a newer build forward-migrating a database restored
from before the upgrade. That was backlog task-24.

`rollback-upgrade <service> <point>`:

| step | guarantee |
|---|---|
| read the image id | from the `.recovery` evidence, **never** from a tag |
| no identity recorded | **refuses** — the application half is unknown |
| archive present | sha256 checked **before** `docker load`; mismatch refuses |
| after loading | the restored id is **compared** to the record; mismatch aborts |
| neither present | **refuses** — data could be restored, the application could not |
| current state | preserved as `<path>.failed-<timestamp>`; nothing deleted |
| restore fails | the preserved state is put back |
| start | `<SERVICE>_IMAGE` **pinned** to the recorded id, then a deliberate recreate |

Recreating is correct *here* and only here: the container that exists belongs to
the image being rolled back from, so `compose start` would restart the failed
application on restored data — task-24 exactly.

### Pin with a subshell export, not `env`

```bash
( export "$image_var=$want_img"; compose_cmd up -d $compose_svcs )
```

`compose_cmd` is a shell function and `env` can only exec a binary — measured,
`env X=1 f` gives `env: 'f': No such file or directory`. The `env` form fails
every time while a test that greps for the text still passes. The subshell keeps
the override from leaking, and `export_env_for_compose` uses
`${PLEX_IMAGE:-default}`, so a value exported first survives.

## The image archive

`docker save` by image **id**, so `RepoTags` is `null`: the identity worth
preserving is the id, not a mutable tag.

**Identity was proven, not assumed.** A disposable image was built from scratch,
saved, **removed** from the local store (confirmed absent), then loaded — the
restored id was byte-identical. No production image was saved, removed or loaded.

**A checksum is not an identity.** The archive's config-blob digest does not equal
the image id on this host (`Id` is the manifest digest), so a matching `.sha256`
proves only that the *file* is unchanged. `docker load` proves the identity, and
loading is a mutation, so `storage verify-archive` checks the file and says
plainly what it did not check. `rollback-upgrade` does the load and then compares.

### Where archives live, and why

`$DOMUM_DATA_ROOT/backups/images/`

- **In the restic set**: `restic backup` is given `$DOMUM_DATA_ROOT` with only
  immich-tmp and media-cache excluded.
- **Outside every service subvolume**: `/srv/data/backups` is a top-level ordinary
  directory, so archives do not duplicate into per-service snapshots.
- `/srv/media` is the deliberately replaceable tier; `/` is not backed up.

Published `.partial` → checksum → `sync` → atomic rename, and it refuses to
overwrite an existing archive.

### Lifecycle, with no automatic deletion

```
a retained recovery point names the image  ->  the archive is NEEDED
no retained point names it                 ->  ORPHAN, operator review only
```

`storage archives` answers, per archive: which point needs it, the image id, the
version, whether the checksum still matches, whether the local Docker object is
also present (so whether the archive is load-bearing *today*), and whether it is
safe to delete. Nothing in the tool deletes one.

## Two kinds of recovery point

| | proves |
|---|---|
| `<service>-<ts>-post-migration` | the state at migration cutover |
| `<service>-<ts>-pre-upgrade` | the state immediately before an upgrade, quiesced |

Both are retained, with `POINT_KIND` recorded. A migration point is **not** a
valid rollback target for an upgrade that happens later: the application has been
running and changing state in between.

## A key read but never written is silently empty

`sed -nE "s/^KEY='(.*)'$/\1/p"` against a key the writer never emits matches
nothing and yields an empty string — no error, well-formed output, wrong answer.
This happened: new code read `..._IMAGE_VERSION` while the writer emits
`..._IMAGE_LABEL_VERSION`. `tests/recovery-metadata-keys-audit.py` compares the
written and read sets across the whole file, and fails if its own extraction
patterns stop matching, so it cannot pass vacuously.

---

# The Plex upgrade, 2026-10-08 — the reference implementation

The first protected application upgrade on this host. It is recorded here
because it is now the pattern every future upgrade is measured against, and
because the measurements settle several questions that had only been argued.

```
old   sha256:58f13a1df833…   1.43.2.10687-563d026ea-ls308
new   sha256:7f9a1d574958…   1.43.3.10896-cb3ebc72d-ls322
point plex-20261008-121553-pre-upgrade
```

## Three Plex artefacts exist, and they prove different things

Confusing them is easy and expensive, so they are named separately.

| artefact | created by | what it proves | what it does NOT prove |
|---|---|---|---|
| `plex-20261006-133511-post-migration` | `storage migrate-subvolume` | the migration copied the state faithfully — it is a snapshot of the *copy*, compared against `.premigration`, the original moved aside | nothing about any later application version; its database is schema 1017 |
| `plex-20261008-121553-pre-upgrade` | `storage pre-upgrade-point` inside `service_upgrade` | the state as the **old application left it**, taken while stopped and quiesced | that the old image can still be *obtained* |
| `plex-58f13a1df833….tar` + `.sha256` | `archive_image_to_file` | the old application itself is retained, byte-identical on `docker load` | that the *file* being intact means the identity is right — only a load proves that |
| `.premigration` | the migration | the original bytes, untouched | — retained deliberately |

A rollback needs the **second and third together**. The migration proof snapshot
is evidence about the migration, not a rollback point for an upgrade.

## Measured: the schema did NOT change, and that is the point

| database | schema_version | pages |
|---|---|---|
| `.premigration` | 1017 | 412 |
| post-migration proof (10-06) | 1017 | 412 |
| pre-upgrade snapshot (10-08) | **1018** | 400 |
| live, after the upgrade | **1018** | 400 |

Plex 1.43.3 did **not** migrate the schema: 1018 before and after. The 1017→1018
step happened earlier, during ordinary operation on 1.43.2.

This is the most instructive number in the whole run, because it is the *opposite*
of the Kavita case — where a container recreated on a newer staged image
forward-migrated its database and left the proof snapshot holding an older schema
than the running binary. Both outcomes are normal. Neither is predictable from
outside the application.

So the pairing requirement is not "schemas always differ". It is that **you cannot
know in advance**, and an upgrade that assumed compatibility would have been right
this time and wrong for Kavita. The archive is insurance against the case you
cannot predict, not against the case you measured afterwards.

A useful consequence: because both Plex recovery points name the same old image
and that image is archived once, *both* remain complete rollback points. The
`cleanup images` dry run reports exactly that:

```
names sha256:58f13a1df833  plex-20261006-133511-post-migration
names sha256:58f13a1df833  plex-20261008-121553-pre-upgrade
```

## Measured: the ordering the safety argument rests on

From the production run, in order:

1. recovery evidence **staged** while the service was still observably running
2. `compose stop plex` — one container, 3.4 s
3. quiescence **proven**: no open handles, no non-empty WAL, no hot journal.
   The live WAL had been 649,792 bytes at preflight and was gone after the stop
4. read-only snapshot created
5. old image archived — 170,408,960 bytes, `sha256 277f5e7f7ffa221d…`
6. recovery metadata **bound** to the snapshot
7. `compose start` — **runtime state preserved, image unchanged, nothing deployed**
8. archive verified *before* deploying
9. `compose up -d plex` — the only reconcile, scoped to one service
10. verification: intended image, all ten other container identities unchanged,
    endpoint answered `1.43.3.10896`, storage still a subvolume, snapshot still
    read-only, archive still verifies

Steps 1–7 deploy nothing. That is what makes the pre-upgrade point a point rather
than a side effect of the upgrade.

## Measured: metadata-only image retention finally demonstrated

This had been argued and tested but never *observed* in production, because until
an upgrade happened the old image was always still in use by a running container.

After the upgrade:

```
old image now used by 0 container(s)
old image present in the cleanup records and NOT a candidate
```

`RepoTags: []` and `RepoDigests: []` — the image is dangling, so nothing but the
recovery metadata stands between it and `cleanup images --confirm`. That is the
`identity,local` exposure, now real rather than hypothetical, and the protection
held.

52 images totalling ~39 GiB are cleanup candidates. None of them is reclaimed
while the recovery framework is still being validated.

## Measured: off-host protection of the archive is PENDING, not done

The archive is at `/srv/data/backups/images/`, which is under `$DOMUM_DATA_ROOT`
and matched by neither restic exclude — so it **will** be included. But:

```
archive created   2026-10-08 12:15 UTC  (08:15 EDT)
last backup run   2026-10-08 02:36 EDT  success   -- BEFORE the archive existed
next backup       2026-10-09 02:31 EDT
```

So until that run, **the only copies of the old Plex application are on this one
host**: the local Docker object and the archive file. The snapshot root
`/srv/snapshots` is deliberately *not* in the restic path — snapshots are local
rollback, not disaster recovery — so the off-host story is "restore `/srv/data`
from restic, load the image from the archive", and that becomes true after the
next scheduled backup. No backup was forced to make this neater.

## Post-upgrade health, recorded as follow-up evidence

```
container   5bcb73d3f378 (recreated, as an upgrade must)
started     2026-10-08T12:16:02Z     restarts 0      oom false
endpoint    machineIdentifier 90527a4e3017aea6…  version 1.43.3.10896-cb3ebc72d
database    integrity_check -> ok   (via Plex's own SQLite, read-only)
            schema 1018, journal_mode wal, 254 sqlite_master rows
logs        0 error/fail/corrupt lines since the upgrade; no sqlite or schema
            complaints; only the documented-benign `Critical: libusb_init failed`
storage     /srv/data/plex still inode 256
snapshot    plex-20261008-121553-pre-upgrade still ro=true, no -wal/-shm inside it
units       0 failed; image refresh still disabled/inactive
```

The `machineIdentifier` surviving is worth noting: it is stored in the config the
snapshot covers, so an unchanged identifier is evidence the upgrade read the
preserved state rather than initialising fresh.
