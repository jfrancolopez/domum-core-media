# Setting up the N100 Host (Debian 13)

This document describes the manual provisioning process for the Intel N100 mini-PC running Debian 13.

These steps are intentionally kept outside of `install.sh` because they modify disks, firmware settings, users, filesystems, and other machine-specific configuration.

---

# 0. Architecture Assumptions

This guide assumes:

```text
OS SSD
└── 512 GB SSD
    ├── EFI
    ├── /
    └── swap

Data SSD
└── 1 TB SSD
    └── /srv/data
```

Current design philosophy:

```text
OS = disposable
Configuration = Git
Secrets = external
Data = persistent
Backups = recovery
```

The OS should be easy to rebuild.

The data disk should survive OS reinstalls.

---

# 1. Install Debian 13

Recommended:

- Debian 13 (Trixie)
- Minimal install
- No desktop environment
- OpenSSH server enabled
- Create a normal user account (e.g. `jfranco`)

Verify:

```bash
hostnamectl
sudo whoami
ip addr
ping -c 3 deb.debian.org
```

Expected:

- Debian 13
- sudo works
- network works
- DNS works

---

# 2. Fix sudo (if required)

Some minimal installations may not have sudo configured.

Install:

```bash
su -
apt update
apt install -y sudo
```

Add user:

```bash
/usr/sbin/usermod -aG sudo jfranco
#add docker too:
sudo usermod -aG docker jfranco
```

Verify:

```bash
groups jfranco
groups
```

Expected:

```text
jfranco sudo
```

Logout and log back in.

Verify:

```bash
sudo whoami
```

Expected:

```text
root
```

---

# 3. BIOS Configuration

Recommended:

Enable:

- Restore on AC Power Loss
- Intel VT-x
- Intel VT-d
- CPU C-States

Disable:

- Fast Boot
- Wake-on-LAN (unless used)

Optional:

- Silent fan profile

---

# 4. Verify Storage Before Modifying Anything

Inspect disks:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
sudo fdisk -l
df -h
```

Example:

```text
sda  512GB  OS SSD
sdb    1TB  Data SSD
```

Verify which disk contains Debian before continuing.

Do not run partitioning commands until disk identities are confirmed.

---

# 5. Base Packages

Install common administration tools:

```bash
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
curl wget git vim nano tmux \
htop btop jq yq \
rsync unzip zip \
smartmontools nvme-cli \
powertop lm-sensors \
ca-certificates gnupg \
dnsutils tree ncdu \
fail2ban openssh-server \
btrfs-progs parted
```

---

# 6. Configure Data SSD (Btrfs)

WARNING:

This destroys all data on the target disk.

Example data disk:

```text
/dev/sdb
```

Create GPT:

```bash
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary btrfs 1MiB 100%
```

Format:

```bash
sudo mkfs.btrfs -f -L data /dev/sdb1
```

Verify:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
```

Expected:

```text
sdb1 btrfs
```

---

# 7. Create Btrfs Subvolumes

Mount temporarily:

```bash
sudo mkdir -p /mnt/btrfs
sudo mount /dev/sdb1 /mnt/btrfs
```

Create:

```bash
sudo btrfs subvolume create /mnt/btrfs/@data
sudo btrfs subvolume create /mnt/btrfs/@snapshots
```

Unmount:

```bash
sudo umount /mnt/btrfs
```

Verify:

```bash
sudo blkid /dev/sdb1
```

Save UUID.

---

# 8. Configure fstab

Backup:

```bash
sudo cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M)
```

Add:

```fstab
# domum-media-core data disk
UUID=<uuid> /srv/data btrfs subvol=@data,noatime,compress=zstd:3,ssd 0 0
UUID=<uuid> /srv/snapshots btrfs subvol=@snapshots,noatime,compress=zstd:3,ssd 0 0
```

Create mount points:

```bash
sudo mkdir -p /srv/data /srv/snapshots
```

Apply:

```bash
sudo mount -a
sudo systemctl daemon-reload
```

Verify:

```bash
df -h | grep srv
findmnt | grep sdb1
```

---

# 9. Create Data Structure

The application uses direct service paths below `/srv/data` and media paths
below `/srv/media`; do not create the obsolete `containers/` or nested
`data/media/` layout.

```bash
sudo mkdir -p /srv/data/immich /srv/data/{jellyfin,plex,navidrome,calibre-web,kavita}
sudo mkdir -p /srv/media/{movies,tv,music,books,photos}

sudo chown -R $USER:$USER /srv/data
```

These commands create ordinary directories, not per-service Btrfs subvolumes.
That matches the current production layout but means the CLI's service-level
snapshot operation will skip them. Do not claim local service rollback
protection until an approved migration or snapshot redesign is complete.

---

# 10. Power Tuning

Calibrate:

```bash
sudo powertop --calibrate
```

Create service:

```bash
sudo nano /etc/systemd/system/powertop.service
```

Contents:

```ini
[Unit]
Description=PowerTOP auto-tune
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
sudo systemctl enable --now powertop.service
```

---

# 11. Neovim / LazyVim

Debian 13 currently ships:

```text
Neovim 0.10.x
```

LazyVim requires:

```text
>= 0.11.2
```

If using LazyVim, install a newer Neovim release instead of relying on the Debian package.

This is not required for server operation.

---

# 12. Ready for Bootstrap

Verify:

```bash
sudo whoami
ping -c 3 deb.debian.org
df -h
findmnt | grep srv
docker --version
```

Then:

```bash
curl -fsSL <install-url> | sudo bash
```

---

# Notes

Btrfs is used only on the data disk.

Root remains ext4.

Current benefits:

- checksums
- clean data separation

Backups remain the primary recovery mechanism.

The top-level filesystem is snapshot-capable, but current service paths are
ordinary directories and are not protected by the per-service snapshot code.
Current status: `Local service snapshot protection: DEGRADED / NOT AVAILABLE`.
Verify any future migration with `btrfs subvolume show /srv/data/<service>`;
do not run a migration as part of this setup procedure on an existing host.

Restic protects against disk loss.
