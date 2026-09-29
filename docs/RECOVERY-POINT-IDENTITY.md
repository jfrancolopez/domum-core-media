# A recovery point is not `service + snapshot`

The Kavita migration produced a filesystem recovery point that is internally
perfect and, as a rollback point, incomplete.

`.premigration == proof snapshot` — 79 files, byte-identical, full metadata
match, both databases `integrity_check=ok`. And the database in it is a **Kavita
0.9.0.2** database, while the service now runs **0.9.1.0**. Restoring it under the
running image would not return Kavita to that state; it would forward-migrate it
again, on startup, exactly as it did the first time.

So the unit of recovery is:

```
service + filesystem recovery point + the exact application that wrote it
```

## What was proven about Kavita

| | |
|---|---|
| application before | **Kavita 0.9.0.2** — proven |
| application after | **Kavita 0.9.1.0** — proven |
| image ID after | `sha256:454f2a77ac740b70c58cc7300a11122fc9ce7b7e2161ef5b0d1df8f81067cc85` |
| image after, built | 2026-08-28T15:53:14Z, source revision `36d4ac76adf70d2522146fcac70fd2032376d053` |
| compose reference | `jvmilazz0/kavita:latest` — **mutable** |
| **image ID before** | **not recoverable** |

The versions come from Kavita's own log, in one file, across the restart:

```
00:00:02  Server is out of date. Current: 0.9.0.2. Available: 0.9.1.4
00:11:34  Performing backup as migrations are needed.
00:11:35  Database backed up to /kavita/config/temp/migration/0.9.0.2
00:11:38  Running Migrations
00:11:39  Server is out of date. Current: 0.9.1.0. Available: 0.9.1.4
```

**The image ID that was running before cannot be established, and it is not
invented from the tag.** Three independent avenues were exhausted:

- **The image store.** Exactly one Kavita image exists locally — the one running.
  The superseded image is not merely untagged: ten dangling images from August
  survive for Traefik, Jellyfin, Plex and Calibre-Web, and none is Kavita. Its
  object is gone.
- **The daemon event log.** It is in-memory and bounded. The earliest retained
  event is from roughly an hour after the migration, and nothing but healthcheck
  `exec_*` events remain. The `create`/`start`/`destroy` events are gone.
- **The old container.** Replaced, and with it its labels. The new container
  carries `com.docker.compose.replace=kavita`, which confirms the replacement but
  describes the new object.

One label on the new container looks like a handle and is not:
`com.docker.compose.image=sha256:4fb58f290f81…`. That digest resolves to nothing
locally, by ID or by `repo@digest`. It is recorded here so nobody mistakes it for
a way back.

### But the pairing is not lost

**Kavita saved the old database itself**, labelled with the version, before
migrating it:

```
/srv/data/kavita/config/temp/migration/0.9.0.2/kavita.db
```

`integrity_check=ok`, 82 tables, last migration `20260429121159_…`, and
**byte-identical** to the copies in `.premigration` and in the proof snapshot —
all three `sha256 ae93833885dec503`. So the 0.9.0.2-compatible database exists in
three places, one of which is explicitly named for the version that wrote it.

The upstream project publishes version tags, so a 0.9.0.2 image is plausibly
re-obtainable — but that is **not verified here**, because verifying it means a
network pull, and nothing was pulled during this investigation.

## Jellyfin, revisited

Previously recorded as unknown. It is now partly resolved, and the part that
matters is settled.

Jellyfin's container was also recreated by its migration
(`Created=2026-09-25T15:33:17Z`, the migration's own timestamp). Its
`__EFMigrationsHistory` is **identical** on both sides of the migration — 71 rows,
last `20250420230000_MoveTrickplayFiles`, product version `10.11.11.0` — and the
running image's label is `10.11.11ubu2604-ls47`. The three superseded Jellyfin
images retained locally are `ls44`, `ls45`, `ls46`, all also `10.11.11`.

Its logs carry **no startup banner** across `log_20260923` … `log_20260925`
(ending at the migration's shutdown, `15:32:56`), so the container had been
running for days beforehand — which does not discriminate `ls46` from `ls47`.

| | |
|---|---|
| **filesystem recovery** | **verified** — `.premigration == proof snapshot` |
| **application-image pairing** | **image ID unknown**, but the application version and schema are **proven unchanged** (10.11.11, 71 migrations) |

That is a materially different situation from Kavita: no schema moved, so the
recovery point remains compatible with the running application whichever `ls`
revision it was.

## The invariant

> **A migration restarts the container it stopped. It never recreates one, and it
> never changes what is running.**

### Why not the preflight check alone

The staged-image preflight added earlier narrows the problem; it cannot close it:

1. preflight confirms the running image is what the tag resolves to,
2. something runs `docker pull` — the operation lock does not cover other tools,
3. the migration stops the service,
4. `up -d` resolves the tag again and recreates.

The window is small and the check is still worth having as a second opinion. But
the invariant has to be structural.

### `compose start`, not `compose up -d`

`up -d` **reconciles**: it recreates any container whose image or configuration
has changed, which means it resolves the image reference afresh. `start` starts
**the same container object** — no reference is resolved, so the image cannot
change and the race has nowhere to happen.

A migration changes no compose configuration. What it changes is the tree a bind
mount points at, and a bind mount is re-resolved when the container starts.
Measured on a disposable compose project, not assumed:

```
up -d                                   -> container 5312d8c00833, sees OLD
compose stop                            -> ps -q: (empty)   ps -qa: 5312d8c00833
  (host directory renamed and replaced)
compose start                           -> container 5312d8c00833, sees NEW
                                           same container, same image
```

Same container, same image, new tree — which is exactly what a migration needs.

**Pinning the restart to the captured image ID was considered and rejected.** It
is expressible — every compose service takes `image: ${SERVICE_IMAGE}`, so
`KAVITA_IMAGE=sha256:454f…` would pin a recreate — but it has two costs. The
container's recorded reference becomes an ID instead of a tag, which permanently
neuters the staged-image detector for that service; and `service_lifecycle_specs`
carries **one** image variable per service, while Immich has four containers, so
the set cannot be pinned from it at all. Not recreating is both simpler and
stronger.

### Runtime state is preserved

| before | after | why |
|---|---|---|
| running | running | stop, migrate, `start` the same container |
| **stopped** | **stopped** | not started. The operator stopped it; a storage migration is not an occasion to undo that — and starting it is the *only* way a migration can be forced to resolve a tag whose identity it never captured |
| **absent** | **absent** | no container is created. There is no identity to preserve, and creating one resolves a mutable tag |

`stopped` is deliberately **not** treated as "no image identity". A stopped
container still carries its image, and it is inspected like any other — which
required fixing `tracked_service_container_id`, whose `compose ps -q` lists
running containers only. Measured: after `compose stop`, `ps -q` is empty while
`ps -qa` returns the container. Conflating those two meant a stopped service
reported "nothing staged" because nothing had been looked at.

For a service with no container at all, the recovery evidence records
`IMAGE_IDENTITY=unknown` rather than guessing.

### Multi-container services

Identity is captured **per container**. Immich has four, and one of them still
starting, or one of them with a staged image, must not be averaged away:
`service_runtime_state` reports `running` if *any* container is up, so the whole
set is restored; `service_staged_image_changes` emits a verdict per container, so
one staged image among four refuses the migration. Immich is not being migrated;
the model is tested against its shape.

## The recovery evidence file

Written before anything is stopped, next to the snapshot metadata:

```
/var/lib/domum-media/snapshots/<recovery-point>.recovery      (mode 0600)
```

```
FORMAT='1'
SERVICE='kavita'
RECOVERY_POINT='kavita-20260929-001131-post-migration'
CAPTURED_AT='2026-09-29T00:11:24-04:00'
DATA_PATH='/srv/data/kavita'
RUNTIME_STATE_BEFORE='running'
COMPOSE_PROJECT='domum-media'
COMPOSE_FILE_1='/opt/domum-core-media/compose/base.yml'
COMPOSE_FILE_1_SHA256='…'
CONTAINER_1_SERVICE='kavita'
CONTAINER_1_IMAGE_IDENTITY='known'
CONTAINER_1_ID='fae6d10aa732…'
CONTAINER_1_IMAGE_ID='sha256:454f2a77…'
CONTAINER_1_IMAGE_REF='jvmilazz0/kavita:latest'
CONTAINER_1_IMAGE_REPO_DIGESTS='jvmilazz0/kavita@sha256:454f2a77…'
CONTAINER_1_IMAGE_CREATED='2026-08-28T15:53:14Z'
CONTAINER_1_IMAGE_LABEL_VERSION='latest'
CONTAINER_1_IMAGE_LABEL_REVISION='36d4ac76adf7…'
CONTAINER_1_COMPOSE_CONFIG_HASH='4aa2a32d…'
```

Line-oriented `KEY='value'` so it can be sourced, with a header that explains
itself to whoever finds it months later — including that a filesystem snapshot
alone is not a complete rollback point.

**No secrets, by construction.** The configuration is identified by the digest of
each layered compose file plus docker's own per-container `config-hash`, and is
never *rendered*: `docker compose config` interpolates secret values, and this
file is meant to be read by a person. The `IMAGE_REF` field is recorded and
labelled mutable — it is evidence of what the container was created from, not a
way back.

## What a true rollback would mean

The current implementation restores data. A complete rollback of a service whose
application migrates its own schema is:

1. stop the current application
2. **preserve** the current state rather than deleting it — already done:
   `restore_snapshot_for_service` moves the live tree to
   `<path>.rollback-<stamp>` and never removes it
3. restore the filesystem recovery point
4. **run the application image that recovery point was written by** — this is the
   step the evidence file above now makes possible, and which nothing implements
5. verify database and application health
6. only then call it successful

Steps 1, 2, 3 and part of 5 exist. Step 4 does not, and until it does a rollback
is honestly a **data** rollback. The rollback path at least no longer makes it
worse: it uses `compose start` too, so it cannot restore an old database and
upgrade the application in the same breath.

For Kavita specifically, a rollback today would hand a 0.9.0.2 database to
0.9.1.0, which would forward-migrate it — so it recovers the *data*, not the
state. **No such rollback is warranted to prove the design**, and none was
performed.

## Every command that can recreate a container

`docker compose up` is the only way containers get recreated here, and there are
six call sites. Classified:

| command | site | class |
|---|---|---|
| `storage migrate-subvolume` | `migrate_restart` | **must preserve** — now `start`, recreate only as a reported fallback |
| `rollback apply` | `restore_snapshot_for_service` | **must preserve** — now `start`, recreate only as a reported fallback |
| `update` | `refresh_images` | **may deploy** — that is its purpose, and it is gated on backup age, health and a snapshot |
| `immich bundle apply` | `immich_refresh_bundle` | **may deploy** — an explicit Immich deployment |
| `apply` | `apply` | **may deploy** — convergence; recreating on a config change is the point |
| `apply`, Immich secret repair | `apply` | **may deploy** — `--force-recreate`, deliberately |

`init` and `configure` do not start containers. `checkup`, `status`, `doctor`,
`report`, `snapshot`, `backup` and `cleanup` never call `up`.

The staged-image detector is available to any of them; the two "must preserve"
paths no longer need it to be correct, because they no longer resolve an image.

Image refresh remains **disabled and inactive**. Nothing here enables it, and the
stage/deploy separation is unchanged: staging still never implies deployment, and
now neither does restarting.
