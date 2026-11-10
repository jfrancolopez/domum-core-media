# domum-core-media/APP-01 Measure real use of the overlapping apps

| Field | Value |
| --- | --- |
| Status | READY |
| Priority and reason | P2 — evidence for D-4; each retired app is one less thing to patch and back up |
| Effort and change risk | 45 min; none, read-only |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker; finding F-17, decision D-4 |
| Dependencies | First task on the apps track |

## Outcome

Two video servers and two book servers run beside a media tier of 5.1 GB of
music and under 1 MB of books. Nobody has measured which are opened. After this
task [D-4](../DECISIONS.md) has numbers under it.

## Scope and setup

- Read-only. No app setting changes, no container restarts, no query against a live database file from the host (WAL-mode databases must not be opened from outside; see `CLAUDE.md`).
- Sources, in order of preference: Traefik's access log (`docker logs traefik`, one line per request with the router name), then each app's own activity view in its UI (owner).
- Write results to `docs/APP-USAGE-<date>.md`: counts and dates only. No usernames, client addresses, titles or hostnames.

## Before editing

`docker logs --since 24h traefik 2>&1 | wc -l` prints a number above 0. If the access log is empty, record that and fall back to the owner reading each app's activity page.

## Implementation and checkpoints

1. Establish how far back the Traefik log goes.
   - **Check** capture `docker logs traefik` to a file in a scratch directory, then read the first and last timestamps
   - **Expected** a window of at least 7 days; if shorter, state the window and say the measurement is weak
   - **Time and failure action** 5 min
2. Count requests per router per day, excluding health probes from the monitor.
   - **Check** total lines in equals lines attributed plus lines excluded (`CLAUDE.md`: a pipeline that can drop a record is not a measurement)
   - **Expected** the tallies agree
   - **Time and failure action** 20 min
3. Record library sizes per app's media root with `du -sh`.
   - **Expected** matches the audit's figures or the difference is explained
4. Write the document with a table: app, days with any use, requests, media it serves, state size from `../../QUEUE.md`.
   - **Check** `python3 tests/documented-commands-audit.py`
   - **Expected** exit 0

## Acceptance

- Pre-review: the document states its window and its tally check.
- Negative check: `git diff` contains no address, username or hostname.
- Owner gate: D-4 is the owner's to select; this task recommends and stops.

## Rollback and stop conditions

Delete the scratch capture. `git revert` the document.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** the usage document exists and its tallies agree
- **Open items** a 7-day window undercounts occasional use; the owner's own knowledge outranks it
