# domum-core-media/SEC-00 Remove the real domain from docs

| Field | Value |
| --- | --- |
| Status | READY_FOR_REVIEW |
| Priority and reason | P1 — decision D-1; the repository is public |
| Effort and change risk | Done; docs only, no behaviour change |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker; finding F-01, decision D-1 |
| Dependencies | First task on the repo track |

## Outcome

Six files under `docs/` named the production domain. They now use `example.test`.

## Scope and setup

`docs/` only. The config example and CLI defaults are SEC-01. Git history is unchanged (D-1a).

## Before editing

Nothing further to edit. To re-check from the repo root: `git grep -c 'example.test' -- docs` prints six files.

## Implementation and checkpoints

1. Replace the domain in the six documents.
   - **Check** count of the real domain under `docs/` before and after the edit
   - **Expected** 8 before, 0 after
   - **Result** PASS (8 → 0)

## Acceptance

- Pre-review: `python3 tests/documented-commands-audit.py`, `python3 tests/no-conflict-markers-audit.py`, `tests/repo-hygiene-smoke.sh` all exit 0.
- Pre-review: diff touches only `docs/`, 8 lines in 6 files.
- Post-landing: none.

## Rollback and stop conditions

`git revert` the commit. No runtime effect.

## Verification handoff

- **Result** READY_FOR_REVIEW, 2026-11-10
- **References** base `e0754a8`; implementation commit `3163086` on local branch `backlog/security-and-apps-2026-11`; not pushed, no PR
- **Evidence** occurrence count PASS (8 → 0); documented-commands-audit PASS (exit 0); no-conflict-markers-audit PASS (exit 0); repo-hygiene-smoke PASS (exit 0). Full CI NOT RUN (branch not pushed)
- **Next model** `git grep -c 'example.test' -- docs | wc -l` prints `6`; next is SEC-01
- **Open items** owner review and push; history still holds the domain (D-1a)
