# Task 02 — Fix `updates` exit code when Immich is disabled

## Objective
`domum-media updates check` / `updates apply` must exit 0 on success even
when Immich is disabled.

## Files involved
- `bin/domum-media` — `updates_cmd()` (~lines 2214–2215)

## Reason
Both branches end with:
```
[[ "${ENABLE_IMMICH:-0}" == "1" ]] && immich_refresh_bundle ...
```
When `ENABLE_IMMICH=0`, the `[[ ]]` test fails, it is the last command in the
case branch, so `updates_cmd` — and therefore the whole CLI — exits 1 after a
completely successful run. Anything scripting the command (a future timer, a
checkup action, `set -e` in a wrapper) sees a false failure.

## Implementation plan
1. Replace the trailing `&&` chains with an explicit guard:
   ```
   if [[ "${ENABLE_IMMICH:-0}" == "1" ]]; then
     immich_refresh_bundle --check-only
   fi
   ```
   (same shape for the `apply` branch with its flags).
2. Grep the rest of the CLI for the same `[[ ... ]] && cmd` pattern in
   tail position of a function/case branch; fix any other instance found
   (report them in the PR description rather than silently expanding scope).

## Testing plan
- With `ENABLE_IMMICH=0` in a sandbox conf: `domum-media updates check; echo $?`
  prints 0 (stub docker/compose as the smoke test does).
- With Immich enabled: behavior unchanged.
- `bash -n` + shellcheck pass.

## Rollback plan
Revert.

## Dependencies
None.

## Risk / complexity / token size
Low. Trivial. ~4k tokens.

## Suggested order
2.
