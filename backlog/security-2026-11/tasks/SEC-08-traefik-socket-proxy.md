# domum-core-media/SEC-08 Put Traefik behind a Docker socket proxy

| Field | Value |
| --- | --- |
| Status | READY (repository half); deployment BLOCKED on the owner |
| Priority and reason | P2 — removes host control from the one container every request passes through |
| Effort and change risk | 90 min for the repo change and rehearsal; medium. Deployment recreates Traefik |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker for the repo half, owner for deployment; finding F-08 |
| Dependencies | First task on the compose-hardening track |

## Outcome

Traefik mounts `/var/run/docker.sock`. The `:ro` flag stops it replacing the
socket file and nothing else: the full Docker API is available, so a flaw in
Traefik is a flaw in the host. After this task Traefik reads container labels
through a proxy that answers only read-only container and network queries, on a
network nothing else joins.

## Scope and setup

- Repo half only: compose fragments, config example, CI env, service registration, tests. Nothing in production.
- Read `docs/add-new-service.md` and `docs/service-template.md` first; the proxy is a new managed service and the same registration applies.
- Change `compose/proxy/traefik.yml` (remove the socket mount; add the new network), `compose/proxy/traefik/traefik.yml` (`providers.docker.endpoint` becomes `tcp://<proxy>:2375`), `compose/base.yml` (a new network with `internal: true`), plus a fragment for the proxy with the socket mounted read-only and only `CONTAINERS`, `NETWORKS` and `EVENTS` reads enabled.
- The proxy must: set `container_name` equal to its service key (a guard enforces this), be declared in `service_state_models` as `stateless` (undeclared services fail closed), have an image variable in `config/domum-media.conf.example` and `config/ci.env`, and publish no port.
- Pick a maintained proxy image and record why. Pin by tag in the example like the others.
- Preserve: every existing router label, the ACME volume, the dashboard auth file mount.

## Before editing

- Baseline: `tests/state-model-smoke.sh` and `tests/monitoring-completeness-smoke.sh` exit 0, and the `docker compose … config -q` step from `.github/workflows/compose-validate.yml` exits 0. Each takes seconds. If any fails on a clean tree, stop and record it.

## Implementation and checkpoints

1. Add the internal network and the proxy fragment; register the service.
   - **Check** the compose `config -q` step from the workflow
   - **Expected** exit 0
   - **Time and failure action** 20 min; an unset variable means `config/ci.env` is missing the new image line
2. Declare the state model and any catalog entries.
   - **Check** `tests/state-model-smoke.sh`
   - **Expected** exit 0, with the new service reported `stateless`
   - **Time and failure action** 15 min; if the suite pins a service count, ask which is wrong before changing the assertion (`CLAUDE.md`, "a test can assert a defect")
3. Repoint Traefik and remove its socket mount.
   - **Check** `git grep -n 'docker.sock' -- compose`
   - **Expected** exactly one hit, in the proxy fragment
   - **Time and failure action** 10 min
4. Rehearse in a disposable compose project, following `operator/rehearsals/README.md`: Traefik pinned by the running container's image ID, the proxy, and one throwaway labelled container. No production network, volume or name.
   - **Check** from inside the rehearsal network, request the throwaway container's hostname through Traefik; then from the Traefik container attempt a write call to the proxy (for example a container-create request)
   - **Expected** the route answers; the write returns 403
   - **Time and failure action** 30 min; assert teardown leaves no container. If the route never appears, the proxy is missing a read permission Traefik needs: add that one, not all
5. Add the rehearsal script under `operator/rehearsals/` so the claim can be re-run.
   - **Check** shellcheck as in `CLAUDE.md` §9; `python3 tests/pipefail-grep-audit.py`
   - **Expected** both exit 0

## Acceptance

- Pre-review: step 4's two results, recorded with the image IDs used.
- Pre-review: CI green on the PR; `tests/ci-coverage-audit.sh` exits 0.
- **Owner gate, deployment:** recreating Traefik is "application/image deployment" under `CLAUDE.md` §11. Two things the plan must state: `compose up -d` would also deploy the newer Traefik image already staged under the same tag unless the image is pinned by ID for the change; and Traefik's state is a Docker volume, so the volume-upgrade gate in `../../QUEUE.md` P3.5 applies.
- Post-landing (owner): every app still loads over HTTPS and `docker inspect traefik` shows no socket mount.

## Rollback and stop conditions

`git revert` for the repo half. For deployment, the plan must keep the previous compose fragment and image ID. Stop if the rehearsal needs a production path to pass.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** `git grep -c 'docker.sock' -- compose` prints one file; next is SEC-09
- **Open items** the Beszel agent also reads the socket (SEC-10); the same proxy could serve it
