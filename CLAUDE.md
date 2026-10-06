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

**Four services are migrated and protected: `jellyfin` (2026-09-25), `kavita`
(2026-09-29), `navidrome` (2026-09-29) and `plex` (2026-10-06).** Each is a real
Btrfs subvolume with a verified read-only proof snapshot and retained
`.premigration`. Plex is the one with symlinks (7, one absolute into the
container's `/config` namespace) and the weakest application pairing
(`identity,local`: both `RepoTags` and `RepoDigests` empty, so the image is
dangling and survives only because a container references it). Its migration
deliberately did **not** deploy its staged image, which was the point of doing
it. `docs/PLEX-MIGRATION-RESULT.md` holds the evidence.

**Still ordinary directories: `calibre-web` and `immich`** — so their upgrades
remain correctly blocked, and `calibre-web` still has a staged image waiting.

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

- `shellcheck` is **not installed on this host**; CI installs it. Do not report
  a shellcheck pass that did not run.
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
