# Task 03 — Fix checkup update-history counters (always zero)

## Objective
Make the "delay-reset events in the last 7 days" and "failed update events in
the last 30 days" checkup warnings actually fire.

## Files involved
- `bin/domum-media` — `checkup_cmd()` (the `reset_recent` / `failed_recent`
  block, ~line 3240)

## Reason
Update-history files are written by `write_env_kv()` using `printf '%s=%q'`,
which produces unquoted values like `EVENT=delay_reset` and `RESULT=failure`.
The checkup greps for `\"EVENT='delay_reset'\"` and `\"RESULT='failure'\"` —
patterns containing literal double quotes *and* single quotes that never
appear in the files. Both counters are therefore always 0, and the operator
never learns from `checkup` that updates have been failing or upstream images
churning. Monitoring that silently reports "all clear" is worse than none.

## Implementation plan
1. Fix the grep patterns to match the actual format:
   `grep -l "^EVENT=delay_reset$"` and `grep -l "^RESULT=failure$"`.
   Check one real file under `/var/lib/domum-media/update-history/` first to
   confirm the exact on-disk form (`%q` may add quoting only if the value
   needs it — for these two values it does not).
2. While in there, confirm `update_rollback_entry_status()` (which writes
   `STATUS='consumed'` WITH quotes via awk) is read back consistently by its
   own consumers (`rollback_entries` sources the file, so quoting is fine
   there — verify, don't change).

## Testing plan
- Sandbox: write a fake history file with `RESULT=failure` dated now;
  run checkup with stubs; the warning appears. Same for `EVENT=delay_reset`.
- On the host: `sudo domum-media checkup` — counters reflect reality.

## Rollback plan
Revert.

## Dependencies
None.

## Risk / complexity / token size
Low. Trivial. ~4k tokens.

## Suggested order
3.
