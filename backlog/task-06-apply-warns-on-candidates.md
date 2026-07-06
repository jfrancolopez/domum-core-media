# Task 06 — Warn on pending update candidates during `apply`  [shared-philosophy]

## Objective
Close the same gap found in domum-core: image checks pull newer images for
moving tags, and a later `domum-media apply` (`compose up -d`) rolls them out
immediately — no delay window, no pre-update snapshot, no health-gated
rollback, no history entry.

## Files involved
- `bin/domum-media` — `apply()` (~line 2487)
- `docs/SETUP-UPDATES.md` (document the behavior)

## Reason
`refresh_images` runs `compose_cmd pull "$svc"` on every check. All service
images are moving tags (`:latest`, `:stable`, `:release`), so after a pull
the local tag points at the new image. `refresh_images` then carefully waits
out the delay window with snapshot + backup gate + health validation — but
plain `apply` recreates containers on whatever the tag points to *right now*,
bypassing that entire pipeline. `apply` does take a pre-apply snapshot
(good), but no health-gated rollback and no update history, and the operator
doesn't know an unplanned version rollout just happened.

## Implementation plan
1. At the top of `apply()` (after `load_cfg`), scan
   `$DOMUM_STATE_ROOT/image-updates/*.env` and the Immich
   `bundle-candidate.env`; if any exist for enabled services, print:
   ```
   WARN: pending image updates: <list>
   WARN: apply recreates containers and WILL roll these out now,
         outside the delay/rollback pipeline.
   ```
   and require typed confirmation (apply is always interactive — the timers
   call `refresh-images`/backup/checkup, never `apply`; verify that claim by
   grepping the systemd units before relying on it).
2. If the operator proceeds, record an `applied via apply` entry in update
   history for each affected service after `compose up` succeeds, and clear
   the candidate state files whose digests now match running containers.
3. Document in `docs/SETUP-UPDATES.md`: "checks download images; apply after
   a check rolls them out."

## Testing plan
- Fabricate a candidate env file for an enabled service → `apply` warns and
  prompts; decline aborts before `compose up`.
- No candidates → `apply` output unchanged.
- Smoke test + shellcheck pass.

## Rollback plan
Revert; `apply` returns to silent rollout behavior.

## Dependencies
None. Mirrors domum-core backlog task 09 — keep the wording/UX similar so the
two CLIs feel like siblings.

## Risk / complexity / token size
Low–medium (touches `apply`). Small. ~8k tokens.

## Suggested order
6.
