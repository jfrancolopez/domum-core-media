# domum-core-media/APP-03 Push alerts to phones

| Field | Value |
| --- | --- |
| Status | BLOCKED — decision D-5 |
| Priority and reason | P2 — requested; failures currently arrive by email only |
| Effort and change risk | 2–3 h; low. Adds a second sender beside SMTP |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | worker after D-5; owner request 2026-11-10 |
| Dependencies | D-5 |

## Outcome

`health-notify` mails on failure and a report arrives on Sundays. A failed
backup at 02:30 is seen when the email is read. After this task the same alert
also reaches a phone within a minute, and silence still means healthy.

## Scope and setup

Written for D-5 option 1 (self-hosted ntfy). Rewrite if another option is chosen.

- `bin/domum-media` has no push transport today (no match for ntfy, gotify or webhook at `e0754a8`).
- Add one function beside `smtp_send_message`, called from `health_notify_cmd` only. Keep the contract in `CLAUDE.md`: healthy sends nothing; a delivery failure fails the unit.
- Push is **additional**. Mail stays the delivery that fails the unit; a push failure is reported by `checkup`, not swallowed and not fatal on its own until it has a track record.
- The push body carries the verdict and a count, never a path, hostname or credential. Detail stays in the email.
- Credentials: a token file under the secrets directory, passed to curl through a 0600 `--config` file, never in argv (the rule PR #193 established for SMTP).
- The ntfy server is a new managed service and needs the same declarations as APP-02. iOS needs `upstream-base-url` set so the public service can wake the phone; only a message ID goes upstream.

## Before editing

- D-5 has a **Selected** line.
- Baseline: `tests/health-notify-smoke.sh` and `tests/smtp-transport-smoke.sh` exit 0.

## Implementation and checkpoints

1. Add the sender with bounded retries and timeouts, mirroring the SMTP flags.
   - **Check** a new smoke test that drives the function against a local stub server
   - **Expected** the stub receives one POST; the token appears in no argv (read `/proc/<pid>/cmdline` of the stubbed curl) and in no output
2. Call it from `health_notify_cmd` after the mail succeeds.
   - **Check** `tests/health-notify-smoke.sh`
   - **Expected** exit 0; a healthy fixture sends neither mail nor push
3. Mutation: remove the silence gate for push.
   - **Expected** a healthy fixture starts pushing and the test fails
4. Add `checkup` coverage: push enabled but token file missing or empty is a warning naming the path.
   - **Check** `tests/health-checks-smoke.sh`
5. Add the ntfy service fragment and declarations (as APP-02 steps 1–3).

## Acceptance

- Pre-review: CI green; shellcheck clean; both smoke tests listed in the workflow.
- Negative: a push-server outage does not suppress or delay the email.
- **Owner gate:** deployment, the token, subscribing the phones, and one real test alert.

## Rollback and stop conditions

Disable with the config flag (default off). `git revert`.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** `tests/health-notify-smoke.sh` exits 0 with the push sections present
- **Open items** Uptime Kuma can post to the same ntfy topic for up/down alerts with no code
