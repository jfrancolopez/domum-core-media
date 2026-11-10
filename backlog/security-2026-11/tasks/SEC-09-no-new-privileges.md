# domum-core-media/SEC-09 Set no-new-privileges on every container

| Field | Value |
| --- | --- |
| Status | QUEUED |
| Priority and reason | P3 — cheap defence in depth; nothing is known to be exploitable |
| Effort and change risk | 60 min; low for the repo change. Deployment recreates every container |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
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

- SEC-08 landed: `git grep -c 'docker.sock' -- compose` prints one file.
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

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** the new audit test exits 0
- **Open items** follow-up tasks: memory limits for Immich ML and the transcoders; capability drops per service
