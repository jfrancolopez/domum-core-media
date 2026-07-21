# Task 29 — Compose paths derive from DOMUM_DATA_ROOT

## Objective
Replace the hardcoded `/srv/data` bind paths in the Immich and Tailscale
compose fragments with `${DOMUM_DATA_ROOT}` interpolation, so the
configurable storage root is actually honored everywhere.

## Files involved
- `compose/photos/immich.yml` — `/srv/data/immich/library` (~15),
  `/srv/data/immich/postgres` (~64)
- `compose/security/tailscale.yml` — `/srv/data/tailscale` (~18)
- `config/ci.env` (ensure `DOMUM_DATA_ROOT` is set for the render check)

## Reason
`DOMUM_DATA_ROOT` exists precisely so the durable root is configurable, and
most fragments honor it via their per-service dir vars (e.g.
`compose/media/jellyfin.yml` uses `${JELLYFIN_CONFIG_DIR:?}`). Immich and
Tailscale hardcode `/srv/data`: on any host configured with a different
root, Immich would write the photo library and PostgreSQL data to an
unmounted/unprotected path — the worst possible silent divergence. On
default hosts this change is a byte-identical mount spec, i.e. a no-op
recreate.

## Implementation plan
1. Use the repo's existing convention: either direct
   `${DOMUM_DATA_ROOT:?}/immich/library` or per-service dir vars exported
   from `export_env_for_compose()` (~940) like the other media services —
   pick whichever matches the surrounding fragment style, with `:?` guards
   so a missing root fails the render loudly.
2. Same for the Tailscale state dir.
3. Verify `export_env_for_compose` exports `DOMUM_DATA_ROOT` (or the new
   per-service vars) into the compose environment.

## Testing plan
- CI render with default `DOMUM_DATA_ROOT=/srv/data`: `docker compose
  config` output byte-identical to before (proves no-op on the live host).
- Render with a non-default root: mounts follow it; unset root fails the
  render with the `:?` message.
- On-host `apply`: no container recreation reported (identical config).

## Rollback plan
Revert; fragments return to literal paths. No data moves either way.

## Dependencies
None. Blocks task 27 (docs describe converged paths, not the hardcodes).

## Risk / complexity / token size
Low (byte-identical render on default hosts is the acceptance bar). Small.
~4k tokens.

## Suggested order
Phase 3, first task of the phase (pure repo change, no maintenance window).
