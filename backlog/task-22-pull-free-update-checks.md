# Task 22 — Pull-free update checks during delay windows

## Objective
Stop `refresh_images` from pulling new images while a candidate is still
inside its delay window. Check remote digests without pulling; pull only
when the candidate is due. This closes the gate-bypass hole at its source:
`apply` can no longer deploy an un-aged image, because the image simply
isn't on disk yet.

## Files involved
- `bin/domum-media` — `refresh_images` (`compose_cmd pull "$svc"` at ~1988;
  delay logic ~1993–2028; `verify_backup_freshness` call ~2073, def ~831)

## Reason
Today every check run pulls the newest image for every managed service, even
during the aging window. Since all configured tags are moving
(`:latest` / `:release`, see `config/domum-media.conf.example`), a plain
`apply` (`up -d` at ~2516) then recreates containers on the freshly pulled
image — skipping candidate aging, the backup-freshness gate, update history,
and rollback preparation. Task 06 adds a warning in `apply`; this task
removes the loophole itself. Remote-digest inspection (e.g.
`docker manifest inspect` or `docker buildx imagetools inspect`, whichever
is available on the host) lets the delay logic see "new digest exists,
candidate started <date>" without materializing the image locally.

## Implementation plan
1. In the check path, replace the unconditional `compose_cmd pull` with a
   remote digest lookup; record candidate-first-seen state exactly as today
   (state file format unchanged if possible).
2. Pull only when: candidate age ≥ its class delay AND the backup gate
   passes — i.e., immediately before the update actually applies.
3. Keep `--force` semantics consistent with task 07: force = "act now",
   which then does pull + apply in one path.
4. Handle registries where the digest probe fails (rate limits, auth):
   degrade loudly to the old pull-based behavior for that service, never
   silently skip the delay accounting.
5. Update `docs/SETUP-UPDATES.md` to describe the new mechanics.

## Testing plan
- Fixture/state-file test: new upstream digest → candidate recorded, no
  local pull (verify via `docker images` digest absence), `apply` recreates
  nothing.
- Candidate past its delay → pull happens, update proceeds, history written.
- Digest probe failure → visible warning, behavior falls back, delay state
  still correct.
- On-host `updates` run before/after shows identical candidate reporting.

## Rollback plan
Revert; checks return to pull-eagerly behavior (the hole reopens, tracked by
task 06's warning).

## Dependencies
Task 20 (locking — refresh and apply must exclude each other before the
pull timing becomes correctness-relevant). Task 07 (force semantics defined
first). Task 06 stays as scoped — its warning remains a second line of
defense.

## Risk / complexity / token size
Medium (touches the heart of the update scheduler; mitigated by unchanged
state format and loud fallback). Medium. ~10k tokens.

## Suggested order
Phase 2, after tasks 08/07/06.
