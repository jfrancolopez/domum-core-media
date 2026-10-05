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

---

# Fail-open, twice, in the same mechanism

Both were found by reading the **merged** implementation rather than the summary
of it. Both had already been "fixed" once — in the preflight check, not in the
restart, which is where the failure actually lives.

## 1. The rollback reconciled after a failed start

```bash
if ! compose_cmd start $compose_svcs; then
  warn "Could not start the existing container(s) ...; recreating instead."
  warn "Recreation resolves the image tag, so $service may come back on a DIFFERENT image"
  warn "than the one that wrote the state just restored."
  compose_cmd up -d $compose_svcs            # <- and then it did exactly that
fi
```

A rollback has *already restored an older database* by this point. So the
sequence was:

```
old data  ->  mutable tag resolved  ->  newer application  ->  automatic schema migration
```

which is the Kavita failure mode, reached during the operation whose purpose is to
undo it. The restored data would have been forward-migrated before anyone looked.

**A documented fail-open is the worst shape available**: the warning proves the
author knew, and shipped it anyway.

## 2. Recovery metadata was advisory

```bash
if write_recovery_point_metadata ...; then
  ...
else
  warn "Could not record the recovery-point evidence"
  warn "The snapshot is intact, but which application image wrote it is not recorded."
fi
```

…and the command went on to print **"Migration complete"** and exit `0`. If the
application identity is part of a recovery point — which this document argues at
length — then a migration that cannot record it has not made one.

## What they have in common

Both substituted a *description* of the harm for a refusal. Warning text is not a
control. The rule now:

> A safety mechanism that can be summarised as "warn and continue" is not a
> safety mechanism. Either the operation refuses, or the result is reported as
> something other than success.

## Fail closed, both

**Neither path recreates.** `start` failing means a container is gone, and
recreating resolves the image tag — so the operator is told, with the exact
command, and nothing happens automatically:

```
Could not start the existing container(s) for navidrome.
NOT recreating them: that resolves the image tag, and a newer application
would migrate the state just restored -- destroying the pairing this
rollback exists to recover.
The restored state is in place at /srv/data/navidrome.
The state it replaced is preserved at /srv/data/navidrome.rollback-20260929-...
navidrome is DOWN. Nothing has been deleted.
The image that wrote the restored state is recorded in:
    /var/lib/domum-media/snapshots/<point>.recovery
```

A service that is down is visible and fixable in one command. A service silently
running a different application than its recovery point pairs with is neither.

**The metadata is captured before the stop and bound atomically.**

| phase | when | why |
|---|---|---|
| **stage** | before anything is stopped | the containers that wrote the state are still the ones running |
| **bind** | once the proof snapshot has its final name | append it, `sync`, then `mv` into place |

A staging failure **refuses at preflight**, where nothing has been touched. A bind
failure cannot be refused — the data is already migrated — so it is reported as an
**incomplete** result, and nothing is deleted.

The landed file is then verified against what it claims to describe: required
keys present, `SERVICE` and `RECOVERY_POINT` matching, at least one container
recorded, and no container claiming `known` identity with an empty image ID. A
truncated write is a failure rather than evidence.

## Four claims, reported separately

"Migration complete" used to be printed before any of them was known, with the
exit status decided by one:

```
[domum-media] Migration result for navidrome
  data migrated   : yes -- /srv/data/navidrome is a Btrfs subvolume
  previous state  : /srv/data/navidrome.premigration   (retained deliberately)
  proof snapshot  : navidrome-20260929-...-post-migration
  recovery point  : complete -- verified, and paired with the image that wrote it
  recovery evidence: /var/lib/domum-media/snapshots/<point>.recovery
  service         : running (as it was before)

[domum-media] Migration COMPLETE for navidrome.
```

Anything less prints `Migration INCOMPLETE`, exits non-zero, and says which claim
failed. `recovery point : DATA ONLY` is the specific outcome when the filesystem
evidence verifies but the application pairing was not recorded.

# Identity is not recoverability

Recording `IMAGE_ID=sha256:…` proves **identity**. It does not prove the image can
still be obtained: a local object can be pruned, and a mutable tag says nothing
about what it will resolve to next year. Recorded per container, never aggregated
into one reassuring word:

| value | meaning |
|---|---|
| `identity` | the exact image this state was written by is known |
| `local` | that object is present on this host **right now** |
| `registry-digest` | an immutable `repo@sha256` reference is recorded |
| `version-only` | only the application version is known |
| `unknown` | nothing |

**A RepoDigest equal to the image ID is not an independent registry reference.**
Measured on this host, docker reports exactly that:

```
kavita     RepoDigests = [jvmilazz0/kavita@sha256:454f2a77…]   == .Image
navidrome  RepoDigests = [deluan/navidrome@sha256:9012939114…] == .Image
```

Counting those as manifest digests would claim retrievability that has not been
established, so they are excluded. Navidrome's current classification is therefore
**`identity,local`** — recoverable today because the object is here, with *no*
immutable reference to fetch it again later.

**No images are being exported or saved.** That is a policy question, and the
policy is the point: recovery metadata must never claim *application recovery
verified* on the strength of a recorded string. It states what is true —
`identity,local` — and leaves the gap visible.

# Application readiness without touching production

navidrome has no Docker healthcheck and no host-published port (4533 is exposed
only on the proxy network), so "the container is running" was the whole claim.

It does log, on stdout, after opening and migrating its database and binding its
listener:

```
goose: successfully migrated database to version: 20260703013908
Started watcher for library libraryID=1 path=/music
----> Navidrome server is ready! address="0.0.0.0:4533" startupTime=128.3ms
```

That is strictly stronger than a process check: it proves the application opened
the **migrated** database and reached its listener. It needs no networking, no
credentials and no production change — `docker logs --since <restart>` is
read-only.

Options considered and not taken: a request from inside the proxy network (needs a
client in some container, and the traefik image has neither curl nor wget); the
existing Traefik route at `music.ladomum.com` (needs TLS and DNS from the host,
and routes traffic through the proxy to prove a local fact); publishing a port
(changes production networking for a test).

The limitation is stated rather than papered over: **a log pattern is fragile.** An
upstream wording change breaks it. The failure is safe — the migration refuses
having deleted nothing, and says exactly what it looked for — and the pattern is
pinned by a test, so a wording change breaks CI rather than a migration. For a
service whose only application-level evidence is a log line, that is the right
trade; for kavita, whose healthcheck makes a real HTTP request, no pattern is
added because the healthcheck is stronger.

A service with neither says so:

```
no healthcheck, no health URL and no readiness pattern for calibre-web:
  'running' is the whole claim. Content was verified byte-for-byte;
  exercise the application yourself before removing .premigration
```

# The reconcile boundary is enforced, not remembered

`tests/reconcile-boundary-audit.py` classifies every call in `bin/domum-media`
that can create or replace a container, and fails when the classification is
violated **or absent**:

| class | members | rule |
|---|---|---|
| **image-preserving** | `storage_migrate_subvolume`, `restore_snapshot_for_service` | no executable reconcile; must use `compose_cmd start`; must state that it is refusing |
| **intentional deployment** | `refresh_images`, `immich_refresh_bundle`, `apply` | must still reconcile — a refactor that quietly stops deploying is also a defect |
| **utility** | `htpasswd_hash` | `docker run --rm` of a one-shot tool, in no compose project |

A reconcile in any **unclassified** function fails the audit, which forces the
decision to be made rather than inherited. Strings and heredoc bodies are
excluded: these functions legitimately *print* `compose up -d` in recovery
instructions, and telling an operator how to recreate a container deliberately is
the opposite of doing it silently. Not excluding heredocs made the audit flag
`recovery_pack_restore_instructions` — a runbook — which is how a checker earns a
suppression instead of a fix.

Seven mutants killed, including the two named directly: rollback `refuse → up -d`,
and migration `refuse → up -d`.

# The historical exceptions stay honest

Nothing is manufactured retroactively.

| | Jellyfin | Kavita |
|---|---|---|
| filesystem recovery | **verified** | **verified** |
| application version then | 10.11.11 (proven, schema unchanged) | **0.9.0.2** (proven) |
| exact image ID then | **unknown** | **unknown** |
| application now | 10.11.11ubu2604-ls47 | 0.9.1.0 |
| pairing | compatible — no schema moved | **data only** — schema moved |

Neither `.premigration` tree nor either proof snapshot has been touched. Kavita is
not downgraded and its forward-migrated database is left alone. Only migrations
from here on carry `.recovery` evidence; the two existing points are recorded as
the exceptions they are.

---

# Navidrome: the first complete recovery point, and two defects it exposed

The migration succeeded on every claim. The **wrapper script** then aborted, and
the readiness check passed for a reason that will not hold everywhere.

## What the migration proved

**The WAL experiment, which is why navidrome was chosen.** It was the first
service migrated with a *non-empty running* write-ahead log:

```
before stop     navidrome.db-wal  20,632 B    navidrome.db-shm  32,768 B    1006 files
after clean stop  (both sidecars GONE)                                      1004 files
quiesced db     1,851,392 B   sha256 2a137d30492486ca…
```

1006 − 1004 is exactly the two sidecars. SQLite checkpointed **and removed** them
on clean shutdown, so the preserved database is complete on its own — there is no
outstanding WAL a restore would need. The gate ran and observed zero
(`quiesced: nothing holding files open, no non-empty WAL`) before any storage
mutation. The live tree has since re-created both, which is what makes the
before/after contrast meaningful rather than incidental.

**The image invariant, in production.** Not "the same tag" — the same objects:

```
container id   ef44ae505efc398924b7c63701e95c794f366507d97d3a9683449d4398e567cf   (before AND after)
image id       sha256:9012939114fbb1bb641b81cf96dec5ded15f0aafefe8d47a511d7cb919658e40   (before AND after)
Created        2026-08-02T09:43:04Z     <- unchanged: the container was NOT recreated
StartedAt      2026-09-29T17:56:58Z     <- the migration's restart
RestartCount   0
```

Contrast Kavita, whose `Created` jumped to its migration timestamp. `compose start`
restarted the container that was stopped, so no image reference was resolved at
all.

**Integrity**, re-derived independently: 1004 files / 816 dirs / 0 symlinks /
51,522,430 bytes on both sides, all 1004 hashed with **zero unreadable**, 1820
metadata entries identical, combined digest `11ca25602c6e9313…` on both. The
snapshot's `navidrome.db`: `integrity_check=ok`, 0 FK violations, WAL mode, 45
tables, 452 pages — checked from a copy, and neither preserved tree changed.

**Three-service topology**: three subvolumes, three read-only snapshots, each
service resolving only its own (`count=1` each, plex `count=0`), the three
`.premigration` directories correctly ordinary (inodes 269, 4377, 272 — the
originals, renamed). Next Sunday's prune traced against the real inventory:
`0 deleted`, and `0 deleted` again with `keep=0` because the floor holds.

## Defect 1 — the wrapper aborted on a string I had changed

```
ABORT: the CLI did not assert the integrity claim at all.
Expected 'recovery point  : verified' in its output.
```

The migration had already completed. The wrapper grepped for a literal summary
line, and that wording had changed when the summary was split into four separate
claims — so a stale string assertion aborted a perfect migration. **The same shape
as the topology invariant that aborted a correct deployment**, in the same class
of hand-written operator script.

Prose is not a contract. The wrapper now asserts on the **exit status** and the
**recovery evidence file**, and reads the evidence through a new read-only
subcommand instead of grepping output:

```
domum-media storage verify-recovery <service> <recovery-point>
```

which prints the per-container identity, availability, and whether the recorded
image is *still on this host now* — a different question from whether it was when
the evidence was written.

## Defect 2 — the readiness window was timezone-dependent

`docker logs --since` given a bare timestamp interprets it in the **caller's**
timezone. Measured against the real readiness line at `17:56:58Z`:

```
TZ=UTC               --since 2026-09-29T17:56:00    -> 1 match
TZ=America/New_York  --since 2026-09-29T17:56:00    -> 0 matches
any TZ               --since 2026-09-29T17:56:00Z   -> 1 match
```

The implementation passed `date -u` output **without a `Z`**. West of UTC that is a
false negative — the window starts in the future and a correct migration aborts
after 120 s. **East of UTC it is a false positive**, which is worse: the window
opens hours early and a readiness line from a *previous start* satisfies the
check. The navidrome run passed only because the environment it ran under resolved
the bare stamp as UTC.

Fixed twice over: the `Z` is appended, **and** each matching line's own timestamp
is compared against the restart, which removes the dependence on `--since`
parsing entirely. Compared at whole-second precision, because docker stamps
`17:56:58.386777720Z` while the boundary is `17:56:58`, and `.` sorts before `Z`
— so a nanosecond stamp in the same second would otherwise read as earlier.

Four mutants killed, including a stale readiness line from a previous start being
accepted.

## The evidence that could not be checked without root

`/var/lib/domum-media` is `drwx------ root`, so the `.recovery` file's **content**
cannot be inspected unprivileged. What is established without root: the CLI
verified it at write time — required keys, `SERVICE` and `RECOVERY_POINT` matching,
no container claiming `known` identity with an empty image ID — and both
`recovery point : complete` and exit 0 depend on that verification passing.

An independent read needs one privileged command:

```
sudo domum-media storage verify-recovery navidrome navidrome-20260929-175657-post-migration
```

Expected, from the evidence captured before the stop:
`IMAGE_ID=sha256:9012939114fb…`, `IMAGE_REF=deluan/navidrome:latest` (mutable),
`IMAGE_LABEL_VERSION=0.63.2`, and **`IMAGE_AVAILABILITY=identity,local`** — the
RepoDigest equals the image ID, so there is no independent registry reference.

---

# A week of three migrated subvolumes

Measured 2026-10-05, six days after the Navidrome migration. Nothing was touched
in between.

| scheduled job | last run | result |
|---|---|---|
| `domum-media-btrfs-snapshot` (prune) | **Sun 2026-10-04 04:48:53** | success, exit 0 |
| `domum-media-check` | Sun 2026-10-04 03:38:53 | success, exit 0 |
| `domum-media-backup` | Mon 2026-10-05 02:39:53 | success, exit 0 |
| `domum-media-host-update` | Mon 2026-10-05 06:10:12 | success, exit 0 |

**The first weekly prune with three subvolumes deleted nothing**, and that is
established without reading its output: `/srv/snapshots` and `/srv/data` both
still carry mtime `2026-09-29 13:56:57` — the instant of the Navidrome migration.
A directory's mtime changes when an entry is created, removed or renamed inside
it, so nothing has been added to or removed from either in six days. Three
snapshots present, one per service.

Backups have run nightly against the three-subvolume topology, with
`/var/log/domum-media/last-success` reading `2026-10-05T02:40:24-04:00`. No failed
units; 11 containers.

So the topology has survived a full cycle of every scheduled job, which is the
thing that was worth waiting for before migrating a fourth service.

# Advice is not a deployment

The acceptance test for the first complete recovery point was handed over as:

```
sudo domum-media storage verify-recovery navidrome navidrome-20260929-175657-post-migration
```

and produced:

```
ERROR: Usage: domum-media storage {migrate-subvolume <service>|topology [--verify <file>]}
```

The subcommand existed only on an unmerged branch. The repository was ahead of
production, and the recommendation came from the repository — the same mistake
shape as the stale string assertion, pointed the other way: instead of a script
asserting against code that had moved, a human was asked to run code that had not
arrived.

`tests/documented-commands-audit.py` now reads every fenced block and inline code
span in `docs/`, `README.md` and `CLAUDE.md`, and fails when a `domum-media`
command named there is not dispatched by the CLI. 78 commands checked; four
mutants killed, including a nonexistent nested subcommand added to a runbook and
the CLI renaming one the docs still mention.

It is explicitly the **weaker half** of the problem. It compares the docs to
`bin/`, and `bin/` is not what runs. Nothing in CI can see `/usr/local/bin` —
which is exactly why the migration wrapper feature-gates on the *installed*
binary, and why a documented command only becomes safe advice once the revision
carrying it has been deployed. The rule that covers the other half is in
`CLAUDE.md` §9, and it is a rule because it cannot be a test.
