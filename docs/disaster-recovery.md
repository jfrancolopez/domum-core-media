# Disaster recovery

Recovery is driven by three artefacts:

- git checkout
- restic backup
- encrypted recovery pack

## 1. Bootstrap the host

```bash
curl -fsSL https://raw.githubusercontent.com/jfrancolopez/domum-core-media/main/install.sh | sudo bash
```

## 2. Decrypt the latest recovery pack

The pack contains:

- `config/domum-media.conf`
- `secrets/*`
- rendered compose manifest
- restore notes

Decrypt it with your age private key and restore:

- `config/domum-media.conf` to `/opt/domum-core-media/config/domum-media.conf`
- `secrets/*` to `/etc/domum-core-media/secrets/`

Set restored secrets to `0600 root:root`.

## 3. Sync local config/state

```bash
sudo domum-media configure --non-interactive
sudo domum-media init
```

## 4. Restore `/srv/data`

```bash
sudo /usr/local/bin/domum-media-backup --restore latest / --repo nas
# or cloud / archive
```

Restore into the correct btrfs layout if you used a different target path.

## 5. Bring the stack up

```bash
sudo domum-media apply
```

## 6. Validate

```bash
sudo domum-media checkup
sudo domum-media doctor immich
sudo domum-media rollback list
```

## 7. Refresh the DR artefacts

```bash
sudo /usr/local/bin/domum-media-backup
sudo domum-media recovery-pack create
```

## What the recovery pack does not contain

- photos
- media libraries
- postgres data files
- restic repositories

Those remain in the backup tier only.
