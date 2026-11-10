# domum-core-media/APP-04 Add Paperless-ngx

| Field | Value |
| --- | --- |
| Status | QUEUED |
| Priority and reason | P3 — requested, but it creates a second irreplaceable dataset |
| Effort and change risk | Half a day for the repo half; high data sensitivity |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker, then owner; owner request 2026-11-10 |
| Dependencies | `../../QUEUE.md` P1.7 (an off-site target for non-Immich state) and P5.2 (recovery key held off-host) |

## Outcome

Scanned bills, IDs and manuals have no searchable home. After this task
Paperless-ngx stores them with OCR and full-text search.

## Why it waits

Photos have an off-site copy. Nothing else on this server does. Paperwork is
irreplaceable and more sensitive than photos, so it must be in an off-site
backup from its first document, and the key that opens that backup must exist
somewhere other than this house. Both are open items in the main queue.
Installing the app first would put identity documents on one SSD with no copy.

## Scope and setup

- A managed service with three containers: the app, PostgreSQL, Redis. Reuse the Immich pattern for the database dump (`tests/atomic-immich-pg-dump-smoke.sh` shows the contract): the backup artefact is a validated dump, never live database files.
- State under `/srv/data/paperless` as a Btrfs subvolume: `media/` (originals and archive PDFs, irreplaceable), `data/` (index, regenerable), `consume/` (inbox).
- Off-site scope: `media/` and the dump. Not the index.
- Declarations as APP-02. OCR is CPU-heavy; set worker count to 1 and a memory limit so a large scan cannot starve Immich.
- Use Paperless's own accounts with a strong password. Family devices get no access unless the owner says so (see SEC-05).

## Before editing

- QUEUE P1.7 and P5.2 are `done` with evidence. If either is not, stop.
- Baseline: the suites named in APP-02.

## Implementation and checkpoints

1. Fragment, variables, declarations.
   - **Check** compose `config -q`; `tests/state-model-smoke.sh`
   - **Expected** exit 0
2. Database dump and import verification, mirroring `verify-db-restore`: the dump imports into a disposable PostgreSQL under `ON_ERROR_STOP=1`.
   - **Expected** import exits 0; a truncated dump fails
3. Add `media/` and the dump to the off-site target chosen in P1.7.
   - **Check** `domum-media-backup backup-scope <path> --json` in a fixture (confirm the subcommand is in the binary under test)
   - **Expected** exit 0, in scope
4. Restore rehearsal: one document in, capture, destroy, restore, the document opens and its text is searchable.

## Acceptance

- Pre-review: CI green; rehearsal recorded.
- Negative: with the off-site target disabled in a fixture, `checkup` reports the paperwork as not covered.
- **Owner gate:** deployment, and the first real document only after one off-site snapshot containing a test document has been listed from another machine.

## Rollback and stop conditions

`git revert`. In production, stop the containers and keep the subvolume. Never delete documents to roll back.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** none until dependencies clear
- **Open items** scanner or phone-app intake path is the owner's choice
