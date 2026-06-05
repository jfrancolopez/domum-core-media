# Image and host update policy

The stack now separates three concerns:

1. `config/domum-media.conf` decides **which image ref** each service uses.
2. `*_AUTO_UPDATE` decides whether a service should automatically roll forward
   when that image ref points at something newer.
3. The systemd timers decide **when** to check for new container images or new
   apt packages on the host.

## Pinned vs moving tags

Pinned example:

```bash
TRAEFIK_IMAGE="traefik:v3.7.1"
TRAEFIK_AUTO_UPDATE=0
```

Moving-tag example:

```bash
TRAEFIK_IMAGE="traefik:latest"
TRAEFIK_AUTO_UPDATE=1
TRAEFIK_AUTO_UPDATE_DELAY_DAYS=7
```

For moving tags, the refresh job pulls the image daily. If the pulled image is
different from the one the container is currently running, the CLI records when
that newer image was first seen. Once the delay window expires, the service is
recreated during the next refresh run.

## Timers

Container image refresh:

```bash
IMAGE_AUTO_UPDATE_ENABLED=1
IMAGE_AUTO_UPDATE_AT="05:15"
IMAGE_AUTO_UPDATE_RANDOMIZED_DELAY="30m"
```

Host package upgrades:

```bash
HOST_PACKAGE_AUTO_UPDATE_ENABLED=1
HOST_PACKAGE_AUTO_UPDATE_AT="Mon 05:45"
HOST_PACKAGE_AUTO_UPDATE_RANDOMIZED_DELAY="45m"
```

## Manual runs

Run the checks immediately:

```bash
sudo domum-media refresh-images --force
sudo domum-media host-upgrade --force
```

## Operational advice

- Keep stateful services pinned unless you have read their release notes and
  understand the migration path.
- If you use moving tags, prefer a non-zero delay so somebody else finds the
  bad release first.
- For Immich, the app images should generally stay pinned; automatic rollouts
  are possible, but only if you accept schema migrations landing unattended.
