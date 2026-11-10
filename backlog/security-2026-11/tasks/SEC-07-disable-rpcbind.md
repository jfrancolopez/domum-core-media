# domum-core-media/SEC-07 Close the unused RPC port

| Field | Value |
| --- | --- |
| Status | BLOCKED — needs root; owner action |
| Priority and reason | P2 — a listening service with no user |
| Effort and change risk | 5 min; low |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner; findings F-04, F-12 |
| Dependencies | none |

## Outcome

rpcbind listens on TCP and UDP 111 on every interface, and no network
filesystem is mounted. After this task the port is closed.

## Scope and setup

Two systemd units. The NFS client package stays installed for the planned NAS
(`docs/NAS-INTEGRATION-ARCHITECTURE.md`); NFSv4 does not need rpcbind.

## Before editing

`ss -tlnH | grep -c ':111 '` prints a number above 0, and `grep -cE 'nfs|cifs' /etc/fstab` prints `0`. If fstab has a network mount, stop: something uses it.

## Implementation and checkpoints

1. `sudo systemctl disable --now rpcbind.socket rpcbind.service`
   - **Check** `ss -tlnH | grep -c ':111 '; ss -ulnH | grep -c ':111 '`
   - **Expected** `0` and `0`
   - **Failure action** if it is still listening, `systemctl status rpcbind.socket` names what re-activated it
2. `systemctl --failed`
   - **Expected** no failed units

## Acceptance

- Port 111 closed on TCP and UDP; still closed after the next reboot (re-run step 1's check after SEC-06).

## Rollback and stop conditions

`sudo systemctl enable --now rpcbind.socket`.

## Verification handoff

- **Result** _not started_
- **References** none in Git
- **Evidence** _before and after counts_
- **Next model** `ss -tlnH | grep -c ':111 '` prints `0`
- **Open items** re-enable only if the NAS ends up on NFSv3
