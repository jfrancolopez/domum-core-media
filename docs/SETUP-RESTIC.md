# restic setup

Use at least two targets.

## Recommended layout

- `nas`: fast local restore
- `cloud`: off-site copy
- `archive`: optional third target

Configure them through:

```bash
sudo domum-media configure
```

The wizard writes the `BACKUP_TARGET_*` config blocks and can create:

- restic password files
- backend env files
- FTP credential files

## SSH key setup for Hetzner Storage Box (SFTP)

For unattended cloud backups to Hetzner Storage Box via SFTP:

### 1. Generate an SSH key on the host

```bash
ssh-keygen -t ed25519 -f /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 -N "" -C "domum-media backup"
sudo chmod 600 /etc/domum-core-media/secrets/hetzner_storagebox_ed25519
```

### 2. Authorize the key on Hetzner Storage Box

1. Log in to Hetzner Robot (https://robot.hetzner.com)
2. Navigate to **Storage Box** > **Your Storage Box**
3. Click **SSH Keys**
4. Add a new key and paste the contents of:
   ```bash
   cat /etc/domum-core-media/secrets/hetzner_storagebox_ed25519.pub
   ```

### 3. Capture `known_hosts`

```bash
ssh-keyscan -p 23 u612125.your-storagebox.de | sudo tee /etc/domum-core-media/secrets/hetzner_storagebox_known_hosts
sudo chmod 600 /etc/domum-core-media/secrets/hetzner_storagebox_known_hosts
```

### 4. Test unattended access

```bash
ssh -i /etc/domum-core-media/secrets/hetzner_storagebox_ed25519 -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/etc/domum-core-media/secrets/hetzner_storagebox_known_hosts \
    -p 23 u612125@u612125.your-storagebox.de "ls -la /./domum-core-media-restic/"
```

Should work without a password prompt.

---

## Initialize repositories

After configuration, initialize each enabled repo:

```bash
sudo domum-media backup init nas
sudo domum-media backup init cloud
sudo domum-media backup init archive
```

If a repository already exists and you want to adopt it (instead of creating a new one):

```bash
sudo domum-media backup init cloud --adopt-existing
```

---

## Verify repository configuration

Before running the first backup, preview what will be included:

```bash
sudo domum-media backup plan cloud
```

This shows the target, repository URL, encryption method, include paths, and excluded paths (without connecting to the repository).

---

## Repository identity and port consistency

If you change the `BACKUP_TARGET_CLOUD_REPOSITORY` URL or `SFTP_PORT`, the backup wrapper will detect the mismatch on the next run:

```
ERROR: cloud restic repository ID mismatch.
  Expected: ee134f75...
  Current:  b4827cfdd7...
This usually means BACKUP_TARGET_CLOUD_REPOSITORY or port changed.
Run: sudo domum-media backup adopt-repo cloud
```

This prevents accidental split-brain backups (two separate repositories). Resolve by either:
1. Reverting to the correct repository URL/port, or
2. Running `sudo domum-media backup adopt-repo cloud` to adopt the new repository

See the **Cloud include profile** section below if changing to a different repository path.

---

## Cloud include profile (Immich only)

The cloud target is scoped to Immich data by default:

- ✅ `/srv/data/immich/library` — photos
- ✅ `/srv/data/immich/backup-staging` — database dump
- ✅ `/var/lib/domum-media/recovery-pack` — DR bundle

NOT included (by design):
- ❌ `/srv/media/movies`, `/srv/media/tv`, `/srv/media/music`, `/srv/media/books` — media libraries
- ❌ `/srv/data/jellyfin`, `/srv/data/plex`, `/srv/data/navidrome`, `/srv/data/calibre-web`, `/srv/data/kavita` — media app state

This keeps cloud storage costs low and focuses on critical data that can't be easily re-downloaded.

To customize the include paths, edit `BACKUP_TARGET_CLOUD_INCLUDE_PATHS` in `config/domum-media.conf` or use the wizard:

```bash
sudo domum-media configure
```

---

## Encryption clarity

**restic encrypts data locally before upload.**

- ✅ **Data at rest**: restic uses AES-256-GCM encryption with your restic password. Ciphertext only is stored on Hetzner.
- ✅ **Data in transit**: SSH/SFTP over port 23 encrypts the connection between your host and Hetzner.
- ✅ **Provider visibility**: Hetzner sees encrypted blobs only. They cannot read plaintext data.

Hetzner's own storage encryption (if any) is an additional layer, but **restic encryption is the primary trust boundary**.

## First run

```bash
sudo /usr/local/bin/domum-media-backup
sudo /usr/local/bin/domum-media-backup --check
```

## Recovery-pack setup

The recovery pack is a small encrypted tarball (~50–200 KB) containing:

- `/etc/domum-core-media/secrets/` (minus large key material)
- `config/domum-media.conf`
- current image manifest and service list
- latest restic snapshot IDs and timestamps
- auto-generated disaster-recovery README

It is **not** a data backup — Immich photos and media files are never included.
Its purpose is to reconstruct the system configuration quickly after a disaster,
when combined with the git repo and a real restic restore.

### 1. Generate an age keypair

```bash
sudo apt-get install -y age
age-keygen -o /tmp/recovery_key.txt
# Output: Public key: age1...
```

Store the private key somewhere safe (password manager, printed copy):

```bash
cat /tmp/recovery_key.txt   # keep the full "AGE-SECRET-KEY-1..." line
shred -u /tmp/recovery_key.txt
```

### 2. Register the public key

```bash
sudo mkdir -p /etc/domum-core-media/secrets
echo "age1..." | sudo tee /etc/domum-core-media/secrets/recovery_pack_pubkey
sudo chmod 600 /etc/domum-core-media/secrets/recovery_pack_pubkey
```

### 3. Configure recovery-pack vars

Edit `config/domum-media.conf` (copy from `config/domum-media.conf.example`):

```bash
RECOVERY_PACK_ENABLED=1
RECOVERY_PACK_ENCRYPTION=age
RECOVERY_PACK_AGE_PUBKEY_FILE="/etc/domum-core-media/secrets/recovery_pack_pubkey"
RECOVERY_PACK_DEST="/var/lib/domum-media/recovery-pack"
RECOVERY_PACK_REMINDER_DAYS=30
```

Optional SMTP delivery (sends the pack to your inbox after each creation):

```bash
RECOVERY_PACK_EMAIL_ENABLED=1
RECOVERY_PACK_EMAIL_TO="you@gmail.com"
RECOVERY_PACK_EMAIL_FROM="domum@ladomum.com"
RECOVERY_PACK_SMTP_HOST="smtp.gmail.com"
RECOVERY_PACK_SMTP_PORT="465"
RECOVERY_PACK_SMTP_USERNAME_FILE="/etc/domum-core-media/secrets/recovery_pack_smtp_username"
RECOVERY_PACK_SMTP_PASSWORD_FILE="/etc/domum-core-media/secrets/recovery_pack_smtp_password"
```

For Gmail, use an [App Password](https://myaccount.google.com/apppasswords), not your account password.

### 4. Create the first pack

```bash
sudo domum-media recovery-pack create
```

Verify it was written:

```bash
sudo domum-media recovery-pack status
```

### 5. Inspect the pack (optional)

```bash
# List contents without decrypting
age -d -i /path/to/private_key.txt \
  /var/lib/domum-media/recovery-pack/recovery-pack-*.tar.gz.age \
  | tar -tzvf -
```

### 6. Restore from the pack

On a fresh Debian install after a disaster:

```bash
# 1. Clone the repo
git clone https://github.com/jfrancolopez/domum-core-media /opt/domum-core-media
cd /opt/domum-core-media && bash install.sh

# 2. Decrypt and unpack
age -d -i /path/to/private_key.txt recovery-pack-YYYYMMDD.tar.gz.age \
  | tar -xzvf - -C /

# 3. Re-initialize restic repos and restore data
sudo domum-media recovery-pack restore
```

### Recovery-pack and daily backups

After a successful daily backup, the backup wrapper refreshes the encrypted
recovery pack if `RECOVERY_PACK_ENABLED=1`. That means the DR bundle stays near
the backup cadence without being mixed into the large data payload itself.

Create it manually anytime with:

```bash
sudo domum-media recovery-pack create
```
