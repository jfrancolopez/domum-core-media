# Audit — 2026-11-10

Read-only review of the repository at `origin/main` = `e0754a8` and of the live
host as the unprivileged operator account. No root, no network scan, no
configuration or data was changed. Identifiers are omitted because the
repository is public.

Each finding is marked **observed** (seen directly), **inferred** (follows from
what was seen) or **unverified** (needs access this review did not have).

## Inventory

| | |
|---|---|
| Purpose | Family photo library (Immich) and a small media library, reached over the home LAN and a Tailscale tailnet |
| Users | The owner and family devices on the tailnet (three phones, a tablet, a laptop, two other Linux hosts) |
| Host | Intel N100, 4 cores, 16 GB RAM (12 GB available), Debian 13 |
| Storage | OS on one SSD (16% used); `/srv/data` and `/srv/snapshots` on a second, Btrfs (24% used) |
| Services | Traefik, Immich (server, ML, Postgres, Redis), Plex, Jellyfin, Navidrome, Kavita, Calibre-Web, Uptime Kuma; Beszel agent and Tailscale on the host |
| Media tier | 5.1 GB of music and under 1 MB of books; no video directory |
| Deployment chain | dev checkout → GitHub `main` (PR + CI) → `/opt/domum-core-media` → installed binaries. Production is `a63ad19`, clean, 48 commits behind |
| Backup | Nightly restic to an off-site SFTP target, Immich only; last success 2026-11-10 02:32 |
| Environment class | Production. Treated as read-only |

## Threat model in brief

The asset that matters is the photo library; next are the credentials that
protect its backup. Nothing is published to the internet, so the realistic
paths in are:

- a compromised or borrowed **device on the LAN or tailnet**;
- a compromised **GitHub account or token**, because Git is what production runs;
- a compromised **container image**, since images are pulled by mutable tag;
- **loss of the host**, which is a recovery question the main queue covers.

## Findings

Severity is harm × reachability. Priority is in the task.

| ID | Sev | Finding | Evidence | Confidence | Task |
|---|---|---|---|---|---|
| F-01 | High | Public repository names the real domain, the off-site backup host and account, a LAN address, a filesystem UUID, and documents exactly which data has no off-site copy | observed: `gh repo view` reports PUBLIC; `git grep` on `e0754a8` finds the domain in 11 tracked files, the backup host in 4, the UUID in 6 | high | SEC-00, SEC-01, SEC-02, D-1 |
| F-02 | High | `main` has no branch protection, and `domum-media update` resets to `origin/main` then applies as root. Push access to `main` becomes root at the next update | observed: branch-protection API returns "not protected"; `repo_update` behaviour is stated in `CLAUDE.md` §4 | high | SEC-03 |
| F-03 | Med | A GitHub token with all-repositories `repo` scope and an SSH key with push access are stored on this host | observed: `gh auth status` scopes | high | SEC-03 |
| F-04 | Med | No host firewall. SSH, HTTP, HTTPS and rpcbind listen on every interface | observed: `ss -tln`; `ufw`, `nftables`, `firewalld` all inactive | high | D-2 (accepted for the LAN), SEC-07 |
| F-05 | Med | sshd has no hardening drop-in: password authentication is not disabled in any config file and X11 forwarding is on | observed: config files. **unverified**: the effective value needs `sshd -T` as root | medium | SEC-04 |
| F-06 | Med | Tailscale SSH is enabled and the tailnet includes family devices. Whether those devices may open SSH is set by ACLs this review could not see | observed: `RunSSH: true`, device list. **unverified**: ACLs | medium | SEC-05 |
| F-07 | Med | The operator account and the `beszel` account are in the `docker` group, which is root-equivalent. The sudo password and root-only secret files do not constrain either account, or an agent running as one | observed: `getent group docker` | high | SEC-10, D-3 |
| F-08 | Med | Traefik mounts the Docker socket. Read-only mounting does not restrict the API, so a Traefik compromise controls the host | observed: `compose/proxy/traefik.yml` | high | SEC-08 |
| F-09 | Med | Immich runs a seven-month-old image, on a Postgres image from February 2025 whose vector extension is deprecated, and Redis 6.2 | observed: image creation dates and version labels | high | existing work: Immich's own phase in `CLAUDE.md` §3 and `docs/IMMICH-RECOVERY-PLAN.md` |
| F-10 | Low | A patched kernel is installed and not running; uptime 35 days | observed: `/var/run/reboot-required`, `uname -r` vs `/boot` | high | SEC-06 |
| F-11 | Low | No container sets `no-new-privileges`, drops capabilities, or has a memory or PID limit; ten of eleven start as root | observed: `docker inspect` | high | SEC-09 |
| F-12 | Low | rpcbind and the NFS client target are enabled with no network mount configured | observed: `systemctl is-enabled`, `/etc/fstab` | high | SEC-07 |
| F-13 | Low | `.claude/settings.local.json` is tracked in the public repo and allows `bash`, `docker` and `curl` wholesale | observed: tracked file | high | existing [`task-09`](../task-09-untrack-claude-settings.md), still pending |
| F-14 | Low | CI has no secret scan and nothing stops an identifier being re-added | observed: no match for a scanner in the workflow | high | SEC-02 |
| F-15 | Low | Plex authenticates through its vendor's cloud and can relay streams outside the tailnet if remote access is on | inferred from how Plex works. **unverified**: the setting is in the Plex UI | low | SEC-11 |
| F-16 | Low | Fifteen superseded deploy and rollback scripts sit in the operator's home directory | observed | high | owner's files; delete when convenient. Current scripts live in `operator/` |
| F-17 | Info | Four apps overlap (two video servers, two book servers) on a media tier that holds 5.1 GB of music and almost nothing else | observed: `du` | high | APP-01, D-4 |

## What is already right

- Nothing is forwarded from the internet; service names resolve to the tailnet address.
- Secret values are root-only files outside Git, referenced by path. GitHub secret scanning and push protection are on.
- Host security updates are automatic and Tailscale auto-updates.
- Only the proxy publishes ports; databases are not reachable from outside Docker.
- The dashboard is behind authentication; services not labelled for the proxy are not exposed.
- Media is mounted read-only into every media server except Calibre-Web's book folder.
- Image auto-deployment is deliberately off, with a gated per-service upgrade path.
- No failed units; the nightly backup, weekly check and weekly report timers are all scheduled.

## Coverage

| Area | Coverage | Not reviewed, and why |
|---|---|---|
| Identity and access | partial | Tailscale ACLs and device approval (admin console); effective sshd settings and sudoers (root); in-app accounts and whether each app has a strong admin password |
| Application and data | partial | Compose and proxy config reviewed. The 20k lines of CLI were not re-audited for security; the repo's own test suite covers them for correctness |
| Runtime and infrastructure | partial | Listeners, containers, mounts, images, timers observed. Production config and secret file modes inside the root-only directory were not readable |
| Git, CI, release | reviewed | Visibility, protection, token scopes, workflow triggers, tracked files. Git history was pattern-searched for identifiers only, not for every secret shape |
| Reliability and operations | by reference | Covered in depth by `../QUEUE.md` and `docs/DISASTER-RECOVERY-STATUS.md`; not repeated |
| User experience | partial | App overlap and alerting reviewed. No app was opened in a browser |

## Outstanding discovery

| Question | How to answer | Feeds |
|---|---|---|
| Is SSH password login actually on? | `sudo sshd -T`, step 1 of SEC-04 | SEC-04 |
| Can family devices reach SSH over the tailnet? | Tailscale admin console, SEC-05 | SEC-05 |
| Is Plex remote access or relay on? | Plex settings, SEC-11 | SEC-11 |
| Which overlapping apps are actually used? | APP-01 | D-4 |
| Does production set its own domain explicitly? | owner confirms before SEC-01 deploys | SEC-01 |

## Recovery risks carried from the main queue

Not security findings, but larger than any above, and already tracked:

- **QUEUE P5.2** — the key that opens every recovery pack has no confirmed off-host copy.
- **QUEUE P1.7** — the five media services and the image archives exist only on this host's SSD.
- **QUEUE P5.6** — the off-site coverage proof is stale and is refreshed by one read-only command.
