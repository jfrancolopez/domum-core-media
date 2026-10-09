# CLAUDE.md — domum-core-media

Operating rules for coding agents working on this repository.

This file holds **durable rules**. Current operational state — snapshot IDs,
repository identities, measurements, acceptance evidence, incident history —
belongs in `docs/`, never here. If a section here grows large, move it to
`.claude/rules/<topic>.md` or to repository documentation and leave a pointer.

---

## 1. Workspaces and fixed paths

| Purpose | Path |
|---|---|
| Development workspace | `/home/jfranco/src/domum-core-media-dev` |
| Production checkout | `/opt/domum-core-media` |
| Production config | `/opt/domum-core-media/config/domum-media.conf` |
| Secrets | `/etc/domum-core-media/secrets` |
| Protected durable data | `/srv/data` |
| Replaceable/reacquirable media | `/srv/media` |
| Local snapshots | `/srv/snapshots` |
| Runtime state | `/var/lib/domum-media` |
| Logs | `/var/log/domum-media` |

- All development happens in the development workspace.
- **Never treat the production checkout as a development workspace.** Do not
  edit, branch, experiment, or leave drift in `/opt/domum-core-media`.
- **Never copy production secrets into the development checkout**, into tests,
  into fixtures, or into any file that git can see.

---

## 2. Data safety

`/srv/data` is the highest-value local data tier (family photo library and
application state). Do not delete, migrate, restructure, bulk-modify, or
experiment on it without explicit operator approval.

`/srv/media` is intentionally replaceable/reacquirable. That is a statement
about recovery cost, **not** blanket permission to delete or restructure it.

Do not modify production data to test code. Use fixtures, temporary
directories, dry runs, or an isolated scratch restore location.

---

## 3. Btrfs truth

**FIVE services are migrated and protected: `jellyfin` (2026-09-25), `kavita`
(2026-09-29), `navidrome` (2026-09-29), `plex` (2026-10-06) and `calibre-web`
(2026-10-09).** Each is a real
Btrfs subvolume with a verified read-only proof snapshot and retained
`.premigration`. Plex is the one with symlinks (7, one absolute into the
container's `/config` namespace) and the weakest application pairing
(`identity,local`: both `RepoTags` and `RepoDigests` empty, so the image is
dangling and survives only because a container references it). Its migration
deliberately did **not** deploy its staged image, which was the point of doing
it. `docs/PLEX-MIGRATION-RESULT.md` holds the evidence.

**Still an ordinary directory: `immich`** — so its upgrade remains correctly
blocked. It is deliberately last and needs its own reviewed phase.

**`calibre-web` was migrated 2026-10-09** (inode 256, `st_dev` 55 vs the
parent's 45; proof snapshot `calibre-web-20261009-131921-post-migration`,
`ro=true`; `.premigration` retained at 264 KB). It was the easiest of the five,
as measured beforehand: 6 files, 255,729 bytes, `journal_mode DELETE` so no WAL
to quiesce, and no symlinks. Its staged 0.6.27 image was reported and
deliberately **not** deployed; the image was unchanged across the restart.

Two per-service declarations were exercised in production for the first time
there, and both worked: `service_sqlite_binary calibre-web` turned
`unsupported: not checked` into `sqlite: 2 checked, 0 not checked` (its image
ships sqlite3 3.45.1, and there is none on the host), and
`service_ready_log_pattern calibre-web` produced
`LOGGED READY since the restart: "port [tcp/*] succeeded!"`. Readiness is still
all that proves — calibre-web has no container healthcheck.

Its upgrade to 0.6.27-ls399 is now possible through the gated per-service path,
and has not been performed.

**`jellyfin` was the first, on 2026-09-25.** `/srv/data/jellyfin` is
a real Btrfs subvolume (inode 256, `st_dev` 51 vs the parent's 45) with a verified
read-only proof snapshot. `docs/JELLYFIN-PILOT-RESULT.md` holds the evidence.
`/srv/data/jellyfin.premigration` and that snapshot are both retained deliberately
and must not be deleted without the operator saying so.

**Every other service path is still an ordinary directory**, so per-service
snapshot/rollback protection remains DEGRADED for them and service snapshots
silently skip.

The report no longer calls a subvolume `protected` on its own: `protected` requires
a snapshot to exist too, `snapshottable` means it can be snapshotted but nothing
has been, and `degraded` means a nested subvolume would be omitted from any
snapshot of it.

Never:

- claim a skipped snapshot provides rollback protection;
- treat snapshot success as proven merely because `/srv/data` itself is Btrfs;
- treat one migrated service as protection for the others;
- use the current snapshot layer to justify a risky deployment;
- write an **absolute** assertion about the storage topology — no subvolumes
  exist, the snapshot root is empty, a global snapshot count, a service-name-only
  gate. Every such assertion was true before the first migration and is
  permanently false after it; one of them aborted a correct production
  deployment. Compare *before* against *after* instead.

`domum-media storage topology` prints the inventory and
`domum-media storage topology --verify <capture>` compares a capture against the
live one (`0` unchanged, `1` changed and named, `2` not comparable). That is the
**one** implementation of the check: operator scripts must invoke it rather than
carry their own copy, which is how the aborted invariant escaped CI. See
`docs/DEPLOYMENT-INVARIANTS.md`.

Operations that depend on a snapshot for rollback (stateful image update,
Immich bundle apply, `immich reset-db`) **refuse to run** when no snapshot could
be created. `SNAPSHOT_POLICY=WARN` is the deliberate, documented override; it
lets the operation proceed without rollback protection and does not create any.
Never re-introduce a call site that downgrades a failed snapshot to a warning or
swallows it — `tests/snapshot-safety-gate-smoke.sh` enforces this.

Btrfs migration or restructuring is a separate high-risk project requiring
explicit operator approval. Do not start it opportunistically.

---

## 4. Image update safety

`domum-media-image-refresh.timer` is intentionally **disabled and inactive**
until the update/apply/rollback pipeline has been audited and proven safe.

- Do not re-enable it.
- Do not deploy locally staged image candidates merely because newer images
  exist.
- Image discovery, pulling, and staging must never automatically imply
  deployment.

**`docker compose up -d` deploys a staged image.** It *reconciles*: it recreates
any container whose image has changed, so every command that restarts a service
is an image deployment vector — not just the update path. The Kavita storage
migration recreated its container on a newer locally-staged image and Kavita
forward-migrated its database on startup, leaving the proof snapshot taken minutes
earlier holding an older schema than the running binary
(`docs/IMAGE-DEPLOYMENT-BY-MIGRATION.md`).

Classify every path that restarts a service, and never leave it implicit:

- **may deploy** — `update`, `apply`, `immich bundle apply`. Recreating is the
  point; they are gated on backup age, health and a snapshot.
- **must preserve** — `storage migrate-subvolume`, `rollback apply`. These use
  **`compose start`**, which starts the container that was stopped and therefore
  resolves no image reference at all. Do not "simplify" them to `up -d`.

  **Measured, 2026-10-06**, with a disposable compose project and no pull, retag
  or prune: a container created on image A, stopped, its compose file repointed at
  image B, then `compose start` → **still on A**. `up -d` with the same file →
  recreated on B. So `compose start` is the control; the preflight staged-image
  comparison is secondary.

  **A merely STAGED image therefore must NOT refuse a migration.** It used to, and
  the refusal's own text said "restarting it would DEPLOY that image" — true of
  `up -d`, false of `compose start`. That deadlocked the project: Plex could not be
  **upgraded** (state unprotected) and could not be **migrated** to gain protection
  (an upgrade was staged). Each gate was individually right; together they were a
  trap. The control is now verification, not prediction: a staged image is reported
  and proceeds, an image that **actually changed** across the restart makes the
  migration **INCOMPLETE** (not a warning), and identity that could not be
  determined still refuses before the stop. `tests/staged-image-migration-smoke.sh`
  pins all three; 6 mutants, all killed.
- **must refuse when identity is ambiguous** — anything that would start a service
  for which no image identity was captured.

**A recovery point is `service + snapshot + the application that wrote it`**, not
`service + snapshot`. An application that migrates its own schema on startup makes
that the difference between a rollback point and a museum piece. Migrations record
the third part in `<recovery-point>.recovery`, and a snapshot whose application
image is unknown must never be advertised as a complete rollback point. Never put
secrets in that evidence — identify configuration by digest, never by rendering
it. See `docs/RECOVERY-POINT-IDENTITY.md`.

**A migration preserves runtime state.** Running before → running after; stopped
before → stopped after; no container before → none after. "Stopped" is not a
loophole for resolving a tag with no captured identity, and a stopped container
still has an image — inspect it with `compose ps -qa`, because `ps -q` lists only
running containers and conflates stopped with absent.

**"Warn and continue" is not a safety mechanism.** Twice now a control has shipped
that described the harm in a warning and then caused it: the rollback warned that
recreating resolves the image tag and then recreated, and a failed recovery-metadata
write warned and still reported "Migration complete" with exit 0. Either the
operation refuses, or its result is reported as something other than success. A
service that is down is visible and fixable in one command; a service silently
running a different application than its recovery point pairs with is neither.

**Never tell the operator to run a command that is not DEPLOYED.** The repository
runs ahead of production, so a subcommand existing in `bin/` says nothing about
`/usr/local/bin`. A `storage verify-recovery` command was recommended while it sat
on an unmerged branch, and the operator got a usage error. Check the installed
binary — `grep` it, or run `domum-media --help` — before putting a command in a
message or a runbook. `tests/documented-commands-audit.py` checks the docs against
the CLI, which is the weaker half of this: it cannot see what is deployed.

**Operator scripts must not assert on the CLI's prose.** A wrapper grepped for the
literal summary line `recovery point  : verified`; the wording changed when the
summary was split into four claims, and it aborted a migration that had completed
perfectly — the same shape as the stale topology invariant. Assert on exit status,
on files, or on a subcommand written for the purpose (`storage verify-recovery`,
`storage topology --verify`). If a script needs a fact, give the CLI a way to state
it.

**Operator scripts live in `operator/`, in this repository, and are in CI.**
Three of them aborted correct production states -- a stale topology invariant, a
grep for the prose `recovery point  : verified`, and a grep for
`make_pre_upgrade_point()`, a private helper from a reverted refactor that had
never existed. All three escaped review because operator scripts were not in the
repository. `tests/operator-wrapper-audit.py` now fails on: grepping the CLI's
source (the rule is "never grep the binary", not "never grep for a function
name" -- the historical form looped over names held in a **variable**, so no
literal name appeared on the grep line); piping a `domum-media` invocation into
grep/sed/awk; and requiring a capability the CLI does not advertise. It is
mutation-tested against the real historical wrapper, which it must reject.

**A wrapper asserts on behaviour, never on internals or prose.** Permitted: exit
status, `capabilities --has <token>`, `--json` output, files on disk, and
external contracts (`docker inspect`, `stat -c %i`, `btrfs property get`,
`systemctl`, `sha256sum`, `git rev-parse`). Forbidden: the CLI's wording, the
CLI's source text, absolute claims about mutable state, and a revision constant
baked into the repository it pins -- that goes stale by construction. What is
always checked instead is that the installed binary's sha256 equals the
production checkout's; a revision pin alone says nothing about `/usr/local/bin`.
See `docs/OPERATOR-CONTRACT.md`.

**`domum-media capabilities [--has <token>]` is the stable surface.** `--has`
exits 0 supported, 1 implementation absent, **2 token unknown** -- a script
asking about a token this binary never heard of must not read that as a yes.
Tokens are promises about behaviour and are never renamed in place. At run time
each is gated on `declare -F` of its implementation, so a token disappears if its
implementation does; in CI `tests/capabilities-contract-audit.py` proves the
advertised argv path actually reaches that implementation. Never advertise a
capability from an unchecked static list.

**`cleanup images --json` is how automation asks about images.** Its record set is
deliberately WIDER than the candidate set, because "is this image still
protected?" cannot be answered from a candidate list -- that cannot distinguish
*protected* from *never considered*, which is the ambiguity that made
`0 named by a recovery point` unfalsifiable. `--json` and the human report are
thin filters over one decision function, `cleanup_image_decisions`, so they
cannot disagree; `--json --confirm` is refused.

**A test that asserts on a function's TEXT does not prove the function runs.**
`service_upgrade` shipped calling an undefined helper while 41 suites passed,
because every assertion about it read its source and none executed it.
`tests/service-upgrade-integration-smoke.sh` enters through
`main updates apply --service plex` against a production-shaped fixture and
asserts on observed behaviour. It found four defects reading could not, all of
the same family -- `set -euo pipefail` aborting an assignment before the branch
written to handle the failure could run:

- `target_image="$(grep '^STAGED ' … | awk …)"` -- nothing staged means grep
  matches nothing, pipefail discards awk's 0, and the graceful "nothing to
  upgrade" branch was UNREACHABLE (exit 1, no message);
- `rollback_entries` ran `find` on a directory that need not exist, so
  `cleanup_image_decisions` aborted part-way and reported an EMPTY image set,
  i.e. "nothing to protect";
- `full="$(domum_image_id_full "$ref")"` aborted the resolve loop before its own
  absent-image branch;
- and a rollback record's `IMAGE_BEFORE=unknown` sentinel was reported as an
  image whose id is the literal string `unknown`.

When a function's failure is EXPECTED and handled, capture it with `|| true`.

**I broke that rule in the same session I wrote it.** The `storage archives`
off-host check rolled its own parser for the successful-backup marker --
`cat … | tr -cd '0-9'` -- against a file holding an ISO-8601 timestamp, not an
epoch: `2026-10-08T02:37:27-04:00` becomes `202610080237270400`, an 18-digit
number larger than any `mtime`. So the comparison was ALWAYS true and the check
could only ever answer "yes". It reported "yes" in production for an archive the
last backup predated by six hours, and the missing timestamp in that line --
`date -d @202610080237270400` fails -- was the only visible symptom.

The test asserted that the strings `yes`, `NOT YET` and `UNKNOWN` appeared in the
function's SOURCE. They did. It passed without ever executing the comparison.
A branch-coverage claim made by grepping for branch text is not coverage: drive
the function against fixtures with controlled inputs and assert the ANSWER. And
`backup_last_success_epoch` already existed -- one implementation of a check, as
with the topology invariant.

**A deployment script must not assert an absolute per-service production
state.** The 5394e453 deployment aborted at its own stage 7 with

```
ABORT: storage protection calibre-web reports 'protected', expected 'unprotected'
```

after it had already fast-forwarded the checkout, installed every file and
removed the old wrapper. The mutations were complete and correct; only the
verification was stale. calibre-web had been migrated that morning — by the
previous step of the same session — and the generated script still carried
`"calibre-web:unprotected"` from the deployment before it.

This is the stale-topology-invariant failure again, in the one place still
outside CI: deployment scripts are generated into `/home/jfranco` and no audit
reads them. Operator wrappers were moved into `operator/` for exactly this
reason; the generator has the same problem and the same fix is not yet applied.

What a deployment may verify about protection: that the state word is one of the
known values, that the exit status is 0 only for `protected`, and that the
services the deployment itself claims to block are blocked. What it may not do
is pin which service is in which state — that is live state the deployment does
not control, and it changed within a day twice running (`plex`, then
`calibre-web`).

Related, and the reason this one got through: I had edited the explanatory
*note* about calibre-web and left the actual check in the loop above it. When a
fact appears twice in a script, changing one is worse than changing neither,
because the remaining copy now has a comment vouching for it.

**Strip comments before asserting that code does NOT contain something.** Three
assertions in one section flagged their own explanatory comments: a test for
"does not invoke restic", one for "does not digit-strip the marker", and the
capability audit's reachability walk, which was fooled by a comment naming
`service_upgrade`. A comment quoting the broken form is how the fix documents
itself.

**Rehearse an operator wrapper; do not merely review it.** The wrapper's roots
are overridable only for that purpose and default to the production paths. Do
not weaken a check to suit the test: the root check is satisfied by running the
rehearsal under `unshare -r`, where the caller maps to uid 0, so
`[ "$(id -u)" -eq 0 ]` runs as written. The rehearsal proves the wrapper's scope
proof is INDEPENDENT of the CLI's, by blinding the CLI's own before/after
comparison and requiring the wrapper to still catch a non-Plex change.

**A test that depends on host state is not a test.** The integration suite passed
here and failed in CI with `install: cannot create directory
'/etc/domum-core-media'`, because `SECRETS_DIR` defaults to a host path that
happens to exist on this machine. Every root a fixture uses must be redirected
into it, and asserted to be.

`tests/reconcile-boundary-audit.py` enforces the classification rather than
trusting it: an image-preserving function containing an executable reconcile fails,
a deployment function that stops reconciling fails, and a reconcile in an
**unclassified** function fails — so the boundary cannot be inherited by accident.

**`domum-media update` is NOT the gated upgrade path.** It is `repo_update`:
`git reset --hard origin/main`, converge, then `exec domum-media apply` — and
`apply`'s pre-apply snapshot is fleet-wide and non-fatal by design, while
`compose up -d` recreates any container whose image changed. The per-service gate
lives in `refresh_images` (`domum-media updates apply` / `refresh-images`), which
snapshots the service it is updating, by name, and dies when that returns nothing.

**An image upgrade may proceed only when the state THAT service may mutate has a
recovery point appropriate to THAT service.** A Jellyfin snapshot must never
satisfy a Plex upgrade — the `immich reset-db` defect class. So it is evaluated per
service and never counted: `apply` refuses before its fleet-wide `up -d` when any
enabled service has a staged image and unprotected state. A service with no state
under `/srv/data` is reported, not blocked — a snapshot could never cover a Docker
volume, and that is the recovery-pack question. A path that exists whose protection
is `unknown` IS blocked. See `docs/UPGRADE-PROTECTION.md`.

**"No `/srv/data/<service>`" is NOT "stateless", and the upgrade gate used to
treat them as the same thing.** `apply_staged_image_blockers` emitted `NOSTATE`
whenever the path was absent, and NOSTATE was reported and then **allowed**.
Measured 2026-10-08, with a staged image waiting for both: `traefik` keeps
`acme.json` (116,015 bytes, mode 0600 — the Let's Encrypt **account private key**
plus 9 issued certificates) in `domum-media_traefik-letsencrypt`, and
`uptime-kuma` keeps `kuma.db` (286,720 bytes **with a non-empty `-wal`**, a live
SQLite database it forward-migrates on startup) in `domum-media_uptime-kuma-data`.

The recovery pack does capture both, so this was never "no coverage" — it is the
wrong KIND. A pack is periodic and operator-driven, records **no image identity**,
and is not created before an upgrade, so it cannot pair state with the
application that wrote it. Disaster recovery and rollback are different artefacts.

`service_state_models` now **declares** a model per service — `protected-tier`,
`docker-volume` or `stateless` — because durability cannot be inferred from a
mount list: a volume holding a model cache and one holding a private key look
identical. The declaration is then **checked against the live mounts and fails
closed**: an undeclared rw volume, an rw bind under the protected root beneath a
service declared stateless, or a `protected-tier` service whose path is absent
all become `unknown`/`missing-state-path` and are **blocked**. `docker-volume` is
blocked too — not because the state is unprotected, but because no pre-upgrade
recovery point is *possible* for it yet. Undeclared services fail closed.
`storage protection` reports the model and exits 0 only for genuinely protected
state. Never add a benign destination to make a gate pass.
`tests/state-model-smoke.sh`; 3 mutants, all killed. See
`docs/STATE-CLASSIFICATION.md`.

**A test can assert a defect.** Fixing the above broke three suites, and two of
them were requiring the old behaviour outright: `update-path-gate-smoke` demanded
`NOSTATE traefik` and *failed if traefik was blocked*, and
`upgrade-protection-gate-smoke` required that a service with no state path be
allowed. The reasoning in both — "a snapshot cannot cover a Docker volume" — was
true, and the conclusion did not follow. Before adapting a test to a change, ask
which of the two is wrong; here the btrfs integration suite had three of the same
shape (`up -d` restarts, "Migration complete" on a failed proof snapshot).

**Docker must not start before `/srv/data` is mounted.** Containers are
`restart: unless-stopped`, so the daemon starts them at boot without compose; with
the mount absent it would create the bind-mount sources on the OS disk and every
service would come up as a fresh install, hidden later when the mount lands.
`systemd/docker.service.d/10-domum-require-mounts.conf` makes the dependency
explicit — it was previously only transitive target ordering, with
`RequiresMountsFor=` empty. Never add `nofail` to those fstab lines.

**A mount dependency belongs on the unit that needs the path, scoped to what it
needs.** `docker.service` requires `/srv/data` and nothing else: measured over
every bind source of all eleven containers, `/srv/media` is a plain directory on
`/` (so `RequiresMountsFor=` would resolve to `-.mount` and add nothing — never
invent a dependency for it), and **zero containers bind `/srv/snapshots`**, so
requiring it there would let a failure of a filesystem no container uses stop all
eleven. The snapshot root is declared on the domum-media units that create, prune
or read snapshots; `domum-media-dr-reminder.service` deliberately declares none,
because a storage failure must not silence the DR reminder. An explicit
`RequiresMountsFor=` accumulates with the one `CacheDirectory=` implies rather
than replacing it. `tests/boot-mount-dependency-smoke.sh` enforces the whole
scope, in both directions.

**Every enabled timer is `Persistent=true`, so a reboot runs missed jobs
immediately** — including `snapshot prune`, which deletes. Check
`LastTriggerUSec` against `NextElapseUSecRealtime` before rebooting rather than
assuming; see `docs/REBOOT-READINESS.md`.

**A reboot is not an image-deployment vector — demonstrated, not argued.** The
2026-10-05 reboot (`6.12.107` → `6.12.111`) brought back all eleven containers as
the *same objects*, original IDs and `Created` timestamps intact, with only
`StartedAt` moving. Four services had a newer image staged locally under the same
tag and all four stayed on the old one. Nothing at boot runs compose, so no tag is
resolved. Keep it that way: no `domum-media-*.service` may gain `WantedBy`, and no
timer may gain `OnBootSec`/`OnStartupSec`.

**A safety check must be tested against the data it will actually see, and a
failing check must name what it matched.** The capture validator's first "no
secrets" assertion matched `[A-Za-z0-9+/]{60,}={0,2}$` and failed on the real
capture — because a 64-character hex digest matches that shape, and digests are
the capture's most ordinary field. It then said only "a secret-looking value",
naming no line, so the finding could not be acted on. An unactionable `FAIL`
trains the operator to ignore it. Prefer an explicit allow-list of expected keys
over an entropy heuristic.

**Never add `--one-file-system` (or `-x`) to the restic backup.** A Btrfs
subvolume gets its own anonymous `st_dev` — measured: `/srv/data` is 45 while
jellyfin=73, kavita=74, navidrome=68 — so that one flag would silently drop every
migrated service, i.e. exactly the highest-value data, and the backup would still
report success. `tests/subvolume-detection-smoke.sh` asserts its absence.

**Plex's running image is `identity,local` only.** Measured: `RepoTags: []` **and**
`RepoDigests: []` — it is dangling, because a newer `:latest` was pulled and moved
the tag. It survives solely because a running container references it, so the
moment Plex is upgraded the old image becomes prunable and the recovery point's
application half turns fragile exactly when it starts to matter. The version is
recoverable only as a label (`1.43.2.10687-563d026ea-ls308`), which is
compatibility information, not a retrievable reference.

**"I could not check it" is not "it is broken".** Plex's databases carry FTS
virtual tables built with its own `collating` tokenizer, which only Plex's
bundled SQLite registers. The host's SQLite raises `unknown tokenizer: collating`
on both `integrity_check` and `quick_check` for a perfectly sound file — measured:
`page_count`, `schema_version`, `journal_mode` and all 254 `sqlite_master` rows
read fine, exactly 2 objects use that tokenizer, and Plex's own SQLite returns
`ok` with zero foreign-key violations. `migrate_sqlite_integrity` reported those
two databases as a **failed recovery point**, contradicting its own comment. An
extension the local SQLite lacks is now `unsupported:` → **not checked**, while a
genuinely broken database still fails. When the application ships its own SQLite
(`service_sqlite_binary`) that is used instead, turning "not checked" back into a
real check. `tests/sqlite-unsupported-smoke.sh`; 6 mutants, all killed.

**`storage verify-recovery … --deep` re-proves an existing recovery point**
(`.premigration` == proof snapshot, plus the SQLite checks). Before it, the only
way to re-run that proof was to re-run a migration — which cannot be done twice,
so a false negative left no route to a clean verdict. It refuses honestly once
`.premigration` is gone, because the comparison then has no left-hand side.

**`cleanup images` must never delete an image a recovery point pairs with, and
its in-use exclusion was broken.** `docker images -q` yields SHORT ids while
`{{.Image}}` yields `sha256:<64 hex>`, and the exclusion compared them with
`grep -Fxq` — which can never match. Measured: **four images belonging to RUNNING
containers** were offered as deletion candidates (plex, calibre-web, traefik,
uptime-kuma — each dangling because a newer `:latest` moved the tag off it).
Separately, the selector consulted no recovery metadata at all, so upgrading a
service would make its paired image deletable: the snapshot would still restore
the data while the application that wrote it became unobtainable. Plex's pairing
is `identity,local`, so the local object is the only copy. Both sides are now
canonicalised through `docker image inspect -f '{{.Id}}'`, recovery-point images
are protected by name, and the dry run **says what it protected** — a deletion
tool that silently omits things gives no way to notice the protection broke.
`tests/cleanup-image-protection-smoke.sh`; 6 mutants, all killed. `cleanup` stays
operator-initiated: `--confirm` required, and on no timer.

**A safety report that cannot be falsified is not a safety report.** The
`cleanup images` dry run printed "`0 named by a recovery point`" in production.
That number counted candidates *blocked by that reason*, and it was genuinely 0 —
the only recovery-named image that is also a cleanup candidate is Plex's, and
`in-use` was checked first and won under first-match-wins. So the line could not
distinguish "no recovery metadata exists" from "nothing reached that branch", and
neither reading could be ruled out. It now reports the recovery-image **set**
(how many images recovery points name, how many are present locally, and which
point names each) independently of what it withheld, and attributes **every**
applicable reason rather than the first. `tests/cleanup-image-protection-smoke.sh`
drives `cleanup_cmd` itself for exactly this reason; 7 mutants, all killed.

**A fixture-backed probe is not production evidence.** The verification that
missed the above stubbed `snapshot_metadata_dir` to a scratch directory and wrote
a `.recovery` file naming an image of its own choosing — then reported the result
as confirmation that production was protected. The real command disagreed. When a
check cannot read the real input, say that; do not substitute an input and
present the outcome as evidence. Relatedly, `grep -qx "<id>"` against
`cleanup images` output can never match, because the command prints
`<id> [tags]` — three absence assertions were vacuously true until that was
found.

**The update path's pre-update snapshot is NOT application-consistent, and
carries no recovery metadata.** Measured in `refresh_images`: it calls
`create_service_snapshot` while the service is **running** — no stop, no
open-handle check, no WAL gate anywhere in that function — so the snapshot is
crash-consistent while Plex holds a live non-empty WAL. `create_service_snapshot`
also writes **zero** recovery metadata, so a pre-update snapshot is a DATA-only
point, and because `cleanup images` protection keys off `.recovery` files, the
old image it depends on would not be protected either. `refresh_images` also
rejects any positional argument, so **it cannot upgrade a single service**;
scope is governed by `*_AUTO_UPDATE` config flags. Do not treat
`updates apply` as a Plex-only upgrade.

**`storage pre-upgrade-point <service> [--archive-image]`** is the complete
rollback artifact, and it deploys nothing: stage metadata → stop → prove
quiescence → read-only snapshot → archive the exact running image → bind
metadata → `compose start` the same container on the same image. Ordering is
asserted, not assumed: staging must precede the stop (the running image has to
be recorded while it is observably running) and binding must precede the restart
(once the application runs again it can mutate the state the point describes).

**A `docker save` archive preserves image identity, and its checksum does not
prove that.** Measured: `docker load` of an archive saved by image ID reported
`Loaded image ID: sha256:fd7dc98638c8…`, byte-identical. But the archive's
config-blob digest does **not** equal the image ID on this host (Id is the
manifest digest), so identity cannot be checked from the blob — the `.sha256`
beside the archive proves the FILE is intact, `docker load` proves the identity,
and neither is presented as the other. Archives live in
`$DOMUM_DATA_ROOT/backups/images`: on the protected tier, inside the restic
backup set, and **outside every service subvolume** so they do not duplicate into
per-service snapshots.

**`updates apply --service <s>` upgrades ONE service; bare `updates apply` is the
fleet path and cannot target one.** They are different operations, not a filter:
`refresh_images` dies on any positional argument, and its scope is every service
with `ENABLE_*=1` and `*_AUTO_UPDATE=1`. `service_upgrade` validates the name
against `managed_image_specs` with an exact whole-line match and **dies** on an
unknown one — a typo must never widen to the fleet. It deploys the image already
staged locally and never pulls, so what was reviewed is what runs, and it
captures every other container's id and image with `ps -a` before and compares
after. That before/after comparison is the scope proof.

**Pre-upgrade protection is not a separate operator step.** `service_upgrade`
creates the point, archives the image and verifies the archive under the same
lock, and cannot reach `up -d` unless all three succeeded.

**Rollback restores BOTH halves or refuses (task-24).** The old auto-rollback
restored the snapshot and used `compose start` — onto the container the upgrade
created, i.e. the **new** image: old data under a newer application, the exact
pairing failure. `rollback_upgrade` takes the image id from the recovery
evidence, never from a tag; loads it from the archive if the local object is
gone and **compares the loaded id to the record**; pins `<SERVICE>_IMAGE` and
recreates deliberately; and preserves the failed state as `.failed-<timestamp>`.

**Pin an image with a subshell `export`, never `env VAR=… compose_cmd`.**
`compose_cmd` is a shell function and `env` can only exec a binary — measured,
`env X=1 f` gives `env: 'f': No such file or directory`, so that form fails every
time while a text-grep test still passes. `export_env_for_compose` uses
`${PLEX_IMAGE:-default}`, so a value exported first is preserved.

**The `--help` text lives in an UNQUOTED `cat <<EOF`, so a backtick or `$( )`
there is command substitution, not documentation.** Measured: usage text
containing a backticked `apply --service <s>` printed as
`"  upgrades ONE … Bare  is the"` — the backticked words were **executed and
vanished**, and `<s>` inside the substitution parsed as an input redirection
(shellcheck reported it as a parse error). `tests/log-hygiene-smoke.sh` now
rejects a backtick in any unquoted heredoc, and `$( )` in the `Usage:` block
specifically — a deliberate `$(immich_postgres_data_dir)` in a *message* heredoc
is fine, which is why the check distinguishes them.

**A metadata key read but never written is silently empty.**
`sed -nE "s/^KEY='(.*)'$/\1/p"` against a key nobody emits matches nothing: no
error, well-formed output, wrong answer. It happened — new code read
`..._IMAGE_VERSION` while the writer emits `..._IMAGE_LABEL_VERSION`.
`tests/recovery-metadata-keys-audit.py` compares the written and read sets across
the whole file and fails if its own extraction patterns stop matching, so it
cannot pass vacuously.

**Identity is not recoverability.** `IMAGE_ID=sha256:…` proves which image wrote a
state; it does not prove that image can still be obtained. A local object can be
pruned and a mutable tag says nothing about next year, so availability is recorded
per container as `identity`/`local`/`registry-digest`/`version-only`/`unknown` and
never collapsed into one reassuring word. A RepoDigest **equal to the image ID** is
not an independent registry reference — measured: docker reports exactly that here
— so it does not count. Never let "application recovery verified" rest on a
recorded string.

---

## 5. Production deployment

**Merging to GitHub `main` is not a production deployment.** Landing code on
`main` is a normal development operation; changing `/opt/domum-core-media` or
anything running on the host is a separate boundary with its own approval.

There is **no blanket-trusted deployment command.** In particular, do not treat
`domum-media update` as automatically the safest mechanism: `update`, `apply`,
`converge_local_installation`, the installer, image refresh, backup gates,
health gates, and rollback paths all still require a dedicated safety audit.

Until that audit is complete, a production-changing deployment must:

- be change-specific, with minimal blast radius;
- avoid application/container recreation unless genuinely necessary;
- preserve rollback material;
- state exactly what will change before it changes;
- use narrow installation where appropriate;
- be verified in production afterwards.

**Stop at the actual risk boundary and present the deployment plan** for any
production change that requires root or could affect running services.

Routine development, tests, git, PRs, CI, documentation, and read-only
production inspection do **not** need repeated approval.

---

## 6. Restic safety

The canonical cloud Restic repository is production recovery infrastructure.

Do not manually run, without explicit approval:

- `forget`, `prune`, `repair`
- repository deletion, migration, or reinitialization
- adoption of an existing production repository
- destructive unlock/recovery operations

Do not change retention policy without explicit approval.

**Important nuance:** configured and scheduled production behavior already
invokes Restic retention operations. Its existence is *not* authorization to
manually trigger, modify, or redesign it. Inspect and report existing behavior
accurately; do not conflate "the schedule does this" with "I may do this".

Historical or malformed Restic repositories are **evidence**. Do not modify or
delete them without a separate, approved cleanup plan.

Never expose Restic passwords or private keys in output, git, documentation,
or tests.

---

## 7. Immich and database safety

Immich is a primary reason this server exists.

The PostgreSQL backup artifact is the **validated atomic dump**, not raw live
PostgreSQL storage.

Do not:

- treat or manipulate live PostgreSQL files as backup artifacts;
- import a database into production for testing;
- reset the Immich database;
- overwrite known-good recovery artifacts without preserving them first;
- recreate the Immich stack merely to validate code.

Scratch restore testing must stay isolated from production paths.

**`encoded-video/` is NOT purely derivative, and the obvious exclusion would
have destroyed data.** The Immich library is 130.2 GiB of originals and 82.4 GiB
of regenerable derivatives, so "exclude `thumbs/` and `encoded-video/`" looks
free. Measured against the live asset table: **58 assets keep their
`originalPath` under `encoded-video/`** — motion-photo parts, each named
`<uuid>-MP.mp4`, 218.9 MiB, with no derivative rows of their own. Excluding the
subtree would have removed the only backed-up copy of all 58 and reported
success. A filesystem walk of `upload/` cannot find them; **only the database
can**. `thumbs/` genuinely is 100% derivative (16,211 preview + 16,211 thumbnail
+ 1 marker = the 32,423 files on disk, exactly). Never reason about what is
regenerable from directory names.

**Never use a restic `!` re-include to protect data.** restic 0.18.0 supports
them, and measured in a scratch repository they are **order dependent and fail
silently in the dangerous direction**: with the re-include written first, zero
`.mp4` files were kept — including the originals — and restic printed
`snapshot … saved` with no warning. Prefer a pattern that cannot match the
protected files at all; the derivative/original split is carried by a character
class (`*[0-9a-f].mp4` matches the 9,028 derivatives and none of the 58
`-MP.mp4` originals), which has no ordering semantics. Verified by duplicating
and reversing the pattern list.

**Exclusion patterns are read from `backup_exclude_patterns`, and
`exclusion-audit` checks them against the live asset table.** They used to be
written inline in the restic invocation where nothing could read them, so "the
backup excludes X" was a claim about source text. The audit is conservative by
construction (restic's `**` matches zero or more components, so the collapsed
variant is tested too — it can over-report, never miss) and **refuses to pass
vacuously**: if the container-to-host prefix translation fails, every path keeps
its container shape, matches no host pattern, and a naive version reports a
clean `0 matched` having compared nothing. `tests/backup-exclusion-audit-smoke.sh`
mutates that guard away and requires the false clean verdict to appear. See
`docs/BACKUP-EXCLUSION-PROPOSAL.md`.

**The asset table is the ONLY authority for what is an Immich original.** A
filesystem walk of `upload/` got both ends of the coverage fraction wrong at
once: it counted the 13-byte `.immich` marker as an original *and* missed the 58
originals under `encoded-video/`. Worse, because selection picks the
median-sized file of each extension, the marker became the representative of
extension "immich" and was reported as a restored original -- `match immich 13
.immich` appeared in a production verification run. Selection and coverage are
now pure functions of an INVENTORY built from `asset.originalPath`
(`immich_original_inventory`), a path the table names but which is absent from
disk is counted as **missing** rather than silently dropped, and both
`verify-sample` and `sample-plan` **refuse** when the table cannot be read
rather than falling back to the walk. Measured: 23,033 originals = 22,975 under
`upload/` + 58 under `encoded-video/`, zero duplicates, zero nulls, zero
elsewhere, zero missing on disk, 130.4 GiB.

**The inventory must never be written inside the restore target.** `$scratch`
is what restic restores into, so a file placed there is indistinguishable from
restored content. It was briefly inside, and the corruption test caught it: the
stub that damages "the first restored file" damaged the inventory instead, and
the corruption went undetected.

**ARCHIVE VALIDATED, DATABASE IMPORT RESTORE TESTED and FULL IMMICH RECOVERY
VERIFIED are three different claims.** `verify-restore` checks gzip, size and
footer -- that the FILE is intact. That says nothing about whether PostgreSQL
can read it, and `dr-status` wrongly promoted it to `RESTORE TESTED`.
`verify-db-restore` imports the restic-restored dump into a DISPOSABLE
PostgreSQL and earns the second claim; the third requires a rebuilt Immich
serving the library and has never been done. Rules that hold:

- **The import runs under `ON_ERROR_STOP=1`.** Without it psql reports success
  having skipped every statement it could not run. Measured against the real
  dump: 20 s, exit 0, zero stderr, 23,033 assets into 61 tables, and a
  deliberately truncated dump fails with the offending column named.
- **The disposable instance must use the image production uses**, read from
  `docker inspect`, never hardcoded: the dump declares
  `CREATE EXTENSION vectors WITH SCHEMA vectors`, which only `pgvecto-rs`
  provides, so a plain `postgres:14` would fail for a reason that has nothing to
  do with the backup. If the image is absent locally it reports NOT ATTEMPTED
  and **refuses to pull** -- what gets tested must be what is already here.
- **Isolation is structural, not promised**: `--network none`, tmpfs PGDATA, no
  published port, no bind mount, removed by a trap that also terminates on a
  signal. The test asserts docker was really given those flags, not that the
  report mentions them.
- **A consistency key that was never emitted returns a sentinel that FAILS every
  check.** `(( $(f missing) > 0 ))` with an empty substitution is a runtime
  syntax error, so under `set -e` a renamed key would abort the verification
  instead of failing it -- the metadata-key family again.

`tests/db-import-verification-smoke.sh`; 1 mutant (dropping `ON_ERROR_STOP=1`
must let a broken import pass), killed.

**A test must not be ABLE to reach the host.** An un-stubbed
`immich_db_original_paths` in `sample-verification-smoke` silently queried the
LIVE production database and the plan reported its 23,033 assets from inside a
fixture library. Redirecting roots is not enough when the code path leaves the
filesystem: put a `docker` stub on `PATH` that exits non-zero, so reaching
production FAILS instead of quietly succeeding.

**The exclusion check matches PATHS from the asset table, never a stat of
them.** Whether a file is currently on disk is a different question: a path the
table names is an original, and a pattern that matches it is wrong even while
the file is absent. Making the match depend on an inventory built by `stat`
meant the audit compared nothing and reported `0 matched` for a library whose
files had not been created -- the vacuity hole again, found by CI, now pinned by
a regression assertion. The inventory with sizes is for SAMPLING; matching needs
only paths.

**The large originals are proven progressively, never in bulk.** Measured: 17
originals exceed the 256 MiB sample cap -- 15 `.mov` and 2 `.mp4`, 274 MB to
1.38 GB, 7.9 GiB in total, i.e. the home videos. Raising the cap would fetch
7.9 GiB from Hetzner on every run to move a reported percentage, so
`verify-large` accumulates instead: smallest unproven file of each container
format first, `LARGE_MAX_RUN_BYTES` (1 GiB) capping a run while always allowing
one file so it cannot deadlock, a durable 0600 history so a proven file is never
fetched twice, `--revalidate` as the only way to re-prove, and `--plan` stating
the byte cost without contacting anything. A default run is **2 files, 524 MiB**.
A `MISMATCH` is recorded and **not** counted as proven, so a corrupted large
original cannot quietly join the coverage figure.

Two defects there, both found by running the code rather than reading it, both
of families already recorded in this file:

- the history filter was `grep -vxF -f <paths>` against `<size>\t<path>` lines,
  which can **never** match on a whole line -- the `docker images -q` short-id
  defect exactly. Every proven file was re-selected and re-downloaded while the
  report claimed they were already proven;
- replacing it with the `NR==FNR` idiom broke the **empty** case: for the first
  line of the second input `NR==FNR==1`, so that line is mistaken for a history
  entry. With no history the candidate set silently emptied and the command
  announced "every large original is proven" having verified none. Read the
  other file with `getline` instead.

**"Not in the backup set" and "the include set was never read" are different
claims.** `dr_path_configured` reported the former for the latter. It now has a
third state and the report says UNKNOWN -- the same conflation the five levels
exist to prevent, in the one place that decides whether anything is covered at
all.

**An exclusion affects NEW snapshots only, and applying one must never prune.**
restic is content-addressed: existing snapshots keep their file lists and the
blobs they reference, so switching the derivative exclusion on would leave every
existing snapshot complete and restorable, stop adding derivative blobs from the
next run, and free nothing until retention forgets those snapshots **and** a
prune runs. The saving is therefore gradual by design, and the old snapshots are
the fallback if the exclusion turns out to be wrong. Never prune to realise a
saving sooner.

**`dr-status` states the backup SCOPE, so the irreplaceable/reacquirable split
is checked rather than assumed.** Measured: `/srv/media` (975 MiB of music,
496 KiB of books) is **not** under the include root, so the replaceable tier is
correctly absent from Hetzner, and `/srv/media/.cache/*` is excluded. The one
deliberate overpayment is the 82.5 GiB of regenerable Immich derivatives, which
is gated and unapplied. A reacquirable tier found INSIDE the include set is
reported as a finding.

**When editing a file programmatically, assert the anchor matched.** A
replacement whose anchor text did not exist silently did nothing, so a test's
database stub was never installed into the harness and the suite reported
"the asset table could not be read" from inside a fixture that had one. A
no-op edit is indistinguishable from a successful one unless the count is
checked.

**Recovery is reported on five levels, and the weakest tier governs.**
`UNKNOWN < CONFIGURED < BACKED UP < RESTORE TESTED < FULL RECOVERY VERIFIED`
(`domum-media-backup dr-status`). They are deliberately not collapsible into a
boolean, because every reporting defect here was the weaker claim stated in the
stronger claim's words. `RESTORE TESTED` requires a **stated denominator**: a
sample proof whose population was never measured is reported as `BACKED UP`
with the reason named, not promoted — a manifest saying "12 sampled, 12 matched"
was true and uninformative while 17 originals (7.9 GiB) sat above the per-file
sampling cap and could never be selected. **Nothing on this host is
`FULL RECOVERY VERIFIED`**, and the report says so in its own words until a
whole tier has been restored and the owning application has confirmed it. Never
promote a tier because another tier was proven. See
`docs/DISASTER-RECOVERY-STATUS.md`.

---

## 8. Git and development workflow

```
inspect → reproduce → develop → test → focused commit → push branch → PR → CI
→ review → merge → controlled production deployment when appropriate → verify
```

- **Never push directly to `main`.** Prefer focused branches and commits.
- `git` and `gh` are authenticated on this server — use them directly. Do not
  ask the operator to perform routine GitHub operations from another machine.
- **Never discard another agent's uncommitted work.** Before changing an
  unfamiliar dirty worktree, understand it and preserve it. Prefer a separate
  `git worktree` over stashing, resetting, or discarding.
- **Never wait on CI with an unbounded loop.** `gh pr checks <n>` returns an
  empty result once a PR is merged, so a loop waiting for `SUCCESS` or
  `FAILURE` never terminates and leaks a polling shell that outlives the task.
  Poll the run instead (`gh run view <id> --json status`), which reaches
  `completed`, and treat an empty or missing result as terminal rather than as
  "keep waiting".
- **Never write `cmd | grep -q` under `pipefail`.** `grep -q` exits at the first
  match, the left-hand command takes `SIGPIPE`, and the *pipeline* reports 141 —
  so **a match reads as no-match**. Measured: `sed bin/domum-media | grep -q <hit>`
  returns 141. It is intermittent, because it only bites when the left side is
  still writing when grep exits, which makes it worse. Capture first
  (`out="$(cmd)"`), then `grep -q … <<< "$out"`. This silently inverted a test
  guard and was one pipe-buffer away from inverting the stop verification that
  the whole migration safety argument rests on.
- **Take the backup before the mutation, unconditionally.** When mutation-testing,
  `cp` the file on its own line — not chained after the command being tested. A
  short-circuited `&&` chain leaves the mutation applied and no way back.

---

## 9. Testing contract

`.github/workflows/compose-validate.yml` is the source of truth for validation.
Read it rather than relying on remembered commands. It currently expects:

- `bash -n` on the shell entrypoints
- `shellcheck --severity=warning`
- the hermetic smoke tests under `tests/`
- `systemd-analyze verify` on `systemd/*.service systemd/*.timer`
- `docker compose --env-file config/ci.env … config -q` with every fragment
  layered on `compose/base.yml`

Notes:

- `shellcheck` is not installed as a host package, but it **can be run here**
  through the image that is now pulled locally, with exactly the flags CI uses:

  ```
  docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
    --severity=warning bin/domum-media bin/domum-media-backup \
    bin/domum-media-report install.sh operator/*.sh
  ```

  Run it before pushing. Two CI failures were spent on findings it reports in
  seconds -- `SC2178`/`SC2128` from reusing the name of an array in the same
  file as a string local, and `SC2155` from `local x="$(...)"`. Still do not
  report a shellcheck pass that did not run.
- **The workflow enumerates every test by name — there is no glob.** A new suite
  is not enforced until a step is added, and seven were not: they passed locally
  and were reported as "CI green" while CI had never run them. `tests/ci-coverage-audit.sh`
  now fails when a test file is missing from the workflow, or when the workflow
  names one that no longer exists. Never describe a suite as CI-verified without
  checking it is listed.
- `systemd-analyze verify` only checks unit syntax and that `ExecStart` binaries
  exist. It cannot detect a unit invoking a subcommand the CLI does not
  implement. `tests/unit-subcommands-exist-smoke.sh` is that separate
  verification, and it also reports host units absent from `systemd/` as drift.
  The live host carries a disabled `domum-media-hot-prune.service` invoking
  `domum-media hot prune`, a subcommand that no longer exists — which is what
  prompted the check.
- The smoke tests are hermetic (`mktemp -d` + cleanup trap) and safe to run.

Run the tests appropriate to the changed area. Add regression coverage with a
focused change when practical. **Do not claim success because a command exited
zero if the test did not actually exercise the intended behavior.**

---

## 10. Autonomy and sudo

This session runs directly on the N100. Do not tell the operator to SSH in.

Work autonomously on normal low-risk development. Do not stop after every step
to ask for approval. Attempt operations you have permission to perform.

`sudo` here requires interactive authentication that the agent cannot supply.
When an operation genuinely requires it, print:

```
OPERATOR ACTION REQUIRED
```

followed by **only the smallest privileged command or block required**, then
resume autonomously once the result is provided.

Never resolve sudo friction by configuring broad passwordless sudo.

---

## 11. Stop conditions — explicit approval required

- deleting user data
- restructuring `/srv/data` or `/srv/media`
- Btrfs migration
- manual/destructive Restic operations
- repository deletion, migration, or historical Restic cleanup
- production database import or reset
- substantial application downtime
- broad container recreation
- application/image deployment
- re-enabling automatic image deployment
- fundamental storage architecture changes
- exposing or copying private keys or secrets
- configuring broad passwordless sudo
- large unrelated redesign with production impact

Do **not** manufacture approval gates for ordinary coding work.

---

## 12. Backlog

`backlog/` is planning information and evidence — **not an execution order and
not authority.** Do not execute tasks blindly by number or phase.

Reconcile each item against actual repository and production evidence before
acting. An item may be DONE, PARTIALLY DONE, STILL VALID, SUPERSEDED, in need
of REORDER, or replaced by something NEW.

Prefer the highest-value safe work given current evidence and project goals.
Do not create duplicate tasks for work already represented.

---

## 13. Relationship to `domum-core`

`domum-core` is the sibling/reference project. The goal is **"same operator
experience, different server responsibilities."**

Borrow Core's *patterns* for CLI ergonomics, reporting, status/checkup, backup
visibility, update safeguards, recovery workflows, and documentation
organization.

- Do not blindly copy its implementation.
- Do not modify `domum-core`.
- Do not copy its known defects.
- **`domum-core` is not currently available on this host.** Record that
  limitation when it matters; never invent or assume its behavior.

---

## 13b. Migration lifecycle — which comparison proves integrity

A service's state legitimately changes during a clean shutdown and again on
restart. Never assert that a pre-stop fingerprint equals a post-restart one: the
first production pilot aborted on a perfect migration for exactly that reason.

The integrity claim is **`.premigration` == proof snapshot** — the original that
was moved aside against a snapshot of the copy that replaced it. Both are static,
so a running application cannot disturb the comparison, and it catches corruption
introduced after `migrate_verify` has already passed.

The live tree is **classified, not compared** — migration stage 10,
`migrate_report_live_tree`. Each differing path gets one record: `CHURN`/`PRUNED`
for expected runtime state, `CHANGED`/`ADDED` reported for review, and `LOST`
(gone and *not* expected churn) is the only one that fails. A database file is
never on the expected-churn allowlist, including a dated backup.

**"Missing is a hard failure" was false, and only Plex showed it.** That rule
held for the first three services and would have aborted a correct Plex
migration on ordinary log rotation and on Plex pruning its own dated database
backups. A disappearance is split the same way an addition is.

**This check lived only in the operator wrapper while two docs claimed the CLI
did it** — stages ran 1–9. It is now one implementation in `bin/domum-media`,
tested by `tests/live-tree-classification-smoke.sh`, invoked by the wrapper. The
wrapper's copy also iterated `for f in $CHANGED $ADDED`, which word-splits: two
real Plex paths became eleven fragments, classified inconsistently with each
other. Anything walking service paths must be NUL-delimited; Plex is the first
service whose paths contain spaces.

Full detail and the measured evidence: `docs/MIGRATION-LIFECYCLE.md`.

---

## 14. Current engineering phase — Operational Trust / Visibility

The goal is that the operator can ignore this server for days or weeks and then
quickly answer:

- Is the host healthy?
- Are containers healthy?
- Are backups current?
- Did scheduled jobs succeed?
- Is storage healthy?
- Is a reboot required?
- Are updates staged?
- Is snapshot protection actually available?
- Is anything approaching failure?

Trustworthy status / checkup / reporting comes **before** large new
infrastructure work. Truthfulness outranks coverage: a report that admits
"unknown" is correct; one that implies protection that does not exist is a
defect.

Cockpit, GPU work, Btrfs migration, application upgrades, historical repository
cleanup, and large observability stacks are later work unless explicitly
reprioritized.

**A NAS is a tier decision, not a capacity decision, and the protected tier
never moves onto one.** Measured 2026-10-09: `/srv/data` is 24% used (715 GiB
free), `/` is 14% used (371 GiB free), and `/srv/media` is ~976 MiB — so space
is not the constraint. NFS and SMB have no subvolumes, snapshots or reflinks, so
moving any migrated service's state to a NAS would silently undo the migration:
`domum_is_subvolume` returns false and per-service protection reverts to
DEGRADED. `/srv/data` and `/srv/snapshots` stay on local Btrfs. Immich originals
stay local — they are the one large irreplaceable dataset, and if they ever
outgrow 931 GiB the answer is a bigger local Btrfs device, not a network
filesystem.

Two further rules follow, both instances of defect families already recorded
here:

- **restic does not check that a path is mounted.** If a backup root were a
  network mount and the NAS were absent at 02:31, restic would walk an EMPTY
  directory and report `snapshot … saved`; current runs add only 10–60 MiB, so a
  near-empty run is not visibly anomalous. Same shape as the
  `--one-file-system` hazard. Any backup root that can be a network mount must
  be asserted mounted and non-empty, and the run must **refuse**, not warn. That
  precondition does not exist yet and is the first thing to build.
- **Every NAS path bound into a container needs an explicit, scoped
  `RequiresMountsFor=`, and its fstab line never gets `nofail`** — containers are
  `restart: unless-stopped`, so Docker starts them at boot without compose and
  would create the bind sources on the OS disk. This deliberately couples
  Docker to the NAS, which is why the mount belongs at a NEW path
  (`/srv/nas/media`) added as an extra read-only source rather than by moving
  `/srv/media`: a NAS outage must not stop four working media services.

See `docs/NAS-INTEGRATION-ARCHITECTURE.md`. Planning only — no mount is
configured and no path is moved.

---

## 15. Known open safety defects

Documented here because they constrain what is safe to do. Remove an entry when
it is actually fixed; keep the detail in `docs/`.

- **Deployment timers must never be auto-enabled.** `systemd/auto-enable.timers`
  is the single source of truth for what installation and convergence may
  enable, and `domum-media-image-refresh.timer` is deliberately absent from it.
  Never add a deploying timer to that file, and never reintroduce a hardcoded
  unit list next to a `systemctl enable` call — `sync_timer_overrides` is
  reached by `apply`, `init`, `configure`, and therefore by `update`, so a
  hardcoded list there lets routine convergence silently resume deployment.
  `tests/timer-auto-enable-safety-smoke.sh` enforces this.
- **`domum-media-btrfs-snapshot.service` runs `snapshot prune`, not
  `snapshot create`** — confirmed, and deliberately left that way for now.
  Its timer is enabled and fires weekly (Sun 04:30 +20m). **It is now a live
  deleting job**: since the Jellyfin migration the snapshot root is no longer
  empty. It ran for the first time with something to prune on 2026-09-27 04:33:43,
  deleted nothing, and exited 0 — see `docs/SNAPSHOT-PRUNE-FORENSICS.md`. It takes
  the operation lock, enforces a retention floor of 1, reports what it deleted, and
  fails when a delete fails. Do not repurpose it to create snapshots as a side
  effect of other work, and treat any change to it as a change to a deletion path.
- Documentation may still describe protection that production does not have
  (snapshot coverage, backup targets that are not enabled). Verify claims
  against live evidence before repeating them.

---

## 16. Documentation boundaries

`CLAUDE.md` = durable operating rules. Detailed historical and operational
evidence belongs in repository documentation, which should preserve the P0
record: original backup failure and root causes, canonical cloud backup design,
accepted repository identity, atomic PostgreSQL dump behavior, recovery-pack
design, successful restore verification, runtime timeout/cache hardening, the
image-refresh safety freeze, the degraded Btrfs snapshot state, and the
historical repositories intentionally preserved.

**Never put credentials or secret values into documentation.**
