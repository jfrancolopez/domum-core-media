# Task 35 — Health probes via catalog

## Objective
Give every media service a real health probe, driven by a catalog column,
so "update succeeded" and "apply succeeded" mean the application answers —
not merely that a container is running.

## Files involved
- `bin/domum-media` — catalog `health_url` column (the
  `service_lifecycle_specs` health field is currently empty for most
  services), `wait_for_service_health` / the post-update health wait, the
  auto-rollback trigger (~2084–2090), `checkup` diagnostics loops (~2174,
  ~3178)
- Compose fragments — add `healthcheck:` blocks only where the upstream
  image supports a cheap in-container check reliably

## Reason
Lifecycle health URLs are mostly empty, so the update pipeline's
health-gate-then-rollback promise degenerates to "container didn't exit."
An app that starts but serves 500s sails through, and auto-rollback (task
24 makes it fully meaningful) never fires. Cheap HTTP probes exist for
every service: Immich server (`/api/server/ping`), Jellyfin
(`/health`), Navidrome (`/ping`), Kavita (`/api/health`), Calibre-Web
(login page 200), Plex (`/identity`), Uptime Kuma (root 200/302), Traefik
(`/ping` if enabled in static config).

## Implementation plan
1. Fill the catalog health column for all services; probe from the host via
   the published/internal port (the CLI already knows service hosts/ports
   from config).
2. Post-update wait: bounded retry loop (timeout per class) probing the
   URL; failure triggers the existing rollback path.
3. `checkup`: probe enabled services, report per-service health.
4. Compose `healthcheck:` blocks only where curl/wget exists in the image
   and the endpoint is stable across versions — the catalog probe is the
   source of truth; compose checks are best-effort container-level extras
   (they feed `depends_on: condition: service_healthy` for postgres/redis
   which Immich already uses).
5. Verify each endpoint against the *currently pinned* image versions, not
   documentation memory.

## Testing plan
- Fixture: break one service (wrong internal port) → update health-gate
  fails → auto-rollback fires despite the container "running".
- All-healthy host: checkup shows green per service; apply wait passes
  quickly.
- Endpoints validated with `curl -fsS` against the live host once.

## Rollback plan
Revert; probes return to empty, pipeline returns to container-level checks.

## Dependencies
Task 16 (catalog column lives there; can technically amend
`service_lifecycle_specs` earlier, but doing it once in the catalog avoids
double work). Task 24 (rollback that the gate triggers is complete).

## Risk / complexity / token size
Low (probes are read-only; the risk is a flaky probe causing a false
rollback — mitigated by generous timeouts and retry counts). Small–medium.
~8k tokens.

## Suggested order
Phase 5, after task 34.
