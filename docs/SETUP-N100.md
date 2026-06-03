# Setting up the N100 host

This is the one-shot manual procedure for the Intel N100 mini-PC running
Debian 13. Everything here is too destructive to live inside `install.sh`.

## 1. Install Debian 13

- Net-install ISO, minimal install (no desktop). Root + an `admin` user.
- SSH server only. Disable password SSH after you've copied your key in.
- Hostname: `domum-media` (or whatever; nothing in the repo depends on it).

## 2. BIOS

- Disable wake-on-LAN unless you actually use it.
- Enable C-states (C8+ is where the N100 sips power).
- Fan curve: silent / passive if your case supports it.
- Disable Intel ME network access if exposed.

## 3. SSD layout (btrfs)

The plan: one 1 TB SSD, one root filesystem on a small partition, and one big
btrfs partition for `/srv/data` with named subvolumes.

```
sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:"EFI"   /dev/nvme0n1
sgdisk -n 2:0:+30G  -t 2:8300 -c 2:"root"  /dev/nvme0n1
sgdisk -n 3:0:0     -t 3:8300 -c 3:"data"  /dev/nvme0n1
```

Format:

```
mkfs.vfat -F32 /dev/nvme0n1p1
mkfs.ext4      /dev/nvme0n1p2
mkfs.btrfs -L data /dev/nvme0n1p3
```

Create subvolumes (mount the bare partition first, then create):

```
mount /dev/nvme0n1p3 /mnt
btrfs subvolume create /mnt/@data
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@data/immich
btrfs subvolume create /mnt/@data/immich/library
btrfs subvolume create /mnt/@data/immich/postgres
btrfs subvolume create /mnt/@data/jellyfin
btrfs subvolume create /mnt/@data/uptime-kuma
btrfs subvolume create /mnt/@data/traefik
umount /mnt
```

## 4. `/etc/fstab`

```
UUID=<data-uuid> /srv/data       btrfs subvol=@data,noatime,compress=zstd:3,space_cache=v2,ssd  0 0
UUID=<data-uuid> /srv/snapshots  btrfs subvol=@snapshots,noatime,compress=zstd:3,space_cache=v2,ssd 0 0
```

`mkdir -p /srv/data /srv/snapshots && mount -a` to apply.

## 5. Power tuning

Install + enable powertop auto-tune via a systemd oneshot at boot:

```
apt-get install -y powertop
cat >/etc/systemd/system/powertop.service <<'EOF'
[Unit]
Description=PowerTOP auto-tune
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now powertop.service
```

Optional: enable CPU `powersave` governor in `/etc/default/cpufrequtils`.

Done right, the N100 idles around 6–8 W with the full stack up.

## 6. Then run `install.sh`

Now you're ready for the curl-bootstrap from the README.

## Notes on the btrfs choice

- **Atomic snapshots before each `apply`** — instant rollback of a bad upgrade
  via `btrfs subvolume snapshot`. The CLI does this automatically.
- **Checksums detect bitrot.** btrfs will surface a corrupt block loudly rather
  than silently feeding it to restic. With a single disk, it can't *repair*;
  but it can flag, which is what we want.
- Snapshots are *not* a substitute for restic. They die with the disk. Restic
  is the recovery story; snapshots are the operator-error story.
