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
- `Restic repository string for cloud` -> `sftp:b11@b11.your-storagebox.de:/home/domum-core-media-restic`
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

Verify the captured fingerprint against a trusted Hetzner source before using
it. `ssh-keyscan` retrieves a key but does not authenticate it.

If your box uses a username-specific host like `u612125.your-storagebox.de`, use that exact hostname in both the repository URL and `ssh-keyscan`.

## 5. Verify passwordless SSH access

```bash
printf 'pwd\nquit\n' | sudo sftp -F /dev/null \
  -i /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts \
  -P 23 b11@b11.your-storagebox.de
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

The accepted path form is `/home/domum-core-media-restic`. If Restic refuses to
open it, first compare the configured target and pinned repository ID with the
accepted production record. Do not adopt a different repository merely because
it opens.

```bash
sudo domum-media backup init cloud --adopt-existing
```

Use `--adopt-existing` when the directory was created by a previous host or a manual SFTP session.

### Reset and reinitialize the cloud repo

Repository deletion, identity removal, and reinitialization are destructive
recovery operations. Stop and obtain explicit operator approval before using
this procedure against the canonical repository. Historical repositories are
not cleanup candidates.

When an approved remote reset has occurred, recreate it from scratch:

1. (optional) Remove the remote dir via a known-good SFTP session — using the
   exact ssh key + known_hosts + port the backup wrapper uses, so it cannot
   prompt for a password:

   ```bash
   sftp -F /dev/null -i /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 \
       -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
       -o PasswordAuthentication=no \
       -o UserKnownHostsFile=/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts \
       -o StrictHostKeyChecking=yes -P 23 \
       b11@b11.your-storagebox.de
    # at the sftp prompt:
    #   rm -r /home/domum-core-media-restic
   ```

2. Clear the saved repo identity so the wrapper does not refuse to reinitialize:

   ```bash
   sudo rm -f /var/lib/domum-media/backups/cloud-repo.env
   ```

3. `backup init cloud` recreates the repo when it is missing. It uses the
   configured `BACKUP_TARGET_CLOUD_REPOSITORY` and the array-built
   `-o sftp.command='ssh … -s sftp'` option, so it never prompts for a password:

   ```bash
   sudo domum-media backup init cloud
   ```

4. Run a fresh backup and integrity check:

   ```bash
   sudo /usr/local/bin/domum-media-backup
   sudo /usr/local/bin/domum-media-backup --check
   sudo domum-media status --counts   # confirms the new snapshot lands
   ```

`restic_cloud_env` is optional — it is for additional backend env vars only and
does not need to contain `RESTIC_REPOSITORY` (the wrapper passes the repo via
`--repo` directly).

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

Hetzner egress is metered and slow, so run this monthly at most. The weekly
check already runs a metadata-only verification.

### Inspect the systemd timer

```bash
systemctl list-timers | grep domum-media
journalctl -u domum-media-backup.service --since '7 days ago'
```

A healthy daily run logs no password prompt, a `restic backup` summary, and a
saved snapshot. Incremental runs can legitimately add very little data.

### Rotate the SSH key

Re-run §2 to generate a new key, §3 to install the new public key in Hetzner Robot, then §5 to verify. Keep the old key listed in Robot until the verify step succeeds with the new one, then remove it.

### Inspect disk usage on the Storage Box

Use Hetzner Robot's Storage Box usage display. The backup key is intentionally
restricted to the SFTP subsystem and should not be broadened to permit remote
shell commands such as `du`.

## Improvement notes (optional follow-ups)

These are recorded for future work; they are not required for the daily backup to function.

- **Upload bandwidth cap.** A first-ever upload of the Immich library can saturate the link. Consider adding `-o sftp.connections=2` to the restic invocation and a `BACKUP_TARGET_CLOUD_UPLOAD_LIMIT_KBPS` knob in `config/domum-media.conf` that maps to restic's `--limit-upload`.
- **Cloud retention.** Current settings (`RESTIC_KEEP_DAILY=7`, `WEEKLY=5`, `MONTHLY=12`, `YEARLY=3` with the cloud target on the weekly `forget` cadence) are appropriate for a metered remote. No change recommended.
- **Heartbeat.** `BACKUP_HEARTBEAT_URL` can feed an external monitor when a daily run fails to report.
- **Recovery drill.** The first representative scratch restore passed in September 2026. Retain a recurring restore-verification task rather than treating that one proof as permanent.

See [P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) for the accepted production
repository ID, first snapshot, restore evidence, and preserved historical paths.
