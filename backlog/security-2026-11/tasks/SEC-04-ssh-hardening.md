# domum-core-media/SEC-04 SSH: keys only, no root login, no X11

| Field | Value |
| --- | --- |
| Status | BLOCKED — needs root; owner action |
| Priority and reason | P1 — the LAN is trusted (D-2), so SSH is the control that matters |
| Effort and change risk | 10 min; medium, a mistake can lock out SSH. Tailscale SSH and the console remain |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner; finding F-05, decision D-2 |
| Dependencies | none |

## Outcome

No drop-in hardens sshd, so password login is probably accepted from any LAN
device (the Debian default) and X11 forwarding is on. After this task only the
operator's key works.

## Scope and setup

One new file, `/etc/ssh/sshd_config.d/10-domum-hardening.conf`. Keep your
current SSH session open until step 4 passes.

## Before editing

`sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|x11forwarding|pubkeyauthentication) '`

Record the four lines. If `passwordauthentication no` already shows, skip to the X11 and root lines only.

## Implementation and checkpoints

1. Confirm key login works: from another machine, `ssh -o PasswordAuthentication=no <this host> true`.
   - **Expected** exit 0 with no password prompt
   - **Failure action** stop. Fix the key first; do not continue
2. Create the drop-in with four lines: `PasswordAuthentication no`, `PermitRootLogin no`, `X11Forwarding no`, `AllowUsers <operator account>`.
   - **Check** `sudo sshd -t`
   - **Expected** no output, exit 0
   - **Failure action** fix or delete the file; nothing is live yet
3. `sudo systemctl reload ssh`
   - **Check** the command in **Before editing**
   - **Expected** `passwordauthentication no`, `permitrootlogin no`, `x11forwarding no`
4. Negative test from another machine: `ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <this host>`
   - **Expected** `Permission denied (publickey)`
   - **Failure action** if a password prompt appears, another config file overrides the drop-in; `sudo sshd -T` shows the effective value

## Acceptance

- Step 4 denies password login; a new key-based session opens.
- Post-landing, optional: add the drop-in to the repository and `install.sh` so Git stays the source of truth. That is a separate worker task; say if you want it written.

## Rollback and stop conditions

`sudo rm /etc/ssh/sshd_config.d/10-domum-hardening.conf && sudo systemctl reload ssh`, from the session you kept open, Tailscale SSH, or the console.

## Verification handoff

- **Result** _not started_
- **References** host file only
- **Evidence** _before values; steps 1–4_
- **Next model** the `sshd -T` line shows `passwordauthentication no`
- **Open items** whether to track the drop-in in Git
