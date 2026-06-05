# Service Template

Copy-paste skeleton for a new compose fragment.

## Fragment

`compose/<category>/<service>.yml`:

```yaml
services:
  SERVICE_NAME:
    image: ${SERVICE_NAME_IMAGE}
    container_name: SERVICE_NAME
    restart: unless-stopped
    networks:
      - domum-proxy
      - domum-internal
    volumes:
      - /srv/data/SERVICE_NAME:/data
    environment:
      - SOME_KEY=${SOME_KEY}
    labels:
      - traefik.enable=true
      - traefik.docker.network=domum-proxy
      - traefik.http.routers.SERVICE_NAME.rule=Host(`SERVICE_NAME.${DOMUM_DOMAIN}`)
      - traefik.http.routers.SERVICE_NAME.entrypoints=websecure
      - traefik.http.routers.SERVICE_NAME.tls=true
      - traefik.http.routers.SERVICE_NAME.tls.certresolver=cf
      - traefik.http.routers.SERVICE_NAME.middlewares=securityHeaders@file
      - traefik.http.services.SERVICE_NAME.loadbalancer.server.port=PORT

networks:
  domum-proxy:
    external: true
  domum-internal:
    external: true
```

## Toggle

In `config/domum-media.conf`:

```
ENABLE_SERVICE_NAME=0
SERVICE_NAME_IMAGE="vendor/image:vX.Y.Z"
SERVICE_NAME_AUTO_UPDATE=0
SERVICE_NAME_AUTO_UPDATE_DELAY_DAYS=7
```

## CLI registration

In `bin/domum-media`, inside `compose_files_for_enabled_services()`:

```bash
if [[ "${ENABLE_SERVICE_NAME:-0}" == "1" ]]; then
  files+=("$DOMUM_DIR/compose/<category>/SERVICE_NAME.yml")
fi
```

## Design rules

- One service per fragment
- No hardcoded IPs
- External networks only (`domum-proxy`, `domum-internal`)
- State under `/srv/data/<service>` as a btrfs subvolume
- Secrets only in `/etc/domum-core-media/secrets/`
- Prefer pinned tags for stateful services. If you decide to use a moving tag,
  add `SERVICE_NAME_AUTO_UPDATE=1` and a delay window.
- If the service has stateful DB data, wire it into the backup quiesce
  routine in `bin/domum-media-backup`
