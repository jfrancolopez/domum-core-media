# restic setup

Two repos. Never one. **Initialise both manually before the timer fires.**

| Repo | Transport | Why |
| --- | --- | --- |
| `nas` | `rest:` (REST server in append-only mode) | Fast local restore, append-only means a compromised N100 can't delete old snapshots |
| `cloud` | Backblaze B2 (`b2:bucket:/path`) | Off-site, geo-separated |

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

## 2. Write the per-repo env files

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

## 3. Initialise both repos

```
sudo bash -c '. /etc/domum-core-media/secrets/restic_nas_env;   RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_nas   restic init'
sudo bash -c '. /etc/domum-core-media/secrets/restic_cloud_env; RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_cloud restic init'
```

## 4. Run the first backup manually

```
sudo /usr/local/bin/domum-media-backup
```

Then verify:

```
sudo /usr/local/bin/domum-media-backup --check
```

Both should be clean before you trust the timer.

## 5. Verification cadence

| Cadence | What | How |
| --- | --- | --- |
| Daily 02:30 | Full backup → NAS + cloud, NAS retention | `domum-media-backup.timer` |
| Weekly Sun 03:30 | `restic check` (metadata) on both repos | `domum-media-check.timer` |
| Monthly | `restic check --read-data-subset=10%` on NAS | `domum-media-backup --check-deep`, drop-in or cron |
| Quarterly | Full `--read-data` on cloud + manual restore drill | `domum-media-dr-reminder.timer` reminds you |

The monthly deep NAS check is not yet wired into a separate timer — drop a
calendar reminder into your phone or extend `domum-media-check.timer` with a
second invocation that calls `--check-deep`.

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
