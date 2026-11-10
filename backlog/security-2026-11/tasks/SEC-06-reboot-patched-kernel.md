# domum-core-media/SEC-06 Reboot into the patched kernel

| Field | Value |
| --- | --- |
| Status | BLOCKED — needs root; owner action |
| Priority and reason | P1 — the fix is installed and not running |
| Effort and change risk | 15 min including checks; low. About two minutes of downtime |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner; finding F-10 |
| Dependencies | none |

## Outcome

A newer kernel is installed and the host still runs the old one after 35 days.
After this task the running kernel matches the newest installed one.

## Scope and setup

Follow `docs/REBOOT-READINESS.md`; it is the authority and this file does not
repeat it. Every enabled timer is `Persistent=true`, so a missed job runs at boot.

## Before editing

- `ls /var/run/reboot-required` exists; `uname -r` is older than the newest `vmlinuz-*` in `/boot`.
- `systemctl list-timers 'domum-media-*'`: do not reboot within an hour before the nightly backup or while a job is running.
- Capture identities: `docker ps --no-trunc --format '{{.ID}} {{.Names}} {{.Image}}' | sort > ~/pre-reboot-containers.txt`

## Implementation and checkpoints

1. `sudo systemctl reboot`
2. After it returns: `uname -r`
   - **Expected** the newest version in `/boot`; `/var/run/reboot-required` is gone
3. `findmnt /srv/data` and `systemctl --failed`
   - **Expected** the mount is present; no failed units
4. `docker ps --no-trunc --format '{{.ID}} {{.Names}} {{.Image}}' | sort | diff ~/pre-reboot-containers.txt -`
   - **Expected** no output: same eleven containers, same IDs, same images
   - **Failure action** a changed image ID means something recreated a container; stop and record it, do not "fix" it with compose
5. Open Immich and one media app in a browser.

## Acceptance

- Steps 2–4 as stated.
- The next nightly backup heartbeat (`/var/log/domum-media/last-success`) is newer than the reboot.

## Rollback and stop conditions

The previous kernel remains in the boot menu. Stop and keep the host as it is if `/srv/data` did not mount.

## Verification handoff

- **Result** _not started_
- **References** none in Git
- **Evidence** _kernel before and after; steps 3–4_
- **Next model** `test ! -e /var/run/reboot-required && echo ok`
- **Open items** the weekly report could flag a pending reboot older than N days; check whether `checkup` already does before adding it
