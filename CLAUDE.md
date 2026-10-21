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
that is the sharpest gap: measured 2026-10-21, THREE running images are
dangling (plex, traefik, uptime-kuma), so for those the `docker save` archive is
the only obtainable copy of the application half of a recovery point, and
`/srv/data/backups/images` is not in the cloud target.

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

  It matters most for the archives: measured 2026-10-21, **three** running
  images are dangling (`RepoTags: []` AND `RepoDigests: []`) -- plex, traefik,
  uptime-kuma -- so for those the `docker save` archive is the only obtainable
  copy of the application half of a recovery point. Lose the SSD and the
  snapshot half is gone with it anyway; lose the archive alone and the data
  survives with no application to open it.

  **Do not expand the Hetzner scope without a measured, selective proposal.**
  `du -sb` on the candidate paths needs root and has not been run, and
  recommending coverage without a size is how a nightly backup window grows
  silently. Family photographs keep priority: any new coverage is additive and
  must never displace or slow the Immich paths. No replaceable bulk media --
  `/srv/media`, movies, TV, downloaded books, derivatives, transcodes,
  thumbnails -- may enter the set. The design and the open measurements are in
  `docs/OFFSITE-COVERAGE-CLASSIFICATION.md`.
- **Mail delivery has never been proven.** `health-notify` has only run with
  `--dry-run`; `smtp_send_message` has never reached the server from this
  command. A healthy host sends nothing, which is the contract and also why
  delivery could stay broken indefinitely unnoticed. The approval-gated test is
  `health-notify --force`, documented in `docs/WEEKLY-REPORT.md`. Until it has
  run, silence means "nothing needed attention OR mail is broken".

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
