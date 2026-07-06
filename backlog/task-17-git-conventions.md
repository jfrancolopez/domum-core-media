# Task 17 — FUTURE: Adopt the shared git-workflow conventions doc  [shared-philosophy]

## Objective
Copy the one-page git conventions doc from domum-core (its backlog task 16)
into this repo, names swapped, once it exists.

## Files involved
- `docs/reference/git-workflow.md` (new — path assumes task 14's layout;
  use `docs/git-workflow.md` if 14 hasn't landed)
- `docs/README.md` index entry (if it exists by then)

## Reason
This repo's history has the same three commit dialects as the sibling
(`backup: Hetzner Storage Box fix 2`, `phase 2: ...`,
`refactor: replace DOMUM_HOT_ROOT...`). One shared page — commit style,
branch usage, the push→SSH→update deploy contract, and the never-commit list
— is the cheapest possible sibling-foundation win. Deliberately no hooks,
no commitlint, no enforcement.

## Implementation plan
1. Wait for domum-core's `docs/reference/git-workflow.md` to land.
2. Copy it; swap `domum-core`→`domum-core-media`, `domum-core update`→
   `domum-media update`, and the never-commit list to this repo's paths
   (`config/domum-media.conf`, `/etc/domum-core-media/secrets`, rendered
   `dashboard.yml`).
3. Note this repo's one workflow difference: `domum-media update` hard-resets
   and auto-applies (post task 05: with drift confirmation).

## Testing plan
- Links resolve; nothing executable.

## Rollback plan
Delete the doc.

## Dependencies
domum-core backlog task 16 (the source doc). Optionally task 14 (path).

## Risk / complexity / token size
None. Trivial. ~3k tokens.

## Suggested order
17 — last.
