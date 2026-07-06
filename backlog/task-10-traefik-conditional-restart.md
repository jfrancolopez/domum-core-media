# Task 10 — Restart Traefik only when its rendered config changed

## Objective
Stop `apply` from restarting Traefik (dropping every proxied service for a
few seconds) when nothing about its config changed.

## Files involved
- `bin/domum-media` — `apply()` (~line 2506), `render_traefik_dynamic()`
  (~line 1040)

## Reason
`apply()` unconditionally runs `docker restart traefik` whenever the
container exists. Since `apply` is the routine converge command (also exec'd
by every `domum-media update`), each run interrupts Immich/Jellyfin/Plex/etc.
ingress for the restart duration even when the dynamic config is byte-for-byte
identical. Traefik also watches the dynamic directory natively, so for
dynamic-file changes a restart is often unnecessary at all — but keeping the
restart-on-change behavior is the conservative, simple fix.

## Implementation plan
1. In `render_traefik_dynamic()`, track whether any rendered file actually
   changed: before `mv "$dst.partial" "$dst"`, compare with `cmp -s` against
   the existing file; skip the mv and the "Rendered" log line when identical.
   Have the function set/return a "changed" flag (e.g. echo nothing / set a
   global `TRAEFIK_DYNAMIC_CHANGED=1`).
2. In `apply()`, only restart when the flag is set:
   `if changed && container exists → docker restart traefik`.
3. Leave first-boot behavior intact (no dst file yet → change → restart).

## Testing plan
- Two consecutive `apply` runs with no config edits: second run performs no
  Traefik restart (watch `docker events` or container uptime).
- Edit `TRAEFIK_DASHBOARD_HOST` in the conf → next apply re-renders and
  restarts.
- Smoke test + shellcheck pass.

## Rollback plan
Revert; unconditional restart returns.

## Dependencies
None.

## Risk / complexity / token size
Low. Small. ~5k tokens.

## Suggested order
10.
