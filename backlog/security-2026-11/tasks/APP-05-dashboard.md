# domum-core-media/APP-05 Family landing page

| Field | Value |
| --- | --- |
| Status | QUEUED |
| Priority and reason | P3 — requested; convenience, no risk reduced |
| Effort and change risk | 60–90 min; low |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker, then owner; owner request 2026-11-10 |
| Dependencies | SEC-08 (so it never needs the Docker socket) and D-4 (so it lists the apps that remain) |

## Outcome

Family members remember one address per app. After this task one page links to
every app that survives D-4, with an up/down dot per app.

## Scope and setup

- Homepage (gethomepage) as a managed, **stateless** service: its configuration is YAML rendered from a template in the repository, like `compose/proxy/traefik/dynamic/dashboard.yml.tmpl`.
- No Docker socket mount. Status comes from each app's own HTTP endpoint, or from the SEC-08 proxy if container status is wanted.
- No API keys for the apps in the first version: link and ping only. Widgets that need an app's API key put a credential into a page every family device can open.
- Hostnames come from the existing `*_HOST` variables; the template contains no real name.
- Declarations as APP-02, with the state model `stateless`.

## Before editing

- SEC-08 landed and D-4 has a **Selected** line.
- Baseline: compose `config -q` and `tests/state-model-smoke.sh` exit 0.

## Implementation and checkpoints

1. Fragment, template, variables, declarations.
   - **Check** compose `config -q`; `tests/state-model-smoke.sh`
   - **Expected** exit 0; the service is `stateless`
2. Render the template against `config/ci.env`.
   - **Check** the rendered file has no unresolved `${…}` (capture first, then grep; never `cmd | grep -q`)
   - **Expected** no placeholder left
3. Start it in a disposable project pinned by image ID.
   - **Expected** the page returns HTTP 200 and lists one link per enabled service
4. `python3 tests/identifier-audit.py` (from SEC-02, if landed).
   - **Expected** exit 0

## Acceptance

- Pre-review: CI green.
- Negative: `git grep -n 'docker.sock' -- compose` still shows only the proxy fragment.
- **Owner gate:** deployment and DNS.

## Rollback and stop conditions

`git revert`; stop the container.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** compose `config -q` exits 0 with the fragment present
- **Open items** widgets with API keys, if ever wanted, need their own review
