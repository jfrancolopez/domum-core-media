# Task 05 — Guard `git reset --hard` against local drift  [shared-philosophy]

## Objective
Warn (and require confirmation when interactive) before discarding local
changes in `/opt/domum-core-media`, in both `repo_update()` and `install.sh`.

## Files involved
- `bin/domum-media` — `repo_update()` (~line 2604)
- `install.sh` — `clone_or_update_repo()` (~line 119)
- `README.md` (one sentence if wording about "resettable checkout" changes)

## Reason
Both paths run `git reset --hard origin/main` unconditionally. The
"resettable checkout" model is intentional here — but the sibling repo
already learned this lesson and added a drift check: uncommitted local edits
(a hotfix made over SSH at 2 a.m., a config experiment in a tracked file) are
silently destroyed. Untracked files (the live conf, secrets) survive a hard
reset, so the risk is specifically *tracked-file* edits — exactly the ones
you made deliberately.

Also note: `repo_update` chains straight into `exec domum-media apply`.
That fusion is intentional (documented flow: push → SSH → update) — keep it,
but the reset must not eat work silently first.

## Implementation plan
1. Port the sibling's pattern: before resetting, run
   `git diff --quiet && git diff --cached --quiet`; if dirty, print the
   changed files and require a typed confirmation (`read -r -p ... yes`).
   In `install.sh` (curl|bash, possibly non-interactive): warn and **skip
   the reset** like domum-core's installer does, telling the operator to
   resolve and re-run — never prompt in a piped script.
2. Keep `exec apply` in `repo_update` unchanged.
3. Add an `--assume-yes`-style escape only if you find a non-interactive
   caller of `repo_update` (none exist today — the timers never call it).

## Testing plan
- Clean checkout: `domum-media update` behaves exactly as before.
- Dirty tracked file: `update` prompts; installer warns and skips reset.
- shellcheck + bash -n pass.

## Rollback plan
Revert; unconditional reset returns.

## Dependencies
None.

## Risk / complexity / token size
Low. Small. ~6k tokens.

## Suggested order
5.
