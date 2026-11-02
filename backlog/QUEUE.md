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

## P1 — Selective off-site protection for media-service state

Design: `docs/SELECTIVE-STATE-PROTECTION.md`. Phase A measured, Phase B
designed. **No implementation exists** — verified 2026-11-03, there is no
`service_state_capture` or equivalent in either CLI.

| # | item | status |
|---|---|---|
| P1.1 | declare navidrome's in-image sqlite3 | **done** — ships 3.45.3, was undeclared; its db is WAL-mode with a live 20,632-byte `-wal`, so a file copy is torn |
| P1.2 | declare per-service essential state (what to capture) | open |
| P1.3 | `service_state_capture` — SQLite-consistent where possible, reusing the `.backup` pattern | open |
| P1.4 | capture manifest: sha256, sizes, image identity, capture mode | open |
| P1.5 | restore into a scratch target, never over live state | open |
| P1.6 | disposable-fixture tests + mutations | open |
| P1.7 | activate a production backup target for it | **BLOCKED** — operator decision; needs the archive size (P2.1) for the cost figure |

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
| P2.1 | measure `/srv/data/backups/images` | **BLOCKED** — `root 0750`. Unblock: `sudo du -sb /srv/data/backups/images && sudo ls -l /srv/data/backups/images` |
| P2.2 | identify which archives a *still-valid* recovery point names | partially blocked — `cleanup images --json` computes it but reads `/var/lib/domum-media` (root) |
| P2.3 | off-site preservation + retention procedure for archives | open — designable now, depends on P2.1 only for the cost figure |
| P2.4 | restore-from-archive procedure, proven on a disposable image | open |

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
| P3.3 | readiness log pattern consulted by the upgrade, with a bounded wait | open — reverted once for escalating without a wait; needs its own tests |
| P3.4 | end-to-end rehearsal against **real disposable containers** (not fixtures) | open |
| P3.5 | production upgrade | **BLOCKED** — `VOLUME_UPGRADE_ENABLED=0`, operator decision |

---

## P4 — Storage

| # | item | status |
|---|---|---|
| P4.1 | scrub unit + timer written, not installed | **done** — unit exists in `systemd/`, absent from the host |
| P4.2 | per-filesystem dedup so one filesystem is scrubbed once | **done** — `btrfs_unique_roots`, both directions tested |
| P4.3 | exit status contract (`0`/`1`/`3`) and a failed scrub failing the unit | **done** |
| P4.4 | SMART wear reaching the notifier | **done** (`b8a36e6`) |
| P4.5 | duplicate-run protection *while a scrub is already running* | open — verify `btrfs scrub start` behaviour on a busy filesystem is handled |
| P4.6 | install/enable the timer, run a scrub | **BLOCKED** — operator decision |

---

## P5 — Disaster recovery

| # | item | status |
|---|---|---|
| P5.1 | credential-custody review + checklist | **done** — `docs/RECOVERY-KEY-CUSTODY.md` |
| P5.2 | off-site copy of the restic password / age key | **BLOCKED** — operator action, and the single highest remaining risk |
| P5.3 | fresh-host restore runbook validated end to end | open |
| P5.4 | hidden recovery dependencies enumerated (pgvecto.rs, Jellyfin DataProtection-Keys, image identity) | open |
| P5.5 | full Immich restore | **BLOCKED** — needs the UGREEN hardware; never claim it without doing it |

---

## P6 — Reliability

Found and fixed this session: see `CLAUDE.md`. Ongoing hunt, no fixed list.

| # | item | status |
|---|---|---|
| P6.1 | dry run must consult the silence gate | **done** (`f7e6d5d`) |
| P6.2 | one verdict ladder shared by body and subject | **done** (`f7e6d5d`) |
| P6.3 | audit remaining CLI paths for the defect families CLAUDE.md records | open — continuous |
