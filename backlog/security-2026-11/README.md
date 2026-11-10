# Security review and app plan — 2026-11

A security review of `domum-core-media` and a plan for the apps the owner asked
about, written as tasks a smaller model can execute one at a time.

**This directory does not replace [`../QUEUE.md`](../QUEUE.md).** The queue is
still the live execution order for backup, recovery and upgrade work. This is a
separate track with its own IDs (`SEC-nn`, `APP-nn`), and `CLAUDE.md` still
governs every task here: no production change without the owner's approval, no
push to `main`, no `sudo` by an agent.

The repository is public, so nothing here names the domain, an address, or a
credential location beyond what the code already states.

| | |
|---|---|
| Reviewed | 2026-11-10 |
| Repo | `domum-core-media`, base `origin/main` = `e0754a8` |
| Production | `/opt/domum-core-media` at `a63ad19`, clean, 48 commits behind `main` |
| Runtime inspected | this host, read-only, as the unprivileged operator account (no root) |
| Audit | [AUDIT.md](AUDIT.md) |
| Decisions | [DECISIONS.md](DECISIONS.md) |

## Summary

The server is in reasonable shape for a tailnet-and-LAN-only box: no service is
published to the internet, secrets are root-only files outside Git, host
security updates are automatic, and the nightly photo backup ran today. The
gaps are at the edges rather than in the applications:

1. **Git is the path to root.** `main` is unprotected and the update command
   applies whatever `main` holds, as root. The repository is public and named
   real infrastructure.
2. **The host trusts its whole LAN** with no firewall, an SSH daemon that has no
   hardening drop-in, and an unused RPC port open.
3. **Docker is the soft spot.** Two accounts are in the `docker` group, Traefik
   holds the raw Docker socket, and no container drops privileges.
4. **A patched kernel is waiting for a reboot**, and Immich is seven months old.

## Next three tasks

| Task | Who | Effort | Priority | Why first |
|---|---|---|---|---|
| [SEC-04](tasks/SEC-04-ssh-hardening.md) SSH key-only | owner (root) | 10 min | P1 | The LAN is trusted by decision D-2, so SSH is the control that matters |
| [SEC-06](tasks/SEC-06-reboot-patched-kernel.md) reboot into the patched kernel | owner (root) | 15 min | P1 | The fix is already installed and not running |
| [SEC-02](tasks/SEC-02-ci-identifier-and-secret-scan.md) CI guard for identifiers and secrets | worker | 45 min | P2 | Keeps D-1 true and detects future secret commits |

## All tasks

Status lives in each task file; this table is a summary.

| ID | Task | Status | Pri | Depends on |
|---|---|---|---|---|
| [SEC-00](tasks/SEC-00-scrub-domain-from-docs.md) | Real domain removed from `docs/` | DONE (`e53adf2`; PR #196, CI green) | P1 | — |
| [SEC-01](tasks/SEC-01-scrub-config-and-cli-defaults.md) | Scrub config example and CLI defaults | DONE (`364a8d1`; PR #197, CI green) | P1 | SEC-00 |
| [SEC-02](tasks/SEC-02-ci-identifier-and-secret-scan.md) | CI guard: identifiers and secret scan | PR_OPEN (owner review/merge pending) | P2 | SEC-01 |
| [SEC-03](tasks/SEC-03-github-hardening.md) | Protect `main`, narrow the token on this host | BLOCKED (approval) | P1 | — |
| [SEC-04](tasks/SEC-04-ssh-hardening.md) | SSH key-only, no root, no X11 | BLOCKED (owner, root) | P1 | — |
| [SEC-05](tasks/SEC-05-tailscale-acl-review.md) | Tailscale ACL review | BLOCKED (owner, admin console) | P1 | — |
| [SEC-06](tasks/SEC-06-reboot-patched-kernel.md) | Reboot into the patched kernel | BLOCKED (owner, root) | P1 | — |
| [SEC-07](tasks/SEC-07-disable-rpcbind.md) | Close the unused RPC port | BLOCKED (owner, root) | P2 | — |
| [SEC-08](tasks/SEC-08-traefik-socket-proxy.md) | Traefik behind a Docker socket proxy | READY (repo half) | P2 | — |
| [SEC-09](tasks/SEC-09-no-new-privileges.md) | `no-new-privileges` on every container | QUEUED | P3 | SEC-08 |
| [SEC-10](tasks/SEC-10-docker-group-boundary.md) | Docker group: state the real boundary | BLOCKED (D-3) | P2 | D-3 |
| [SEC-11](tasks/SEC-11-plex-remote-access-check.md) | Plex relay and remote access check | BLOCKED (owner, Plex UI) | P2 | D-4 may supersede |
| [APP-01](tasks/APP-01-measure-usage-for-consolidation.md) | Measure real use of the overlapping apps | READY | P2 | — |
| [APP-02](tasks/APP-02-audiobookshelf.md) | Add Audiobookshelf | QUEUED | P2 | D-4 |
| [APP-03](tasks/APP-03-push-alerts.md) | Push alerts to phones | BLOCKED (D-5) | P2 | D-5 |
| [APP-04](tasks/APP-04-paperless-ngx.md) | Add Paperless-ngx | QUEUED | P3 | QUEUE P1.7, P5.2 |
| [APP-05](tasks/APP-05-dashboard.md) | Family landing page | QUEUED | P3 | SEC-08, D-4 |

Two findings are already tasks in the older audit and are not duplicated here:
untracking `.claude/settings.local.json` is [`task-09`](../task-09-untrack-claude-settings.md),
and network segmentation is [`task-40`](../task-40-future-network-segmentation.md).

## Order

- **Owner track (root or a console, any order):** SEC-04, SEC-06, SEC-05, SEC-07, SEC-11.
- **Repo track:** SEC-00 → SEC-01 → SEC-02, then SEC-08 → SEC-09.
- **Apps track:** APP-01 → decision D-4 → APP-02 → APP-05. APP-03 waits on D-5.
  APP-04 waits on off-site coverage for non-Immich state.

## Starting a worker

1. Work in a `git worktree` off `origin/main`, on a branch named for the task.
   Never work in `/opt/domum-core-media`.
2. Open the task file. Run its **Before editing** check first.
3. Do one numbered step, run its check, record the result, then the next.
4. Fill in **Verification handoff**, set the status, and update the table above
   if the order changed.
5. Open a PR. Merging is not deploying; deployment is the owner's step.

## Decisions waiting on the owner

| ID | Question | Blocks |
|---|---|---|
| D-3 | Keep the operator account in the `docker` group? | SEC-10 |
| D-4 | Which of the overlapping apps stay? | APP-02, APP-05, SEC-11 |
| D-5 | Where do phone alerts go? | APP-03 |
