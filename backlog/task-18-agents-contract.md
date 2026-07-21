# Task 18 — AGENTS.md agent contract  [shared-philosophy]

## Objective
Create an `AGENTS.md` execution contract at the repo root, ported from
`domum-core/AGENTS.md` and adapted to this repo's CLI names, paths, and
verification commands, so every implementing agent works under the same
prime directives.

## Files involved
- `AGENTS.md` (new)
- `backlog/README.md` ("For implementing agents" section links to it)

## Reason
domum-core has an explicit contract (prime directives: never delete data /
secrets / backups, secrets never touch git, checkout ≠ production host,
disposable-OS philosophy, simplest-change-wins; plus the backlog workflow,
pre-commit verification block, and stop-and-ask conditions). This repo has
none, and it is the repo where an agent's mistake can touch the family photo
library. The contract must exist before the riskier phases start — it
soft-blocks every other task.

## Implementation plan
1. Read `domum-core/AGENTS.md` as the source. Keep its structure and prime
   directives verbatim where they are repo-agnostic.
2. Adapt specifics: CLI names (`bin/domum-media`, `bin/domum-media-backup`),
   paths (`/opt/domum-core-media`, `/etc/domum-core-media/secrets`,
   `/var/lib/domum-media`, `/srv/data`, `/srv/media`), the verification
   block (`bash -n`, `shellcheck --severity=warning`,
   `tests/immich-secret-propagation-smoke.sh`, compose config with
   `config/ci.env`).
3. Add one media-specific prime directive: `domum-core` is a read-only
   pattern reference — port from it, never modify it, never copy its known
   defects (unprefixed named-volume backup names; manifest written before
   volume exports).
4. Add the backlog workflow: one task per session, work phases in order,
   update the task's Status in `backlog/README.md` in the same commit,
   Operator-runbook tasks never auto-applied.

## Testing plan
- Every command named in the verification block actually exists and runs
  from a clean checkout.
- Every path named in the contract matches `config/domum-media.conf.example`
  defaults.

## Rollback plan
Delete the file; no runtime behavior involved.

## Dependencies
None. Soft-blocks all other tasks (contract first).

## Risk / complexity / token size
None (docs only). Small. ~6k tokens.

## Suggested order
Phase 0, after task 09.
