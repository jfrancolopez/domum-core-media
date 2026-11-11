# domum-core-media/SEC-10 Docker group: state the real boundary

| Field | Value |
| --- | --- |
| Status | PR_OPEN (#202; CI pending); deployment BLOCKED on the owner |
| Priority and reason | P2 — the documented boundary (sudo) is not the real one |
| Effort and change risk | 30 min for the documentation option; low |
| Target and baseline | `domum-core-media`, branch off `origin/main` = `758833d`; security audit baseline `e0754a8` (2026-11-10) |
| Owner and evidence | worker for repository documentation, owner for deployment; finding F-07 |
| Dependencies | D-3 selected (2026-11-10); SEC-08 repository change landed |

## Outcome

`CLAUDE.md` §10 treats the sudo prompt as what stops an agent changing
production. The operator account is in the `docker` group, so it can already
mount any host path into a container as root. The rule is honoured by
instruction, not enforced by privilege. After this task the document says so,
and the operator account's membership is documented. The owner has determined
that Beszel needs per-container statistics, so its current membership remains
until the separate SEC-12 proxy migration is designed and owner-approved.

## Scope and setup

The owner selected option 1 in [D-3](../DECISIONS.md): keep and document the
operator account's membership. Edit `CLAUDE.md` §10 only for that boundary; do
not demonstrate the escalation. `getent group docker` is the evidence. The
owner also confirmed Beszel needs per-container stats. Leave host memberships
unchanged; SEC-12 tracks moving Beszel to a constrained proxy path.

## Before editing

- D-3 has a **Selected** line: option 1, with Beszel retaining access for stats.
- `getent group docker` lists two members: the operator account and `beszel` (observed 2026-11-10); PASS.

## Implementation and checkpoints

1. (Option 1) Add a short paragraph to `CLAUDE.md` §10: Docker access is root-equivalent; the approval rules in §5 and §11 bind regardless; an agent never uses a container to read a root-only file or change a host path it could not change directly.
   - **Check** `python3 tests/no-conflict-markers-audit.py`
   - **Expected** exit 0
   - **Time and failure action** 15 min
2. Owner decided Beszel needs per-container statistics and selected to retain its membership for now. No group or service action is authorized by this repository task.
    - **Evidence** read-only `getent group docker` check listed the operator account and `beszel`; PASS.
3. SEC-08 has landed in the repository. Since its proxy is internal-network-only and Beszel is a host service, track a host-reachable, read-only proxy design as separate SEC-12. Do not expose a TCP port, change the host service, or remove group membership here.

## Acceptance

- Pre-review: the paragraph reads as a rule, not as incident history (the file's own first instruction).
- Negative check: the diff to `CLAUDE.md` adds no command that performs the escalation.

## Rollback and stop conditions

`git revert`; re-add the group member.

## Verification handoff

- **Result** PR_OPEN — D-3 resolved; repository documentation and SEC-12 follow-up task submitted; CI pending; no host changes.
- **References** base `758833d`; implementation `0230d51`; branch `task/sec-10-docker-group-boundary`; PR [#202](https://github.com/jfrancolopez/domum-core-media/pull/202).
- **Evidence** read-only `getent group docker` listed two members (operator account and `beszel`). Owner selected D-3 option 1 and confirmed Beszel needs per-container statistics. `tests/no-conflict-markers-audit.py`, `tests/no-conflict-markers-smoke.sh`, `tests/ci-coverage-audit.sh` (92 files), and documented-command audit (106 commands) PASS; redacted Gitleaks scan PASS (0 findings); `git diff --check` PASS. The CLAUDE diff states Docker access is root-equivalent, preserves §5/§11 approval rules, and adds no escalation command. No group membership or service was changed.
- **Next model** verify PR #202's `compose-validate` run and obtain review; keep deployment owner-gated.
- **Open items** PR CI/review pending. SEC-12 must design a host-reachable read-only path through the SEC-08 proxy before Beszel can safely leave the Docker group; owner approval is required for any host-side deployment.
