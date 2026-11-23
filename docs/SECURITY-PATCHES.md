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

This upgrades Tailscale, restic, btrfs-progs and related host tooling from
their configured apt repositories. **It does NOT upgrade Docker Engine or
Compose** (`docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin`, `docker-compose-plugin` -- `docker_engine_packages` is
the one list, also used as the unattended blacklist). When any of them is
upgradable it says so (`HELD BACK`), and `checkup` reports it as a warning.

## Tier 3: Docker Engine -- attended maintenance only

Upgrading Docker Engine restarts the Docker daemon, and with it **every
container**. Production, 2026-11-23: the weekly host-update upgraded docker-ce
29.9.3 -> 29.10.0 at 05:50, every container restarted, and Traefik came back
on a bind-mounted static config that had changed since its last start -- all
seven HTTPS routes returned 404 until it was restarted by hand at 12:18.

So it is done by the operator, in a window, and checked afterwards:

1. Confirm nothing live-mounted has changed since the containers last started.
   `operator/domum-media-deploy-reporting-fixes.sh` names every file a
   fast-forward changes under a running container's bind mount, and refuses
   them without `--accept-mounted-changes`.
2. `sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`
3. Verify: all containers running, every HTTPS route answering its
   application, Traefik's logs free of provider errors.

A reboot restarts every container in the same way, so the same check applies
before one (`docs/REBOOT-READINESS.md`).

If `/var/run/reboot-required` exists and the reboot window is open,
`host-upgrade` can schedule a reboot automatically when
`HOST_AUTO_REBOOT_ENABLED=1`.
