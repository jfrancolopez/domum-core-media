# Hetzner Storage Box b11 setup

This guide configures the `cloud` backup target to use a Hetzner Storage Box over restic + SFTP.

The example below uses box user `b11`. Replace the host/path values with your real Storage Box details.

## 1. Open the backup wizard

```bash
sudo domum-media configure
```

Use these answers for the `cloud` target:

- `Enable cloud backup target?` -> `yes`
- `Target type for cloud` -> `repository`
- `Restic repository string for cloud` -> `sftp:b11@b11.your-storagebox.de:/./domum-core-media-restic`
- `Password file for cloud` -> keep the default unless you have a reason to change it
- `Optional backend credential env file for cloud` -> keep the default or set a path, but leave the file empty/comment-only for SFTP targets
- `Use SSH key authentication` -> `yes`
- `Path to SSH private key` -> `/etc/domum-core-media/secrets/hetzner_storagebox_ed25519`
- `Path to known_hosts file` -> `/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts`
- `SFTP port` -> `23`

For the backend env-file prompt:

- Submit just `.` to keep the current file unchanged.
- If the file does not exist and you do not need extra backend variables, leave it absent or save a comment-only file such as `# Hetzner SFTP target does not need backend env vars.`

## 2. Generate an SSH key on the host

```bash
sudo ssh-keygen -t ed25519 -f /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 -N "" -C "domum-media backup"
sudo chmod 600 /etc/domum-core-media/secrets/hetzner_storagebox_ed25519
```

## 3. Add the public key in Hetzner Robot

Print the public key:

```bash
sudo cat /etc/domum-core-media/secrets/hetzner_storagebox_ed25519.pub
```

Then in Hetzner Robot:

1. Open `Storage Box`.
2. Select your `b11` box.
3. Open `SSH Keys`.
4. Add a new key and paste the public key.

## 4. Save the server host key locally

```bash
ssh-keyscan -p 23 b11.your-storagebox.de | sudo tee /etc/domum-core-media/secrets/hetzner_storagebox_known_hosts >/dev/null
sudo chmod 600 /etc/domum-core-media/secrets/hetzner_storagebox_known_hosts
```

If your box uses a username-specific host like `u612125.your-storagebox.de`, use that exact hostname in both the repository URL and `ssh-keyscan`.

## 5. Verify passwordless SSH access

```bash
sudo ssh -i /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts \
  -p 23 \
  b11@b11.your-storagebox.de "pwd"
```

This should not prompt for a password.

If it still prompts, the key is not installed correctly in Hetzner or the hostname/user does not match the repository URL.

## 6. Initialize the repository

```bash
sudo domum-media backup init cloud
```

If the repository already exists and you want to adopt it:

```bash
sudo domum-media backup init cloud --adopt-existing
```

## 7. Run a plan and a check

```bash
sudo domum-media backup plan cloud
sudo /usr/local/bin/domum-media-backup --check
```

## 8. If no backend env vars are needed

SFTP targets such as Hetzner Storage Box do not need B2/S3 backend variables.

This env file is valid if you want one:

```bash
sudo tee /etc/domum-core-media/secrets/restic_cloud_env >/dev/null <<'EOF'
# Hetzner SFTP target does not need backend env vars.
EOF
sudo chmod 600 /etc/domum-core-media/secrets/restic_cloud_env
sudo chown root:root /etc/domum-core-media/secrets/restic_cloud_env
```

An absent file is also fine.

## Troubleshooting & maintenance

Replace `b11` and `b11.your-storagebox.de` with your actual Storage Box user and host wherever they appear below.

### Key auth still prompts for a password

Re-run the verify command from §5. If it still prompts, the public key is missing on the Hetzner side. Open Hetzner Robot -> Storage Box -> SSH Keys and confirm the contents of `/etc/domum-core-media/secrets/hetzner_storagebox_ed25519.pub` are listed.

### `subprocess ssh: usage:` or `unexpected EOF` from restic

This is a regression of a known bug: restic's `sftp.command` option must be a complete command including the destination and the `-s sftp` subsystem. Confirm `sftp_command_option_for_target` in both `bin/domum-media` and `bin/domum-media-backup` appends `user@host -s sftp` to the ssh command — not just option flags.

### `repository does not exist`

The repo path on the box is `~/domum-core-media-restic`. If restic refuses to open it:

```bash
sudo domum-media backup init cloud --adopt-existing
```

Use `--adopt-existing` when the directory was created by a previous host or a manual SFTP session.

### Confirm a backup actually landed

```bash
sudo /usr/local/bin/domum-media-backup --snapshots
sudo domum-media backup plan cloud
sudo domum-media status --counts
```

The status command should list at least one snapshot under `=== restic last snapshots === -- cloud --`.

### Deep integrity check (transfers data, slow)

```bash
sudo /usr/local/bin/domum-media-backup --check-cloud-deep cloud
```

Hetzner egress is metered and slow, so run this monthly at most — the weekly check already runs a metadata-only verification.

### Inspect the systemd timer

```bash
systemctl list-timers | grep domum-media
journalctl -u domum-media-backup.service --since '7 days ago'
```

A healthy weekly run logs no password prompt, a `restic backup` summary, and a non-zero `Added to the repository` size.

### Rotate the SSH key

Re-run §2 to generate a new key, §3 to install the new public key in Hetzner Robot, then §5 to verify. Keep the old key listed in Robot until the verify step succeeds with the new one, then remove it.

### Inspect disk usage on the Storage Box

```bash
sudo ssh -i /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 \
  -o UserKnownHostsFile=/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts \
  -p 23 b11@b11.your-storagebox.de "du -sh ./domum-core-media-restic"
```

## Improvement notes (optional follow-ups)

These are recorded for future work; they are not required for the weekly backup to function.

- **Upload bandwidth cap.** A first-ever upload of the Immich library can saturate the link. Consider adding `-o sftp.connections=2` to the restic invocation and a `BACKUP_TARGET_CLOUD_UPLOAD_LIMIT_KBPS` knob in `config/domum-media.conf` that maps to restic's `--limit-upload`.
- **Cloud retention.** Current settings (`RESTIC_KEEP_DAILY=7`, `WEEKLY=5`, `MONTHLY=12`, `YEARLY=3` with the cloud target on the weekly `forget` cadence) are appropriate for a metered remote. No change recommended.
- **Heartbeat.** `BACKUP_HEARTBEAT_URL` is empty. Wiring it to the existing `uptime-kuma` container produces a paging signal when a weekly run silently fails.
- **Recovery drill.** `docs/disaster-recovery.md` documents `--restore latest --repo cloud`. Run it quarterly into a scratch directory to prove the restore path, not just the backup path.
