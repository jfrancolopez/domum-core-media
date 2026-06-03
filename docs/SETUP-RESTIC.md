# restic setup

At least two repos. Never one. **Initialise every enabled target manually
before the timer fires.**

| Repo | Transport | Why |
| --- | --- | --- |
| `nas` | `rest:` (REST server in append-only mode) or NFS | Fast local restore |
| `cloud` | Backblaze B2 (`b2:bucket:/path`) | Off-site, geo-separated |
| `archive` | FTP via `rclone:` or another restic backend | Optional third copy |

The easiest path now is to run `sudo domum-media configure` and fill in the
backup target section instead of hand-maintaining multiple env files.

## 1. Generate passwords

```
openssl rand -base64 48 | sudo tee /etc/domum-core-media/secrets/restic_password_nas   >/dev/null
openssl rand -base64 48 | sudo tee /etc/domum-core-media/secrets/restic_password_cloud >/dev/null
sudo chmod 600 /etc/domum-core-media/secrets/restic_password_{nas,cloud}
```

### Password escrow (NOT optional)

A lost restic password means the backups are useless. Place each password in
**both** of these durable locations before you run the first backup:

1. **Sealed envelope**, stored with your other vital documents (birth certs,
   etc.). Print the password, seal the envelope, sign across the flap.
2. **Password manager** whose recovery does not depend on this house — i.e.,
   if the house burns, you can still restore the password manager from a
   recovery code you keep elsewhere.

Print them. Seal them. Stash them. Then proceed.

## 2. Choose how to define each target

### Option A: use the config file directly

In `config/domum-media.conf`, set the enabled targets and fill the matching
`BACKUP_TARGET_*` block. For a normal restic backend, paste the repository
string directly:

```
BACKUP_TARGET_NAS_TYPE="repository"
BACKUP_TARGET_NAS_REPOSITORY="rest:http://nas-host:8000/domum-media"
BACKUP_TARGET_NAS_PASSWORD_FILE="/etc/domum-core-media/secrets/restic_password_nas"
```

If that backend also needs credential exports, point the target at an env file:

```
BACKUP_TARGET_CLOUD_TYPE="repository"
BACKUP_TARGET_CLOUD_REPOSITORY="b2:your-bucket-name:/domum-media"
BACKUP_TARGET_CLOUD_PASSWORD_FILE="/etc/domum-core-media/secrets/restic_password_cloud"
BACKUP_TARGET_CLOUD_ENV_FILE="/etc/domum-core-media/secrets/restic_cloud_env"
```

For NFS:

```
BACKUP_TARGET_ARCHIVE_TYPE="nfs"
BACKUP_TARGET_ARCHIVE_NFS_REMOTE="nas.example:/exports/domum-media"
BACKUP_TARGET_ARCHIVE_NFS_MOUNT_POINT="/mnt/domum-media-archive"
BACKUP_TARGET_ARCHIVE_REPOSITORY="/mnt/domum-media-archive/restic"
BACKUP_TARGET_ARCHIVE_PASSWORD_FILE="/etc/domum-core-media/secrets/restic_password_archive"
```

For FTP, the wrapper uses restic's `rclone:` backend and reads the FTP
username/password from files under `/etc/domum-core-media/secrets/`.

### Option B: keep the legacy per-repo env files

The old `restic_nas_env` / `restic_cloud_env` files are still supported as a
fallback for repository-style targets.

## 3. Write the per-repo env files

`/etc/domum-core-media/secrets/restic_nas_env`:

```
export RESTIC_REPOSITORY="rest:http://<nas-host>:8000/domum-media/"
# If your rest-server is auth'd:
# export RESTIC_REPOSITORY="rest:http://user:pass@<nas-host>:8000/domum-media/"
```

`/etc/domum-core-media/secrets/restic_cloud_env`:

```
export RESTIC_REPOSITORY="b2:your-bucket-name:/domum-media"
export B2_ACCOUNT_ID="<application-key-id>"
export B2_ACCOUNT_KEY="<application-key>"
```

`chmod 600` both, root-owned.

For the NAS: run a `rest-server` somewhere with `--append-only` so a
compromised N100 can write new snapshots but cannot delete or rewrite old
ones. Append-only mode is *the* reason we use `rest-server` over `sftp:`.

## 4. Initialise the repos

```
sudo bash -c '. /etc/domum-core-media/secrets/restic_nas_env;   RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_nas   restic init'
sudo bash -c '. /etc/domum-core-media/secrets/restic_cloud_env; RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_cloud restic init'
```

## 5. Run the first backup manually

```
sudo /usr/local/bin/domum-media-backup
```

Then verify:

```
sudo /usr/local/bin/domum-media-backup --check
```

Both should be clean before you trust the timer.

## 6. Verification cadence

| Cadence | What | How |
| --- | --- | --- |
| Daily 02:30 | Full backup → every enabled target, plus daily-retention targets | `domum-media-backup.timer` |
| Weekly Sun 03:30 | `restic check` on enabled targets + weekly-retention targets | `domum-media-check.timer` |
| Monthly | `restic check --read-data-subset=10%` on one target | `domum-media-backup --check-deep [target]` |
| Quarterly | Full `--read-data` on one target + manual restore drill | `domum-media-backup --check-cloud-deep [target]` + `domum-media-dr-reminder.timer` |

The deep checks are still manual by default. If you want them scheduled,
create an extra timer or add a calendar reminder.

## If Debian's restic version is too old

Some restic features (compression in v0.14, official Backblaze B2 auth
improvements) need a newer version than Debian ships. Pinned binary install:

```
RESTIC_VER=0.17.3
curl -fsSL -o /tmp/restic.bz2 \
  https://github.com/restic/restic/releases/download/v${RESTIC_VER}/restic_${RESTIC_VER}_linux_amd64.bz2
bunzip2 /tmp/restic.bz2
install -m 0755 /tmp/restic /usr/local/bin/restic
rm -f /tmp/restic
restic version
```

`/usr/local/bin` takes precedence over `/usr/bin`, so the wrapper will pick it
up without further changes.
