# Task 09 — Untrack `.claude/settings.local.json`

## Objective
Stop tracking local AI-agent permission state in git, matching the sibling
repo (which gitignores `.claude/` entirely).

## Files involved
- `.claude/settings.local.json` (untrack)
- `.gitignore` (add `.claude/`)

## Reason
`.claude/settings.local.json` is machine-local editor/agent state (a Bash
permission allowlist accumulated during past sessions). It is tracked here
but gitignored in domum-core — accidental drift, and the file's own name says
`local`. It carries no secrets today, but it churns with every AI session and
has no business in the deploy checkout that gets `git reset --hard` on the
host (a reset would clobber the host's local copy with the laptop's).

## Implementation plan
1. `git rm --cached .claude/settings.local.json`
2. Add to `.gitignore` (mirror domum-core's block):
   ```
   # Local editor and AI agent workspace state
   .claude/
   ```
3. Commit with a note that other checkouts keep their local copy on disk
   after pulling.

## Testing plan
- `git ls-files | grep claude` → empty.
- File still present on disk; `git status` clean.

## Rollback plan
Revert; re-add the file.

## Dependencies
None.

## Risk / complexity / token size
None. Trivial. ~2k tokens.

## Suggested order
9 (any time).
