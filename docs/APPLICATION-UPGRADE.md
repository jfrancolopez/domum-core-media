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
