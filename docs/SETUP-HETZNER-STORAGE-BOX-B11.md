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
