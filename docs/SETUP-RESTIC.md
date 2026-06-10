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

## Initialize repositories

After configuration, initialize each enabled repo manually.

Example:

```bash
sudo bash -c '. /etc/domum-core-media/secrets/restic_nas_env; RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_nas restic init'
sudo bash -c '. /etc/domum-core-media/secrets/restic_cloud_env; RESTIC_PASSWORD_FILE=/etc/domum-core-media/secrets/restic_password_cloud restic init'
```

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
