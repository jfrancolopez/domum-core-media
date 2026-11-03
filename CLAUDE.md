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

**The deployment script generator's problem is fixed by moving it into
`operator/`, which this file said was "not yet applied".** It is applied now:
`operator/domum-media-deploy-reporting-fixes.sh` is in the repository, in CI,
shellchecked by the `operator/*.sh` glob, read by
`tests/operator-wrapper-audit.py`, and REHEARSED by
`tests/deploy-reporting-rehearsal-smoke.sh`. A deployment script generated into
`/home/jfranco` is reviewed by nothing.

Its design follows the rules this file already records:

- **No baked-in revision.** The target is whatever `origin/main` is at run
  time; `--expect-revision=<sha>` pins it and is supplied by the OPERATOR, not
  stored. A revision constant inside the repository it pins goes stale by
  construction.
- **No absolute per-service production state.** It asserts nothing about which
  service is protected -- that is live state the deployment neither controls nor
  changes, and pinning it aborted a correct deployment at its own stage 7.
- **The one invariant it does assert cannot go stale**: each installed file's
  sha256 equals that file in the production checkout.
- **Fast-forward, never `reset --hard`.** A fast-forward cannot discard a
  commit and git refuses it when history has diverged. It also refuses outright
  if the checkout has ANY local change, tracked or untracked, rather than
  deciding which changes are legitimate.
- **Behaviour through `--json` + `jq`, never prose.** It requires the
  classification keys to be present and the verdict to be one of the known
  words. Counts are PRINTED and deliberately not asserted, because the library
  changes hourly -- asserting them would be the stale-state mistake again.
- **A reported BACKUP GAP does not fail the deployment.** It is a finding about
  the backup, not about installing a file, and conflating them would make a real
  finding look like a deployment problem.

**A script cannot deploy its own replacement.** Production, 2026-10-20: the
deployment fast-forwarded the checkout, which installed a NEWER copy of
`operator/domum-media-deploy-reporting-fixes.sh`, while the shell went on
executing the version it had already started. That older logic knew nothing
about the systemd units added in the same revision, so it installed one binary,
skipped BOTH unit files, and printed `== deployed ==` as though the job were
complete. `systemctl cat` then reported `No files found` and the operator had to
be told why. The dry run had looked right, because it was also the old script.

It now records its own sha256 before anything can change it, and once the
checkout holds a different copy it hands over -- `exec env
DOMUM_DEPLOY_REEXECED=1 bash "$CHECKOUT/$SELF_REL" "$@"`. The guard makes it
happen exactly once, and by then the fast-forward is a no-op so the second pass
does all the installing with the complete target list. The dry run cannot hand
over, so it says the script itself changes in that revision and the file list
may grow. The rehearsal asserts the replacement really ran (a marker only the
new copy prints), that the handover happens exactly once, and that a dry run
runs nothing.

Git does not commit an empty directory, so a fixture that needs the checkout to
contain the script must put it in the FIRST commit; `mkdir -p` alone left
nothing to compare against and the dry-run assertion silently had no subject.

**"Nothing to classify" is not "unknown", and the distinction turned the best
possible state into an alert.** Production, 2026-10-20: coverage reported
`23155 of 23155, gap 0, pending 0, unknown 0` -- complete -- and `checkup` said
*"recorded but NOT classified"* and demanded a reconciliation of a fully
reconciled library. The classification block was guarded on `n_missing > 0`, so
with nothing missing `class_known` stayed 0 and the evidence recorded
`missing_classified: unknown`. **That would have been the first notification
this host ever sent, and it would have been wrong** -- precisely the false alarm
the four classes exist to prevent.

Fixed at both ends, deliberately: the writer sets `class_known=1` when nothing
is missing, and the reader checks the COUNT before the classification, so
evidence already on disk from before this was understood also reads as healthy.
A mutation removes the count check and requires the false alarm to return.

**Installing a unit is not enabling it, and the deployment does only the
first.** The weekly unit carries the `health-notify` step, so installing the
file is what makes the notification AVAILABLE; enabling the timer is what starts
sending mail. The deployment installs it 0644, runs `daemon-reload`, says "not
enabled, not started", and prints the `systemctl enable --now` line for the
operator. The rehearsal asserts the reload HAPPENED (via a recording stub) and
that no `enable`/`start`/`restart` was ever issued -- in the script's own text
and in the calls it made.

**A sandbox may PROVIDE an external dependency; it may not weaken the check.**
systemd is unreachable inside `unshare -r`, so a real `daemon-reload` fails and
the deployment aborts -- correctly, because a failed reload means systemd has
not seen the new unit. The rehearsal supplies a recording `systemctl` stub on
`PATH`, exactly as it supplies a fake git upstream, and then asserts the call.
Making the reload non-fatal to suit the test would have been the wrong fix.

**A dry run must not speak in the indicative.** The deployment's dry run
printed `fast-forward: 6551bd48 -> 3bb4e79c` before its own `--confirm` gate,
which reads as though the checkout had already moved. It had not -- verified
afterwards, the checkout was still at `6551bd4` and both installed binaries were
untouched -- but the operator had to be told that, which is exactly backwards.
It now says `WOULD fast-forward: … (not done yet)` unless `--confirm` was given,
and the rehearsal asserts BOTH tenses: the dry run must not print the plain
form, and a confirmed run must not hedge. A report that implies a mutation it
did not make is the defect this repository keeps correcting, and a deployment
script is the worst place to have it.

**`--json` prints the machine-readable line and THEN the human report, so the
JSON is the FIRST line beginning with `{`.** The deployment script first took
`| tail -n 1`, which returns a line of prose; the rehearsal caught it with a
`jq` parse error. Extract it from a captured variable with
`sed -n '/^{/{p;q;}'` -- no pipe, so nothing can short-circuit.

**Rehearsing found what reviewing would not.** Two defects in one sitting: the
JSON extraction above, and a FIXTURE whose checkout history diverged from its
upstream -- the script refused, correctly, and the fixture was wrong. A wrapper
that has only been read has not been tested.

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

**Plex's running image WAS `identity,local` with both lists empty.** Measured
2026-10-06: `RepoTags: []` **and** `RepoDigests: []` — dangling, because a newer
`:latest` had been pulled and moved the tag. It survived solely because a running
container referenced it, so the old image was prunable and the recovery point's
application half was fragile exactly when it would start to matter.

**Re-measured 2026-10-28, after the Plex upgrade: it is no longer dangling, and
that is NOT the same as being recoverable.** Plex now runs
`7f9a1d574958` carrying `lscr.io/linuxserver/plex:latest`, and the tag still
resolves to the running image, so no prune would remove it and no newer Plex
image is staged. But its `RepoDigest` **equals its image Id** —
`sha256:7f9a1d574958…` for both — and this file already records that such a
RepoDigest is not an independent registry reference. Measured, the equality
holds for **all five** tagged services (plex, calibre-web, jellyfin, kavita,
navidrome), so it is how docker reports images on this host rather than anything
about Plex.

So the honest statement is narrower than "dangling" and narrower than
"recoverable": the local object is no longer prune-exposed, and registry
availability is still unproven. **The `docker save` archive remains the only
proven copy**, and the version is still recoverable only as a label
(`1.43.2.10687-563d026ea-ls308`), which is compatibility information, not a
retrievable reference. Reading a present RepoTag plus a present RepoDigest as
"now recoverable" is the optimistic direction this file exists to prevent, and
it was the first conclusion drawn before the two hashes were compared.

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

**JELLYFIN AND KAVITA ARE BOTH IN WAL MODE, and they are the two services
with no sqlite3 anywhere.** Measured 2026-11-02 from the SQLite file header
(bytes 18/19, a pure read -- no open, no lock, no privilege):

```
jellyfin/config/data/data/jellyfin.db   write=2 read=2  -> WAL
kavita/config/kavita.db                 write=2 read=2  -> WAL
navidrome/navidrome.db                  write=2 read=2  -> WAL
calibre-web/config/app.db               write=1 read=1  -> rollback journal
```

No `-wal` or `-shm` file exists for either right now, which is why an earlier
measurement read them as not-WAL: in WAL mode those files are removed when the
last connection closes, while `journal_mode` persists in the header. **Absence
of a `-wal` is not evidence of a non-WAL database.**

A read-only open of both fails with `attempt to write a readonly database` --
the classic WAL symptom, because SQLite must create the `-shm`. So the host's
python3 sqlite3 (3.46.1, with the `.backup()` online-backup API available)
cannot currently be used to give them a consistent capture either.

The consequence is sharper than the capture mode first suggested: their
`file-copy-unproven` captures are copies of **WAL-mode** databases taken while
the service may be writing, which is torn rather than merely crash-consistent.
`CAPTURE_MODE=unproven` is therefore the correct and honest word, and closing
it needs either a quiesce (stop, copy, start under the operation lock) or a
writable `-shm`, not a cleverer read.

**AN ARCHIVE CAN STATE ITS OWN IDENTITY WITHOUT BEING LOADED, and
`verify-archive` was admitting it could not.** It proved the FILE was intact
and said so honestly -- *"that is not the same as the identity it restores:
`docker load` is what proves the image id, and loading is a mutation, so it is
not done here."* True, and it left the one claim that matters unproven: the
`docker save` archive is the only PROVEN copy of the application half of every
recovery point on this host.

Measured 2026-11-02, this host (containerd image store, overlayfs), by saving
a real image to a disposable file:

```
docker image inspect -f '{{.Id}}' busybox:latest
  sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
index.json  manifests[0].digest
  sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e   <- EQUAL
blobs/sha256/fd7dc98638c8...  9,535 bytes, sha256 of its own bytes
  fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e          <- EQUAL
```

So the proof is content-addressing: **a blob inside the archive whose digest
equals the recorded image id**. `domum_archive_identity` is that one test, and
it is store-independent -- under the classic image store the Id is the CONFIG
blob's digest, written as `<hex>.json` at the archive root, and the same test
finds it there. This does NOT contradict the existing rule that the archive's
config-blob digest does not equal the image Id here; it is why the test looks
for the object NAMED by the id rather than assuming which object that is.

Four verdicts, and three of them are not a pass: `verified`, `corrupt` (the
object is present under that digest but no longer hashes to it, so the archive
would not restore that image), `absent` (the archive holds a DIFFERENT image --
the pairing failure), and `undetermined` (unreadable, unrecognised, or no
recorded id). The mutation that treats an unreadable archive as verified must
make a missing file read as proven.

**Identity and the file checksum are different claims and neither subsumes the
other.** Corrupting a LAYER blob leaves the manifest blob intact, so identity
still verifies while the recorded sha256 of the file does not. Both are
reported. And the report still states what remains unproven: containing the
right image is not evidence that the application STARTS.

**`tar` matches member names literally and fails when ANY listed member is
absent.** `docker save` writes `blobs/sha256/x`; a tar created with
`tar -cf out .` writes `./blobs/sha256/x`, so the first synthetic fixture read
as `undetermined` against correct code. And `tar -tf a.tar -- index.json
./index.json` exits non-zero because one of the two is missing, which turned a
present-metadata test into a negative. Each spelling is asked for on its own.
`--occurrence=1` stops tar at the member instead of reading to the end of a
250 MB archive.

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

**An estimate of remaining work must model the mechanism, not divide the
bytes.** `verify-large` reported `13 file(s), 6.5 GiB -- about 7 more run(s) at
the 1.0 GiB per-run budget`, which was `ceil(bytes/budget)`. Measured in
production 2026-10-12, the very next run fetched **2 files and 614.5 MiB -- 60%
of the budget** -- because a run is capped **twice**, by `LARGE_DEFAULT_COUNT`
(2 files) and by `LARGE_MAX_RUN_BYTES` (1 GiB), and it cannot split a file. The
division modelled neither cap: the binding one here was the file count. The
estimate is now a SIMULATION of the real packing over `large_select`'s own
order, and it says what binds. For the measured remaining set it gives 7 where
the division gave 6; where the files are smaller it is twice out -- eleven
280 MB files are 6 runs, not 3. The report also still calls it an estimate,
because `large_select` re-orders as files become proven.

**"Over the budget" was false of the file.** Production, 2026-10-14: a 919.5
MiB original was reported as `over the 1.0 GiB per-run budget`. It is
comfortably under it -- it did not fit ALONGSIDE the 579.0 MiB file already
selected. A file genuinely larger than the whole budget is always taken as a
run's first file so the command cannot deadlock, which means it can never reach
that line: the message described a case that cannot occur while misdescribing
the one that did. The deferral is now attributed to the run's remaining room.

**Verify which cap binds before reasoning about throughput.** I first explained
the 614.5 MiB run as the byte budget failing to pack, and the fix I wrote
simulated only the budget. It was the file count. A per-run limit that is not
the one named in the message is exactly how a plausible wrong estimate survives.
`tests/large-verification-smoke.sh` drives both caps and mutates the count cap
away; without it the same set reports 4 runs instead of 6.

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

**The report named the wrong backup scope, and the operator caught it from
another machine.** Production, 2026-10-20: `dr-status` printed
`included /srv/data` and `image archives 2 in /srv/data/backups/images (in the
backup set)`. The operator listed the Hetzner snapshot from their Mac and saw
**three** roots:

    /srv/data/immich/library
    /srv/data/immich/backup-staging
    /var/lib/domum-media/recovery-pack

Both are "right": the cloud target is **immich-only by design** -- the comment
on `immich_only_include_paths` says it exists so `/srv/media` is never swept
off-site -- while `dr_backup_scope` and `dr_path_configured` read the GLOBAL
`BACKUP_INCLUDE_PATHS`, which defaults to `/srv/data`. So every coverage
question was answered against a path set that target never uses, and
`/srv/data/backups/images` looked covered merely because it sits under
`/srv/data`.

Measured with the shipped resolver against the real paths:

| artefact | cloud target |
|---|---|
| Immich library | PRESENT (23,155/23,155 observed) |
| Immich PostgreSQL dump (`immich/backup-staging`) | PRESENT |
| Encrypted recovery pack | PRESENT -- config, secrets, repo metadata, Traefik `acme.json`, validated Uptime Kuma dump |
| **exact-image archives** (`/srv/data/backups/images`) | **NOT COVERED** |
| **jellyfin / plex / navidrome / calibre-web / kavita state** | **NOT COVERED** |

The archives matter most: a recovery point is service + snapshot + the
application that wrote it, and Plex's image is `identity,local` -- dangling,
with no registry copy. So the snapshot half survives in Hetzner and the
application half would not. That is now a named risk that states the
consequence and offers the decision, rather than a line claiming coverage.

`dr_target_roots` is the one implementation, and every caller passes its
target. A coverage question with no target is answerable only against the
global default, which is what produced the false claim.

**The recovery pack's own path was hardcoded in the backup scope.**
`immich_only_include_paths` contained the literal
`/var/lib/domum-media/recovery-pack`, while the pack is written to
`${RECOVERY_PACK_DEST:-$DOMUM_STATE_ROOT/recovery-pack}`. They are equal on this
host **by accident**. Move the state root or set `RECOVERY_PACK_DEST` and the
backup would include a path that does not exist while the pack -- holding the
config, the secrets, Traefik's ACME private key and Uptime Kuma's database --
silently stopped being backed up, with the run still reporting success. The path
is derived now; verified that the production scope is byte-identical and that it
follows a moved state root.

**Two tests were asserting the old, global-scoped behaviour.** One unset
`BACKUP_INCLUDE_PATHS` and required UNKNOWN -- but the cloud target has its own
built-in scope, so reporting UNKNOWN would itself be false; the third state is
now exercised where it is real, by making the target's roots unresolvable. The
other set the global to include the media root and required the
reacquirable-tier finding to fire, against a path the target never reads. Both
now establish scope the way the code resolves it. Before adapting a test to a
change, ask which of the two is wrong -- here the behaviour was right and both
fixtures were addressing a variable that had stopped mattering.

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

**Two numbers in one report that must agree are ONE number, computed once.**
The first production `dr-status` run printed `23021 never restore-tested` in the
originals row and `23019` in the summary four lines below, because only the
summary knew about the two large originals `verify-large` had just proved. Both
now read `dr_large_proven_count`, and the test asserts the two figures are equal
and mutates the shared count away to prove the assertion bites.

**Read positional fields by INDEX, never by "the last one".** `dr_sample_proof`
returned `sampled population unsampled` and its caller took the remainder with
`${proof##* }`. Appending a fourth field silently redefined that expression, and
the row claimed `0 never restore-tested` for a library with 22,964 untested
originals. A trailing-field expression is a dependency on arity that nothing
declares.

**Every recorded claim cites the snapshot it is ABOUT.** In production the
archive check was two days older than the import -- `476f8797` versus
`05a6adb0` -- and the line showed neither snapshot, so two claims about
different objects read as one. A proof of an earlier snapshot is still a proof
and keeps its level, but it is now marked `[not the current snapshot]`.

**A recorded denominator and the live one are different questions.** The tier
row quotes the population recorded when the sample ran; the summary counts the
library now. They diverge as photos are added, so a `population drift` line
states both rather than leaving two numbers that look like they should match.

**A deterministic sample proves the pipeline, not the library, and must
ACCUMULATE.** Selection is deterministic so a run is reproducible -- and the
measured consequence was that the 2026-10-09 and 2026-10-11 production runs
sampled the **same 12 files**, holding coverage at 12 of 23,033 however often
the command ran. `verify-sample` now skips already-proven originals and keeps a
durable 0600 history, as `verify-large` does; `--revalidate` is the only way to
re-prove. `dr-status` reports the CUMULATIVE count, because reporting the
per-run figure would have hidden the cap. Stated honestly: 23,016 originals are
reachable by sampling, and sampling will never prove the whole library --
`FULL RECOVERY VERIFIED` needs a disposable Immich serving a full restore
instead.

Quote the figure for the cap that BINDS. This rule used to say "even at the
1 GiB per-run cap full coverage is ~130 runs and ~130 GiB", which is the
estimate for a configuration nobody runs: `SAMPLE_DEFAULT_COUNT` is **12**, and
a default run transfers ~260 MB, so the COUNT binds and full coverage is
**~1,900 runs**, not ~130. The ~130 figure needs the count raised to ~190 so
the byte budget binds. `docs/DISASTER-RECOVERY-STATUS.md` states both rates and
always did; only this summary quoted the favourable one -- the same mistake as
the `verify-large` estimate, made in prose instead of in code.

Measured 2026-10-15, and a reminder that the sample is NOT random: the
selection deliberately includes the largest original under the per-file cap,
which is 249.1 MiB, so one such file dominates a 12-file run. Dividing the mean
size (5.46 MiB) by the budget gives ~65 MB per run and is wrong for this
selection.

**Four claims about an original, none of which implies another.**
`LOCAL` (the file the asset table names exists here) < `IN SNAPSHOT` (that path
is in a real off-site snapshot) < `RESTORE TESTED` (restored and compared
byte-wise) < `APP USABLE` (a recovered Immich served it). `dr-status` reported
`backed up (in the backup set): all 23033`, which was claim 2 **inferred from
configuration** -- the library is under the backup root and no exclusion
matches it. That is an argument, not an observation, and it had never been
checked for a single file. `verify-snapshot-coverage` reconciles every
`originalPath` against a snapshot's own file list; `restic ls` reads tree
metadata and downloads **no file content**, so claim 2 costs almost nothing and
must never be confused with the ~130 GiB restore that claim 4 needs. The report
now prints the configuration claim and the observed claim on separate lines and
says `NOT CHECKED` until a reconciliation has happened.

**A recorded proof is about the BYTES that were there when it was taken.** If a
verified file is later replaced or truncated the proof says nothing about the
new content, so the path drops out of the proven set, is reported rather than
silently reducing a number the operator saw last week, and becomes selectable
again. A vanished path is not proven either. Size is the discriminator and the
limit is stated rather than overclaimed: it catches replacement and truncation,
not a same-size edit. Re-hashing 6.5 GiB of home videos on every run to detect
a change that has never happened would cost more than the verification it
guards.

**Commands that answer the same question must read the same evidence.**
`domum-media report` read only the per-run sample manifest while `dr-status`
read the cumulative histories, so once `verify-sample` began skipping
already-proven originals the two would have drifted apart with every run -- the
report frozen at "12 of 23033" while dr-status counted upward. Both now read
the sample history, the large-file history and the snapshot-coverage proof.
This is the "two numbers that must agree are one number" rule at system level,
and it is the real risk in having several commands, not duplication.

**A measurement pipeline that can silently drop a record is not a
measurement.** Piping one `docker exec` into another lost a line: I counted 16
over-cap originals totalling 7.56 GiB and briefly suspected a large original
had vanished. Re-measuring via a file with an explicit in/out tally gave 17
files, 7.90 GiB, 23,033 counted, 0 missing. The shipped
`immich_original_inventory` already compares `want` against `got`, which is why
only the throwaway pipeline was wrong -- write to a file and count both ends.

**Assert that a mutation actually applied.** A mutation test "failed" against
an unmutated binary: expressing the target line through two layers of script
needed enough escaping to produce a SyntaxError, so the edit silently did
nothing. Write the mutation script to a FILE with a quoted heredoc and assert
its effect before relying on it. In the same section a second assertion was
checking for a notice emitted by a different, unmutated function -- so it was
testing the wrong thing. Name the observable the mutation actually changes.

**Immich OPENS the recovered database — proven, not argued.** Rehearsed
2026-10-11 by `immich-phase-a`: a fresh Immich of the production image
(pinned by ID) started against the restored dump and logged
`Running migrations` → `Finished running migrations` → `Checking for schema
drift` → `No schema drift detected`, then authenticated a recovered user and
reported asset counts matching the database per media type. Record counts were
identical before and after startup, so migrations altered nothing recovered.
The claim is `APPLICATION STARTUP VERIFIED` and is deliberately narrow: no
original was restored, so nothing shows the library can be SERVED. Never let it
promote a tier to `FULL RECOVERY VERIFIED`.

Three facts that rehearsal established, each of which would otherwise have been
discovered during a real recovery:

- **Recovery depends on a DEPRECATED extension.** Immich itself warns that
  `pgvecto.rs` support "will be removed very soon" in favour of VectorChord.
  Once Immich drops it, today's dump will no longer import into a current
  Immich. The window in which an old backup restores into a contemporary
  application is narrowing, and that is a recovery risk independent of whether
  production is ever upgraded.
- **Immich requires its library SCAFFOLD, not just the database.** With an empty
  upload directory the microservices worker dies on
  `Failed to read "<UPLOAD_LOCATION>/encoded-video/.immich"` after reporting
  mountChecks for all six subtrees. Those `.immich` files are Immich's own
  13-byte integrity markers and are real backed-up files, so Phase A RESTORES
  all six from the snapshot (78 bytes). Nothing is fabricated to make the
  application look healthy.
- **7,428 of the 23,033 originals are HIDDEN motion-photo components.**
  13,893 timeline images + 1,712 timeline videos + 7,428 hidden videos. The API
  reports only the 15,605 timeline-visible assets and matches the database
  exactly per media type, so a check comparing the API total against every row
  FAILS on a perfectly healthy recovery -- which the first version of that
  comparison did. The hidden ones are the video halves of live photos:
  irreplaceable, backed up, never shown in a timeline.

**A rehearsal's isolation is structural or it is nothing.** Phase A uses an
**internal** docker network -- measured: container-to-container DNS works and
`curl https://…` returns 000 -- which is the only honest way to guarantee no
mail, integration or telemetry escapes, because that configuration lives in the
restored database and may well be populated. It pins images by **ID** read from
the running containers, never the mutable `:release` tag; uses tmpfs PGDATA; and
mounts **no** production path, read-only or otherwise. Names are unique and
refused if taken, and the teardown is asserted rather than assumed.

**Pass only the environment variables production passes.** The first Phase A
rehearsal added `IMMICH_TELEMETRY_INCLUDE=none` and Immich refused to boot with
`Error: Invalid telemetry found: none`. An unknown variable is ignored; a known
one with a wrong value is fatal. Isolation comes from the network, so there is
nothing to gain by guessing at feature switches.

**"Never restore-tested" is a claim about the library NOW, and it was computed
against the recorded denominator.** Production, 2026-10-12: after 69 photos were
added, the tier row said `23013 never restore-tested` and the summary four
sections below said `23082`. Both were derived from the same proven count (20);
the row subtracted it from the population RECORDED when the sample ran (23033)
and the summary from the LIVE library (23102). The row's figure silently
treated 69 brand-new originals as tested -- the weaker claim in the stronger
claim's words. One `dr_never_restore_tested` now answers it, against the live
count, and the proof's own FRACTION keeps the recorded population with both
labelled. This is the second instance of this exact rule in this function; the
first is recorded in `dr_sample_proof`'s comment.

**A test that establishes the precondition for agreement cannot detect
disagreement.** The suite already had a section called "the tier row and the
summary report the SAME untested count", and it passed throughout. Its own
comment explained why it could not work: *"the fixture must make them the same
population for the two untested figures to be comparable at all"* -- it set
recorded == live, the one case where the two cannot differ. A sibling section
then asserted `22964 never restore-tested` with a recorded population of 22976
and a live library of 20, i.e. it REQUIRED the defect. Both now drive the grown
library, which is the only configuration in which the invariant has content.

**One read of the asset table per report, passed as an argument -- never
memoised in a global.** Every call site in `dr-status` is a command
substitution, so a global assigned inside `$( )` is set in the subshell and the
parent never sees it. The first version of this fix cached the inventory that
way and the path came back EMPTY: the summary reported `20, 0 B` with no
location breakdown, because `sample_coverage_stats ""` happily returns zeros.
Two reads would also be two observations, and the whole defect here was two
denominators wearing one label.

**The risk block is what the operator acts on, so a drift note is not a risk.**
The summary printed `[the library has 23102 originals now vs 23033 when
reconciled]` -- honest, unactionable, and the REMAINING RISKS block said
nothing, so 69 originals that had never been observed in ANY snapshot were
invisible where it mattered. `dr_remaining_risks` now names them, says they are
the newest photos, names `verify-snapshot-coverage` and says it downloads
nothing -- a remedy that reads as expensive does not get run.
**A safety report lost its own verdict exactly when the news was bad.**
Production, 2026-10-12: `verify-snapshot-coverage` listed 20 missing originals
and then stopped -- no `... and 49 more`, no `result : INCOMPLETE`, and it
exited **141**. The cause was `sed … "$missing" | head -20 | sed …`: `head`
closes its input after 20 lines, the first `sed` took SIGPIPE, the pipeline
reported 141, and under `set -euo pipefail` the function DIED there. With 20 or
fewer missing, `head` reads everything and nothing fails -- so the defect
appeared only when the list was long, i.e. only when there was something to
report. Reproduced against the real function before fixing. Slice with
`sed -n '1,20{…;p}'`, which has no pipe.

`tests/pipefail-grep-audit.py` now covers every consumer that STOPS EARLY:
`grep -q`/`-m`, `sed Nq`, and `head` with no count, a count that is not 1, or a
variable count -- six more sites, including two `diff | head -20` on migration
mismatch paths. `| head -1` after a `sed -nE 's/^KEY=…/p'` is deliberately NOT
flagged (about sixty of those): the producer emits at most a line or two, and an
audit that cries wolf is one somebody switches off. That scope is stated in the
audit rather than left implicit.

**A test that relaxes production's shell options is not a test of production.**
`snapshot-coverage-smoke`'s harness ran with `set +e`, so the abort could not
occur there however long the list was. Driving it needs its own bash process:
`( f ) || rc=$?` does not work, because bash suppresses errexit inside a
function invoked as part of a `&&`/`||` list -- which is exactly the condition
being tested.

**A broken pipe does not have one exit status, so do not assert on the
number.** The mutation above exits **141** here (SIGPIPE kills `sed`) and **4**
on the CI runner (GNU sed's "I/O error", because an ancestor ignores SIGPIPE so
the write returns `EPIPE` instead of killing it) -- same mutant, same fixture.
Pinning 141 made the assertion pass locally and fail in CI. The observable is
that the verdict is LOST and the status is neither of the meaningful ones.

**Size a SIGPIPE fixture deliberately.** The mutation that restores `| head -20`
survives at 69 paths, because 69 short lines fit the 64 KiB pipe buffer and the
writer finishes before `head` exits. It only dies reliably at ~3,000 paths. The
intermittency is the hazard, so the fixture has to exceed the buffer or the
mutation proves nothing.

**"Missing from the snapshot" conflated two different facts.** 69 originals were
reported as "NOT protected off-site" with no further distinction. They were the
69 photos uploaded at 20:05 -- a 02:42 snapshot cannot contain them. So the line
would fire every day anything was added, while a genuinely dropped original
would look identical. It is now split: `added AFTER the snapshot` (expected,
exit **3**, `PENDING`, and still stated as unprotected right now) against
`present BEFORE the snapshot` (a real gap, exit 1, `INCOMPLETE`). A split that
cannot be computed says so and is never promoted to `PENDING`.

**Recency of an Immich original comes from the asset table, never from mtime.**
Measured: 69 assets had `createdAt` after the snapshot while only **27** files
under `upload/` had a newer mtime -- an uploaded photo keeps a date from the file
it came from. I reasoned from mtime first and was one step from reporting "42
originals predate the backup and are genuinely missing", a false alarm about
family photos, from the exact inference this file already forbids. The asset
table settled it: exactly 69, created 20:05-20:06.

**The snapshot comparison was built by `stat`, so it only covered originals
present on disk.** `cut -f2 "$inv"` takes the inventory, which
`immich_original_inventory` builds with `stat` -- a path the table names but
which is absent never enters it. A fixture that created no files reported
`IN the snapshot: 3000 of 3000`: full coverage, having compared nothing. This is
the same hole already recorded for the exclusion audit, in a second command. The
comparison now uses the table's PATHS, and an empty left-hand side returns
UNKNOWN instead of a clean sweep.

**The full missing list is durable evidence.** It existed only as 20 truncated
terminal lines, so a finding could not be diagnosed without re-running the
command. It is written to `<target>-snapshot-missing.txt` at 0600 and the report
names it.
**A recovered Immich SERVES recovered originals — proven 2026-10-12.**
`immich-phase-b` restored 8 originals from the snapshot and the application
returned all 8 with **bytes identical** to the restored files: jpeg, heic, png,
raw, an ordinary video, a larger video, and a live-photo image together with its
hidden motion-photo video. 41.0 MiB transferred, no leftovers, production
untouched. The claim is `REPRESENTATIVE RECOVERY VERIFIED (8 of 23033)` and it
states its own denominator, because 23,025 originals were never served and only
one user was tested.

Rules that came out of it:

- **`/original` may be hash-compared; `/thumbnail` may not.** The first returns
  the stored file, the second a GENERATED preview. The report fetches the
  thumbnail to show the application works and never claims its bytes match an
  original. No thumbnail came back at all, because derivatives were not
  restored -- reported as explicitly not a failure, and useful evidence for the
  exclusion question: serving originals did not need the derivatives.
- **Immich enforces per-user ownership, and ignoring that looks like a bug.**
  The first rehearsal selected a PNG owned by the non-admin user while
  authenticating as the admin; Immich returned nothing and it read as
  a failed fetch, i.e. a serving defect. It was correct authorization.
  Selection is scoped to the authenticated user's `ownerId`.
- **A multi-user library needs per-user verification.** Measured: 17,084 assets
  owned by the admin, 5,949 by the other user. Proving one user's assets serve
  says nothing about the other's, so the ownership scope and the untested count
  are printed.
- **The live-photo relationship is NOT 1:1.** Measured: 7,432 images carry a
  `livePhotoVideoId` pointing at 7,428 distinct hidden videos, so four videos
  are each shared by two images. Follow the column; never derive the pair.
- **`WARN` and `ERROR` on a captured function's stdout are reserved, because
  that stdout IS the return value.** The Phase B verdict shipped as
  `ERROR no-response` and `tests/captured-stdout-purity-smoke.sh` rejected it in
  CI -- correctly: the audit exists because `create_service_snapshot` once
  logged a progress line into its own return value, and it cannot tell a verdict
  word from contamination when the two share a vocabulary. The prefix also said
  nothing `no-response` did not. Verdicts are drawn from this file's own
  vocabulary -- `match` / `MISMATCH` / `NO-RESPONSE` / `NO-LOCAL-FILE` -- and the
  log words stay on stderr. Do not widen the audit's `LOGLIKE` pattern to admit
  a new caller.
- **`ORDER BY`/`LIMIT` inside a `UNION` branch must be parenthesised**, or
  PostgreSQL applies them to the whole union and the statement is a syntax
  error. It was, and the tool reported only "no representative asset could be
  selected" because it sent stderr to /dev/null -- an unactionable FAIL. The
  database's own error is now printed.

**Off-host recovery is viable: measured 2026-10-12.** The audit, run as root,
found all four repository credentials present, 37 encrypted recovery packs with
the newest 0 days old, **off-host delivery ENABLED by email**, the pack
correctly NOT inside the backup it would be needed to open, and all three
application images obtainable from their registries. Verdict `UNPROVEN` rather
than clean, because two items cannot be established from the host whose loss is
assumed: the age PRIVATE key is held by the operator, and pgvecto.rs is
deprecated so the set of Immich versions able to import today's dump shrinks
over time. The whole chain rests on that age key -- 37 copies are equally
useless without it.

**A stale coverage proof was reported in the present tense.** Production,
2026-10-14: the reconciliation had been taken on `b18ea965`, and two backup
runs later -- `8aae9af2` was current -- `dr-status` still said *"69 original(s)
are NOT in the snapshot that was reconciled. They exist locally but are not
protected off-site."* By then those 69 had almost certainly been collected by
the intervening runs. The summary's `[reconciled against an earlier snapshot]`
note did not say WHICH, that another had run since, or that the missing count
was therefore not about now. A proof is about the snapshot it was taken on, and
repeating its count in the present tense outlives its own evidence. When the
proof's snapshot is not the latest successful run the risk now says the
reconciliation is STALE, names both snapshots, states that the present position
is UNKNOWN, and points at the free remedy; when it IS the current snapshot the
plain "not protected off-site" claim stands. The distinction is tested in both
directions, because a softer wording that never asserts anything is not an
improvement.

**`[[ … && false ]]` is TRUE: inside `[[ ]]` the bare word `false` is a
non-empty STRING, not the command.** Measured. A mutation written that way
applied textually, passed its own `grep` check, and changed nothing -- so the
mutant still behaved correctly and the test "failed" against code that was
right, which cost a long hunt through the wrong half of the problem.
`[[ … ]] && false` does work, because there `false` is a command, and so does
`if false; then`. Prefer mutating the comparison itself into something that
cannot hold -- `"$a" != "$a"` -- which has no such ambiguity. "Assert that a
mutation actually applied" is not enough; assert that it changed the ANSWER.

**"Missing from the snapshot" was one word for four different situations.**
Production, 2026-10-15: five HEIC originals were reported absent from snapshot
`d0829433` with the words *"NOT protected off-site"* and `INCOMPLETE`. They were
uploaded at **11:09:50 that morning**, 8h37m after the backup finished. A 02:32
snapshot cannot contain photos ingested at 11:09, so that report fires every day
anything is added -- and a genuinely skipped photo reads identically. Missing
originals are now classified against the backup **WINDOW**:

| class | meaning | verdict |
|---|---|---|
| `BACKUP GAP` | ingested at or before the window OPENED | exit 1, escalated, path list written |
| `PENDING` | ingested at or after the window CLOSED | exit 3, stated, not a defect |
| `UNKNOWN` | ingested DURING the window, or no window | exit 2, neither excused nor blamed |
| covered | not missing | exit 0 |

**A snapshot is not an instant.** restic records when the run STARTED; the run
record holds when it FINISHED. A file ingested between the two may or may not
have been walked, so it is `UNKNOWN` -- calling it pending would quietly excuse
a real miss. The window's end is only accepted from a success record whose
`SNAPSHOT_ID` matches the snapshot being checked; a record for a different
snapshot says nothing about this one.

**Only `createdAt` answers "did this exist when the backup ran", and the
production case proved why.** For those five files, measured:

```
createdAt         2026-10-15 11:09:50      (ingestion -- the truth)
fileCreatedAt     2026-10-14 16:11-16:17   (capture, the day before)
fileModifiedAt    2026-10-14 16:56 for TWO of them -- BEFORE the backup
filesystem birth  2026-10-15 11:09:50.02-.68  (agrees with createdAt)
```

Capture time would have called all five a gap; `fileModifiedAt` would have
called two of them a gap. The filesystem **birth** time agrees with `createdAt`
and is the independent confirmation. This is the third appearance of the mtime
trap in this file -- never use mtime, `fileModifiedAt`, or capture time for
timing.

**A classification key read but never written must read as "not classified".**
Evidence recorded before this existed has no `missing_backup_gap` key, and
`jq -r '.missing_backup_gap // empty'` returns empty -- which must not become
`0`, or an unexamined finding would present as a clean one. `missing_classified`
is defaulted to `unknown` in the accessor, and the test drives evidence with the
keys absent.

**A routine upload is stated but NOT numbered as a risk.** The pending line is
printed with the count and the fact that those originals exist only on this host
-- but it is not listed among the numbered risks, because a report that flags
normal operation every day is one the operator stops reading. A gap and an
unknown are numbered risks; a pending upload is not.

**`&&` between an operator's commands means the second never runs on a
non-zero verdict.** `verify-snapshot-coverage cloud && dr-status` is correct
failure propagation -- and because the coverage command deliberately exits
non-zero for any missing original, `dr-status` did not run. That is the chain
working, not a defect, but a command pair offered to the operator should say
which part is conditional.

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

  **The rule was written down and then not enforced: ten more instances were
  sitting in the tree.** `tests/pipefail-grep-audit.py` now fails on the shape,
  in both CLIs, `install.sh` and `operator/*.sh`. The direction of failure
  differed at every site, which is why none of them looked alike:

  - `phasea_name_free` -- the guard that keeps the disposable Immich harness
    away from PRODUCTION containers. A name that **does** exist would read as
    free;
  - the config render check -- an unresolved `${PLACEHOLDER}` would be written
    to a live config instead of refused;
  - the `cleanup images` warning "THE OLD IMAGE IS A DELETION CANDIDATE" would
    be silently skipped, which is the protection the recovery point rests on;
  - **three copies** of the managed-service gate -- `die` on a **valid**
    service name, aborting a correct upgrade or rollback. Now one
    `is_managed_service`;
  - the PostgreSQL dump footer check, twice -- a **valid** dump rejected, so the
    backup fails on good input;
  - the operator wrapper's post-migration check -- abort a migration that had
    completed perfectly, which is the failure that wrapper has already caused
    three times in other forms.

  Two of the ten were invisible to a line-at-a-time search because the pipeline
  was **split across lines**, so the audit joins continuations; and `||` must
  not read as a pipe, or the audit flags the very fix it prescribes. Both are
  mutation-tested, because the leading-pipe shape is caught either way and
  asserting the mutation against it would have passed vacuously.

  **The audit did not scan `tests/`, and the suites carried the banned shape 32
  times across 15 files.** Measured 2026-10-28. That was a blind spot in exactly
  the place where the failure mode is worst: an **assertion silently stops
  asserting**, and a suite that cannot fail is indistinguishable from one that
  passes. It was not theoretical -- `backup-target-evidence-smoke` had
  `awk … | grep -q 'die "Backup failed for target'`, which passed for months and
  began failing the moment an unrelated 40-line insertion pushed awk's output
  past the pipe buffer. All 32 are now addressed and `tests/*.sh` is in scope.

  **A QUOTED heredoc body is DATA and is not scanned; an UNQUOTED one still
  is.** Nothing in `<<'EOF'` expands or executes, and the banned shape lives
  there legitimately: a suite reproducing the historical operator wrapper it
  must reject, the fixtures this audit feeds itself, a mutation string restoring
  `| head -20`. Demanding those be "fixed" would make a test stop describing the
  defect it exists to catch. In an unquoted heredoc `$( )` IS command
  substitution -- a defect family this file already records -- so those are
  still scanned. The limitation is stated rather than hidden: a quoted heredoc
  body that is written out and then EXECUTED is code the audit sees as data, and
  it was verified that no production file does that.

  **The remaining three sites are string literals, exempted by an explicit
  `# pipefail-audit: <reason>` marker, and every exemption is PRINTED.** An
  allowance nobody can see is how a real defect gets a marker stuck on it. The
  marker is read before comments are stripped, exempts only its own line, and
  cannot be put inside a heredoc -- adding a comment there would change the
  fixture.

  **The vacuity guard counts the suites with `os.listdir`, deliberately NOT the
  `glob` that built the target list.** Re-asking the same glob could not detect
  that glob breaking: it would report zero expected and zero scanned and call
  that agreement. An EMPTY `tests/` directory expects zero and is not a failure
  -- requiring suites unconditionally rejected every one of the audit's own
  single-file fixtures, including the one asserting that the capture-first fix
  is ACCEPTED.

  **Diagnostics are the same shape.** Three `| head -N >&2` lines printed hits
  before a `fail`. These suites run without errexit so a 141 could not abort
  them, but the shape is identical; they slice a captured variable with
  `sed -n '1,Np' <<< "$x"`, which has no pipe -- the same fix as the lost
  `INCOMPLETE` verdict.

  **A text-grep test cannot tell a fix from a regression.**
  `service-upgrade-smoke` section 2 asserted that `service_upgrade` contained
  the literal pipeline `managed_image_specs | cut … | grep -qxF "$service"` --
  so replacing it with the fix *failed the suite*. It now EXECUTES the checker:
  5 valid names must be accepted (a check that refuses valid input is the
  aborted-deployment family) and 7 invalid ones rejected, substring, case,
  trailing-space and empty among them.
- **Never `--delete-branch` a PR that another PR is based on.** GitHub CLOSES a
  pull request whose base branch is deleted, and a closed PR cannot be reopened
  once that base is gone -- `gh pr reopen` fails with "Could not open the pull
  request". Merging #108 with `--delete-branch` closed the stacked #113 that way.
  Nothing was lost (the branch and its commits survived), but recovering it
  meant replaying the commits onto the squashed `main` and opening a new PR.
  Merge the base WITHOUT deleting, retarget the child to `main`, land it, then
  delete.
- **A squash merge makes every stacked branch conflict.** The child's parent
  commit no longer exists in `main`'s history, so a rebase or cherry-pick is
  required even when no file content actually disagrees. With several PRs each
  inserting a rule block at the SAME anchor in this file, every merge invalidates
  the next, and the conflicts are adjacent insertions where **both sides must be
  kept** -- resolving one by taking a side silently deletes a rule. Prefer
  landing such a series in one branch, or expect one rebase per merge.
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

**Four git conflict markers were committed to this file and survived several
merges.** `merge.conflictStyle` is `zdiff3` here, so a conflict has THREE
sections, not two:

```
  <<<<<<< HEAD
  ours
  ||||||| base            <- the one that was missed
  the common ancestor
  =======
  theirs
  >>>>>>> commit
```

(indented by two spaces on purpose: the audit below matches only a marker at
the START of a line, so this illustration documents the shape without tripping
it, and the audit keeps its full strictness rather than learning to skip code
fences.)

The resolver used to land the stacked PRs handled `<<<<<<<`, `=======` and
`>>>>>>>`, kept "both sides", and treated the `|||||||` line as ordinary
content. Nothing noticed, because a stray line in Markdown breaks no test, fails
no shellcheck, and renders as plain text -- the rules file carried visible
merge debris while every suite passed. Every rule between the markers turned
out to be present exactly once, so only the four marker LINES were removed.

`tests/no-conflict-markers-audit.py` scans every tracked text file.
`=======` alone is deliberately NOT matched: it is legitimate Markdown setext
heading underlining, and an audit that fires on ordinary documents gets switched
off. A marker INSIDE a line is not matched either, because prose quoting one is
how a fix documents itself. The audit also fails when it scans zero files, so it
cannot pass vacuously.

**One filesystem must be reported once, however many roots live on it.**
Measured 2026-10-20: `/srv/data` and `/srv/snapshots` are both subvolumes of
`/dev/sda1`, uuid `211e06b3-6aaf-40d8-8646-9361b8399eb2`. Iterating by PATH gave
the operator two identical "never been scrubbed" warnings and told them to run
TWO scrubs of the same device -- the second re-reading the same 215.87 GiB for
nothing. Device error counters are per-filesystem too, so those were doubled as
well. Dedup is keyed on the filesystem UUID from `findmnt`, falling back to
`stat -c %d`, because an absent tool must not silently double every finding.

**A fixture that skips a loop iteration makes the assertion pass for the wrong
reason.** The dedup test asserted "exactly one warning" and passed immediately
-- but `$TMP/snapshots` did not exist, so `[[ -d "$root" ]]` skipped the second
root entirely and the loop never had two iterations to dedup. The companion
"two DIFFERENT filesystems are both reported" case is what exposed it: it
demanded two warnings and got one. Assert both directions of a dedup, or the
single-result case is indistinguishable from never having looked.

**A grep that finds nothing killed `checkup` entirely.** Production,
2026-10-20: `sudo domum-media checkup` printed NOTHING -- not a header, not an
error -- and `bash -x` located it at

```
reset_recent="$(find … -print0 | xargs -0 grep -l … | wc -l | tr -d ' ')"
```

With history files present but no `delay_reset` event among them, `grep -l`
exits 1, `pipefail` fails the pipeline, the ASSIGNMENT fails, and `set -e`
exits the shell -- after every check has run and before one line of the report
is printed. Reproduced standalone: exit 123, and the next line never executed.
**The command died precisely when there was nothing wrong to report**, and a
blank report is indistinguishable from a healthy one. Finding nothing is the
normal answer, so it takes `|| true`, and `xargs -r` stops grep being run with
no file arguments at all. This is the rule this file already states -- "when a
function's failure is EXPECTED and handled, capture it with `|| true`" -- in the
one place where breaking it blinded the whole report.

**The same two lines could never have matched anything.** The patterns were
`\"EVENT='delay_reset'\"`, and inside a double-quoted command substitution
those backslashed quotes reach grep as LITERAL characters, so the pattern
searched for was `"EVENT='delay_reset'"`, quotes included. `write_env_kv` uses
`printf '%s=%q'`, and `%q` leaves a plain word unquoted, so the file contains
`EVENT=delay_reset`. Measured: the shipped pattern matches that file zero times.
**Both the delay-reset and failed-update checks could only ever answer zero,
for as long as they have existed** -- the same shape as the archive marker that
could only answer "yes". The fixture had to be corrected too: it invented
quotes, which would have matched the broken pattern and hidden the defect.

**`command -v` depends on PATH, and root's PATH is not the operator's.** I
reported that `smartmontools` was absent and that no SMART measurement existed
on this host. It was installed all along (7.4-3): `smartctl` lives in
`/usr/sbin`, which is on root's PATH and not on the user's, so my probe as
`jfranco` found nothing while `checkup` -- which runs under sudo -- was reading
SMART successfully for both disks. Two of the six healthy checks were those
SMART passes. Never conclude a tool is missing from a `command -v` run as a
different user than the one that will execute the code.

**`/srv/data` HAS now been scrubbed, and it was clean.** Production,
2026-10-21: 215.87 GiB, 7m14s, 509.34 MiB/s, **zero errors**, exit 0 -- the
first time anything on this host had looked for silent corruption. The derived
estimate said ~10 minutes, over-stating the cost by 38%, which is the safe
direction. Evidence and the measured rate: `docs/BTRFS-SCRUB-PLAN.md`. The
monthly timer is now justified by measurement rather than argument, and is
still neither installed nor enabled.

**HEALTHY must not mean UNMEASURED.** Production, 2026-10-20: `health-notify
--dry-run` reported `VERDICT: HEALTHY, 6 healthy, 0 warnings` on a host where
`/srv/data` had **never been scrubbed** -- 215.87 GiB holding 23,155
irreplaceable originals with nothing looking for silent corruption. (The same
report also claimed `smartmontools` was absent; it was not -- see the
`command -v` rule below.) Two causes, both mine:

- **The never-scrubbed matcher looked only for `never ran`.** btrfs-progs on
  this host prints `no stats available`, so the check fell through, found no
  `Scrub started:` line either, and said **nothing at all** -- neither healthy
  nor a warning. It now matches both wordings, and an unparseable status is a
  warning rather than silence. Note that `Error summary: no errors found` is
  printed for a scrub that NEVER RAN, so it must never be read as a clean
  result. The remedy also states its own limit: a scrub detects checksum errors
  but cannot repair them without a second copy, and `/srv/data` and
  `/srv/snapshots` share one physical SSD.
- `sudo domum-media checkup` printed **nothing at all** -- not a header, not an
  error. The report prints only after every check has run, so one abort under
  `set -euo pipefail` anywhere in the chain produces a blank screen, and a
  blank report is indistinguishable from a healthy one.
  `tests/checkup-produces-output-smoke.sh` drives `checkup_cmd` and asserts the
  header and all four sections exist. Writing it immediately exposed the
  mechanism: stubbing `load_cfg` left `RECOVERY_PACK_DEST` unbound and `set -u`
  killed the shell before a single line printed. The fixture now runs the REAL
  `load_cfg` against a real config, because that function is what applies every
  default the rest of the chain reads.

**The `-` prefixes on a multi-ExecStart oneshot unit were exactly backwards.**
systemd runs each `ExecStart` in order, and a non-zero one WITHOUT a `-` fails
the unit and the remaining lines are **never executed**. The weekly unit had
`report --write` unprefixed and `health-notify` prefixed, which meant:

- a failed report **suppressed the alert** -- precisely when being told matters;
- an **undeliverable alert left the unit green**, so nothing surfaced it.
  Silence would have meant "healthy" when it actually meant "could not tell
  you".

They are now the other way round: the report is tolerated, a delivery failure
fails the unit, and `checkup_systemd_health` reports a failed domum unit as
CRITICAL -- which is what closes the loop. Both halves are asserted, including
the ordering, because `-` on the report only helps if the report runs first.

**Nothing on this host proactively told the operator anything.** Measured
2026-10-20: five timers ran (backup nightly, restic check weekly, snapshot
prune weekly, host update weekly, DR reminder quarterly), every one wrote to the
journal, the DR reminder appended to a logfile, and
`domum-media-weekly-report.service` wrote a report file -- and **nothing read
any of it**. The weekly-report timer was not even installed on the host. The
operator learned the state of the server by running commands by hand, which is
the babysitting the whole phase exists to end.

`domum-media health-notify` is the one notification path, wired as a second
`ExecStart` on the existing weekly unit rather than as a new timer. Its contract:

| state | behaviour |
|---|---|
| healthy | **no mail at all** -- silence IS the healthy signal |
| expected activity | recorded in the summary, never mailed on its own |
| action required | one mail, naming the remedy |
| critical | one mail, named first |

Silence is only trustworthy if the checks cannot fail quietly, so **an input
that cannot be read is a WARNING naming the remedy, never a pass.** Measured:
`smartctl` and `nvme` are absent here, so disk health reports
`UNKNOWN: smartmontools is not installed` with the `apt-get` line rather than
"no disk warnings" from a host that cannot read SMART at all. Nothing is
installed automatically -- that is a host change and belongs to the operator.

`tests/health-notify-smoke.sh` mutates the silence gate away and requires a
perfectly healthy server to start mailing; without that mutation the gate could
rot into "always send" and nobody would notice, because mail arriving is not
evidence that mail is meaningful.

**Checks added because nothing covered them**, all of which existed only as
journal lines before:

- `systemctl --failed` lists only units CURRENTLY failed, so the last exit
  status of every domum timer's service is read separately -- a weekly restic
  integrity check that failed and was restarted was completely invisible;
- Btrfs **device error counters** per Btrfs root. A non-zero `corruption_errs`
  is a checksum failure on the photo tier and is reported as one;
- Btrfs **scrub age**, because a library that is never scrubbed has nothing
  looking for silent bit-rot;
- Immich **off-site coverage**, read from the recorded evidence: only a
  `BACKUP GAP` is a defect, and originals ingested after the backup window are
  reported as HEALTHY with their count. A report that flags normal uploads every
  day is one the operator stops reading.

**One SMTP transport.** `smtp_send_message` is now the only place that knows how
mail leaves this host; the recovery pack and the health notifier each build
their own message and hand it over. Two senders would be two places to get
credentials wrong.

**A summary is a stream, not a captured value.**
`summary="$(health_summary_text)"` made it a captured function, and
`tests/captured-stdout-purity-smoke.sh` flagged
`printf '  - %s' "${CHECKUP_WARNINGS[@]}"` -- because `LOGLIKE` matches `WARN`
anywhere on the line, here only inside a VARIABLE NAME. Widening that pattern to
admit a caller is forbidden, so the summary is written to a file with
`> "$body"` and the same file is printed or mailed. The ambiguity is removed
rather than excused.

**That audit read COMMENTS as code.** `captured_names` searched the whole source
for `$(name`, so the comment explaining why `health_summary_text` must not be
captured made the audit flag a function that is never captured anywhere. It now
strips comments first -- the rule already recorded for the capability audit,
which a comment naming `service_upgrade` once fooled identically. Stripping too
much would blind it, so the smoke test asserts BOTH directions: the real tree is
clean, and a genuine `$(health_summary_text)` capture is still caught.

**The scrub remedy overstated its own cost by an order of magnitude.**
`checkup` told the operator `btrfs scrub start /srv/data   # read-only verify,
takes hours`. Measured: `Total to scrub: 215.87GiB` on a `Samsung SSD 870 EVO
1TB` (SATA, non-rotational) is about **ten minutes**, not hours. This file
already records that *a remedy that reads as expensive does not get run*, and
this was that rule applied to the one check standing between silent bit-rot and
23,155 irreplaceable originals. `btrfs_scrub_estimate` now reads the
`Total to scrub:` line the filesystem itself reports and picks the rate from
`/sys/block/<dev>/queue/rotational` -- 400 MB/s solid-state, 100 MB/s spinning.
Dividing bytes by a rate is legitimate HERE, unlike the `verify-large`
estimate: a scrub is one pass over the allocated extents with no count cap and
nothing it cannot split, so the division IS the mechanism. An unparseable size
omits the clause rather than printing `~0 min`.

Three things that only driving it revealed:

- **Stripping trailing DIGITS stops at `nvme0n1p`** and never reaches
  `nvme0n1`, so an NVMe root fell through to the fallback rate and a spinning
  disk would have read as an SSD. Shave one trailing `[0-9p]` at a time and let
  the existence check stop the walk -- it cannot pass a real device name,
  because that name matches first.
- **`DOMUM_SYSBLOCK_ROOT` exists so the rotational branch can be tested at
  all.** Both disks here are SSDs, so without an overridable root the 100 MB/s
  path could never be driven and the test would default to 400 and pass for the
  wrong reason -- the fixture-skips-the-iteration mistake. It defaults to the
  production path, and the mutation that ignores the flag must make a
  39-minute scrub advertise itself as 10.
- **I rewrote a clause that was already correct.** "cannot repair without a
  second copy" became "cannot repair data on a single-device filesystem", and
  an existing assertion caught it. The original is the better statement: it is
  true of `Data: single` AND correctly implies `Metadata: DUP` *can* be
  repaired, whereas a single-device filesystem with `-d dup` could repair data
  too. Before adapting a test to a change, ask which of the two is wrong -- here
  the test was right.

**`ionice` does nothing to a scrub on this host, so never offer it as the
throttle.** `btrfs scrub start -c 3` is the obvious gentleness flag and is
silently ineffective: `/sys/block/sda/queue/scheduler` is `mq-deadline`, and
`btrfs-scrub(8)` states that ionice is supported only by BFQ and that the
options "may not work as expected" otherwise. (`-n 18` was wrong independently
-- ioprio classdata is 0-7, not a nice value.) The lever that works on any
scheduler is btrfs-progs' own `--limit`, which resets itself when the scrub
finishes. A flag that describes a protection it does not provide is the defect
family this file keeps correcting; it is named in
`docs/BTRFS-SCRUB-PLAN.md` rather than quietly included in the command.

**One scrub covers the whole filesystem, and the profiles decide what it can
fix.** Measured 2026-10-20, without root -- `btrfs filesystem df` needs no
privilege, which is why these facts could be established at all:

```
Data,     single: total=218.01GiB, used=215.26GiB   <- ONE copy
Metadata, DUP:    total=1.00GiB,   used=313.98MiB   <- two copies, same SSD
System,   DUP:    total=8.00MiB,   used=48.00KiB
```

So a **metadata** checksum error is repairable by scrub and a **data** one is
not: there is no second copy of the photo library. The honest claim is that a
scrub on this host **detects** silent corruption in the family photos and
**cannot repair** it -- the remedy is restoring the named file from restic, and
the backup-scope correction above decides whether that is even possible
(`immich/library` yes; `/srv/data/backups/images` and the five migrated
services NOT COVERED). Both DUP copies are on the same physical SSD, so DUP
protects against a bad block, not against the device failing.

**No scrub has been started, and no scrub timer exists.**
`docs/BTRFS-SCRUB-PLAN.md` holds the duration arithmetic, the windows to avoid,
what a checksum error means, the recovery actions, and a proposed monthly unit
that is deliberately not written. Starting a scrub and enabling a timer are
operator actions.

**`btrfs_unique_roots` is the ONE implementation of the per-filesystem
dedup.** `checkup_btrfs_health` carried its own copy, and `storage scrub`
would have been a second -- two chances to tell the operator to scrub the same
device twice, which is the defect the dedup was written to fix. Both consume it
now. The refactor was proved behaviour-preserving by the dedup tests that
already existed, including the "two DIFFERENT filesystems are both reported"
direction; a single-result assertion alone cannot tell a dedup from never
having looked.

**`domum-media storage scrub {start|status}` is the scrub surface, and its
EXIT STATUS is the contract** -- `0` clean, `1` could not scrub, `3`
uncorrectable errors found, which is `btrfs-scrub(8)`'s own meaning kept rather
than reinvented. `start` passes `-B` internally and a mutation removing it must
fail: without blocking, `btrfs scrub start` returns immediately and a oneshot
unit goes green before reading a single block. The worst result across
filesystems governs, so a clean filesystem can never mask corruption on
another. It deliberately does **not** take the operation lock: a scrub is
NOT read-only -- see below -- but btrfs serialises scrubs on a filesystem
itself, a metadata repair is an internal consistency operation rather than an
application-visible mutation, and a 7-26 minute job holding the global lock
could make the nightly backup fail to acquire it, trading a detection pass for a
missed backup.

**A SCRUB ALREADY RUNNING IS NOT A FAILURE, and the generic branch would have
mailed a critical for an entirely normal condition.** btrfs refuses to start a
second scrub on the same filesystem, so `btrfs scrub start` returns non-zero and
landed in `*)` -- `scrub FAILED on $root`, `worst=1`, a failed oneshot unit,
which `checkup_systemd_health` reports as CRITICAL and `health-notify` mails.
The monthly timer firing while a manual scrub is still going, or while the
previous month's has not finished, would do exactly that.

Asked two ways on purpose. `btrfs_scrub_running` reads the `Status:` field
(btrfs-progs v6.14 prints `running|finished|aborted|interrupted`, and
`no stats available` for a filesystem never scrubbed), which avoids depending on
the wording of an error; btrfs's own `already running` message is the authority
and closes the race between asking and starting. **Anything neither recognises
stays a failure** -- an unrecognised error genuinely may be one, and that is the
conservative direction, asserted in its own section.

`btrfs scrub status` needs privilege, so an unreadable status is `unknown` and
is **never** read as "not running": the status check abstains and btrfs's
refusal remains the control. Reading it as idle would produce a confident
failure from a check that could not see.

**The summary narrows its claim rather than hiding the skip.** A skipped
filesystem makes no claim, so the plain `scrubbed N filesystem(s)` line is
replaced by one stating how many were scrubbed and how many were already
running, plus an explicit line that the skipped ones are unproven here. HEALTHY
must not mean UNMEASURED, and `0 scrubbed` reported as "clean" would be exactly
that.

**My own change broke two existing assertions, and one of them was right to
break.** Capturing the invocation's output moved `btrfs scrub start` off column
0, so the `-B` mutation's anchor no longer matched (the mutation reported "not
unique: 0" rather than silently passing, which is why that rule exists) and the
`^btrfs scrub start -B` assertion failed against correct code. The anchor was
updated; the assertion is now `btrfs scrub start -B( |$)`, which still asserts
`-B` is an argument of `scrub start` itself without depending on what precedes
it on the line.

**A RESTORE must state the CAPTURE MODE, because a digest is not a consistency
claim.** A digest proves the restored bytes are the captured bytes; it says
nothing about whether those bytes were a consistent point in time. jellyfin's
and kavita's databases are both WAL-mode with no sqlite3 anywhere, so their
captures are copies taken while the service may be writing -- and a restore
report that omitted the mode read as strong for an `unproven` capture as for a
consistent one. The mode is printed with its reason, a consistent capture is
reported distinctly (so the unproven wording cannot be boilerplate), and an
absent `CAPTURE_MODE` reads as `unknown` rather than the reassuring value --
the metadata-key family, defaulted in the accessor and driven by a test with
the key deleted.

**A scrub that found corruption must leave a FAILED unit.** `ExecStart` carries
no `-` prefix, so exit 3 fails `domum-media-btrfs-scrub.service`, which
`checkup_systemd_health` reports as CRITICAL and `health-notify` mails. The
report names the capture commands (`scrub status -R`, `device stats`, the
kernel log that names the FILE) and says explicitly **not** to attempt a
repair. "Warn and continue" is not a safety mechanism, least of all here.

**The scrub timer is protective and low-cost and is still NOT in
`auto-enable.timers`**, because enabling it means a scrub *will* start
unattended and starting one is an operator decision. The test requires the unit
file to EXIST and the timer to be absent, so the assertion cannot pass by
naming a unit that was never written.

**I inserted a test section into a quoted heredoc and it became FIXTURE
DATA.** The anchor I matched -- `# comment mentioning
domum-media-image-refresh.timer` -- was a line of test *input*, not a code
comment. The block never executed, the mutation that lists the scrub timer in
`auto-enable.timers` SURVIVED, and the hostile-parser fixture was corrupted
into the bargain. Anchor a programmatic edit on code, never on a string that
also appears in test data, and re-run the mutation afterwards: the section
printed nothing and the suite still said PASS.

**`checkup_disk_health` sent an UNREADABLE device to CRITICAL, and the fix
introduced a worse bug that the test caught.** The original greped
`smartctl -H` for `PASSED|OK` -- matching `ok` as a case-insensitive SUBSTRING
anywhere in the output -- and sent anything else to **CRITICAL "did NOT pass"**,
so a permission failure told the operator to replace a healthy disk. Measured:
under permission denied `smartctl -j -H` returns well-formed JSON with
`exit_status: 2` and NO `smart_status`. "I could not check it" is not "it is
broken". The verdict is now read from `--json`, which is also the form the real
captures are in -- a text pattern could not be verified without root and would
have failed closed into two mailing warnings if smartctl's wording differed.

**`jq`'s `//` is FALSE-coalescing, not null-coalescing.** My fix used
`.smart_status.passed // empty`, so a drive that genuinely **FAILED** its
self-assessment produced NOTHING and was reported as UNKNOWN rather than
CRITICAL -- the dangerous direction, in the one check that exists to notice a
dying disk. Measured:

```
{"smart_status":{"passed":false}} | .smart_status.passed // empty  -> (nothing)
{"smart_status":{"passed":true}}  | .smart_status.passed // empty  -> true
{}                                | .smart_status.passed // empty  -> (nothing)
```

`| tostring` keeps all three distinct: `false` / `true` / `null`. jq's falsy set
is exactly `null` and `false`, so only a BOOLEAN read is at risk -- the
codebase's other `// empty` reads are counts, ids and strings and are
unaffected; verified, `{"n":0} | .n // empty` yields `0`. Never read a boolean
through `//`.

**Measured 2026-10-21: neither SSD has an actionable wear or error indicator,
and the asymmetry between them is the finding.** `/dev/sda` (Samsung 870 EVO
1TB, holds `/srv/data`) has **0.52% of its 600 TBW used** -- 3.11 TB written in
148.7 days, ~79 years at that rate -- every error counter zero, and
`Wear_Leveling_Count` normalized 99/100 agreeing independently. `/dev/sdb`
(KOWIN, holds `/`) reports **all 30 attributes at `value=100, threshold=50`**,
10 of them unknown to smartmontools, `Wear_Leveling_Count` raw 0 after 3054
hours, and a `Total_LBAs_Written` whose unit is not determinable: it is
reporting PLACEHOLDERS, not measurements, and **will report "passed" until it
does not**.

The drive whose health can be measured is the one holding data that cannot be
replaced; the drive that measures nothing holds only a rebuildable OS. That is
the right way round, which is why there is no action. **Attribute thresholds
were deliberately NOT added to `checkup`**: nothing would fire on sda today, and
on sdb comparing `value` against `threshold` would produce a confident
"healthy, 0% wear" from a drive that measures nothing -- the
HEALTHY-means-UNMEASURED defect, manufactured on purpose. Evidence, including
sda's historical 62 °C peak and its 8 unclean power-loss recoveries:
`docs/SSD-HEALTH-STATUS.md`.

**Three tested volume primitives had ZERO reachable call sites.**
`storage_volume_pre_upgrade_point`, `storage_verify_volume_dumps` and
`rollback_volume_upgrade` all existed, were tested, and nothing could reach
them: `create_upgrade_rollback_point` called `storage_pre_upgrade_point`
unconditionally, so a docker-volume service was refused by
`assert_pre_upgrade_possible` for the generic reason that its path is not a
subvolume. The orchestration is now dispatched on the DECLARED state model --
`create_upgrade_rollback_point`, `verify_upgrade_rollback_point` and
`rollback_dispatch` -- and an `unknown` or `stateless` model is REFUSED rather
than guessed, because restoring a subvolume snapshot over a Docker volume would
report success having restored nothing.

**PHASE 4 WAS NOT MODEL-AWARE, so a successful volume upgrade reported
failure.** Two of its assertions were unconditional:

```
domum_is_subvolume "$(service_data_path "$service")"   || rc=1
btrfs property get -ts "$DOMUM_SNAPSHOT_ROOT/$point"   || rc=1
```

For `traefik` and `uptime-kuma` both are false **by construction** -- there is
no `/srv/data/<service>`, and a volume pre-upgrade point is a dump set, not a
read-only Btrfs snapshot. So the verification set `rc=1` twice on an upgrade
that had gone perfectly, and reported `Upgrade INCOMPLETE`. **The volume path
could not succeed even with the gate open.** Phases 1-3 were made model-aware
when the dispatch was added and phase 4 was left behind -- the same defect as
`assert_pre_upgrade_possible` dying on `docker-volume`, in the same function,
one phase later. `verify_upgrade_rollback_point` is already model-aware and is
what checks the dumps and the archive, so the volume case loses no coverage.

**The guard must not become a blanket skip**, and that direction is asserted
too: for the protected tier those two assertions are what prove the recovery
point survived the upgrade.

**`service_is_healthy` accepts `none`, so a started container read as a working
one.** Phase 4 printed `health: none` for a service whose application was never
asked anything -- traefik exactly: no container healthcheck, no readiness probe,
and deliberately no declared log pattern. It now says
`readiness: UNPROVEN -- no container healthcheck, no readiness probe and no
declared log pattern. RUNNING is the whole claim.`

**I also wired the declared readiness log pattern into phase 4 and had to
revert it.** `service_logged_ready_since` exists and only the MIGRATION path
used it, so an upgrade had weaker readiness evidence than a migration of the
same service -- a real gap. But phase 4 runs IMMEDIATELY after `up -d` with no
wait, so a service whose readiness line lags by seconds was reported as having
failed, and escalating on absence changes the success criteria for the four
services that declare a pattern. Driving the real argv path caught it; reading
the diff had not. It needs a bounded wait and its own tests, and half of it is
worse than none. Recorded as a candidate rather than shipped.

**I referenced `$restart_boundary` before defining it.** Under `set -u` that
kills the function -- the `service_upgrade` calling-an-undefined-helper family
again, in the same function, caught because the integration suite enters through
the real argv instead of reading the source.

**I then wrote the gate in the wrong place and my own dispatch was still dead
code.** `assert_pre_upgrade_possible` runs near the top of `service_upgrade` and
**dies** on `docker-volume` ("there is no pre-upgrade recovery point for this
service yet") -- a refusal that predates the volume path. So the new dispatch
below it could never execute. The model is now resolved FIRST, the gate refuses
before the lock and before compose, and the tier-specific assert is called only
for `protected-tier`; the volume path relies on
`storage_volume_pre_upgrade_point`'s own equivalent checks. Found by DRIVING the
function; reading it had looked fine twice.

**`VOLUME_UPGRADE_ENABLED` defaults to 0 and the gate is the point.** The volume
path is implemented and exercised only against fixtures -- it has never run
against a real service -- so production refuses until the operator sets it. The
refusal happens before the lock is acquired and before any container is stopped,
because a closed gate that still causes downtime is not a closed gate. The
mutation neutralises the COMPARISON (`"$X" != "$X"`, never `&& false` inside
`[[ ]]`) and requires the refusal to disappear.

**Name the observable a mutation actually changes.** The gate mutant was first
asserted to "reach the lock". It does not: with the gate neutralised the
function runs on into `other_container_identities` and the staged-image
resolution, which the fixture does not stub, so it dies there for an unrelated
reason and the assertion failed against a mutant that had genuinely got past the
gate. What the mutation changes is whether the REFUSAL happens at all.

**Measured 2026-10-21: traefik and uptime-kuma are BOTH running dangling
images, with a newer image already staged under the same tag.**

| service | running image | tag now points at |
|---|---|---|
| traefik | `9c3b91d5…` (`RepoTags: []`, `RepoDigests: []`) | `9c2a54d87f76` |
| uptime-kuma | `a8610b3b…` (`RepoTags: []`, `RepoDigests: []`) | `3e24e96c89ef` |

That is the Plex condition in both: the running image survives only because a
container references it, so a prune would make the application half of any
recovery point unobtainable. The `--archive-image` step is therefore not
optional for these two -- it is the only copy that would survive.

**uptime-kuma ships sqlite3 3.40.1 and nothing was using it.**
`service_sqlite_binary uptime-kuma` now declares `/usr/bin/sqlite3`, which turns
`kuma.db` from `unsupported: not checked` into a real integrity check -- the
same gap calibre-web had. It matters more here: `kuma.db` is WAL-mode and the
application forward-migrates it on startup, which is exactly the state a
rollback point has to vouch for.

**uptime-kuma's readiness is the best-evidenced of the eleven; traefik's cannot
be evidenced at all.** Measured across a real restart, uptime-kuma logs
`Connected to the database` and then `Listening on:`, so the declared pattern
comes AFTER the database is open -- a stronger claim than Plex's TCP-listener
probe -- and it also has a container healthcheck. traefik has **no** healthcheck
and logs **no** readiness line: its providers start asynchronously, the last
lines of a clean start are `Starting provider *acme.Provider` and friends, and
there is no `Configuration loaded from` line at all on this host (0
occurrences). `service_ready_log_pattern` deliberately leaves traefik
undeclared, because declaring a `Starting provider` line would assert readiness
from evidence that only shows a provider beginning to start. Its readiness is
reported as unproven instead.

**Local Btrfs snapshots are not off-site protection, and the per-service
classification says so explicitly.** `/srv/data` and `/srv/snapshots` are
subvolumes of ONE filesystem on ONE device, and a proof snapshot plus its
`.premigration` copy both live there. They protect against a bad upgrade, a bad
migration and operator error; they do not survive the SSD failing.
`docs/OFFSITE-COVERAGE-CLASSIFICATION.md` classifies every service and never
counts a local snapshot as off-site coverage.

The five migrated media services -- plex, jellyfin, kavita, navidrome,
calibre-web -- are **local snapshots only**. So are the image archives, and
that is the sharpest gap. Measured 2026-10-21 three running images were
dangling; **re-measured 2026-10-28 it is TWO -- traefik and uptime-kuma** --
because the Plex upgrade gave its image a tag. The conclusion does not change:
no service has independent registry evidence (every tagged one's RepoDigest
equals its image Id), so the `docker save` archive is the only PROVEN copy of
the application half for all of them, and `/srv/data/backups/images` is not in
the cloud target. What changed is narrow: plex's local object is no longer
prune-exposed, while traefik's and uptime-kuma's are.

**The production config is `0600 root`, so which backup targets are ENABLED
cannot be established from the development account.** A second target `nas` is
declared with `/srv/data` as its root. `load_cfg` run as `jfranco` silently
falls back to defaults -- `BACKUP_TARGETS=unset` and both targets reporting
ENABLED -- which is a DEFAULT, not a measurement, and reporting it as one would
be the fixture-backed-probe mistake. It is recorded as an open question needing
root, because if `nas` is enabled then `/srv/data` is already covered and the
proposed selective backup is unnecessary.

**No new backup coverage is proposed until the bytes are measured.**
`du -sb` on the candidate paths needs root. The design is written down; the
recommendation is deliberately withheld, because recommending coverage without
a size is how a nightly window gets quietly lengthened. Family photographs keep
priority: any new coverage is additive and must never displace or slow the
Immich paths, and no replaceable bulk media -- `/srv/media`, movies, TV,
downloaded books, derivatives, transcodes, thumbnails -- enters the set.

**The scrub estimate assertion depended on the RUNNER'S DISK.** It passed here
and failed in CI: `health-checks-smoke` asserted the remedy derives
`~10 min` for 215.87 GiB, and CI reported **39** -- because the rate is chosen
from `/sys/block/<dev>/queue/rotational` and the device backing `/tmp` on the
runner reports **1**. The dedicated rotational sections pinned both halves
(`DOMUM_SYSBLOCK_ROOT` plus a `findmnt` stub); the `probe`-based section used
the REAL `findmnt` and the real sysfs. "A test that depends on host state is not
a test" -- and the irony is that this is the suite that introduced
`DOMUM_SYSBLOCK_ROOT` precisely so the device class could be pinned. Both
probe-based sections now pin it, and flipping the FIXTURE's flag is required to
make the section fail, which is what proves it reads the fixture rather than the
machine.

**MAIL DELIVERY IS PROVEN -- 2026-10-25 08:25:56 -- and the proof is an exit
status, which took one near-miss to get right.** This file recorded that
`health-notify` had only ever run with `--dry-run` and that `smtp_send_message`
had never reached the server. Both were false, and the chain is entirely
read-only state:

1. `RECOVERY_PACK_EMAIL_ENABLED=1`. The off-host audit, **run as root on
   2026-10-12**, printed `off-host delivery ENABLED`, which
   `bin/domum-media-backup` emits only when that flag is 1 -- and the production
   config's mtime is **2026-09-23 15:08:21**, readable without privilege, so it
   has not changed since before that measurement.
2. `domum-media-check.service` entered the failed state at **03:36:56** that
   morning (exit 11), so `systemctl --failed` listed it.
3. `domum-media-weekly-report.service` ran at **08:25:56** with
   `Result=success`, `ExecMainStatus=0`.
4. The binary installed then was `383f9e6`'s -- confirmed by hash,
   `8760cfa51f3d`, exactly what the 2026-10-27 deployment reported as INSTALLED.
5. At that revision `health_notify_cmd` collected through `checkup_collect_all`
   and the timer exit-status loop emitted a **CRITICAL** for status 11.
6. `health-notify` is the SECOND `ExecStart` and carries **no `-` prefix**, and
   a failed `smtp_send_message` calls `die`.

**`health_notify_cmd` returns 0 in THREE situations, not one**, and the first
version of this conclusion checked only two of them. A dry run returns 0 (the
unit passes no such flag); nothing-to-report returns 0 (excluded by the critical
at step 5); and **mail delivery not enabled returns 0** after warning to the
journal -- excluded only by step 1. Without step 1 the exit status is equally
consistent with "sent" and with "delivery switched off", and the production
config is `0600 root`, so an unprivileged account cannot tell them apart. Every
zero-exit path has to be enumerated before an exit status proves anything.

The claim's limits, stated: it proves the transport worked **once**, to one
address, and it is an inference from an exit status rather than a received
message -- sound only because the delivery failure is fatal, and it would
collapse the moment anyone put a `-` on that `ExecStart`. The operator
independently confirms receiving mail. Silence now means "nothing needed
attention" rather than "nothing needed attention OR mail is broken".

**The third path was a live hazard, and `checkup_notification_path` now reports
it.** `RECOVERY_PACK_EMAIL_ENABLED` **defaults to 0**, so a host with the weekly
timer enabled and that flag unset writes every alert it ever raises to the
journal, discards it, and leaves the unit GREEN -- the
HEALTHY-must-not-mean-UNMEASURED defect inside the notifier itself. The check
fires only on the CONTRADICTION (timer enabled, delivery off), because an
operator who does not want mail disables the timer and that is not a finding; an
absent timer is not read as an enabled one; and when the flag IS set it reports
the transport as **configured**, never as proven delivered. On this host it
reports healthy, so it is a regression guard rather than a live finding.
**ENABLED is not USABLE, and nothing checked the credentials until a message
had to go out.** `smtp_send_message` dies on a missing `RECOVERY_PACK_SMTP_HOST`
or credential file, and `checkup`'s secrets loop never covered them -- so the
first symptom would have been a failed send, which happens only when something
needed reporting, and the one thing that cannot then be delivered is the report
saying so. They are verified before the first real alert depends on them. An
**empty** file is reported as well as an absent one, because
`smtp_send_message` tests `-f` and would hand an empty credential to the server.
Only PATHS are named, never contents.

`tests/health-checks-smoke.sh` drives all four notifier states and all three
unusable-transport states, asserts that no credential VALUE ever appears in the
output, and the mutation defaults the flag to 1 -- it must make a host that can
deliver nothing report a clean path.

**A known open defect can be closed by reading state, and leaving it open has a
cost.** "Never proven" was the stated reason to distrust silence, and it had
been falsified four days before anyone looked. Check an open entry against
evidence before repeating it.

**A RETENTION failure was reported as a BACKUP failure, and it cost the
heartbeat.** `restic_forget_for` returns restic's status, and `do_daily_backup`
called it unguarded under `set -e`, so a failure aborted the function **before
`heartbeat`** -- which writes `$DOMUM_LOG_DIR/last-success`, the marker
`checkup` reads for "Last backup completed Nh ago". A backup that had fully
succeeded, with its own per-target evidence already recording
`RESULT=success`, would therefore be reported as a **STALE** backup, the
recovery-pack refresh would be skipped, and the cause would be misattributed.
The same shape in `do_weekly_retention` let the FIRST target's failure skip
every later target's retention.

Continuing is both the accurate and the safe direction: retention is
`forget --prune`, so not running it leaves snapshots in place, which this file
already calls the safe direction, whereas aborting loses the heartbeat and the
pack. It is **not** swallowed -- the run does every must-happen step and THEN
fails the unit naming retention, and the recorded retention evidence says
`RESULT=failure`. `tests/backup-evidence-endtoend-smoke.sh`; the mutation
restores the unguarded call and the observable is the **heartbeat**, not the
exit status, because the run fails either way.

**Latent, not active, and the cadence is why.** `backup_target_retention`
defaults `cloud` to **weekly** and `nas` to daily, and only `cloud` is enabled
(proved from the backup log, not from defaults -- see above) -- so
`retention_targets daily` is EMPTY and no daily retention runs on this host.
**The daily loop body is therefore unreachable in this configuration**, and
enabling `nas` is the single change that makes it live, which §F2 pins.

**The WEEKLY half of that fix is behaviourally equivalent for one target.**
`retention_targets weekly` is `cloud` alone, so the deployed unguarded form and
the guarded one both end in the unit failing; the fix adds a clearer message and
multi-target robustness. And `restic_forget_for` in the DEPLOYED binary already
records retention evidence, so the next scheduled run records regardless.
Deploying the fix ahead of that run therefore reduces **no** risk -- which is
the honest answer to "should we deploy now", and the opposite of what urgency
would feel like after finding a defect. That is why the nightly backup survived the Mac's stale lock from
2026-10-20 to 10-27. It goes live the moment a daily-retention target is
enabled. Verified from systemd: backup `*-*-* 02:30` +15m, check
`Sun *-*-* 03:30` +20m, both `Persistent=true`, and the check unit's second
`ExecStart` is `--weekly-retention`. **Retention on this host happens only on
Sundays, only via the check unit, and only if `--check` succeeds** -- which is
why exit 11 on 2026-10-25 skipped it. Oct 18 -> Oct 29 is therefore exactly ONE
missed weekly run, not a recording gap.

**"No successful retention run is recorded" and "retention did not run" are
different claims, and both were true at once.** The recording shipped
2026-10-28; retention has not run since 2026-10-18. So the report's wording is
literally correct and deliberately does not say retention has never happened.
Keep them distinct: one is about the evidence, the other about the operation.

**`export TZ="${TZ:-UTC}"` is for the CONTAINERS and leaks into the CLI's own
process**, so `epoch_to_iso` renders UTC while `domum-media-backup` records
local time -- production 2026-10-29 showed `cloud@...T15:22:34+0000` beside
`Reconciled at ...T10:55:03-04:00` in one report. Both denote the same instant,
so nothing is wrong, only inconsistent. **Deliberately NOT changed**: that
`TZ=UTC` is load-bearing for the journal `--since` window, which carries a
measured comment showing the comparison returns 1 match under `TZ=UTC` and 0
under `TZ=America/New_York`. Changing it to tidy a timestamp would break a
working comparison.

**`\xc2\xb0C` reached the operator as nine literal characters.** The weekly
report's trend suffix is printed with `%s`, so a double-quoted `"\xc2\xb0C"` is
never interpreted -- production printed `Disk temp   47\xc2\xb0C`, and the HTML
part inherited it because that renderer wraps the rendered TEXT. ANSI-C quoting
(`$'\xc2\xb0C'`) makes the bytes real. This is the rule this file already
records about `\xNN` not being interpreted, in a renderer rather than in a
test, and the assertion against it must use `printf` for the same reason.

**`systemctl reset-failed` does NOT clear `ExecMainStatus`, and I recommended it
as though it did.** Production, 2026-10-29: the operator ran it and `checkup`
printed `No systemd unit is in the failed state` **and** the same exit-11
critical as before. Measured immediately afterwards:

```
Result=success          <- reset-failed set this
NRestarts=0
ExecMainStatus=11       <- and left this, which is what the finding reads
ExecMainExitTimestamp=Sun 2026-10-25 03:37:11 EDT
```

`checkup_systemd_health` has TWO loops on purpose -- `systemctl --failed` lists
only what is CURRENTLY failed, so the last exit status of every domum timer's
service is read separately, which is what made a failed-and-restarted weekly
check visible at all. So the two findings have **different** remedies, and
collapsing them into one wording was the error: `reset-failed` is the fix for
the `--failed` listing and cannot touch the recorded exit status. Each now says
what it does and what it does not, and the exit-status finding states that its
own value is replaced when the unit next runs.

**`systemctl start domum-media-check.service` must never be offered as a
convenience.** Its SECOND `ExecStart` is `--weekly-retention`, i.e.
`restic forget --prune`, so "just run it now" is a manual retention run, which
needs approval. Asserted.

**A finding whose cause is already fixed needs a listed way to say so.** The
same production run offered only `journalctl` and an approval-gated
`restic unlock` -- for a repository the operator had already unlocked and
verified **twice**. The action that retires it is a recorded successful check,
which is read-only, so `sudo domum-media-backup --check` is now listed FIRST,
before the approval-gated remedy: if it passes, the unlock advice is moot, and
exit 11 from it means the lock really is still there. Ordering is asserted,
because a free read-only step listed after an approval-gated one is a remedy
nobody reaches.

**Only `cloud` is enabled -- and the way I first "measured" that was an invalid
inference.** I read it off the root-run `checkup` output because every
per-target healthy line named `cloud` and none named `nas`. Those lines are
**conditional on the repository being `sftp:`**, so an enabled target with a
local or NFS repository prints nothing at all, and absence proved nothing. The
operator was right to challenge it.

**The default is the trap: `backup_target_default_enabled` returns 1 for `nas`
AND for `cloud`.** A target listed in `BACKUP_TARGETS` is therefore ENABLED
unless the configuration explicitly disables it, and production does list it:
`BACKUP_TARGETS="nas cloud archive"` with `BACKUP_TARGET_NAS_RETENTION="daily"`.

The real evidence is the **world-readable rotated log**,
`/var/log/domum-media/backup.log.5.gz`: across **107 consecutive nightly runs**
(2026-06-09 to 09-26) it contains `restic backup -> cloud` 107 times and
**zero** occurrences of `nas` or `archive` in any form. `restic_backup_to` logs
`restic backup -> $target` *after* its include-path check and
`check_repo_identity` runs before it, so an enabled-but-broken nas would have
left either that line or an `ERROR: no configured include path` line. Neither
exists, so nas never entered the loop. The only two `restic forget --prune`
lines are `on cloud`, on Sundays (09-13 and 09-20) -- the weekly path. There is
also **no network mount of any kind** on this host and no `/srv/nas*`.

So: `nas` is a configured placeholder for hardware that does not exist yet,
explicitly disabled against a default of 1; `archive` is default-disabled with
cadence `none`. `/srv/data` is **not** covered by an enabled second target and
the selective-backup proposal still stands.

**Distinguish configured / enabled / reachable / backed up / retained.** They
are five different states and this file previously collapsed two of them.
`tests/backup-evidence-endtoend-smoke.sh` §F2 now drives the REAL
`enabled_backup_targets` -> `retention_targets` chain against the production
shape -- every suite had stubbed `retention_targets`, which is why nothing
caught the guess.

**THE WEEKLY REPORT PRESENTED A STALE COVERAGE PROOF AS CURRENT.** Production,
2026-11-02: the Immich block read `Immich originals 23265`,
`In off-site snapshot 23265 of 23265`, `Missing none` -- every figure taken
from the reconciliation RECORDED on 2026-10-29 against snapshot `fb948da5`,
with `78e40ef8` (11-01) newer and 10-30, 10-31 and 11-02 in between. **Any
original ingested since 10-29 was neither counted nor reported as unknown**,
and the block read as a present-tense claim about complete coverage.

`dr-status` already had this corrected -- it names both snapshots and says the
present position is UNKNOWN. The weekly report was built later and reproduced
the presentation WITHOUT the staleness test, which is the
"commands that answer the same question must read the same evidence" rule one
level up: the same question, different honesty.

`backup_run_last_success` reads the per-target run evidence (a local file --
a report must do no recovery work) and the block now has three answers: STALE
naming both snapshots and what the figures do not cover, current, or **UNKNOWN
when no successful backup run is recorded**. The remedy says `metadata only`,
because a remedy that reads as expensive does not get run. The mutation drops
the comparison and a four-run-old proof must read as current.

**A DRY RUN THAT DOES NOT CONSULT THE GATE DESCRIBES THE WRONG ACTION.**
Production, 2026-11-02, the first real run after deploying the severity split:
on a host with six warnings and zero actions `health-notify --dry-run` printed
`no mail was sent (subject would be: domum-media: WARNINGS (6))`. That reads as
"a real run WOULD send, with this subject". It would not -- the silence gate
holds, nothing is sent, and there is no subject at all. The dry branch
`return`ed BEFORE the gate, so it could not know.

A preview must describe the action it is previewing, which is the same rule as
`PREVIEW NEVER SENDS` and as the deployment dry run that must not speak in the
indicative. The gate's decision is now computed ONCE into `would_send` and both
the preview and the run read it, so a preview cannot disagree with the run it
previews. With the gate holding it says a real run would send **NOTHING** and
why; with an action present it says it WOULD send and names the subject. The
existing silence mutation was re-anchored onto `would_send`, because forcing
that decision open is the same defect in the new shape.

**`VERDICT: ATTENTION` under a subject of `WARNINGS (6)` -- two answers to one
question, again.** `health_summary_text` carried its own verdict ladder
(`CRITICAL` / `ACTION REQUIRED` / **`ATTENTION`** / `HEALTHY`) which agreed with
`health_verdict` on three rungs and diverged on the fourth. This file already
records that defect and the fix applied to the SUBJECT; the body kept a private
copy, so the disagreement merely changed direction. One ladder now --
`health_summary_text` calls `health_verdict` -- and the mutation reintroduces a
private one and must bring the disagreeing word back. **Two numbers that must
agree are one number, and that applies to a WORD just as much.**

**Both were found by running the deployed code on the real host, not by
fixtures.** Every fixture prediction for this deployment held exactly -- the
verdict, the advisory section, the degree sign, the trend heading and span, the
wear lines, and the coverage-freshness verdict. These two were in the one place
a fixture had not looked: the preview's own description of itself.

**Suppressing `du`'s stderr turned a measurement into a lower bound I could not
tell apart from one.** Jellyfin and Kavita were recorded as `>=489 KiB` and
`>=5.8 MiB` and labelled partial, because `config/` is owned `911:911` and
`root:root`. Both are `drwxr-xr-x`, so `du` can traverse them -- and re-run
2026-11-02 with **stderr left visible** it emitted no permission errors at all.
Checking stderr is what distinguishes the two; `2>/dev/null` made a complete
walk indistinguishable from a blocked one.

Measured: jellyfin **490.5 KiB** total with ~469 KiB irreplaceable
(`jellyfin.db` 466,944 plus `system.xml` and the two
`.aspnet/DataProtection-Keys` that decrypt stored secrets); kavita **5.83 MiB**
with ~1.13 MiB irreplaceable (`kavita.db` 1,114,112). **Kavita's own
`backups/` is 3,497,442 bytes -- 3.1x the database it backs up, and the largest
single item in its tree** -- so taking it off-site would pay three times over
for the same data.

All five services: **8.90 MiB of irreplaceable state against 352.28 MiB of
directories, 2.5%**, driven almost entirely by Plex's 230.6 MiB of regenerable
`Drivers/`. Jellyfin and calibre-web are small enough that selection buys
nothing -- take them whole. Only `/srv/data/backups/images` remains unmeasured
(`root 0750`), and it is the one figure that could change the recommendation: a
`docker save` of a media image runs to hundreds of MiB, so the archives could
be two orders of magnitude larger than everything else combined. See
`docs/SELECTIVE-STATE-PROTECTION.md`.

**My own fix then overclaimed in the ALARMING direction, which is the same
defect pointing the other way.** The staleness note said newer originals were
`UNVERIFIED, not covered` -- and "not covered" asserts they are **not backed
up**, which the evidence does not establish: they are very likely already in
the newer snapshots and nothing has RECONCILED them. The four claims must stay
distinct, and the absence of a re-observation is not evidence of absence. It
now says `NOT RECONCILED -- it may already be in the newer snapshot, but
nothing has checked`, and the test asserts BOTH directions: the note must say
that, and must not contain `not covered`, `not protected`, `not backed up` or
`not in the backup`. The operator caught this.

**The comparison reads the cloud BACKUP snapshot, traced rather than assumed.**
`SNAPSHOT_ID` in `<target>-run.env` comes from
`sed -n 's/.*snapshot \([0-9a-f]\{6,\}\) saved.*/\1/p'` over restic's own
**backup** output and is written only when `RESULT=success`; retention writes a
separate `<target>-retention.env`. The report's target is
`${REPORT_COVERAGE_TARGET:-cloud}` and both the coverage read and the run read
use that one variable, so it cannot compare one target's proof against
another's backup, nor against a retention timestamp.

**The two timestamps in the Nov 2 report measured different things, and both
were true.** `Last backup 8h ago` is the aggregate heartbeat
`$DOMUM_LOG_DIR/last-success`, touched at the END of a successful nightly run.
`Reconciled at 2026-10-29T10:55:03-04:00` is when `verify-snapshot-coverage`
last reconciled the asset table against a snapshot's file list -- about
`fb948da5`, the 10-29 02:31 backup. Neither contradicted the other; what was
missing was any statement that the coverage figures described a snapshot four
runs old.

**Debian's kernel changelog is ONE cumulative entry and cannot establish a
per-version CVE delta.** `/usr/share/doc/linux-image-6.12.113+deb13-amd64/changelog.gz`
names **1,532** CVEs across the whole 6.12.x series, and the
`New upstream stable update` block lists every `ChangeLog-6.12.*` without
delimiting them -- so extracting "the top stanza" yields 70,894 lines and the
same 1,532 CVEs. What local metadata DOES establish: `linux-image-amd64
6.12.113-1` is installed, its archive is `trixie-security`, and the entry is
`urgency=high`, so Debian classes it a security update; and the running kernel
is **6.12.111**, so whatever 6.12.112 and 6.12.113 changed is not in effect.
**Never claim a specific vulnerability is fixed, or that any is exploitable
here, from this file.** A newer installed kernel establishes only that the
running one predates it.

**A fixture must redirect `REPO_META_DIR`** -- it defaults to
`/var/lib/domum-media/backups`, a host path. Unredirected, the new check reads
production, and on this host fails for permissions, which would have made the
assertion pass for the wrong reason.

**I hit the `[[ … && false ]]` trap that this file already documents.** The
mutation was written `&& false` inside `[[ ]]`, where the bare word is a
non-empty STRING rather than the command, so it applied textually and changed
nothing. The prescribed form -- mutating the comparison into `"$a" != "$a"` --
is prescribed precisely because it has no such ambiguity.

**2026-11-01 scheduled run: both operations succeeded, and the exit-11 finding
cleared for the right reason.** `Main PID … status=0/SUCCESS`; retention ran at
03:32:40 -05:00 and forgot 14 snapshots, pruning 588 blobs / 168.105 MiB,
leaving 243802 blobs / 207.503 GiB. The 10-18 -> 11-01 retention gap is closed.
The check's own output was truncated by the operator's `-n 120`, but it is
proved structurally: `--check` is the FIRST unprefixed `ExecStart`, so retention
could not have started had it failed, and `Result=success` on a oneshot requires
every unprefixed `ExecStart` to succeed. The finding disappeared because the
unit RAN AGAIN and replaced `ExecMainStatus`, not because anything suppressed
it.

**The "5 security updates" are the least urgent pending items.** Measured
2026-11-02: they are one source package -- vim, vim-common, vim-tiny,
vim-runtime, xxd -- not referenced by any unit or by this project's code, with
no vim process running, and containers use their own image userland, so the
exposure is an operator opening a malicious file. `tzdata` 2026c->2026f is not
security, and DST ended correctly under 2026c. The genuinely security-relevant
change is `linux-image-6.12.113`, already installed against a running 6.12.111,
and it appears in the report only as `Reboot required`. **Urgency classification
was deliberately NOT added**: apt's metadata is not a reliable severity source,
and a confident wrong severity is worse than none.

**WEAR reached the weekly report and never reached the notifier.**
`checkup_disk_health` read only `smart_status.passed` -- the drive's own
opinion -- while the report has shown interpretable wear since the HTML work.
So a drive approaching end of life appeared in a document nobody is paged by
and could never become a finding or an email. `checkup_disk_wear` closes that,
reusing `mreport_smart_interpretable` rather than copying it, with three
outcomes kept apart:

| state | class | mails |
|---|---|---|
| interpretable, wear healthy | `healthy` with the figure | no |
| interpretable, wear <= `DISK_WEAR_WARN_PERCENT` (20) | **critical** + read-only confirmation | **yes** |
| placeholders, or no wear attribute | `advice` -- "not evidence of health" | no |

Measured on this host: sda reports 99%, sdb gets the advisory because all 30
attributes read alike after 3054 hours. The unavailable case is deliberately
**not a warning** -- it is permanent on that drive and it holds only a
rebuildable OS, so a weekly alert nobody can act on would train the operator to
ignore the report -- and deliberately **not healthy**, because unavailable wear
information is not evidence of health. The threshold cannot fire here today
(0.52% of 600 TBW used), so it is a guard rather than a finding, which is what
makes it compatible with the recorded decision NOT to threshold raw attributes:
the interpretability guard is the whole safety, and the mutation that ignores it
turns sdb's placeholders into a confident "100% of life remaining".

**`DISK_WEAR_WARN_PERCENT` is defaulted AT THE USE SITE as well as in
`load_cfg`.** A variable set only by `load_cfg` is unbound for any caller that
has not run it, and under `set -u` that kills the shell -- the defect that once
made `checkup` print nothing at all.

**"TRENDS (WEEK BY WEEK)" was not weekly, and the scheduled job never fed it.**
Three facts, each read from the source rather than assumed:

- rows are keyed on `date -I` and deduped to that day's last run, so a row means
  "a day the report ran";
- `mreport_trend_line` takes the last **8 ROWS**, and nothing makes them a week
  apart;
- **`mreport_append_history` is called only by `mreport_weekly_cmd`.** The
  weekly unit runs `report --write`, which dispatches to the report LIBRARY and
  never appends -- as that function's own comment says. So the series is fed by
  MANUAL runs only, which is exactly why production showed two points under a
  heading promising eight weeks.

The heading is now `TRENDS (LAST 8 OBSERVATIONS)` and the axis prints its real
span, because two observations five days apart and two a month apart are
different things and a fixed heading cannot tell them apart.

**A DRY RUN appended a history row.** A preview that mutates the series the
report then draws is the same class of side effect as a preview that sends
mail, and this file already holds that a preview never sends. The render suite
stubs the writer, so the test replaces that stub with a RECORDER and asserts
whether the CALL HAPPENS -- the mode gate is what changed, not the writer.

**Deliberately NOT done: pointing the weekly unit at the new report path.** It
would make the series genuinely periodic, and it is a systemd change under a
production freeze as well as a decision about whether the scheduled job should
drive the new report at all. Reported, not taken.

**A REMEDY IS NOT A REQUIREMENT, and conflating them made the report cry wolf.**
Production, 2026-10-29: the weekly report said `ACTION REQUIRED (4)` on a
healthy host. The four "actions" were an optional image cleanup, two
suggestions to read about rebooting, and a line that literally began
`no action needed`. Nothing needed doing.

The cause was structural. `CHECKUP_ACTIONS` was **both** the remedy list and
the escalation signal -- `health_verdict` reads it and so does the notifier's
silence gate -- so attaching a helpful command to a routine finding promoted the
whole report to ACTION REQUIRED and mailed it. The symmetric half was worse: the
four routine warnings had been left deliberately **remedy-less** to keep them
quiet, which made the quiet findings also the undiagnosable ones.

`CHECKUP_ADVICE` splits the two. The classes and what each one DOES:

| class | meaning | verdict | mails |
|---|---|---|---|
| `healthy` | measured good | — | no |
| `advice` | a remedy the operator MAY apply | — | **no** |
| `warning` | worth knowing | `WARNINGS` | no |
| `action` | the operator MUST act | `ACTION REQUIRED` | **yes** |
| `critical` | failure, or protection that cannot be verified | `CRITICAL` | **yes** |

Driven against the exact production finding set, the verdict becomes
`WARNINGS (6)` with **0 actions** -- so the silence gate holds and nothing is
mailed. Reclassified as advisory: the image cleanup, both reboot suggestions,
`reset-failed` on a superseded unit, and the `no action needed` line.

**The split is what finally let the routine warnings carry commands.** Before
it, giving "6 update candidates are waiting" a remedy would have started mailing
it weekly. All six routine findings now have a read-only advisory, and the
pairing contract got STRONGER rather than weaker: `warning-remedy-smoke` used to
require EXACTLY FOUR warnings with no remedy at all, and now requires **zero** --
every warning must carry an action or an advice, because a warning with neither
is a finding nobody can act on.

**It also found a warning that was only paired by ACCIDENTAL ADJACENCY.**
`N containers are exited` had no remedy of its own; it merely sat within seven
lines of the cleanup-images action, and inserting a comment exposed it. The
same window caught the reboot pair twice. **A comment between a warning and its
remedy pushes the remedy out of the pairing window** -- put the explanation
ABOVE the pair. That is now three occurrences of this one mistake.

**A CRITICAL with no remedy is worse than a warning with none**, and the backup
criticals had none: `Last successful backup is Nh old` and
`No successful backup timestamp found` -- the two findings that say the
photographs may be unprotected -- offered no command at all. Both now name a
read-only diagnosis, as does a Btrfs checksum failure, whose remedy says to read
the kernel log (which NAMES the file) and explicitly **not** to attempt a
repair, because data is single-profile here. The config-validation criticals
(`DOMUM_DOMAIN is empty`) are deliberately left bare: they name the exact
variable, which IS the remedy.

**An ALERT mail carries ACTIONS only.** Advisories are omitted from it
deliberately: a message sent because something needs attention must not be
padded with things that do not. They appear in `checkup` and in the full weekly
report under `OPTIONAL MAINTENANCE`, introduced by "nothing here needs doing
this week".

`tests/severity-taxonomy-smoke.sh` drives fifteen scenarios through REAL check
functions and then through the real `health_verdict` and the real silence gate --
healthy, routine maintenance, staged images, pending reboot, superseded restic
lock, current lock failure, corruption, backup gap, pending originals,
window-unknown originals, absent evidence, unreadable disk, failed disk. The
routine-maintenance case is asserted as a **DELTA** (turning maintenance on must
add warnings and advice and **zero** actions), because the aggregate collector
runs every check and a fixture cannot satisfy them all -- pinning the whole
verdict would mean asserting fixture artefacts. The delta is also required to be
non-empty, so it cannot pass by measuring nothing. The mutation folds advice
back into actions and must make a quiet host mail again; it adds 6 spurious
actions.

**A warning with no paired action NEVER mails, and seven real problems were in
that state.** `health_notify_cmd`'s silence gate sends only when
`CHECKUP_CRITICAL` or `CHECKUP_ACTIONS` is non-empty, by design -- warnings
alone are "expected activity", which is what stops a weekly mail saying
"3 general package updates are available". But seven warnings carry no remedy
and are therefore invisible to the notifier:

| warning | why it matters |
|---|---|
| `<service> is UNHEALTHY` | a container healthcheck failing |
| `<service> is not running` | a service is down |
| `<path> is N% full` | the protected tier filling up |
| Btrfs error counters **could not be read** | that counter IS the photo-tier corruption signal |
| Btrfs scrub status could not be read | the corruption check cannot be seen |
| Btrfs scrub history could not be parsed | same |
| restic password file looks very short | a backup credential problem |

**Fixed by adding a remedy to each, NOT by making warnings mail.** The other
four non-notifying warnings -- package updates available, update candidates
waiting, Immich bundle candidate -- are routine and must stay silent, or the
operator starts getting weekly mail about available updates and stops reading
it. The Immich UNKNOWN-timing coverage DID get a remedy, because this file
already says a gap and an unknown are numbered risks while a pending upload is
not. `tests/warning-remedy-smoke.sh` asserts both directions and requires the
non-notifying set to be EXACTLY those four, so a future warning added without a
remedy fails CI.

Two rules the remedies themselves had to obey:

- **The remedy for a stopped service is `compose start`, NEVER `up -d`.**
  `up -d` reconciles, so a routine "start it again" would recreate the container
  on whatever the tag now resolves to -- turning a restart into an unreviewed
  deployment. Asserted, in both directions.
- **It must name the COMPOSE services, not the logical one.** `immich` maps to
  four containers, so `docker logs immich` would fail on the one service where
  being told about a failed healthcheck matters most. Both container remedies
  resolve `service_compose_services`.
- **The short-restic-password remedy suggests no restic operation and prints
  nothing.** Rotating a repository password needs approval and is not a routine
  remedy; the likely cause is a truncated write, so that is what it checks.

**A stub of a function nobody calls is not a stub, and it made two sections
test the HOST.** Both notifier sections stubbed `checkup_run_all`, which does
not exist -- `health_notify_cmd` calls the four checks directly -- so the real
checks ran against this machine and the "it mails" section passed only because
the host happened to produce an action. Related, found in the same sitting:
`health_notify_cmd` RESETS all four arrays at entry, so an action seeded by the
caller is wiped; the action has to be added BY one of the checks. And asserting
"it did not take the silent path" is satisfied by dying in between, so the
positive form -- the transport was reached -- is asserted too.

**A negative control is what makes a notification assertion falsifiable.**
"An action does not take the silent path" would pass against a notifier that
never prints that line for any input. The healthy case -- a routine warning,
zero actions -- is required to take it.

**`grep -A3` is a dependency on comment length.** Three pairing assertions
failed against correct code because an explanatory comment sits between the
warning and its remedy. The window has to exceed the comment, and the
comment-stripping pass is what keeps a note saying "deliberately does NOT
suggest `restic key`" from tripping the assertion that no restic operation is
suggested.

**Asserting on a bare function name flagged my own comment.** The check that no
stub of the non-called collector remains matched the comment explaining why it
must not be stubbed. Assert on the DEFINITION form (`name() {`), the same
mistake the capability audit and the stdout-purity audit each made once.

**THE SCRUB IS NOT READ-ONLY, and I called it read-only in thirteen places.**
The operator asked whether the implementation passes `-r`. It does not:

```
btrfs scrub start -B ${limit:+--limit "$limit"} "$root"
```

`btrfs-scrub(8)` is explicit -- *"read-write scrub will also automatically
repair any damage by copying verified good data from one of the other
replicas"* -- and Metadata and System on this filesystem are **DUP**, a
replicated profile. So a default scrub **writes**: it rewrites a corrupt
metadata block from its second copy. The claim appeared in the runtime message
the operator actually reads, in two `checkup` remedies, in the unit's
`Description=`, in the function header, in the lock justification, and five
times in the plan document -- including *"it never writes, never moves data,
and cannot be the cause of corruption"*, which is three false statements in one
sentence.

This is the defect family this whole file exists to correct, committed by me in
the middle of correcting it: a report describing an operation as something it is
not. Nothing was harmed -- repairing DUP metadata is the desirable behaviour --
but the operator was told the blast radius was zero when it was not.

The accurate statement, per profile:

| profile | on a checksum error | writes? |
|---|---|---|
| `Metadata: DUP` | **corrected** from the second copy (`corrected_errors`) | **yes** |
| `System: DUP` | corrected, same mechanism | **yes** |
| `Data: single` | reported (`uncorrectable_errors`) -- no second copy | no |

Two consequences worth keeping:

- **`exit 3` means DATA corruption specifically.** A metadata error would have
  been corrected and exited 0, so "uncorrectable errors found" on this
  filesystem can only be the half that has no second copy.
- **`-r` is deliberately NOT passed.** Refusing to fix metadata the filesystem
  can fix would leave it knowingly damaged. A read-only detection pass, for a
  disk already suspected of failing, is `btrfs scrub start -r -B` run directly;
  the CLI does not wrap it, because a second mode is a second thing to get
  wrong.
- **The "no operation lock" decision survives but its justification does not.**
  It was argued from "a scrub is read-only". The real reasons are that btrfs
  serialises scrubs itself, that a metadata repair is an internal consistency
  operation, and that holding the global lock for 7-26 minutes could fail the
  nightly backup.

**A measured operation can still be described wrongly.** The scrub ran, was
clean, and was reported accurately in every numeric respect -- 215.87 GiB,
7m14s, 509.34 MiB/s, zero errors -- while the sentence next to those numbers
mischaracterised what the command does. Measuring the outcome is not the same as
describing the mechanism, and only reading `--help` and the man page caught it.

**`health-notify` ran only a SUBSET of the checks, and that silently undid the
remedy work.** `health_notify_cmd` called the four EXTRACTED checks
(`checkup_systemd_health`, `checkup_btrfs_health`, `checkup_disk_health`,
`checkup_immich_offsite`) while every other check is INLINE in `checkup_cmd`'s
310 lines. So a container going UNHEALTHY, a service down, or `/srv/data`
filling up could appear in `checkup` and **never be mailed** -- and the remedies
added for exactly those cases were unreachable from the notifier. I had reported
that gap as closed, having verified the remedies existed and that `checkup`
showed them, without verifying that the notifier RUNS those checks.

`checkup_collect_all` is now the one collection, used by `checkup`,
`health-notify` and the weekly report. A mutation reverting the notifier to the
four-check subset must fail. This is "commands that answer the same question must
read the same evidence" one level deeper than it had been applied: the same
*question*, different *collections*.

**The `CHECKUP_*` arrays are declared at FILE SCOPE.** `${#arr[@]}` on an unset
array is an unbound-variable error under `set -u`, so `health_verdict` would have
killed the shell if it were ever reached before a collector reset them. Every
caller resets first, which is precisely why it was invisible -- the same shape as
the unbound variable that made `checkup` print nothing at all in production.

**The weekly report's plain text IS the source; the HTML wraps it.** Adapted
from `domum-core` (`report_render_weekly*`), studied from a read-only clone.
The HTML renderer re-derives nothing: it wraps the rendered text line by line,
keyed on PREFIX (box drawing, `> `, `Verdict: `, `-- SECTION`) and coloured by
the escalation GLYPH the text already carries, so the two MIME parts cannot
disagree about a number. The line grammar is load-bearing -- changing it changes
the HTML. `domum-media report weekly [--stdout|--html|--email|--dry-run]`;
PREVIEW NEVER SENDS and a mutation that makes `--stdout` send must fail. See
`docs/WEEKLY-HTML-REPORT.md`.

Two things from `domum-core` deliberately NOT copied: its **POWER** section,
which reads Raspberry Pi wattage via `vcgencmd` (no trustworthy N100 source, and
a test requires POWER to be ABSENT), and its **missing header sanitisation** --
`send_email_body` interpolates the subject with no CR/LF guard, a
header-injection hole by construction even though its subject is a controlled
verdict. `mreport_header_safe` strips CR, LF and NUL from every header value.

**The verdict is four-level and SHARED with the notifier, and the subject
derives from it.** Without that, a `--force` send on a warnings-only host
carried the subject "healthy" over a body saying "WARNINGS": two answers to one
question inside one email. The silence GATE is unchanged and is not part of the
verdict -- warnings still mail nothing.

**A report must do no recovery work.** No restic call, no asset-table query, no
byte downloaded: the Immich counts come from the RECORDED coverage evidence, and
a test asserts the renderer contains no `restic`, no
`immich_original_inventory` and no `docker exec … psql`. Trends refuse to invent
history -- fewer than two recorded rows says so and draws nothing, because one
current measurement spread across eight weeks is a fabricated chart.

**`email.message_from_file` corrupts a verified-correct message.** On a TEXT
stream `get_payload(decode=True)` round-trips through `raw-unicode-escape` and
manufactures `\uXXXX` for every box-drawing character, so a correct
`multipart/alternative` looked broken and the box glyphs appeared lost. The
bytes were fine -- `xxd` showed `e2 94 80` and the file contained zero literal
`\u25` sequences. Use `message_from_binary_file`. My verification was the
defect, not the code.

**`grep -E` does not interpret `\xNN`, and three of my assertions were
therefore VACUOUS** -- including the one asserting that NO sparkline is drawn
without history, which could never have matched whatever the code did. Use
ANSI-C quoting (`$'\xe2\x9c\x97'`) or a literal character when asserting on a
glyph.

**The HTML was verified against the REAL reference, by diff.** Both renderers
were fed the same synthetic report and their output compared: normalising
colours and text, the structure is IDENTICAL -- same tags, same nesting, same
style shape -- and the only colour difference is one deliberate divergence.
Comparing screenshots by eye, or checking contrast ratios alone, would not have
established that.

**The one divergence from `domum-core`'s palette is an accessibility fix.** Its
dim (`#5f7263`) measures **3.43:1** against `#141a15`, below WCAG AA for body
text, and it is used for the 11px footer; lifted to `#748978` (4.71:1). A test
recomputes every text colour's ratio from the rendered HTML, so a future palette
edit cannot silently regress contrast.

**The two MIME parts are proven to carry the same VALUES, not just the same
words.** Every `label  value` row in the text part must appear, unescaped and
tag-stripped, in the HTML part -- 23 rows on a healthy report. That is what
makes "the plain text is the source" an observation rather than a design
intention.

**The longest line in a critical report is 84 characters and it WRAPS.** About
655px at 13px monospace, wider than the 600px column. `white-space:pre-wrap` on
every body block, no `nowrap`, no `<pre>`, no element above the cap -- so no
horizontal scroll on a phone. Wrapping beats truncation because the operator
has to copy the command. All four conditions are pinned.

**Monitoring completeness is proven through the three real commands.**
`tests/monitoring-completeness-smoke.sh` builds ONE fixture with five genuine
problems -- an unhealthy container, a stopped service, a filesystem at 96%, a
four-day-old backup, and a non-zero `corruption_errs` -- and requires
`checkup`, `health-notify` and `report weekly` to each see all five. The
collection is deliberately NOT stubbed. The mutation reverting the notifier to
the four-check subset loses three of the first four problems **while the
mutant's `checkup` still sees them** -- which is exactly what made the gap
invisible: one command looked complete while the notification was not.

**Stubbing a function the caller no longer invokes is dead stubbing, and it
makes a fixture reach the host.** Two suites stubbed the four individual checks
after `health_notify_cmd` began collecting through `checkup_collect_all`; the
stubs did nothing, the real collection ran against the host fixture, and the
notifier was never silent. When a call site moves, the stubs move with it.

**Client compatibility is proven by SIMULATING what each client strips, not by
grepping CSS.** `tests/fixtures/email-client-simulation.py` applies each
client's documented transformation and requires the report to survive it:
Gmail removes `<head>` and `<style>` (body text must come out
**byte-identical** -- measured 2258 characters either way -- with the cursor
animation the only casualty, and the inline colours and `bgcolor=` fallback
intact); Apple Mail keeps the style block and the `color-scheme` hints; the
Outlook Word engine needs a table layout and none of the CSS it drops; and with
ALL markup removed the findings must still be there. A CSS grep proves none of
that.

**`tests/fixtures/` holds helpers, and the CI audit now tells them from
suites.** A helper needs no workflow step -- most cannot run standalone -- but
excluding a directory could let one become dead, so each must be INVOKED by a
suite the workflow does run. That is strictly stronger than requiring a step,
and an orphan helper fails the audit.

**Neither renderer puts the word "Verdict" in the HTML**, and that is
faithfulness, not a loss: both strip the prefix and render the severity in a
bordered box. The test asserts the box's structure and that it contains the
severity as a WORD, because a coloured border alone is not an accessible
signal.

**A backtick in a double-quoted string is command substitution, in a test
title as much as in a heredoc.** A `sect` heading that quoted the word *report*
in backticks EXECUTED it, printed `command not found`, and silently deleted the
word from the heading -- so the test's own description lied about what it
tested. Same class as the `--help` heredoc defect this file already
records.

**The argv path is asserted, not assumed.** `main report weekly --stdout` is
driven through the real dispatcher, alongside proof that `report --json` still
delegates to the report library and that an unknown `weekly` flag is refused --
a function that works when called directly but is unreachable through the
dispatcher is the defect the capabilities audit exists for.

That assertion passed here and failed in CI, for the fourth time this session:
`report --json` loads the report LIBRARY, and `load_report_lib` looks for it at
`REPORT_LIB_DEFAULT` -- an INSTALLED path that exists on this machine and not on
a runner. The fixture now points `DOMUM_DIR` at the repository and blinds
`REPORT_LIB_DEFAULT`, so the repository's own copy is what loads either way.
Every root a fixture uses must be redirected into it, and that includes the
paths a function falls BACK to.

**The first real HTML report downgraded a failed domum unit to a warning.**
Production, 2026-10-27: it said *"systemd unit ● has failed."*
`systemctl --failed --no-legend` still prints the leading bullet, so the
parser's `$1` was `●` -- and because `●` does not match `domum-media*` the
`case` fell through to the generic branch. **A FAILED domum-media unit was
reported as a generic warning with a meaningless name**, and the real failure
surfaced only because a separate loop reads each timer's last exit status. The
field is now selected by looking like a unit NAME rather than by position, which
is presentation-independent; a line with no recognisable unit is reported as
unparseable rather than given an invented name.

**`restic` exit 11 means THE REPOSITORY IS ALREADY LOCKED** -- read out of the
binary's own exit-status table, not from memory (10 is "does not exist", 12 is
"password is incorrect"). The project contains no `exit 11`, so a status 11 from
`domum-media-check.service` is restic's, and it means the integrity check **never
ran**: the repository is UNVERIFIED, not damaged.

Two consequences, one easy to miss. `--weekly-retention` is the SECOND
`ExecStart` with no `-` prefix, so a locked check also **skipped retention** for
that week -- safe in direction, silent in cause. And the timers are only
~45-56 minutes apart (`backup` daily 02:30 +15m, `check` Sun 03:30 +20m), so a
transient lock converts into a whole week with no integrity check and no
retention, **with no retry**. Measured for scale: the 2026-10-27 backup took
**37 seconds**, so the gap is normally ample; which process held the lock on
2026-10-25 cannot be established without the journal. See
`docs/FIRST-REPORT-TRIAGE.md`.

**A finding must name the CONTAINER, not just the logical service.** The report
said *"immich is UNHEALTHY"* while all four immich containers were running and
only `immich_machine_learning` was unhealthy -- the operator had no way to know
which to look at. `service_unhealthy_members` names them;
`service_health_state`'s single-word contract is unchanged because other callers
depend on it.

**"Up 7 of 8" counted LOGICAL SERVICES and read as missing containers.** immich
is one service mapping to four containers, so 8 enabled services with one
unhealthy looked like three of eleven containers being down. The report now
states the logical count, the container count, and each health class
separately -- `Healthcheck passing`, `No healthcheck`, `UNHEALTHY`, `Stopped`,
`Unknown` -- because adding "healthy" to "running with no healthcheck" is the
claim this project forbids.

**A remedy must be read-only first, use the project's wrapper, and contain no
placeholder.** The first report suggested `systemctl status <unit>` (a literal
placeholder), bare `docker compose logs` (bypassing the layered fragments;
`domum-media compose` is the wrapper), and `host-upgrade --force` for a merely
PENDING reboot -- which installs packages and may reboot. The reboot remedy now
shows `list-timers` and names the consequence that matters: every timer is
`Persistent=true`, so a reboot runs missed jobs immediately, **including
`snapshot prune`, which deletes**.

**An exact-duplicate finding is now suppressed.** A failed unit is found both in
`systemctl --failed` and in its timer's last exit status, and printing the
identical text twice made the host look twice as bad as it was. Only identical
text is dropped -- a differently-worded finding about the same thing is a wording
problem, not something to hide.

**`sed 's/#.*//'` deletes a remedy's own annotation, so a PRESENCE assertion
must read the raw source.** Comment-stripping exists for "does not contain"
assertions; the remedies annotate their commands after a `#`, and that text is
operator-facing, not a code comment. Two assertions failed against correct code
before this was separated.

**A mutation's own `assert` was SWALLOWED, and the suite failed somewhere
else.** The mutation heredoc in `warning-remedy-smoke` had no `|| fail`, so when
its target text changed the python exited non-zero unnoticed and the suite then
failed with a confusing *"got 4, expected 5"* orphan count -- pointing at the
wrong thing entirely. "Assert that a mutation actually applied" is not enough if
the assertion itself can be ignored: wrap the heredoc in a subshell with
`|| fail` naming the cause.

**A remedy must stay textually ADJACENT to its warning, because that is what
the pairing check can see.** Emitting one `systemctl status` after the loop
instead of one per unit moved it outside the 7-line window: the warning still
mailed, but `warning-remedy-smoke` could no longer see the pairing and counted
it as orphaned. Widening the window was the wrong fix -- it would have weakened
the mutation that depends on the same window. Emitting the remedy per unit
inside the loop restores adjacency AND is more actionable, since each failed
unit gets a command naming only itself.

**"A successful backup proves no lock is held" was WRONG, and it was a
confident wrong answer about whether a live problem was still live.** The
journal named the holder: a lock created **2026-10-20 10:47:46 from the
operator's Mac** (`PID 14058 on lamac`), still present **112h49m** later. I had
reasoned that the nightly backup takes "the same repository lock" and had
succeeded, therefore no lock remained.

`check` logs `create exclusive lock for repository`; the nightly backup kept
succeeding *alongside* that lock every night. So the Mac's lock **coexists with
`backup` and blocks the exclusive lock `check` needs**. A successful backup
proves only that no EXCLUSIVE lock is held -- it says nothing about the lock
that was actually there. **Never reason from "the same lock" when two commands
take different lock types**, and prefer the journal over an inference when the
journal exists.

**A stale lock recurs, and silently blocks retention as well.** The check fails
every Sunday until the lock is removed, and `--weekly-retention` is the second
`ExecStart` with no `-` prefix so it never runs -- and `forget`/`prune` need an
exclusive lock themselves, so they would fail anyway. Measured from the
journal: retention last succeeded **2026-10-18** (7 snapshots removed, 17.044
MiB pruned) and has not run since. Snapshots accumulate, which is the safe
direction, but nothing says so.

**restic exit 11 now has its own finding, scoped to the check service.** A bare
"exited non-zero (status 11)" reads like possible corruption. It now says the
repository could not be LOCKED, that the check therefore **never ran**, and --
explicitly both ways -- that this is *"not evidence of damage, and not evidence
of health either"*. The remedy names `restic unlock` and that it needs
approval, rather than offering a command to paste. Exit 11 from any other unit,
and any other status, is still reported generically: 11 only means "already
locked" for the command that takes that lock.

**`domum-media-backup --unlock <target>` is the stale-lock remedy, and it
exists because I first documented one that did not.** The triage doc offered
`--unlock-stale`, which was never implemented -- the rule this file already
states, broken in the one place the operator most needed a working command. It
is a thin wrapper because `restic unlock` needs the repository credentials and
only `restic_for_target` knows how to assemble them (password file, SFTP
command, env files).

Safe by restic's own definition, quoted from its help: *"The 'unlock' command
removes stale locks that have been created by other restic processes."* Only
locks restic considers STALE are removed, a live process keeps its own, and
restic 0.18.0 has no flag to force-remove a live lock -- so it cannot interrupt
a running backup. The wrapper lists the locks before AND after, read-only, so
the operator sees the effect; it never passes a force flag; it refuses an
unknown or disabled target; and it is referenced by **no systemd unit**. All
four are tested.

**The pipefail audit caught `cmd | grep -q` in the remediation command I had
just written.** `enabled_backup_targets | grep -qxF "$target"` in
`do_unlock_stale`: under `pipefail` a MATCH makes the left side take SIGPIPE,
the pipeline reports 141, and a **valid** target would have been rejected --
the "die on valid input" family, in the one command the operator needed in
order to fix a live problem. Seventh instance. Captured first, and the refusal
now also prints the enabled targets. The audit existing is why this was a
two-minute fix instead of a support question.

**A stale FAILURE stated in the present tense is the same defect as a stale
proof, and it told the operator to redo work they had already done.**
Production, 2026-10-25 to 10-28: the scheduled check exited 11 against a stale
lock; the operator removed the lock on 10-27 and the check passed, and passed
again on 10-28 with no lock present beforehand (22 → 23 snapshots, `no errors
were found` both times). **systemd keeps a unit's failed state until THAT unit
runs again** -- a manual `domum-media-backup --check` does not clear it -- so
`checkup`, driven against the real state three days later, still said the
integrity check *"never ran"* and still sent the operator to an approval-gated
`restic unlock`. Every word was true of the 10-25 run and false of the present,
and it would have repeated until 2026-11-01.

Nothing could have known: `do_check` and `do_weekly_retention` recorded
**nothing**, while per-target backup runs had recorded evidence for months. Both
now write `<target>-{check,retention}.env` beside it, 0600, with a `MODE` field
-- because a structure check is not a read-data verification and not a restore
test, and collapsing them would advertise a verification that never happened. **A
manual run is recorded exactly like a scheduled one**: the operator's
remediation has to become evidence, or the report can never see that it worked.

`check_unit_verdict` is the ONE implementation, consulted by both places that
report this unit; two copies would be two chances to call a resolved problem
current. Rules it follows, each the safe direction:

- **`superseded` requires EVERY enabled target, never one.** One repository's
  clean check says nothing about another's -- the per-service upgrade gate's
  reasoning.
- **Absent evidence changes nothing.** A fix that only reads correctly once new
  evidence appears would silence a live finding in the meantime.
- **An unreadable timestamp is `unknown`, not `superseded`**, and a recorded
  FAILURE is never read as a success.
- The `restic unlock` advice is **not** repeated once superseded, and the remedy
  becomes `systemctl reset-failed`, which touches no repository, no data and no
  container.

**The exit status is PRESERVED through the new recording.** restic exit 11 is
the entire mechanism by which a locked repository fails the unit; swallowing it
to make room for an evidence write would be "warn and continue" in the one place
it must not be. Both operations capture the status, record success or failure,
and return it unchanged.

**A standalone "retention is overdue" check was deliberately NOT added.** Its
input cannot exist until retention next runs, so deploying it would mail
"retention status unknown" on a healthy host immediately -- a false alarm
manufactured on purpose, in the path whose whole value is that silence means
something. Retention recency is surfaced INSIDE the already-critical
check-failure finding instead, with its recorded date, because "retention is
blocked" does not say how many weeks of snapshots have accumulated.

**Two findings about one unit share one remedy line.** The `--failed` summary
and the exit-status detail both report the check service, so the remedy is
worded IDENTICALLY in both branches and `checkup_add`'s exact-duplicate
suppression collapses it. Differing comments on the same command showed the
operator the same line twice.

**A test asserting the absence of "never ran" was wrong, not the code.** Scoped
to *that run* the phrase is accurate and worth keeping; what must disappear is
the unscoped present-tense form and the "not evidence of health either" clause,
which stops being true once a later check has passed. Before adapting a test to
a change, ask which of the two is wrong. `tests/restic-op-evidence-smoke.sh`
(3 mutants, all killed) and five production-shaped sections plus a gate mutation
in `tests/monitoring-completeness-smoke.sh`. See `docs/FIRST-REPORT-TRIAGE.md`.

**A SELECTIVE capture pays 2.5% of the bytes for the whole recovery, and that
ratio is why it is selective.** Measured 2026-11-02 across the five migrated
services: 352.28 MiB of state directories, of which **8.90 MiB is
irreplaceable**. Plex's `Drivers/` is 230.6 MiB and is downloaded on demand;
navidrome's `cache/` is 95.4 MiB of transcodes; kavita's `backups/` is 3.5 MB,
**3.1x the database it backs up**. So `service_essential_state` DECLARES what
is essential per service rather than taking the tree, and the regenerable
subtrees are excluded by name with the measurement beside them. Tests assert
both directions -- the declarations must cover the databases, the configuration
and jellyfin's `.aspnet/DataProtection-Keys`, and must NOT cover
`Drivers`/`cache`/`backups`/`logs`.

**Nothing is captured off-site yet. `storage capture-state` writes to a
directory the operator names, and no backup target includes it.** Activating
coverage is an operator decision that needs the archive size first.

**A capture missing a declared item is NOT a backup, so it fails closed.**
`service_state_capture` records `RESULT=INCOMPLETE`, names the missing item in
the manifest, exits 1, and `service_state_verify` then refuses the capture
outright. The mutation that accepts a missing item must make a partial capture
read `COMPLETE` -- which is the "warn and continue" failure in the one place
where the operator would discover it during a recovery.

**`CAPTURE_MODE` is `consistent` only where the APPLICATION ships an sqlite3.**
Measured: plex (`Plex SQLite` 3.39.4), navidrome (3.45.3) and calibre-web
(3.45.1) have one; **jellyfin and kavita have none, and neither does the
host**, so their captures are recorded `unproven` and never claimed otherwise.
`.backup` and `integrity_check` run INSIDE the container, which is the only
SQLite that can read plex's `collating` FTS tables. navidrome's database is
WAL-mode with a live 20,632-byte `-wal`, so a plain file copy there is torn --
which is why the declaration was added.

**The capture digests DIRECTORIES including their MODES.** Jellyfin's
DataProtection keys are 0600 and they decrypt its stored secrets; a restore
that widened them would be a disclosure, and a digest over contents alone
would verify clean. A test widens a captured key to 0644 and requires
verification to fail.

**The manifest records `IMAGE_ID`, because state alone is not a recovery
point.** This file already holds that a recovery point is service + snapshot +
the application that wrote it. A capture is the snapshot half.

**A RESTORE never writes into live state, and the refusal is on RESOLVED
paths.** `service_state_restore` takes a scratch target and refuses it when it
equals, contains or sits inside `service_data_path`, because a symlink or a
`..` would otherwise walk straight into the running service's tree -- a
production mutation wearing a verification's clothes. It also refuses a
non-empty target (restored content could not be told from what was already
there) and refuses a capture that does not verify. The mutation that
neutralises the overlap comparison must make a restore actually write inside
the live tree.

**The proof is the RESTORED bytes, not the copy's exit status.** Every item's
digest and mode are recomputed after it lands, and a restored database is
opened: a digest proves the bytes arrived, not that they are a usable
database. Measured in the suite -- a database corrupted before capture
restores with a perfectly matching digest and must still fail. And the restore
states its own limit: it proves the CAPTURE restores, never that the service
runs against it.

**"I could not check it" is not "it is broken" -- and I wrote that defect into
the new restore.** Its first classification sent anything that was not `ok` or
`unsupported:` to "not a sound database", so on a host with no sqlite3 a
`command not found` read as corruption. The same family that once reported
plex's two sound databases as a failed recovery point. A tool failure, an
unopenable file and an absent SQLite are all `not checked`.

**A test stub must hide exactly what it means to hide.** The fixture's
`cmd_exists() { [[ "$1" != docker ]]; }` claimed EVERY other tool exists, which
sent `domum_sqlite_check` down its `sqlite3` branch on a host that has none.
It now hides docker and defers to `command -v` for everything else.

**A fixture database must be a database.** The jellyfin fixture wrote
`SQLite format 3\000library-rows` -- enough to look like one and not enough to
open -- so the restore's integrity check failed for the wrong reason and looked
like a code defect. It builds a real one with `sqlite3` now.

**The stored filename folds `/` and ` ` to `_`, so a COLLISION is possible and
is refused.** Plex's declared paths contain spaces, so `a/b` and `a b` map to
one name; without the guard one item would silently overwrite the other and
both recorded digests would read the same file. The capture records
`COLLISION` and fails closed.

**A file item's digest covers CONTENTS, so its MODE is recorded and compared
separately.** Plex's `Preferences.xml` holds the server token. A directory
item's digest already covers modes, which is what protects jellyfin's 0600
DataProtection keys; a file item had no such cover until the mode field was
added (`SCHEMA_VERSION=2`).

**The suite's `probe` runs `set +e`, so it cannot see an abort under
production's options.** The digest helpers are pipelines -- exactly the shape
that has aborted this project's functions before -- so one section drives
capture, verify and restore in their own `set -euo pipefail` bash process. A
test that relaxes production's shell options is not a test of production.

**Eighth instance of `cmd | grep -q` under pipefail**, four sites in one
sitting: three in the new suite and one I had added to
`sqlite-unsupported-smoke.sh` the session before, where a service that DOES
declare an sqlite binary would have read as declaring none -- an assertion
silently inverted. `tests/pipefail-grep-audit.py` found all four in seconds.
Write the capture-first form the first time.

---

**THE DISASTER-RECOVERY RUNBOOK OFFERED `nas` AS ITS PRIMARY RESTORE EXAMPLE.**
`docs/disaster-recovery.md` is the one document read while the host is gone, and
step 4 said *"Restore from your preferred backup target. Example (NAS):"*
followed by `--restore latest / --repo nas`. Measured: across 107 consecutive
nightly runs the rotated log contains `restic backup -> cloud` 107 times and
**zero** occurrences of `nas` in any form, there is no network mount on this
host, and no `/srv/nas*` exists. The first command an operator would copy under
pressure points at a repository that was never written. `cloud` is now the
example, with `--snapshots` given as the way to check a target has one at all.

Three more stale claims in the same document, each pointing the wrong way:

- *"Service-level Btrfs rollback is not currently available on production
  because service paths are ordinary directories"* -- false since 2026-09-25;
  **five** services are subvolumes with proof snapshots. It then told the
  operator to recreate "only the existing top-level layout", which happens to
  be right for a fresh host but for the wrong reason. The corrected text says
  why: a restic restore writes files, not subvolumes, so a recovered host
  legitimately has directories and `storage migrate-subvolume` is a separate
  gated operation not to be improvised under recovery pressure.
- *"The current CLI does not provide a guided PostgreSQL import command"* --
  stale. `verify-db-restore` imports into a disposable instance under
  `ON_ERROR_STOP=1` and has been proven against the real dump. There is still
  no guided import into PRODUCTION, which is the distinction the text now
  draws.
- **It never said the cloud target is immich-only.** The most important fact
  about a fresh-host recovery was absent: restoring from `cloud` brings back the
  photo library, the validated dump and the recovery pack, and the five media
  services come up as **fresh installs**. That is now a table, with the
  consequence spelled out per path.

**A runbook states which of its own steps have been executed.** The document
read as validated and none of it had been run end to end. It now opens with a
per-step table -- proven / partly proven / never executed, each with its
evidence -- and says plainly that the step never taken is putting any of it on a
different machine. `tests/documented-commands-audit.py` checks the commands
exist in the CLI (100 now), which is the weaker half: it cannot see whether a
procedure has ever been performed.

**A fact that appears twice: I updated the wrong copy.** `backlog/QUEUE.md` had
P4.5 in its P4 table and I had earlier appended a second P4.5 row to the P1
table; marking the work done, I edited my own duplicate and left the original
reading `open`. This file already records that changing one of two copies is
worse than changing neither, because the remaining copy now has a neighbour
vouching for it. The duplicate is removed and the original row carries the
result.

---

**THREE MORE `set -euo pipefail` ABORTS, where the PRODUCER may legitimately
find nothing.** The recorded family is "when a function's failure is EXPECTED
and handled, capture it with `|| true`"; these are three sites where it was
not, found by sweeping both CLIs with comments stripped and then **reproducing
each one standalone** before changing anything:

- **the nightly dump.** `pg_cid="$(docker ps --filter … -q 2>/dev/null | head -1)"`
  in `quiesce_immich_postgres`. An unreachable daemon makes `docker ps` exit
  non-zero, so the assignment failed and `set -e` killed the function **before**
  the `if [[ -n "$pg_cid" ]]` branch written to report the database as absent.
  The backup's highest-value stage, aborting instead of degrading.
- **`dr_immich_summary`.** Three `find "$lib/<subtree>" … 2>/dev/null | awk …`
  byte sums. `find` on a missing directory exits 1 and `2>/dev/null` hides the
  message, not the status -- so the report died part-way. The `${th_b:-0}`
  defaults a few lines below were already written on the assumption that an
  empty value is survivable, which is the tell. It aborts exactly where it is
  needed most: a freshly restored host, where the derivative subtrees have not
  been rebuilt.
- **phase B's live-photo selection.**
  `lp_img="$(grep '^livephoto image|' <<< "$sel_lines" | cut -d'|' -f2 | head -1)"`.
  A user with no live photo is the normal case, and grep finding nothing killed
  the function before its own `if [[ -n "$lp_img" ]]`. Measured: exit 1, and the
  `if` is never reached. It also carried the stop-early shape, so it is sliced
  with `sed -n '1p'` now and nothing can take SIGPIPE.

**An audit for this family is NOT shipped, deliberately.** `find` and `grep`
inside `$( )` are everywhere and most instances are genuinely guaranteed to
match, so a naive rule would cry wolf -- which this file already says is how an
audit gets switched off. A narrow form (a `find` over a PATH with no `|| true`
and no `[[ -d ]]` guard) looks tractable and needs its own mutation testing
before it can be trusted; it is queued rather than rushed.

**My own sweep read comments as code, for the fourth recorded time.** Grepping
for a boolean read through `jq`'s `//` flagged `.smart_status.passed // empty`
three times -- all three being the COMMENT that documents that exact defect and
its measured outputs. The shipped code uses `| tostring`. Strip comments first,
including when the thing being audited is this file's own history.

---

**I put a backtick in a comment INSIDE AN UNQUOTED HEREDOC, and two
independent controls caught it.** The comment explaining why the call must not
be short-circuited was written inside `<<STRICT`, so the backticked words were
command substitution: bash tried to run them when the heredoc was WRITTEN, the
words vanished from the generated script, and shellcheck reported `SC1070
Parsing stopped here`. `tests/log-hygiene-smoke.sh`'s repository-wide scan also
catches it -- verified by reintroducing one backtick and watching the suite go
from 0 to 1 -- so it was not a blind spot; I had simply run shellcheck first.
This is the second recorded instance of this family in a test rather than in
help text. No backticks in a heredoc comment.

**My own strict-mode harness defeated itself with `|| true`.** The test for
"does this function abort under production's shell options" called it as
`do_dr_status 2>&1 || true`, and bash suppresses errexit for a function invoked
as part of an `&&`/`||` list -- the trap this file already records. The mutant
therefore ran to completion and the test "failed" against code that was right.
The call is bare now, and the OUTER `bash … || true` is what keeps the suite
alive.

**And the observable was wrong in a second way: `do_dr_status` legitimately
returns non-zero.** It exits non-zero when the weakest tier is UNKNOWN, which
is the normal state of this host, so a marker echoed after the call could never
run even on a healthy report. The observable is the OUTPUT -- an abort inside
TRUNCATES the report, so the assertions read for the regenerable-data block and
the final `WEAKEST TIER` line. Name the observable the mutation actually
changes, and check it is reachable at all on a passing run.

**`git rebase --onto origin/main <tip>~1` drops the commit before the tip.**
`--onto X Y` replays `Y..HEAD`, so passing the second-newest commit as the
upstream silently excluded the newer of my two commits -- and the conflict it
then raised showed the OLD rows, which is what gave it away. The upstream is
the last commit that LANDED upstream, not an offset from the local tip. Nothing
was lost: `git rebase --abort` restored the branch, and the patch scripts made
re-applying the working-tree edits deterministic.

---

**THE DECLARED READINESS LINE IS NOW CONSULTED BY THE UPGRADE, BOUNDED AND
DELIBERATELY ASYMMETRIC.** `service_logged_ready_since` existed and only the
MIGRATION path used it, so an upgrade had **weaker** readiness evidence than a
migration of the same service. The first attempt at closing that gap was
reverted, and the reason governs the design: phase 4 runs immediately after
`up -d`, so a line that lags by seconds read as a FAILURE, and escalating on
absence changes the success criteria for the four services that declare a
pattern.

So finding the line STRENGTHENS the claim and not finding it is REPORTED and
never sets `rc`. The wait is `UPGRADE_READY_LOG_WAIT`, default 60 s in 5 s
steps, and it makes **one attempt before any sleep** -- so a wait of 0 means
"look once, do not sleep", which is what lets a test drive both outcomes
without a minute of real time per run. The fixture sets it to 0.

**The boundary is captured BEFORE the deploy**, so a readiness line from the
previous start can never be accepted as evidence of this one. It is defined at
the top of phase 3 rather than inside phase 4 because referencing
`$restart_boundary` before defining it once killed this function under
`set -u` -- and the test asserts the ORDER (boundary < deploy < readiness read)
rather than trusting it.

**The UNPROVEN sentence is BUILT from what is actually absent.** The fixed
wording said "no container healthcheck, no readiness probe and no declared log
pattern", which would be **false** for a service that declares a pattern and
stayed silent -- a report describing something it is not, in the one place an
upgrade is being declared successful. It now distinguishes "no readiness probe"
from "a readiness probe that did not answer", and "no declared log pattern"
from "a declared log pattern that did not appear". A test asserts the false
form does not appear.

**`missing` is an ARRAY name elsewhere in this file**, and my first version
used it as a string local -- SC2178/SC2128, the pair this project has already
paid two CI failures for. shellcheck reported it in seconds, exactly as §9
promises. Renamed `ready_missing`.

**`EXTRA_STUB` is a per-section stub hook in the integration fixture**,
appended LAST so a section can override any stub above it. Without it a section
cannot change one behaviour without duplicating the whole fixture, which is how
a suite ends up with two fixtures that drift apart.

---

**A QUIESCED CAPTURE EXISTS FOR THE TWO SERVICES THAT CANNOT HAVE A CONSISTENT
ONE ANY OTHER WAY, and it is the only capture path that causes downtime.**
jellyfin.db and kavita.db are both WAL-mode and neither their images nor this
host has an sqlite3, so their ordinary captures are copies of a WAL database
taken while the service may be writing.
`storage capture-state <service> <dir> --quiesce` stops the service, PROVES it
quiescent with `migrate_assert_quiesced`, copies, and starts the same container
again with **`compose start`** -- never `up -d`, which reconciles and would turn
a capture into an unreviewed deployment of whatever the tag now resolves to.
`service_state_capture_quiesced` is in `PRESERVING` in
`tests/reconcile-boundary-audit.py`, so that is enforced rather than intended.

`QUIESCED_CAPTURE_ENABLED` defaults to 0 and **the refusal happens before the
lock and before any stop** -- a closed gate that still causes downtime is not a
closed gate, the same reasoning as `VOLUME_UPGRADE_ENABLED`. The mutation
neutralises the comparison and must make an unset flag actually stop the
service.

Rules it follows, each already recorded: quiescence is PROVED rather than
assumed (a refusal restarts the service and captures nothing); runtime state is
preserved, so a service that was stopped is captured without being started;
and the mode is a PARAMETER of `service_state_capture`, not an environment
variable, so it cannot be set by accident -- the caller that passes `quiesced`
is the one that took the lock and proved quiescence. A quiesced copy is
recorded `file-copy-quiesced` and the restore reports it as the strongest mode.

**I invented `domum_release_lock`, and the function-definition audit caught
it.** There is no release function: `domum_acquire_lock` holds the lock through
a file descriptor for the life of the process, it is re-entrant, and
`storage_pre_upgrade_point` does not release it either. Three calls to a
function that does not exist -- the `service_upgrade` undefined-helper family,
and `bash -n` cannot see it.

**My test STUBBED that invented function**, which is why the calls looked fine
while the suite passed: a stub of a function the CLI does not have makes the
fixture agree with the mistake. The ordering assertion now covers lock < stop <
start only, and additionally asserts that nothing in the CLI calls a release at
all.

**And that new assertion flagged its own explanatory comment** -- the comment
naming `domum_release_lock` to document the mistake. Comments are stripped
first. That is the rule this project records, broken in the assertion written
to enforce it, which is now its fifth recorded occurrence.

---

**`tests/find-abort-audit.py` -- `find` inside a command substitution must not
be able to abort the shell.** This was queued as "deliberately not shipped yet"
on the grounds that it would cry wolf. Measured instead of assumed: across the
three CLIs there are **18** command substitutions containing a `find`, and only
**three** lacked a guard. All three were real, and one of them mattered:

```
checkup:  waiting_count="$(find "$DOMUM_STATE_ROOT/image-updates" … | wc -l | tr -d ' ')"
```

`image-updates` does not exist until `ensure_dirs` has run, `find` then exits
1, and `2>/dev/null` hides the message and not the status -- so under pipefail
the assignment fails and `set -e` kills `checkup`. The report prints only after
every check has completed, so that produces a **BLANK report**, which is
indistinguishable from a healthy one. **That is the exact shape that blanked
the report in production once already**, with a `grep` instead of a `find`, and
it was still live in a second place. Reproduced standalone: exit 1, and the
line after it never runs.

**`| wc -l` does not save it.** pipefail takes the rightmost non-zero status,
so `find /absent | wc -l` is a failed pipeline even though `wc` succeeded and
printed `0`. The fix is `|| true`, which leaves the `0` and fixes only the
status.

Scope, stated in the audit rather than left implicit: `bin/*` only, because the
operator wrappers verify their paths far earlier than any window this could
inspect; continuations are joined, because two of the pipefail audit's findings
were invisible to a line-at-a-time search; a QUOTED heredoc body is data; and
an explicit `# find-audit: <reason>` marker exempts **its own line only** and
is PRINTED. A marker on the preceding line deliberately does NOT exempt -- it
would drift away from the line it vouches for, the same problem as a comment
between a warning and its remedy, and the smoke test asserts that direction.

**It is deliberately NOT a guard-detection audit.** Recognising `[[ -d "$x" ]]`
before a `find "$x/y"` is fragile and the guard is often many lines away;
requiring `|| true` unconditionally is simpler and strictly safer, because it
costs nothing where the path is guaranteed.

`tests/find-abort-audit-smoke.sh` drives the audit against fixtures in both
directions, including that it **accepts the fix it prescribes** -- an audit
that rejected its own remedy would be switched off -- and that it cannot pass
vacuously. Reporting the problems BEFORE the vacuity guard was a correction: a
stale target list produces zero matches AND a problem, and the first version
printed "matched no find" while hiding "the target list is stale", which is the
actionable half.

---

**`tests/` IS NOW SHELLCHECKED, at `--severity=error` only.** A backtick in a
double-quoted message is command substitution: it executes when the string is
built and silently deletes the words it wraps. That happened **twice in one
session** -- once in a heredoc comment and once in a `fail` message -- and
nothing in CI could see either, because `log-hygiene-smoke` covers backticks in
unquoted HEREDOCS and the shellcheck step covered only `bin/`, `install.sh` and
`operator/`.

Error level and not warning level, deliberately: `SC1090` (cannot follow a
non-constant source) is legitimate and unavoidable in a test harness, so
`--severity=warning` would flood and the step would get switched off. What
error level catches is PARSE failures, which is exactly the gap. All suites
pass it today.

**A prose comment must not BEGIN with the word `shellcheck`**, or it is parsed
as a directive -- `SC1072`/`SC1073`. One such comment existed, in the suite
that exists to police exactly this family of quoting mistakes. Reworded rather
than exempted.

---

**FOUR CLAIMS ABOUT AN ARCHIVE, and none implies the one above it.** Measured
2026-11-02 against a disposable `busybox` archive: `FILE INTACT` (the
`.sha256`) < `HOLDS THE IMAGE` (a blob whose digest equals the recorded id --
read-only) < `LOADS TO THAT IMAGE` (`docker load` reports the same id --
mutates the image store) < `THE IMAGE RUNS` (a disposable container started
from the image ID, not a tag, on `--network none`). All four held.

**Loading an archive of an image the store ALREADY HOLDS is a no-op**, which is
what makes the third claim safe to measure: the id is content-addressed, so a
load cannot replace a different image with this one. The local id was
unchanged across the load, verified.

**The limit is the point of separating them.** This proves the MECHANISM and
proves nothing about the project's own archives, which live under `root 0750`
and have never been loaded or run -- a fixture-backed probe is not production
evidence, and `busybox` is a fixture. It also proves nothing about a recovered
SERVICE: an image that runs is not a service that works, which needs the image,
its state, its configuration and its dependencies together. So for the real
archives, the first two claims are checkable today without privilege and
without mutation, and the last two are proven for the mechanism and unproven
for those specific files.

---

**P3.4 -- a rehearsal against REAL disposable volumes -- REQUIRES ROOT, and
that was measured rather than assumed.** The half fixtures cannot establish is
`dump_volume_to_file` / `restore_volume_from_file`, and both `tar -C` the
volume's host mountpoint from
`docker volume inspect --format '{{.Mountpoint}}'`. Measured 2026-11-02:
`/var/lib/docker` is `drwx--x--- root root`, so **no** volume mountpoint is
readable unprivileged -- verified against a volume created for the probe and
removed afterwards, so it is not an artefact of production ownership.

**The isolation itself is sound and was checked BEFORE anything else.**
`storage_volume_pre_upgrade_point` resolves volumes from `docker inspect` of
the running container, so the compose PROJECT is the boundary: production is
`domum-media_*` and a `domum-rehearsal` project yields `domum-rehearsal_*`,
both of which were verified free. A rehearsal must assert, before anything
mutating, that every resolved volume name carries the disposable prefix and
that none exists yet -- the "every root a fixture uses must be redirected into
it, and asserted to be" rule applied to Docker objects instead of filesystem
paths.

**A rootless variant was considered and REJECTED, twice over.** A volume can be
read without host root by mounting it into a helper container; that would let
the rehearsal run unprivileged and would not be driving the production
primitives, so it would prove something adjacent -- a fixture-backed probe is
not production evidence, and a helper container reading the volume is a
fixture. Changing the production code to use a helper container was rejected
too: the CLI already runs as root in production so it buys nothing there, and
it would change the semantics of a RESTORE path -- `--numeric-owner`, xattrs
and ACLs behave differently inside a container's user namespace, and
`acme.json`'s mode 0600 is exactly what must not change. A restore path is the
worst place to trade correctness for testability.

See `docs/VOLUME-UPGRADE-REHEARSAL.md` for the six things the rehearsal would
prove and the shape it should take.

---

**THE UNBOUND-CONFIG-VARIABLE FAMILY DOES NOT WARRANT AN AUDIT, and that was
measured rather than assumed.** `DISK_WEAR_WARN_PERCENT` had to be defaulted at
its use site because a variable set only by `load_cfg` is unbound for a caller
that has not run it, and under `set -u` that kills the shell -- the defect that
once made `checkup` print nothing at all. The obvious next step is an audit for
the whole family. Measured 2026-11-02, it would be noise:

- `load_cfg` assigns **26** config variables, and **14** of them are read
  somewhere outside it with no `${VAR:-}` default, across **160+ sites**.
  `DOMUM_DATA_ROOT` alone has 54. A blanket rule would reject almost every
  path in the CLI.
- the production path is **structurally safe**: all **24** arms of `main`'s
  dispatcher delegate to a handler, and the handlers call `load_cfg` before
  reading anything. `load_cfg` is not called in the dispatcher, which is why a
  check at that level reads as "none of them do" and proves nothing.
- the one recorded failure was a **FIXTURE** stubbing `load_cfg`, and **20
  suites stub it deliberately** -- they set the roots as environment variables
  instead. Forbidding the stub would reject all twenty.

So the correct scope is the fix already applied: a fixture that needs every
default applied runs the REAL `load_cfg` against a real config, as
`checkup-produces-output-smoke` now does, and a use site that a caller can
reach without `load_cfg` carries its own default. Neither is a rule a scanner
can usefully enforce. Recorded so the question is settled rather than
re-derived: "we looked and decided no" is worth as much as an audit, and an
audit that cries wolf is one somebody switches off.

---

**THE QUIESCED CAPTURE IS NOW REHEARSED AGAINST A REAL CONTAINER, and the
reason it was not is a mistake worth recording: I conflated two different
blockers.** `docs/VOLUME-UPGRADE-REHEARSAL.md` correctly establishes that a
rehearsal of `dump_volume_to_file` needs root, because it tars
`/var/lib/docker/volumes/...` and that tree is `drwx--x--- root root`. I then
treated "real-container rehearsal" as blocked in general. The quiesced capture
reads `/srv/data/<service>`, a **bind mount**, so it needs no root at all.
Measure the blocker for the path in front of you, not for a neighbouring one.

Rehearsed 2026-11-02, unprivileged, against a disposable compose project, with
production verified untouched afterwards:

- **isolation asserted through the real CLI before anything mutated** --
  `service_data_path kavita` resolved into the temp directory and not
  `/srv/data/kavita`, only the fixture's compose file was layered, the
  project's container list was empty, and production `kavita`
  (`fae6d10aa732`) was checked absent from that list before the first stop;
- **a non-empty WAL refuses and restarts.** The fixture left `kavita.db-wal`
  at 4,152 bytes by skipping the clean close. The real function stopped the
  real container, refused, and brought it back **with the same container id** --
  which is what proves `compose start` rather than a recreate -- and left no
  capture directory;
- **the whole chain then worked**: `CAPTURE_MODE=quiesced`, `IMAGE_ID` read
  from `docker inspect` rather than invented, `RESULT=COMPLETE`, verify and
  restore both matching, and the restored database opened with
  `integrity_check: ok` and **both** rows -- including the one that existed
  only in the WAL before the checkpoint, so the capture carried the
  checkpointed state rather than a stale main file;
- **teardown asserted**: no `domum-caprehearsal` container, volume or network
  remained, and production still had its 11 containers with `kavita`
  `Up 7 days (healthy)`.

**The limit stays explicit.** `kavita` in the rehearsal was a `busybox`
container holding a bind mount, not Kavita. Nothing here shows how Kavita
itself shuts down or whether it checkpoints its WAL on stop -- which is the
question the real run answers, and it causes downtime.
`QUIESCED_CAPTURE_ENABLED` stays 0.

---

**A STALE PROTECTION CLAIM WAS STILL IN A CODE COMMENT.**
`image_archive_dir`'s comment justified the location partly by asserting that
an archive there is in the off-host backup set, because restic is given
`"$DOMUM_DATA_ROOT"`. That is true of the GLOBAL include set and false of the
target that actually runs -- the cloud target is immich-only and
`/srv/data/backups/images` is NOT COVERED. The operator found exactly this
error in `dr-status` by listing the Hetzner snapshot from another machine; the
code comment carried it for longer, because nothing reads a comment. Corrected,
and the test asserts the claim is gone AND that the replacement says what is
actually true -- not just that a string disappeared.

**My correction first QUOTED the old claim verbatim, and the assertion fired on
the documentation of the fix.** A comment quoting the broken form is normally
how a fix documents itself, and it is the right instinct -- but not when the
subject under assertion IS a comment. Paraphrase there instead, and the
assertion keeps its full strictness rather than learning to skip the fix.

**`storage capture-state` now has a DEFAULT destination.**
`state_capture_dir()` -> `<data>/backups/state/<service>/<stamp>`. Without one,
every invocation needed an operator-invented path, which means nothing could be
scheduled and a backup scope had nothing stable to name -- the missing link
between "the capture works" and "the capture can be protected". It is a sibling
of the service directory and never inside it: a capture written under
`/srv/data/<service>` would duplicate into every per-service snapshot of that
service, and a capture of a service is not part of that service's state.

It puts nothing off-site, and the comment says so: the cloud target is
immich-only, so the default is on the protected local tier and nowhere else.
`--quiesce` is accepted in the destination slot and must never be taken AS the
destination -- a capture written to a directory called `--quiesce` is the kind
of thing a test should pin, so it is pinned.

---

**MY OWN FULL-SUITE RUN SILENTLY OMITTED A CI SUITE, and the inverse of that
is already recorded here.** This file records that seven suites existed which
CI never ran, and `tests/ci-coverage-audit.sh` was written to stop that. The
mirror image went unnoticed: a local run that globs `tests/*.sh` and
`tests/*.py` does **not** match
`tests/integration/btrfs-migration-integration.sh`, which IS in the workflow
and DOES run unprivileged. So "the full suite passes locally" was a claim about
80 of the 81 runnable files, every time it was made.

Run separately, it passes -- it exercises the real primitives (subvolume
create/snapshot, `cp --reflink=always`, `rename(2)`, `flock`, `/proc`), which is
exactly the coverage a stubbed suite cannot give, so omitting it was omitting
the strongest one.

**The two counts are different numbers and must not be quoted
interchangeably.** `ci-coverage-audit` uses `find -maxdepth 2` and reports
**82 test files**: 70 `tests/*.sh` + 10 `tests/*.py` + the integration suite +
`tests/fixtures/email-client-simulation.py`, which is invoked BY a suite rather
than run standalone. **81** are runnable standalone. Quoting 82 as "suites that
pass" is a count of one thing wearing another's label -- and a first attempt at
explaining the gap blamed `tests/fixtures/` alone, which does not add up
(82 - 80 = 2, and that directory holds one file). Measure the difference
instead of reasoning about it.

---

**KAVITA CHECKPOINTS ITS WAL ON A CLEAN STOP -- measured 2026-11-03 against
the REAL image, which settles the question Phase E left open.** The earlier
rehearsal used a `busybox` stand-in and said so: *"nothing here shows how
Kavita itself shuts down or whether it checkpoints its WAL on stop."*

```
running      kavita.db    430,080    kavita.db-wal  4,132,392
clean stop   kavita.db  1,114,112    kavita.db-wal  ABSENT
```

The main database grew by almost exactly the WAL's content and the `-wal` was
removed outright, verified a second time with the container stopped to isolate
the claim from the restart. So `migrate_assert_quiesced` passed on its own
terms, the capture completed (`rc=0`, same container id), and the captured
database opens with **84 tables**, `integrity_check: ok`, and Kavita's own table
names -- the application's real schema rather than a fixture's.

The image was pinned **by ID** read from the running container, never by
`jvmilazz0/kavita:latest`, so a tag that moves cannot change what was
rehearsed.

**A measurement that is easy to misread, and nearly was.** After the capture the
service restarts and Kavita immediately creates a NEW 41,232-byte `-wal`. The
directory inspected *after* a capture therefore shows a non-empty WAL, which
says nothing about what the check saw. The decisive evidence is the main
database's growth plus the WAL's absence WHILE STOPPED; the post-restart size
is a different file in a different epoch, and reading the later one as the
earlier one would have inverted the conclusion.

**Teardown of a rehearsal whose container runs as ROOT.** Kavita writes
root-owned files into the bind mount, so the fixture cannot be removed by the
development account. A disposable `busybox` container with the temp directory
mounted does it -- the same tool that created the problem removes it, and no
privilege is needed on the host.

**Still not rehearsed: jellyfin**, the other service with no sqlite3 anywhere.
And this was a disposable Kavita with an EMPTY library; production has days of
uptime, a populated library and active scan tasks, so its shutdown has more to
finish. The real run causes downtime and `QUIESCED_CAPTURE_ENABLED` stays 0.

---

**JELLYFIN ALSO CHECKPOINTS ITS WAL ON A CLEAN STOP** -- measured 2026-11-03
with the production image pinned by ID: a 3,188,912-byte `jellyfin.db-wal`
before the stop, nothing after it. Both services with no sqlite3 anywhere
behave the same way, which is the result the quiesced path needed. Its six
declared items appear in STAGES during startup (`encoding.xml` is absent until
initialisation finishes), so a capture taken mid-startup correctly reports
INCOMPLETE.

**AND THE REAL IMAGE EXPOSED A DEFECT NO FIXTURE COULD.** The capture failed
closed on `config/.aspnet/DataProtection-Keys` -- present, but the key inside is
**`-rw------- root root`** and the rehearsal ran unprivileged, so `cp -a` could
not read it. The one declared item that is mode-restricted is exactly the one
that decrypts Jellyfin's stored secrets, so refusing was right. A fixture could
never have shown this, because a fixture's 0600 key is owned by the user running
the test.

**But the capture had already STOPPED THE SERVICE.** `capture-state` did not
call `need_root` while every other `storage` subcommand does, so an
unprivileged operator would take real downtime for a capture that could never
succeed. "A closed gate that still causes downtime is not a closed gate"
applies to a missing privilege exactly as it does to a feature flag.
`need_root` is now the FIRST thing the quiesced path does -- before the gate,
before the lock, before the stop -- and the ordering is asserted behaviourally
(nothing locked, nothing stopped, no destination created) and positionally.

**`FAILED` now names its cause.** An item that exists and cannot be read is
`FAILED:UNREADABLE`; a bare `FAILED` sent nobody anywhere, and an unactionable
failure trains the operator to ignore it. **Three** readers examine an item
mode -- the capture's tally, `verify-state` and `restore-state` -- and matching
only the bare form would have made a `FAILED:UNREADABLE` item look like
something to restore. The second site was caught by checking every match
instead of the first.

---

**A REHEARSAL WHOSE CONTAINER RUNS AS ROOT LEAVES LITTER THE DEVELOPMENT
ACCOUNT CANNOT REMOVE, and I made that avoidable mistake.** The Jellyfin
rehearsal set `PUID: "0"` / `PGID: "0"` in its disposable compose file, so the
container wrote 39 root-owned entries into the fixture. Tearing the container
down worked; `rm -rf` on the fixture then failed with `Permission denied` and
left 1.2 MB behind in the scratch directory.

**linuxserver.io images honour `PUID`/`PGID`** -- Jellyfin is one -- so a
rehearsal should pass the invoking account's own ids:

```
    environment:
      PUID: "<id -u>"
      PGID: "<id -g>"
```

Then every file the rehearsal creates belongs to the account that has to delete
it. That is the fix, and it costs nothing: the rehearsal is about shutdown
behaviour and capture correctness, neither of which depends on the container
running as root.

The Kavita rehearsal met the same problem and solved it differently -- a
disposable `busybox` container with the fixture mounted did the removal, the
same tool that created the problem removing it. That works, but it is the
second-best answer: it needs a privileged container to clean up after an
unprivileged test, and a removal run inside a container is exactly the shape a
safety check should and does question. Prefer `PUID`/`PGID`.

**What the two rehearsals DID get right**, and what any future one must: a
disposable compose project whose name is checked free first, images pinned by
ID read from the running container rather than by a mutable tag, bind mounts
under a temp directory, no external network, no production path or volume, the
production container id asserted absent from the project's scope BEFORE the
first stop, and teardown asserted rather than assumed. The one thing not
asserted was the FIXTURE's removal -- only the container's -- which is how the
litter went unnoticed until the final state check counted 12 containers instead
of 11.

**Count the containers at the end.** That is what caught it: the final
verification printed `containers 12 running` and one `rehears` match, and the
Jellyfin project had never been torn down at all. A rehearsal's teardown
assertion belongs in the rehearsal, not in a later review.

---

**THE ARCHIVE COST DID NOT NEED ROOT, and calling it blocked cost several
sessions of a withheld recommendation.** `/srv/data/backups/images` is
`drwxr-x--- root root`, so it cannot be LISTED unprivileged -- and I let that
stand for the whole question. But what gated the recommendation was never the
directory listing: it was the size of **one archive per service**, and
`docker save <id> | wc -c` measures that exactly, without touching
`/srv/data` and without writing anything.

Measured 2026-11-03:

```
traefik        55,649,280   53 MiB      kavita        253,559,808  242 MiB
navidrome      89,996,288   86 MiB      calibre-web   270,126,080  258 MiB
plex          187,711,488  179 MiB      jellyfin      348,975,616  333 MiB
                                        uptime-kuma   600,544,256  573 MiB
all seven  1,806,562,816  1.68 GiB      mean 246 MiB
```

An archive is **26-30% of the image size** -- `docker save` stores the layer
blobs already compressed, which is also why restic will dedupe and compress
almost nothing of them. Budget the full 1.68 GiB.

The earlier guess that the archives could be "two orders of magnitude larger
than everything else combined" was right: **190x** the 8.90 MiB of service
state. And against the 207.5 GiB already in the cloud repository, 1.68 GiB is
**+0.8%**, so the §4b retention policy (newest valid point per service) is
affordable and the recommendation is no longer withheld.

What genuinely still needs root is **how many archives exist on disk now** --
which is a retention question, not a cost question: it decides how much of the
current directory the policy would EXCLUDE, not what the policy costs going
forward.

**The lesson is the same one the quiesced capture taught, in a second place:
measure the blocker for the question you are actually asking.** "The directory
needs root" is true and was not an answer to "what would this cost". This is
the third time in two sessions that a blocker turned out to belong to a
neighbouring question -- the volume mountpoint versus the bind mount, and now
the directory listing versus the archive size.

---

**"COULD NOT READ IT" AND "IT READS ALIKE" ARE DIFFERENT FINDINGS, and the
wear check collapsed them.** `mreport_smart_interpretable` returned 1 both for
an attribute table with one distinct value (genuine vendor placeholders) and
for **no table at all**, and `checkup_disk_wear` then asserted the placeholder
cause. Run unprivileged against this host, `smartctl` returns
`Permission denied` with an empty table -- so **/dev/sda, whose attributes ARE
interpretable as root (0.52% of its 600 TBW used), was reported as holding
"vendor placeholders"**. A check that names the wrong cause is the defect this
file exists to correct, in the check written to avoid exactly that.

Three states now: `0` interpretable, `1` placeholders, `2` could not be read.
Both non-zero values stay falsy, so every existing `if ! f` caller is
unaffected. The unreadable advice says it needs root and that unknown is not
evidence of health either -- it does not borrow the placeholder wording.

**It was found by running the real checks against the real host, unprivileged.**
Every fixture stubs `mreport_smart_interpretable` or feeds it a populated
table, so no suite could see the empty-table path; the host could. That is the
second finding this session that only appeared outside a fixture -- the first
was Jellyfin's 0600 DataProtection key.

**What the same run CONFIRMED, which is why it was worth doing:** a permission
failure reports `UNKNOWN: smartctl reported no verdict` as a WARNING and
**zero CRITICAL**. That is the recorded defect -- a permission failure once
reported "did NOT pass" and told the operator to replace a healthy disk -- and
it is fixed and now verified against the real host rather than against a
fixture.

**The scrub timer justified `Persistent=true` with the wrong reason.** Its
comment said a missed run at boot is "harmless" because "unlike `snapshot
prune` this job deletes nothing". True, and not the same claim: a default scrub
is READ-WRITE and repairs a corrupt metadata block from its DUP copy, and
Metadata and System here are DUP. The real mitigations are the ones now
recorded -- `RandomizedDelaySec=20m` keeps it off the boot critical path, and
`--limit 150M` makes it **~25 minutes** of throttled I/O rather than the
measured 7m14s at full rate. `systemd-analyze calendar` confirms the schedule
resolves to the first Sunday monthly (next elapse 2026-12-06 05:30), which is
the only part of a timer that can be tested without installing it.

---

**SPLICING A LINE BY REBUILDING IT FROM THE PREFIX YOU MATCHED SILENTLY
DELETES THE REST OF IT.** Found 2026-11-03 during a final backlog review:
`backlog/QUEUE.md`'s **P1.7** row -- the one item gating the whole
selective-backup priority -- had read

```
| P1.7 | activate a production backup target for it |
```

with **no status column at all** since `731a907`. The cause was my own edit:

```python
old = "| P1.7 | activate a production backup target for it |"   # a PREFIX
i = s.index(old); j = s.index("\n", i)
s = s[:i] + new_rows + old + s[j:]        # rebuilds the line from the prefix
```

`s.index` found the prefix, `j` was the end of the whole line, and the line was
reassembled from the prefix alone -- so `**BLOCKED** - operator decision; needs
the archive size (P2.1)` was dropped. The edit APPLIED, the assertion passed,
and nothing was malformed enough to notice: four commits carried a
two-column row in a three-column table.

To insert before a line, match the WHOLE line (ending in `\n`) and write
`new_rows + whole_line`, or insert at `i` without consuming anything. Never
rebuild a line from a fragment you searched with. "Assert that the anchor
matched" does not cover this: the anchor matched exactly once and the edit
still destroyed data.

**And a status column that is empty reads as "no status", not as "blocked".**
The row that mattered most for P1 looked unexamined for four commits, in the
file whose entire purpose is to survive context compaction. Every remaining
blocked row now names the specific prohibition or resource and, where one
exists, the exact command that unblocks it -- so the terminal state is
self-documenting rather than something a later session has to re-derive.

---

**FOUR OF THE APPROVAL-GATED ITEMS NEED THE DEPLOYMENT FIRST, which no row
said.** `capture-state`, `verify-state` and `restore-state` are **not in the
installed binary** -- production is `a63ad19` and predates all of them. So
**P1.7** (activate a target for the captures) and **P1.8**'s real run are
gated on the deployment and only then on approval, while **P4.6**, **P3.5** and
**P5.2** act on what is installed today.

Recommending a capture command now would hand the operator a usage error --
precisely the recorded defect from when `storage verify-recovery` was suggested
while it sat on an unmerged branch. The rule is "never tell the operator to run
a command that is not DEPLOYED", and it applies to an OPERATOR ACTION REQUIRED
block more than anywhere else, because that block is written to be pasted.

Checked while assembling it: `QUIESCED_CAPTURE_ENABLED` is read from the
environment and is **not** set by `load_cfg`, so `sudo env
QUIESCED_CAPTURE_ENABLED=1 …` is the correct form -- `domum-media` is a script
file, not a shell function, so `env` can exec it.

**Btrfs error escalation, re-verified against the real host 2026-11-03:**
unreadable counters give `0 CRITICAL` and a warning paired with the
`btrfs device stats` remedy, so the finding reaches the notifier without
claiming damage; a simulated `corruption_errs = 7` escalates to **CRITICAL**;
and `btrfs_unique_roots` collapses `/srv/data` and `/srv/snapshots` to the one
filesystem uuid `211e06b3`, which is the recorded dedup.

---

**`sudo` IS UNOBTAINABLE HERE, AND THAT IS NOW MEASURED RATHER THAN ASSERTED.**
This file has always said sudo "requires interactive authentication that the
agent cannot supply". Measured 2026-11-03:

```
$ sudo -n true          -> sudo: a password is required
$ sudo -n -l            -> sudo: a password is required
   NOPASSWD entries visible: 0
```

It is worth having as a measurement because it settles every root-gated
question at once -- `du` on the image archives, installing a unit, traversing
`/var/lib/docker`, running the deployment, running `install.sh` -- without
each one having to be argued separately. A future session should check this
once and then stop re-deriving it per item.

**"The command exists in the installed binary" is not "the agent can run it",
and I conflated them.** An operator block described `du -sb
/srv/data/backups/images` and the scrub-timer install as working "against the
installed binary today", meaning only that they would not give a usage error.
Both halves have to hold before anything is runnable: the subcommand must be
DEPLOYED *and* the privilege must be obtainable. The first was the defect
recorded when `storage verify-recovery` was recommended off an unmerged branch;
the second is this one, in the opposite direction.

---

**NOTHING CHECKED THE ENCRYPTED RECOVERY PACK, AND MY FIRST CHECK ASKED THE
WRONG QUESTION -- the opposite of what `dr-offhost-audit` asks about the same
configuration.** Found 2026-11-03 from the production config the operator
pasted while installing the scrub timer.

`dr_path_configured` verifies the Immich library, the five service paths and the
image-archive directory. It was never asked about the **pack** -- the artefact
that makes every other off-site copy openable, holding the configuration, the
secrets, Traefik's ACME account private key and the validated Uptime Kuma dump.

**The first version asked "is the pack in the backup set" and reported its
absence as a risk. That is a finding about the DESIGNED configuration**:
`immich_only_include_paths` -- the cloud target's own scope -- puts the pack
there deliberately. Worse, it contradicted `dr_offhost_audit`, which reports the
pack being **inside** the backup as `CIRCULAR` and counts it a problem. Two
commands, opposite verdicts, one configuration, and
`docs/RECOVERY-KEY-CUSTODY.md` carried **both claims three lines apart** -- a
table row saying the pack lives "inside the cloud backup set" above a paragraph
saying it was "correctly **not** inside the backup it would be needed to open".

**The audit's row was reassuring because it read the WRONG SCOPE.** It looped
over the global `BACKUP_INCLUDE_PATHS` (default `/srv/data`), under which
`/var/lib/domum-media/recovery-pack` does not sit -- so on production it printed
`pack inside the backup  no  correct -- that would be circular` about the one
configuration it exists to warn about. That is the wrong-scope defect
`dr_path_configured` already had, in the command that is supposed to be the
authority, and it is why `recovery_pack_coverage` is now the ONE implementation
consumed by all three readers.

**And its POLARITY was wrong.** A copy inside the repository is circular only
when it is the pack's **only** copy off this host -- you would need the
credentials in order to fetch the credentials. While email delivery is enabled
it is redundancy. So:

| in a target's scope | off-host delivery | verdict |
|---|---|---|
| yes | enabled | `offhost` -- redundant, not a problem |
| yes | **disabled** | **`circular`** -- its only copy off the host is inside the repository it opens |
| no | enabled | `offhost` -- the email route is the designed one |
| no | **disabled** | **`none`** -- the pack never leaves |
| either | **unreadable config** | `unknown` -- an unread setting is not a setting of 0 |

**The decisive question is whether a pack reaches anywhere this host is not, and
"is it in the backup set" is a COMPONENT of the answer rather than the answer.**
A check that fires on the designed configuration is how a real finding gets
ignored.

**`domum-media-backup pack-offhost [target] [--json]`** is the bridge, because
the two commands that reported on the pack -- `dr-status` and
`dr-offhost-audit` -- are not notification paths, so a pack that never left this
machine was visible only to an operator running a command by hand. Its contract
is the EXIT STATUS, matching `exclusion-audit` and `verify-snapshot-coverage`:
**0** a pack is delivered off-host, **1** none or CIRCULAR, **2** not
answerable. It reads configuration only -- a test asserts the function body
contains no `restic`, `docker`, `curl`, `ssh` or `sftp`, because a report must
do no recovery work.

**The JSON is REQUIRED by the caller, and that is the load-bearing part.** An
exit status alone cannot tell a verdict from a NON-ANSWER: an installed binary
that predates this subcommand dies with status **1**, which is the alarming
answer -- a CRITICAL about the family photographs manufactured from a binary
that never looked. So `checkup` requires the reply to parse and to carry a
verdict it has been taught, and anything else is reported as "could not ask".
That is the `capabilities --has` rule in both directions: a token this binary
never heard of must not read as a yes, **and must not read as a no either**.
The mutation that classifies on the exit status alone must make an older
binary's usage error become `never leaves this host`.

**`checkup` asks it, so the finding is now mailed**, which was the whole point:
`circular` and `none` are **critical with an action** (the only two classes that
pass the notifier's silence gate), `unknown` and "could not ask" are **warnings
with advice** and deliberately do not mail -- "I could not check it" is not "it
is broken", and it is not healthy either. The remedy is worded IDENTICALLY to
`checkup_notification_path`'s, so `checkup_add`'s exact-duplicate suppression
collapses them when both fire: two different findings ("nothing can tell you"
and "nothing could open the backup") with one fix.

**`backup_cli_path` resolves the CHECKOUT's copy first**, matching `status`,
because the two CLIs must be at the same revision -- a new `checkup` asking an
older installed binary produces "could not ask" for a reason that is about the
deployment rather than about the pack. `DOMUM_BACKUP_CLI` redirects it for a
fixture.

**`recovery_pack_dest` is the ONE implementation of the destination**, and the
two it replaced were NOT equivalent: one defaulted `DOMUM_STATE_ROOT` and the
other did not, so a caller that had not run `load_cfg` would die under `set -u`
rather than fall back.

**A fix in a default is not in force wherever the configuration overrides that
default.** `immich_only_include_paths` was changed to DERIVE the pack path from
`RECOVERY_PACK_DEST` because a literal goes stale if the pack moves -- but
`backup_target_include_paths` resolves `"${paths:-$target_default}"`, so an
explicit `BACKUP_TARGET_<T>_INCLUDE_PATHS` **wins and the derived default is
never consulted**, and production sets it explicitly with the pack path as a
literal. The values agree today, and they agree by having been written
together, which is the accident the derived default was introduced to remove.

**A test that required the over-alarming behaviour had to be corrected, not
adapted around.** `offhost-recovery-audit-smoke` asserted `CIRCULAR` with
delivery **enabled** -- i.e. it required the designed configuration to be
reported as a defect. Before adapting a test to a change, ask which of the two
is wrong; here the test was. Both directions are asserted now, because a
single-verdict assertion cannot tell a check from one that always fires.

**ONE ROOT CAUSE IS ONE GAP.** With delivery off, the audit's delivery row and
its circularity row would each have incremented `problems`, so a single fixable
cause read as two blocking gaps -- fixing delivery clears both. The circular row
is reported and deliberately NOT counted again, and the test asserts
`problems == 1`. Same defect as printing identical text twice making the host
look twice as bad as it is, one level up.

`tests/pack-offhost-bridge-smoke.sh`; 2 mutants, both killed. Everything above
reports healthy on this host, so it is a regression guard rather than a live
finding.

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
- **Media-service state and the image archives are NOT backed up off-site, and
  this is a KNOWN, ACCEPTED limitation -- not an oversight to be quietly
  fixed.** The cloud restic target is immich-only by design (three roots:
  `immich/library`, `immich/backup-staging`, the recovery pack). So
  `/srv/data/{plex,jellyfin,kavita,navidrome,calibre-web}` and
  `/srv/data/backups/images` exist on exactly one device -- the Samsung 870 EVO
  that also holds every snapshot and every `.premigration` copy. A local
  snapshot is not off-site protection.

  It matters most for the archives. Measured 2026-10-21 three running images
  were dangling (`RepoTags: []` AND `RepoDigests: []`); **re-measured
  2026-10-28 it is two -- traefik and uptime-kuma** -- since the Plex upgrade
  tagged its image. For every service the `docker save` archive is still the
  only PROVEN copy of the application half, because no tagged image here has an
  independent registry reference. Lose the SSD and the snapshot half is gone
  with it anyway; lose the archive alone and the data survives with no
  application to open it.

  **Do not expand the Hetzner scope without a measured, selective proposal.**
  `du -sb` on the candidate paths needs root and has not been run, and
  recommending coverage without a size is how a nightly backup window grows
  silently. Family photographs keep priority: any new coverage is additive and
  must never displace or slow the Immich paths. No replaceable bulk media --
  `/srv/media`, movies, TV, downloaded books, derivatives, transcodes,
  thumbnails -- may enter the set. The design and the open measurements are in
  `docs/OFFSITE-COVERAGE-CLASSIFICATION.md`.
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
