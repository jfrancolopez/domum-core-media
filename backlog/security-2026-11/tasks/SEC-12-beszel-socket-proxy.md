# domum-core-media/SEC-12 Move Beszel container stats off Docker-group access

| Field | Value |
| --- | --- |
| Status | QUEUED (host-only proxy design; deployment owner-gated) |
| Priority and reason | P2 — Beszel needs container metrics but Docker-group access is root-equivalent |
| Effort and change risk | Unknown until the installed agent configuration and supported endpoint are inspected; host service and proxy networking changes require owner approval |
| Target and baseline | `domum-core-media`, current repository `origin/main` = `758833d`; observed Docker group has the operator account and `beszel` (2026-11-10) |
| Owner and evidence | worker for read-only discovery and repository-side rehearsal; owner for host changes; D-3, F-07 |
| Dependencies | SEC-08 repository change landed; SEC-10 D-3 selected that Beszel needs per-container statistics |

## Outcome

Preserve Beszel's per-container statistics without granting the agent direct,
root-equivalent Docker access. Prefer a narrowly reachable, read-only path
through the SEC-08 socket proxy; remove `beszel` from the `docker` group only
after the approved change is deployed and both host and container metrics are
verified.

The current SEC-08 proxy is attached only to the internal `domum-traefik-docker`
network and publishes no host port. Beszel runs on the host and has no
configured attachment to that network; a host-reachable transport must be
designed and verified before changing the agent. Do not expose the Docker API
on the LAN, mount the raw socket into Beszel, or enable API writes (`POST`
remains disabled).

## Scope and setup

- Read-only inspection of the installed Beszel agent version, service unit,
  configuration source, and supported Docker endpoint. Do not print secret
  environment values.
- Design the narrowest host-only route from the agent to the SEC-08 proxy and
  confirm the proxy allowlist covers the agent's actual read operations.
- Keep the current group membership and service unchanged until the owner
  approves a specific deployment plan.

## Before editing or deploying

- Confirm SEC-08 remains merged and inspect the current proxy network/port
  configuration; do not assume the host can reach its internal container IP.
- Identify Beszel's exact Docker API calls and confirm each is read-only and
  supported by the proxy. Stop if it needs an API section or write operation
  not currently allowed.
- Record rollback steps that restore the previous agent endpoint and group
  membership without exposing credentials.

## Implementation and checkpoints

1. Inspect the agent configuration without disclosing secret values; establish
   whether it supports a TCP Docker endpoint and its required API paths.
   - **Check** review the sanitized unit/config facts and endpoint documentation.
   - **Expected** exact requirements are recorded; no service or group changed.
2. Rehearse the proposed host-only route and proxy allowlist with a disposable
   project. Exercise Beszel-compatible read requests and prove write requests
   remain denied; verify no non-loopback listener is exposed.
   - **Check** container inventory, network inventory, port bindings, and
     representative metrics before and after teardown.
   - **Expected** host and container metrics work through the proxy; no
     production object or host configuration changes.
3. Present the narrow deployment and rollback plan for owner approval. After
   approval, point the agent at the proxy, verify host and container metrics,
   then remove the `beszel` group membership and restart only the agent.
   - **Check** `getent group docker` no longer lists `beszel`; the dashboard
     still shows host and per-container metrics; the proxy exposes no
     non-loopback listener and continues to deny writes.
   - **Failure action** restore the previous agent endpoint and group
     membership, then verify metrics. Do not leave a partially working setup.

## Acceptance

- Beszel no longer has Docker-group or raw-socket access after deployment.
- Both host and per-container metrics continue to work through the constrained
  proxy path.
- The proxy path is not reachable from the LAN and cannot perform writes.
- Deployment and any service restart are owner-approved and independently
  verified.

## Rollback and stop conditions

Restore the saved agent configuration and group membership if metrics fail.
Stop if Beszel needs write access, a broad socket-proxy allowlist, or a
non-loopback Docker API endpoint; return the design to the owner instead.

## Verification handoff

- **Result** _not started_
- **References** _base, design, commit, PR_
- **Evidence** _record sanitized discovery and rehearsal results_
- **Next model** inspect the installed Beszel agent endpoint requirements read-only
- **Open items** host configuration is not tracked in this repository; all deployment actions remain owner-gated
