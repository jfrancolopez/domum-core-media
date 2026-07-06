# Task 15 — Unified logging convention  [shared-philosophy]

## Objective
Introduce a `log()` helper in `bin/domum-media` and stop hand-writing
`echo "[domum-media] ..."` at ~150 call sites, matching the convention being
adopted in the sibling repo (its backlog task 15).

## Files involved
- `bin/domum-media` — add `log()` next to `warn()`/`die()`; mechanical
  replacement of `echo "[domum-media] ...` call sites
- `bin/domum-media-backup` — already has a timestamped, file-teeing `log()`;
  align only if the sibling decision changes stdout/stderr routing

## Reason
The CLI has `warn()` and `die()` but no `log()` — every informational line
is a hand-typed `echo "[domum-media] ..."`. That's drift waiting to happen
(a few lines already lack the prefix) and makes any future change (adding
timestamps, tee to `$DOMUM_LOG_DIR`) a 150-line diff instead of a 1-line one.
The backup script does it right. Decide the exact format together with
domum-core's task 15 so both repos land the same helper shape.

## Implementation plan
1. Add `log() { echo "[domum-media] $*"; }` (or the timestamped variant if
   the sibling decision includes timestamps — check domum-core's task 15
   outcome first).
2. Mechanically replace `echo "[domum-media] ` → `log "` (careful with the
   few multi-line/heredoc cases and `>&2` variants — those become `warn`).
   Do NOT change any message text.
3. shellcheck will catch quoting mistakes from the replacement.

## Testing plan
- `diff <(old-cli checkup 2>&1) <(new-cli checkup 2>&1)` in a sandbox —
  byte-identical output (or identical modulo the agreed new prefix/timestamp).
- Smoke test + shellcheck + bash -n pass.

## Rollback plan
Revert.

## Dependencies
Coordinate format with domum-core backlog task 15 (whichever lands first
sets the convention).

## Risk / complexity / token size
Low (mechanical). Small–medium diff. ~8k tokens.

## Suggested order
15.
