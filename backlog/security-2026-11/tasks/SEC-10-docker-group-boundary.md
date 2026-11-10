# domum-core-media/SEC-10 Docker group: state the real boundary

| Field | Value |
| --- | --- |
| Status | BLOCKED — decision D-3 |
| Priority and reason | P2 — the documented boundary (sudo) is not the real one |
| Effort and change risk | 30 min for the documentation option; low |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker after D-3; finding F-07 |
| Dependencies | D-3 |

## Outcome

`CLAUDE.md` §10 treats the sudo prompt as what stops an agent changing
production. The operator account is in the `docker` group, so it can already
mount any host path into a container as root. The rule is honoured by
instruction, not enforced by privilege. After this task the document says so,
and the monitoring account's membership is justified or removed.

## Scope and setup

Depends on the option chosen in [D-3](../DECISIONS.md). For option 1
(recommended): edit `CLAUDE.md` §10 only, and review the `beszel` account.
Do not demonstrate the escalation; the group membership is the evidence.

## Before editing

- D-3 has a **Selected** line. If not, stop.
- `getent group docker` lists two members (observed 2026-11-10).

## Implementation and checkpoints

1. (Option 1) Add a short paragraph to `CLAUDE.md` §10: Docker access is root-equivalent; the approval rules in §5 and §11 bind regardless; an agent never uses a container to read a root-only file or change a host path it could not change directly.
   - **Check** `python3 tests/no-conflict-markers-audit.py`
   - **Expected** exit 0
   - **Time and failure action** 15 min
2. Owner: decide whether Beszel needs per-container statistics. If not, `sudo gpasswd -d beszel docker && sudo systemctl restart beszel-agent`.
   - **Check** `getent group docker`
   - **Expected** one member; the Beszel dashboard still shows host metrics
   - **Failure action** re-add with `sudo gpasswd -a beszel docker`
3. If it does need them, point the agent at the socket proxy from SEC-08 instead of the group. Write that as its own task once SEC-08 has landed.

## Acceptance

- Pre-review: the paragraph reads as a rule, not as incident history (the file's own first instruction).
- Negative check: the diff to `CLAUDE.md` adds no command that performs the escalation.

## Rollback and stop conditions

`git revert`; re-add the group member.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** `getent group docker`
- **Open items** options 2 and 3 of D-3 are larger and need their own tasks
