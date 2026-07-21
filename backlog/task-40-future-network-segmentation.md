# Task 40 — FUTURE: Network segmentation

> **Future idea. Do not start without an explicit go decision.** High blast
> radius, zero user-visible feature gain; every service's connectivity is
> touched. Do it only after the catalog (tasks 16/33/34) and health probes
> (task 35) are stable, so misconnections are detected immediately.

## Objective
Split the flat `domum-internal` network into purpose networks — proxy,
application-internal, database — so unrelated backends (Immich PostgreSQL,
Redis, ML, restic REST server if ever enabled) are not mutually reachable
and Traefik cannot reach databases directly.

## Files involved
- `compose/base.yml` (network definitions; `domum-internal` is not
  `internal: true` today)
- Every service fragment's `networks:` attachment
- `docs/` (traffic-matrix documentation)

## Reason
Today every container shares `domum-internal`: a compromised media app can
reach the Immich database directly. Segmentation is real defense-in-depth,
but it is deliberately LAST/FUTURE: the homelab threat model is modest, the
change touches every fragment, and debugging "service can't reach its DB
after apply" without health probes (task 35) would be miserable. domum-core
has the same flat-network gap — whichever repo does it first becomes the
pattern source.

## Implementation plan (when activated)
1. Document the required traffic matrix first (who must talk to whom, on
   which port), derived from the catalog.
2. Define networks: `domum-proxy` (Traefik ↔ app frontends),
   `domum-immich` (server ↔ ML ↔ redis ↔ postgres, `internal: true`),
   keep-or-add others only where the matrix demands.
3. Re-attach services per the matrix; one service group per commit, with
   health probes green after each.
4. Negative tests: proxy cannot reach postgres; media apps cannot reach
   redis.

## Testing plan
- Per-group: health probes (task 35) green after re-attachment.
- Negative reachability checks (`docker exec ... nc -z`) for the forbidden
  pairs.
- Full `apply` from scratch on a fixture host.

## Rollback plan
Revert re-attachment commits; the flat network definition remains until
the final cleanup commit.

## Dependencies
Tasks 16/33/34 (catalog drives the matrix), task 35 (probes catch
misconnections). Explicit go decision from Franco.

## Risk / complexity / token size
High risk, large effort. ~12k tokens across multiple sessions.

## Suggested order
Phase 6, last — future.
