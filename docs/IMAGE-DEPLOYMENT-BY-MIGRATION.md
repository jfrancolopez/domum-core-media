# A storage migration must not deploy an image

The Kavita migration succeeded, verified its recovery point, and **upgraded the
application** on the way.

## What happened

```
kavita container   Created  2026-09-29T00:11:31Z   <- the migration's `compose up -d`
                   Image    jvmilazz0/kavita:latest -> 454f2a77ac74, built 2026-08-28
```

The previous container had been running since 2026-09-21. Its database, preserved
in `.premigration` and in the proof snapshot, carries EF Core migrations up to
**2026-04-29**. The live database now carries migrations dated **2026-08-12 …
2026-08-18** and two tables the recovery point does not have:

```
only in live     : KavitaPlusAuditLogs, ScrobbleRuleHistory
last in live     : 20260818224653_AddSeriesMetadataProviderOverride
last in recovery : 20260429121159_AppUserReadingHistoryIndexChange
```

So a newer image had been pulled at some point and was sitting locally, staged
but not deployed. `docker compose up -d` recreates a container whose image has
changed — that is what it is for — so restarting the service deployed it, and
Kavita forward-migrated its schema on startup.

Nothing was lost. Kavita is healthy, its library is empty, and both copies of the
pre-migration state are intact.

## Why it matters

- `CLAUDE.md` §4: image discovery, pulling and staging must **never**
  automatically imply deployment.
- `CLAUDE.md` §11: application/image deployment and broad container recreation are
  operator boundaries.
- **The recovery point is weakened.** `.premigration` == proof snapshot still
  holds, and both contain the *old* application's data. A restore would hand a
  2026-04 schema to a 2026-08 binary. Kavita would forward-migrate it again, so
  this is recoverable — but the snapshot is a **data** recovery point, not a
  rollback of the service, and the migration did not say so.

This is the same shape as the already-documented `rolled_back_data_only` defect in
the update path: data and image are separate halves, and treating an operation on
one as covering the other is how a rollback silently does less than it claims.

## It is not specific to Kavita

Measured the same day, across every running container — is the running image still
what its tag resolves to locally?

```
kavita                   current        (the migration already deployed it)
jellyfin                 current
navidrome                current
immich_server            current
immich_redis             current
immich_postgres          current
immich_machine_learning  current
uptime-kuma              STAGED-NEWER
traefik                  STAGED-NEWER
plex                     STAGED-NEWER
calibre-web              STAGED-NEWER
```

Ten dangling images remain locally, all built in August, which is the trail of
those pulls. **Two of the four primed services — `plex` and `calibre-web` — are
migration candidates.** Migrating either today would have upgraded it silently,
exactly as Kavita was.

Jellyfin's migration on 2026-09-25 recreated its container too. Whether its image
changed at that moment cannot be reconstructed now: Jellyfin keeps no schema
history to compare, and the superseded image is gone. The mechanism was the same,
so it is recorded as unknown rather than as "did not happen".

## The fix

`storage migrate-subvolume` now **refuses at preflight** when the service's
running image differs from what its tag resolves to:

```
Refusing: a newer image is already staged for plex, so restarting it would DEPLOY that image.
A storage migration must not upgrade the application as a side effect ...
To accept the upgrade as part of this migration, set MIGRATE_ALLOW_IMAGE_CHANGE=1.
```

Refused **before** the service is stopped and before anything is moved, so the
cost of the refusal is nothing. `MIGRATE_ALLOW_IMAGE_CHANGE=1` is the deliberate
override, in the same spirit as `SNAPSHOT_POLICY=WARN`: it proceeds and says
plainly that the proof snapshot will hold the previous application's data.

### Three answers, because "I could not tell" is not "nothing is staged"

The first version of the check returned **nothing** for every case it could not
decide, so it reported clean when it had simply failed to look. Measured against
real production state, unprivileged — where `compose ps -q` yields no container id
— all four services with a staged image came back clean. **A guard that fails open
is worse than no guard, because it is trusted.**

It now emits a verdict per container and never nothing:

| verdict | meaning | migration |
|---|---|---|
| `STAGED` | the tag resolves to a different image | **refused** |
| `UNKNOWN` | the container could not be inspected, the tag is not present locally (`up -d` would pull), or no compose services are mapped | **refused** |
| `STOPPED` | no running container | allowed, and reported |

`STOPPED` is deliberately not `UNKNOWN`: a service that is not running has no
current image to preserve, so starting it on whatever the tag resolves to changes
nothing that existed. It is still printed, because the version that comes up is
one the operator did not choose.

Everything is refused **before** the service is stopped and before anything is
moved, so the cost of a wrong refusal is nothing.

### And the case no preflight can predict

If the tag is absent locally, `up -d` pulls; if it is re-pointed mid-migration,
the preflight answer is already stale. So the images running before the stop are
compared again after the restart:

```
kavita IS RUNNING A DIFFERENT IMAGE than before the migration:
  before: kavita sha256:...
  after : kavita sha256:...
The application was upgraded by this migration. The proof snapshot holds the
PREVIOUS application's data, so it is a data recovery point, not a full rollback.
```

When nothing changed it says `image unchanged across the restart`, because a check
that is silent on success is indistinguishable from one that did not run.

## Coverage

`tests/storage-migration-failure-smoke.sh`:

| case | expectation |
|---|---|
| a newer image is staged | refused, **before** the stop; no `.premigration`, no `.new`; data intact |
| refused for the right reason | the message names the staged image |
| the tag is not present locally | refused as **undeterminable**, and says which container |
| `docker inspect` fails outright | refused as undeterminable |
| the service is not running | proceeds, and reports what will be started |
| `MIGRATE_ALLOW_IMAGE_CHANGE=1`, staged | proceeds, announces the upgrade and the weakened recovery point |
| `MIGRATE_ALLOW_IMAGE_CHANGE=1`, undeterminable | proceeds — the override has to work when it is needed |
| running image equals the tag | proceeds, and confirms `image unchanged` |
| the image changes anyway across the restart | reported, and the weakened recovery story stated |

Nine mutants killed: the refusal disabled, the post-restart comparison disabled,
the staged-image detector always returning nothing, the override forced on, the
detector's equality test inverted, and each of the three `UNKNOWN` verdicts turned
back into silence — plus `STOPPED` downgraded to `UNKNOWN`, which would refuse a
legitimate migration of a stopped service.

## What is deliberately not changed

`restore_snapshot_for_service` and `apply` also run `compose up -d`, and both can
therefore deploy a staged image. They are **not** gated here: a rollback that
refuses to start the service is worse than one that starts it on a newer image,
and `apply` is convergence, where recreating containers is the point. The honest
fix for those is backlog task-24 — roll the image back with the data — not a
refusal. They are named here so the gap is not mistaken for coverage.
