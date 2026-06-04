# Navidrome — multi-source music library

Navidrome is a Subsonic-compatible music server. It is reached at
`https://music.${DOMUM_DOMAIN}` and works with any Subsonic client
(play:Sub, Symfonium, DSub, Feishin, the web UI, etc.).

The design goal here is **one server, many libraries, sourced from anywhere** —
not just music that physically lives on this N100. We do that the same way
Jellyfin handles media: the *host* assembles every music source under one
parent directory, and the container mounts that parent read-only. Navidrome's
native multi-library feature (v0.58+) then exposes each subfolder as its own
library.

```
                         NAVIDROME_MUSIC_ROOT (/srv/music)  --ro-->  /music
                         ├── local      (music on this box)            Library "local"
                         ├── nas        (NFS/SMB mount, another host)   Library "nas"
                         └── cloud      (rclone mount, cloud remote)    Library "cloud"
```

Each subfolder can be a plain directory **or a mount from somewhere else**.
Navidrome doesn't care — it just reads the filesystem.

---

## 1. Enable the service

```
sudo domum-media configure      # answer "y" to "Enable Navidrome (music)?"
# or hand-edit config/domum-media.conf:  ENABLE_NAVIDROME=1
```

Relevant config keys (`config/domum-media.conf`):

| Key | Default | Meaning |
| --- | --- | --- |
| `NAVIDROME_VERSION` | `0.61.2` | Pinned image tag — never `latest`. |
| `NAVIDROME_DATA_DIR` | `/srv/data/navidrome` | DB + scan cache (snapshotted, backed up). |
| `NAVIDROME_MUSIC_ROOT` | `/srv/music` | Parent of all music sources, mounted `:ro`. |
| `NAVIDROME_USER` | `0:0` | Container uid:gid that reads music. |
| `NAVIDROME_SCAN_SCHEDULE` | `@every 1h` | Rescan cadence. `0` disables. |
| `NAVIDROME_LOG_LEVEL` | `info` | `error\|warn\|info\|debug\|trace`. |

## 2. Create the state subvolume

State must be a btrfs subvolume so it is snapshotted before each `apply` and
swept into restic (it lives under `/srv/data`). The music itself is **not**
backed up here — like Jellyfin media, it is treated as large/replaceable.

```
sudo btrfs subvolume create /srv/data/navidrome
```

(`navidrome` is already in the CLI snapshot list and `ensure_dirs`, so once the
subvolume exists it is picked up automatically.)

## 3. Assemble the music sources

Create the parent root and put each source under it. Pick whichever recipes
match where your music actually lives.

```
sudo mkdir -p /srv/music
```

### a) Music already on this box

Just use a subfolder (or bind/symlink an existing path):

```
sudo mkdir -p /srv/music/local
# copy/move music in, or:
sudo mount --bind /path/to/existing/music /srv/music/local
```

### b) A NAS or another server over NFS

```
sudo apt install -y nfs-common        # if not already present
sudo mkdir -p /srv/music/nas
```

Add to `/etc/fstab` so it survives reboots (then `sudo mount /srv/music/nas`):

```
nas.example:/exports/music   /srv/music/nas   nfs   ro,soft,timeo=30,_netdev,nofail   0 0
```

### c) A NAS / Windows box over SMB/CIFS

```
sudo apt install -y cifs-utils
sudo mkdir -p /srv/music/nas
```

Store the credentials root-only (`/etc/domum-core-media/secrets/smb_music`,
`chmod 600`, lines `username=…`, `password=…`), then `/etc/fstab`:

```
//nas.example/music   /srv/music/nas   cifs   ro,credentials=/etc/domum-core-media/secrets/smb_music,uid=0,gid=0,_netdev,nofail   0 0
```

### d) A cloud remote over rclone

`rclone` is already installed (the backup system uses it). Configure a remote
(`rclone config`), then mount it. A simple systemd unit keeps it mounted:

`/etc/systemd/system/rclone-music.service`
```
[Unit]
Description=rclone mount cloud music
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount myremote:music /srv/music/cloud \
  --read-only --allow-other --dir-cache-time 24h --vfs-cache-mode full
ExecStop=/bin/fusermount -uz /srv/music/cloud
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
```
sudo mkdir -p /srv/music/cloud
sudo systemctl enable --now rclone-music
```

> If you use `:ro` NFS/SMB or `--read-only` rclone, also keep
> `NAVIDROME_USER="0:0"` (root) so the container can always read regardless of
> remote ownership mapping.

## 4. Bring it up

```
sudo domum-media apply
```

## 5. Add the libraries in the UI

1. Open `https://music.${DOMUM_DOMAIN}` and create the admin account on first
   launch.
2. `/music` is automatically **Library 1** (your `NAVIDROME_MUSIC_ROOT`). If you
   want each source as a distinct library, point Library 1 at one subfolder and
   add the others:
3. **Settings → Libraries → +**, name it (e.g. `nas`) and set the path to the
   in-container path, e.g. `/music/nas`, `/music/cloud`. Save and trigger a scan.
4. Grant non-admin users access per library under their user settings (admins
   see all libraries automatically).

## 6. DNS

LAN: add an A record in UniFi for `music.${DOMUM_DOMAIN}` → `${DOMUM_LAN_IP}`
(or use the wildcard). Tailscale split-DNS already covers everything under
`${DOMUM_DOMAIN}`.

---

## Notes & gotchas

- **The music root is read-only inside the container** (`:ro`). Navidrome never
  writes to your files; ratings/playlists live in `/srv/data/navidrome`.
- **`_netdev,nofail` matters.** Without it a missing NAS/cloud mount can block
  boot or, worse, let Navidrome scan an *empty* mountpoint and mark the whole
  library as deleted. With `nofail` the source simply shows up empty until the
  mount returns.
- **Adding a new source later** is just another subfolder/mount + a new library
  in the UI — no compose or CLI changes.
- **Backups:** `/srv/data/navidrome` (the DB) is backed up; the music under
  `/srv/music` is not. Back up the originals at their source.
