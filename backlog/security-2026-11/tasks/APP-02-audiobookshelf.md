# domum-core-media/APP-02 Add Audiobookshelf

| Field | Value |
| --- | --- |
| Status | QUEUED |
| Priority and reason | P2 — requested; no current app handles audiobooks or podcasts with progress sync |
| Effort and change risk | 2–3 h for the repo half; medium. Deployment is the owner's |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker, then owner; owner request 2026-11-10 |
| Dependencies | D-4 (it also reads ebooks, which may settle which book server stays) |

## Outcome

Audiobooks and podcasts have no home. After this task Audiobookshelf is a
managed service: listening progress syncs across phones, podcasts download on a
schedule, and its state is protected like the other five media services.

## Why this app

Self-hosted, no vendor account, native iOS and Android apps, light on an N100.
Its ebook reader is basic; it does not replace Kavita for comics or Calibre-Web
for library editing.

## Scope and setup

- Follow `docs/add-new-service.md` step by step; it is the authority.
- New fragment `compose/media/audiobookshelf.yml`, modelled on `compose/media/navidrome.yml`: proxy network, `securityHeaders@file`, media mounted read-only at a new `/srv/media/audiobooks` and `/srv/media/podcasts`, config and metadata under `/srv/data/audiobookshelf`.
- Declare everything the newer services needed, or the gates fail closed: `service_state_models` (`protected-tier`), `service_essential_state` (its SQLite database and config), `service_sqlite_binary` if the image ships one, `service_ready_log_pattern`, the toggle and image variables in the config example and `config/ci.env`, and a monitor entry.
- Create the state path as a Btrfs subvolume from the start, so it never needs migrating.
- Podcast downloads write to the media tier: mount only `/srv/media/podcasts` read-write.

## Before editing

- D-4 has a **Selected** line.
- Baseline: `tests/state-model-smoke.sh`, `tests/monitoring-completeness-smoke.sh`, `tests/state-capture-smoke.sh` exit 0.

## Implementation and checkpoints

1. Add the fragment and variables.
   - **Check** the compose `config -q` step from the workflow
   - **Expected** exit 0
2. Add the declarations.
   - **Check** the three baseline suites
   - **Expected** exit 0, and the new service appears in each
3. Measure, do not assume, in a disposable container pinned by image ID: which files hold state, whether the database is WAL-mode (header bytes 18/19), whether the image ships `sqlite3`, and what line marks readiness.
   - **Expected** each declaration in step 2 cites a measurement
   - **Failure action** correct the declaration; never declare a path a fresh install does not create
4. Capture and restore rehearsal as in `operator/rehearsals/navidrome-capture-restore-start.sh`.
   - **Expected** the restored instance starts and a marker row survives
5. Update `docs/STATE-CLASSIFICATION.md` and `docs/OFFSITE-COVERAGE-CLASSIFICATION.md`.
   - **Check** `python3 tests/documented-commands-audit.py`

## Acceptance

- Pre-review: CI green; rehearsal output recorded with image IDs.
- Regression: `domum-media storage protection audiobookshelf` reports the declared model in a fixture.
- **Owner gate:** creating the subvolume, DNS, and first start are production changes.
- Stated limit: until `../../QUEUE.md` P1.7 is decided, its state is on this SSD only, like the other media services. Listening progress is the only part that cannot be re-downloaded.

## Rollback and stop conditions

`git revert`; in production, stop the container and keep the subvolume.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** `tests/state-model-smoke.sh` lists the service; next is APP-05
- **Open items** whether it replaces a book server (D-4)
