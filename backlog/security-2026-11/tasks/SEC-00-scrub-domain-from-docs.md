# domum-core-media/SEC-00 Remove the real domain from docs

| Field | Value |
| --- | --- |
| Status | DONE — merged 2026-11-10 via PR #196 |
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

- **Result** DONE — merged 2026-11-10; independent review and PR CI PASS.
- **References** implementation `3163086`; review record `94885bf`; PR [#196](https://github.com/jfrancolopez/domum-core-media/pull/196); merge commit `e53adf2`.
- **Evidence** docs-only matching lines PASS (8 at baseline → 0 after); `example.test` appears in six docs; implementation diff is 6 files / 8 insertions / 8 deletions, all under `docs/`. `documented-commands-audit` PASS (106); `no-conflict-markers-audit` PASS (267); `repo-hygiene-smoke` PASS; GitHub `compose-validate` PASS on `42865dd`.
- **Next model** SEC-01; `git grep -c 'example.test' -- docs | wc -l` prints `6`.
- **Open items** history still holds the domain as selected by D-1a.
