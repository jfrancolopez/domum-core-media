# Security patches

Host package handling is split into two tiers.

## Tier 1: unattended security patches

`domum-media` writes `/etc/apt/apt.conf.d/50domum-unattended-upgrades` and
restricts unattended upgrades to Debian Security.

Docker packages are blacklisted from this tier.

Relevant config:

```bash
HOST_SECURITY_AUTO_UPDATE_ENABLED=1
HOST_AUTO_REBOOT_ENABLED=0
HOST_AUTO_REBOOT_WINDOW_START=03:00
HOST_AUTO_REBOOT_WINDOW_END=05:00
```

## Tier 2: general package upgrades

```bash
sudo domum-media host-upgrade --force
```

This upgrades Docker, Compose, Tailscale, restic, and related host tooling from
their configured apt repositories.

If `/var/run/reboot-required` exists and the reboot window is open,
`host-upgrade` can schedule a reboot automatically when
`HOST_AUTO_REBOOT_ENABLED=1`.
