# Task 07 — Align `--force` semantics across update commands

## Objective
Make `--force` mean the same thing everywhere, and say what it does in the
usage text.

## Files involved
- `bin/domum-media` — `refresh_images()` (~line 1950),
  `immich_refresh_bundle()` (~line 2231), `usage()`
- `docs/SETUP-UPDATES.md`

## Reason
Today the flags mean different things in the two update pipelines:
- `refresh-images --force`: bypasses only the global
  `IMAGE_AUTO_UPDATE_ENABLED` gate. It does **not** bypass the per-service
  delay window — that's `--apply-now`. The backup gate always applies.
- `immich refresh-bundle --force`: bypasses the auto-update gate **and** the
  delay window (candidate goes straight through).

So "force" is weaker for regular services than for Immich — the service
where you'd least want a stronger force. `updates apply` papering over it
with `--apply-now --force` shows the flags have grown organically. This is
the same *family* of bug as domum-core's broken `--force` (there it silently
did nothing); here it silently does different things.

## Implementation plan
1. Decide the contract (recommend, matching the sibling):
   - `--check-only`: report, change nothing.
   - `--apply-now`: bypass the delay window (both pipelines).
   - `--force`: bypass the enable/auto-update gates only.
   - Backup freshness gate is never bypassed by any flag (already true —
     keep it that way and state it).
2. In `immich_refresh_bundle`, split the current `--force` behavior:
   accept `--apply-now` for the delay bypass; keep `--force` for the gate
   bypass; update `immich_cmd`'s `apply-bundle` to pass both (preserving its
   current behavior).
3. Update `usage()` and `docs/SETUP-UPDATES.md` with one line per flag.

## Testing plan
- Sandbox with a candidate inside its delay window:
  `refresh-images --force` → still waits; `--apply-now` → proceeds (to the
  backup gate). Same matrix for the immich bundle path.
- `updates apply` end-to-end behavior unchanged.
- Smoke test + shellcheck pass.

## Rollback plan
Revert; old mixed semantics return.

## Dependencies
Task 02 (touches the same `updates_cmd` region — land 02 first to avoid
conflicts).

## Risk / complexity / token size
Low. Small. ~7k tokens.

## Suggested order
7.
