# Adding a New Service

Same six-step formula as `domum-core`. Don't reinvent it.

## 1. Compose fragment

Create `compose/<category>/<service>.yml`. Keep it focused. Reuse the shared
networks declared in `compose/base.yml` — don't redefine them.

```yaml
services:
  myservice:
    image: ${MYSERVICE_IMAGE}
    container_name: myservice
    restart: unless-stopped
    networks:
      - domum-proxy
      - domum-internal
    volumes:
      - /srv/data/myservice:/data
    labels:
      - traefik.enable=true
      - traefik.docker.network=domum-proxy
      - traefik.http.routers.myservice.rule=Host(`myservice.${DOMUM_DOMAIN}`)
      - traefik.http.routers.myservice.entrypoints=websecure
      - traefik.http.routers.myservice.tls=true
      - traefik.http.routers.myservice.tls.certresolver=cf
      - traefik.http.routers.myservice.middlewares=securityHeaders@file
      - traefik.http.services.myservice.loadbalancer.server.port=8080

networks:
  domum-proxy:
    external: true
  domum-internal:
    external: true
```

Prefer a pinned image tag. If you decide to use a moving tag, add matching
`MYSERVICE_AUTO_UPDATE` and `MYSERVICE_AUTO_UPDATE_DELAY_DAYS` config keys.

## 2. Add a toggle

In `config/domum-media.conf` (host) and `config/domum-media.conf.example`
(repo, default off):

```
ENABLE_MYSERVICE=0
MYSERVICE_IMAGE="vendor/myservice:vX.Y.Z"
MYSERVICE_AUTO_UPDATE=0
MYSERVICE_AUTO_UPDATE_DELAY_DAYS=7
```

## 3. Register the fragment in `bin/domum-media`

In `compose_files_for_enabled_services()`:

```bash
if [[ "${ENABLE_MYSERVICE:-0}" == "1" ]]; then
  files+=("$DOMUM_DIR/compose/<category>/myservice.yml")
fi
```

## 4. Subvolume for stateful data

If the service stores state, create a btrfs subvolume so it gets snapshotted:

```
sudo btrfs subvolume create /srv/data/myservice
```

Then add it to the snapshot list in `bin/domum-media`
(`snapshot_subvolumes()`).

## 5. Apply

```
sudo domum-media apply
```

The CLI takes a pre-apply btrfs snapshot, runs `docker compose up -d
--remove-orphans`, and you're done.

## 6. DNS

LAN: add an A record in UniFi for `myservice.${DOMUM_DOMAIN}` →
`${DOMUM_LAN_IP}` (or wildcard).

Tailscale split-DNS already covers everything under `${DOMUM_DOMAIN}` if you
set it up per `SETUP-CLOUDFLARE.md`.

## Best practices

- One service per fragment
- No hardcoded IPs
- `/srv/data/<service>` for state — subvolume, not plain dir
- Secrets only in `/etc/domum-core-media/secrets/`, sourced by the CLI
- Never edit files inside `/opt/domum-core-media` directly
