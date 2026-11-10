# domum-core-media/SEC-09 Set no-new-privileges on every container

| Field | Value |
| --- | --- |
| Status | PR_OPEN (#200; CI pending); deployment BLOCKED on the owner |
| Priority and reason | P3 — cheap defence in depth; nothing is known to be exploitable |
| Effort and change risk | 60 min; low for the repo change. Deployment recreates every container |
| Target and baseline | `domum-core-media`, branch off `origin/main` = `b094616`; security audit baseline `e0754a8` (2026-11-10) |
| Owner and evidence | worker, then owner for deployment; finding F-11 |
| Dependencies | SEC-08 landed (same files) |

## Outcome

No container sets a security option. After this task every service has
`security_opt: ["no-new-privileges:true"]`, and a test fails when a new
fragment omits it.

## Scope and setup

- Every fragment under `compose/` except Traefik's config directory.
- This task adds one option. Capability drops, read-only root filesystems,
  non-root users and memory limits each break images in different ways and are
  separate tasks to write after this one, per service.
- linuxserver.io images start as root and drop to `PUID`; `no-new-privileges`
  does not interfere with that, but prove it in step 2 rather than trusting this sentence.

## Before editing

- SEC-08 landed: `git grep -F -n '/var/run/docker.sock' -- compose` prints one hit, in the socket-proxy fragment. (The older non-fixed grep also matched `docker-socket-proxy` because `.` is a regex wildcard.)
- Baseline: the compose `config -q` step exits 0.

## Implementation and checkpoints

1. Add the option to each service.
   - **Check** render with the workflow's compose command using `config` instead of `config -q`, capture to a variable, and count services against `no-new-privileges` lines
   - **Expected** the counts are equal
   - **Time and failure action** 15 min
2. Rehearse one image of each family in a disposable project, pinned by image ID: one linuxserver.io image, Navidrome, Kavita, the Immich server with its database.
   - **Check** each reaches its declared readiness line (`service_ready_log_pattern`) or healthcheck
   - **Expected** all start; `docker inspect -f '{{.HostConfig.SecurityOpt}}'` shows the option
   - **Time and failure action** 30 min; an image that fails to start is recorded and excluded with a comment naming the reason, not silently skipped
3. Add a hermetic test that fails when a compose service lacks the option, with a printed exemption marker like the other audits use.
   - **Check** the new test, and `tests/ci-coverage-audit.sh`
   - **Expected** both exit 0; removing the option from one fragment makes the test fail and name the service

## Acceptance

- Pre-review: step 2 results per image, with image IDs.
- Pre-review: CI green.
- **Owner gate, deployment:** this is "broad container recreation" under `CLAUDE.md` §11. Deploy per service through the gated upgrade path, never with a fleet-wide `up -d`, and never Immich until its own phase allows.

## Rollback and stop conditions

`git revert`. Stop if any image needs the option removed to start and no reason can be found.

## Verification handoff

- **Result** PR_OPEN — repository options, disposable runtime rehearsal, hermetic audit, mutation check, and local regression checks PASS; GitHub CI pending.
- **References** base `b094616`; implementation `23f1947`; branch `task/sec-09-no-new-privileges`; PR [#200](https://github.com/jfrancolopez/domum-core-media/pull/200).
- **Evidence** SEC-08 landed in merge commit `b094616`; fixed-string socket-mount check finds exactly one hit. Baseline state-model and monitoring-completeness tests PASS; workflow Compose `config -q` PASS. Rendered Compose contains 14 services and exactly 14 `no-new-privileges:true` entries; JSON verification confirms all 14 services carry the option. Disposable rehearsal, pinned by running-container image IDs, PASS: LinuxServer calibre-web (`sha256:d5ad2aaf36f83dc56d70a589cb5a8788f998bdb9d4e495e8276e6302808c5265`) and Navidrome (`sha256:9012939114fbb1bb641b81cf96dec5ded15f0aafefe8d47a511d7cb919658e40`) emitted their readiness lines; Kavita (`sha256:454f2a77ac740b70c58cc7300a11122fc9ce7b7e2161ef5b0d1df8f81067cc85`), Immich server (`sha256:c15bff75068effb03f4355997d03dc7e0fc58720c2b54ad6f7f10d1bc57efaa5`), PostgreSQL (`sha256:739cdd626151ff1f796dc95a6591b55a714f341c737e27f045019ceabf8e8c52`) and Redis (`sha256:c9ab371a96b057d3642be9bd71cb1b3fe97920d345dc949860578bffb3d54460`) healthchecks became healthy. `docker inspect` confirmed `no-new-privileges:true` on all six; cleanup verified existing container IDs/names and network inventory unchanged, with no rehearsal network remaining. No production mounts or named volumes used. New `tests/compose-no-new-privileges-smoke.sh` PASS; mutation in a temporary repository copy removed Kavita's option and the test failed, named `kavita`, and printed its config-directory exemption marker. CI coverage audit PASS (92 test files); socket-proxy, state-model, monitoring, Compose `config -q`, pipefail, identifier, conflict-marker, documented-command, Bash syntax, ShellCheck, and redacted Gitleaks checks PASS (0 findings).
- **Next model** verify PR #200's `compose-validate` runs and obtain owner review; keep deployment owner-gated.
- **Open items** PR/CI and owner review pending. Deployment remains owner-gated: per-service gated rollout only, no fleet-wide `up -d`, and no Immich until its own phase allows. Follow-up tasks: memory limits for Immich ML and the transcoders; capability drops per service.
