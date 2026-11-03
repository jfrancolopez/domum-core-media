# Live work queue

**This is the execution queue. `backlog/task-*.md` is the 2026-07 audit
evidence and is NOT an execution order** (CLAUDE.md §12). This file is the
thing to read first in a new session or after a context compaction.

Reconciled against the repository and the live host on **2026-11-03**.

| | |
|---|---|
| production | `a63ad19` |
| development / `main` | `f7e6d5d` |
| rule | an item is only `done` with evidence named here |

Statuses: `open` · `in progress` · `done (sha)` · `BLOCKED (reason)`.
A blocker must name what would unblock it, and blocked items stay in the queue
rather than being deleted.

---

## Deployment

Production is at `a63ad19` with **no drift** — every installed file's sha256
matches that revision's blob, verified 2026-11-02. A reviewed plan for
`a63ad19` → current `origin/main` is in `docs/DEPLOYMENT-PLAN-2026-11-02.md`:
two files change, no unit changes, no `daemon-reload`, no container touched, no
timer enabled, and no handover. Not executed — that is an approval boundary.

---

## P1 — Selective off-site protection for media-service state

Design: `docs/SELECTIVE-STATE-PROTECTION.md`. Phase A measured, Phase B
designed. **No implementation exists** — verified 2026-11-03, there is no
`service_state_capture` or equivalent in either CLI.

| # | item | status |
|---|---|---|
| P1.1 | declare navidrome's in-image sqlite3 | **done** — ships 3.45.3, was undeclared; its db is WAL-mode with a live 20,632-byte `-wal`, so a file copy is torn |
| P1.2 | declare per-service essential state (what to capture) | **done** — `service_essential_state`; `sqlite`/`file`/`dir` kinds, and the big regenerable trees (plex `Drivers/` 230.6 MiB, navidrome `cache/` 95.4 MiB, kavita `backups/` 3.5 MB) are deliberately excluded |
| P1.3 | `service_state_capture` — SQLite-consistent where possible, reusing the `.backup` pattern | **done** — `.backup` + `integrity_check` run INSIDE the container for the three services that ship sqlite3; jellyfin/kavita are recorded `unproven`, never claimed consistent |
| P1.4 | capture manifest: sha256, sizes, image identity, capture mode | **done** — `MANIFEST` carries `CAPTURE_MODE`, `IMAGE_ID` and a digest per item; `service_state_verify` re-reads them, and a missing declared item is `RESULT=INCOMPLETE` with exit 1 |
| P1.5 | restore into a scratch target, never over live state | **done** — `service_state_restore` + `storage restore-state`. Refuses a target that overlaps the live state root (resolved paths, so a symlink or `..` cannot walk in), refuses a non-empty target, refuses a capture that does not verify, re-proves every restored item's digest and mode, and integrity-checks restored databases. 4 mutants, all killed |
| P1.6 | disposable-fixture tests + mutations | **done** — `tests/state-capture-smoke.sh`, wired into CI; 2 mutants, both killed. A `docker` stub that exits non-zero is on PATH, so reaching the real daemon fails rather than quietly succeeding |
| P1.8 | jellyfin/kavita are WAL-mode with no sqlite3 anywhere — a quiesced capture is the only way to make their mode consistent | **rehearsed against the REAL Kavita image; gated off** — measured 2026-11-03: Kavita's clean stop folds its 4,132,392-byte WAL into the main database and removes the `-wal` outright, so quiescence passes on its merits and the captured database opens with 84 tables and `integrity_check: ok`. Image pinned by ID, production untouched, teardown asserted. `docs/SELECTIVE-STATE-PROTECTION.md` Phase E (mechanism, busybox) and Phase F (real image). **jellyfin not yet rehearsed**, and production Kavita has a populated library and days of uptime, so the real run — which causes downtime — stays an operator decision |
| P1.9 | surface `CAPTURE_MODE` in the restore report | **done** — printed with its reason; a consistent capture reports distinctly so the unproven wording cannot be boilerplate, and an absent key reads `unknown`, never the reassuring value |
| P1.6b | a DEFAULT capture destination, so captures are schedulable | **done** — `state_capture_dir()` -> `<data>/backups/state/<service>/<stamp>`, a sibling of the service directory and never inside it (a capture written under `/srv/data/<service>` would duplicate into every per-service snapshot of that service). Proven end to end, not just in the dispatcher. It puts nothing off-site: the cloud target is immich-only, so the default is on the protected local tier and nowhere else |
| P1.6c | a stale protection claim in `image_archive_dir`'s comment | **fixed** — it asserted an archive there was covered off-site because restic is given `$DOMUM_DATA_ROOT`. True of the GLOBAL include set, false of the target that runs. The operator found the same error in `dr-status` by listing the Hetzner snapshot; the code comment still carried it |
| P1.7 | activate a production backup target for the captures | **BLOCKED — requires operator approval.** The action is "change backup configuration" / "activate production backups", both explicitly prohibited. Everything short of it is done: the capture has a default destination (`<data>/backups/state/<service>/<stamp>`), a measured size (**8.90 MiB** of state), a rehearsed restore, and §4a of `docs/OFFSITE-COVERAGE-CLASSIFICATION.md` states the two remaining choices (where the captures live; a third include root on `cloud` versus a separate target). The archive cost this row used to wait on is now measured (**1.68 GiB**, P2.1), so nothing technical is outstanding |

### Measured capture capability, 2026-11-03

Taken by exec'ing each running container. **The host has no `sqlite3` at all**,
so every consistent capture depends on the service's own binary.

| service | in-image sqlite3 | live `-wal` | consistent capture |
|---|---|---|---|
| plex | `/usr/lib/plexmediaserver/Plex SQLite` 3.39.4 | **911,792 B** + `-shm` | `.backup` — and only this binary can read its `collating` FTS tokenizer |
| navidrome | `/usr/bin/sqlite3` 3.45.3 | **20,632 B** + `-shm` | `.backup` |
| calibre-web | `/usr/bin/sqlite3` 3.45.1 | none (`journal_mode delete`) | `.backup`, and a copy is already sound |
| jellyfin | **none** | **no `-wal`, no `-shm`** | **unprovable** — see below |
| kavita | **none** | **no `-wal`/`-shm`** on `kavita.db` | **unprovable** |

The two services with no sqlite3 are exactly the two showing no WAL sidecars,
which is fortunate but **is not proof of non-WAL mode**: SQLite removes the
`-wal` when the last connection closes, and the absent `-shm` only says there
is no open WAL connection *right now*. Without a binary that can run
`PRAGMA journal_mode` there is no way to establish it, so their capture mode
must be reported as unproven rather than assumed safe. Declaring a sqlite path
they do not have would turn "not checked" into a check that always fails.

---

## P2 — Image recovery

| # | item | status |
|---|---|---|
| P2.1 | measure the image-archive cost | **MEASURED 2026-11-03, and it did not need root** — the directory needs root to *list*, but what gates the recommendation is the size of one archive per service, and `docker save \| wc -c` measures that exactly without touching `/srv/data`. **1.68 GiB for all seven** (53 MiB traefik … 573 MiB uptime-kuma, 246 MiB mean), i.e. 26–30% of image size and **190×** the 8.90 MiB of state. Against the 207.5 GiB already in the repository: **+0.8%**, so coverage is affordable and §4b's recommendation is no longer withheld. Still root-only: how many archives exist on disk NOW — a retention question, not a cost one |
| P2.2 | identify which archives a *still-valid* recovery point names | **done in code** — `storage archives` names the point per archive and now also says whether the archive actually holds that image. Still needs root to run against production |
| P2.3 | off-site preservation + retention procedure for archives | **designed** — `docs/OFFSITE-COVERAGE-CLASSIFICATION.md` §4b: retain off-site only an archive a *still-valid* recovery point names, verify it holds that image (`domum_archive_identity`, read-only) before counting it as coverage, never select by filename or mtime, keep the newest valid point per service, and treat off-site retention and on-disk retention as separate decisions. Every rule is answerable by the CLI today. §4a is now the selective capture (8.90 MiB) rather than whole directories. Activation still gated on P2.1 |
| P2.4 | restore-from-archive procedure, proven on a disposable image | **done for the MECHANISM, not for the project's archives** — four separate claims, measured 2026-11-02 against a disposable busybox archive: FILE INTACT, HOLDS THE IMAGE (content-addressed, read-only), LOADS TO THAT IMAGE (`docker load` reports the same id), THE IMAGE RUNS (a disposable container from the image id, `--network none`). Loading an archive of an image the store already holds is a no-op, which is what made it safe to measure. The project's own archives are `root 0750` and have never been loaded — a fixture-backed probe is not production evidence. `docs/RECOVERY-POINT-IDENTITY.md` |

Measured 2026-10-28 and still true: **traefik and uptime-kuma run images with
`RepoTags: []` and `RepoDigests: []`**, and every tagged image's `RepoDigest`
equals its image Id, so no service has an independent registry reference. The
`docker save` archive is the only *proven* copy of the application half of any
recovery point.

---

## P3 — Traefik / Uptime Kuma volume upgrades

Largely complete. `volume-recovery-point-smoke` covers 11 properties and
`volume-upgrade-dispatch-smoke` covers the dispatch, both verifiers, rollback
dispatch, the closed gate, and phase 4's model-awareness.

| # | item | status |
|---|---|---|
| P3.1 | phase-4 model awareness (a volume upgrade could not succeed) | **done** (`b67eee1`) |
| P3.2 | readiness reported as UNPROVEN where it cannot be evidenced | **done** (`b67eee1`) |
| P3.3 | readiness log pattern consulted by the upgrade, with a bounded wait | **done** — `UPGRADE_READY_LOG_WAIT` (default 60 s, 5 s steps) with ONE attempt before any sleep, so a wait of 0 means look-once. Deliberately asymmetric: found strengthens the claim, absent is reported and never sets `rc`, because escalating on absence is what got the first attempt reverted. The boundary is captured before the deploy and the ORDER is asserted. The UNPROVEN sentence is now built from what is actually absent, so it cannot claim a service has no declared pattern when it has one |
| P3.4 | end-to-end rehearsal against **real disposable containers** (not fixtures) | **BLOCKED — requires root, measured 2026-11-02.** The half fixtures cannot prove is `dump_volume_to_file` / `restore_volume_from_file`, and both `tar -C` the volume's host mountpoint. `/var/lib/docker` is `drwx--x--- root root`, so NO volume mountpoint is readable unprivileged — verified against a volume created for the probe and then removed. Isolation itself is sound and was checked: a `domum-rehearsal` compose project yields `domum-rehearsal_*` volumes, and production is `domum-media_*`. Unblock: run the rehearsal as root once written. See `docs/VOLUME-UPGRADE-REHEARSAL.md` for what it would prove and why a rootless variant was rejected |
| P3.5 | production upgrade of traefik / uptime-kuma | **BLOCKED — requires operator approval.** The action is "upgrade production applications" and setting `VOLUME_UPGRADE_ENABLED=1`, both explicitly prohibited ("keep volume-upgrade gates disabled"). Everything short of it is done and tested: model-aware dispatch, both verifiers, rollback restoring BOTH halves, a model-aware phase 4, and a gate that refuses before the lock and before any container is stopped |

---

## P4 — Storage

| # | item | status |
|---|---|---|
| P4.1 | scrub unit + timer written, not installed | **done; schedule now TESTED too** — `systemd-analyze calendar` resolves `Sun *-*-01..07 05:30:00` to the first Sunday monthly (next elapse 2026-12-06), which is the only part of a timer testable without installing it. Both units verify clean and neither is installed. The timer's comment justified `Persistent=true` with "this job deletes nothing" — true but the wrong reason for a READ-WRITE job; corrected to the real mitigations (`RandomizedDelaySec=20m`, and `--limit 150M` making it ~25 min rather than the measured 7m14s) |
| P4.2 | per-filesystem dedup so one filesystem is scrubbed once | **done** — `btrfs_unique_roots`, both directions tested |
| P4.3 | exit status contract (`0`/`1`/`3`) and a failed scrub failing the unit | **done** |
| P4.4 | SMART wear reaching the notifier | **done, and re-verified against the real host 2026-11-03** — driving the checks unprivileged confirmed a permission failure reports `UNKNOWN` as a WARNING with **zero CRITICAL** (the recorded defect, fixed), and exposed a new one: `mreport_smart_interpretable` collapsed "no table at all" into "placeholders", so /dev/sda — interpretable as root — was reported as holding vendor placeholders. Three states now (0/1/2), advice worded per cause, pinned by a section no fixture could have reached |
| P4.5 | duplicate-run protection *while a scrub is already running* | **done** — measured: `btrfs scrub start` on a busy filesystem returns non-zero and landed in the generic branch, so it reported `scrub FAILED`, failed the unit, and would have mailed a CRITICAL for an entirely normal condition. `btrfs_scrub_running` reads the `Status:` field and btrfs's own `already running` error closes the race; a skip does not fail the unit; the summary narrows its claim instead of saying `clean`; an unreadable status is `unknown`, never `not running`; an unrecognised error stays a failure. 1 mutant, killed |
| P4.6 | install + enable the scrub timer, run a scrub | **BLOCKED — requires operator approval.** The action is "enable timers", explicitly prohibited. Everything short of it is done: both units exist and pass `systemd-analyze verify`, neither is installed, the timer is absent from `auto-enable.timers`, and the schedule is calendar-tested (`Sun *-*-01..07 05:30:00` → first Sunday monthly, next elapse 2026-12-06). Unblock: `sudo install -m 0644 systemd/domum-media-btrfs-scrub.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now domum-media-btrfs-scrub.timer` |

---

## P5 — Disaster recovery

| # | item | status |
|---|---|---|
| P5.1 | credential-custody review + checklist | **done** — `docs/RECOVERY-KEY-CUSTODY.md` |
| P5.2 | off-site copy of the restic password / age private key | **BLOCKED — requires operator action, and it is the single highest remaining risk.** The action is making a credential copy, explicitly prohibited ("do not make or transmit credential copies automatically"; "do not access or display private key material"). 37 encrypted recovery packs exist and every one is unopenable without the age private key, which is deliberately not on this host. `docs/RECOVERY-KEY-CUSTODY.md` is the checklist; the custody decision is the operator's |
| P5.3 | fresh-host restore runbook validated end to end | **corrected, NOT validated** — `docs/disaster-recovery.md` now opens with a per-step proven/never-executed table and four stale claims are fixed: it offered **`nas` as the primary restore example** (a target with zero snapshots across 107 nightly runs and no mount on this host), said service-level Btrfs rollback is unavailable (five services have been subvolumes since 2026-09-25), said no guided PostgreSQL import exists (`verify-db-restore` is proven), and never mentioned that the cloud target is immich-only — so a fresh host comes up with the photo library and five media services as fresh installs. End-to-end validation needs a second machine (P5.5) |
| P5.4 | hidden recovery dependencies enumerated (pgvecto.rs, Jellyfin DataProtection-Keys, image identity) | **done** — `docs/HIDDEN-RECOVERY-DEPENDENCIES.md`, 12 entries, each citing the measurement and the document holding it. 8 are closed in code and still listed, because each was closed *after* giving the wrong answer first |
| P5.5 | full Immich restore → `FULL RECOVERY VERIFIED` | **BLOCKED — unavailable hardware.** A whole-tier restore is ~130 GiB from Hetzner plus a rebuilt Immich serving it, which needs the UGREEN machine. Proven instead, and deliberately not promoted: the dump imports (`verify-db-restore`), Immich OPENS the recovered database (phase A), and it SERVES 8 of 23,033 recovered originals byte-identically (phase B). Never claim the tier without doing the restore |

---

## P6 — Reliability

Found and fixed this session: see `CLAUDE.md`. Ongoing hunt, no fixed list.

| # | item | status |
|---|---|---|
| P6.1 | dry run must consult the silence gate | **done** (`f7e6d5d`) |
| P6.2 | one verdict ladder shared by body and subject | **done** (`f7e6d5d`) |
| P6.3 | audit remaining CLI paths for the defect families CLAUDE.md records | **pass 1 and pass 2 done; continuous** — pass 1: boolean `//` reads and trailing-field arity reads clean, three real aborts found and fixed (P6.4), audit shipped (P6.5). pass 2: the unbound-config-variable family **does not warrant an audit** — 14 of `load_cfg`'s 26 variables are read without a default across 160+ sites, all 24 dispatch arms reach a handler that calls `load_cfg`, and 20 suites stub it deliberately, so a rule would reject twenty suites and almost every CLI path. Recorded so it is not re-derived |
| P6.4 | three `set -euo pipefail` aborts where the producer may legitimately find nothing | **done** — the nightly dump's `docker ps` (an unreachable daemon aborted the backup instead of reporting the database absent), `dr-status`'s three `find`s on derivative subtrees that need not exist (the report died on a freshly restored host), and phase-b's live-photo selection (a user with no live photo aborted before the branch written for it). All three reproduced standalone before fixing; 1 mutant, killed |
| P6.5 | an AUDIT for that family, not just the three fixes | **done** — `tests/find-abort-audit.py` + smoke test, in CI. The cry-wolf worry was measured rather than assumed: 18 command substitutions contain a `find` and only **three** lacked a guard, all three real. One was `checkup`'s `waiting_count` over `image-updates`, which does not exist until `ensure_dirs` has run — the shape that blanked the report in production once already, still live in a second place. `bin/*` only, continuations joined, quoted heredocs skipped, and a `# find-audit:` marker exempts its own line and is printed |
