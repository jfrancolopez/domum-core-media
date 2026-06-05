# Traefik dashboard auth

The dashboard is exposed through Traefik itself and protected with HTTP basic
auth. The credentials live outside git so the repo remains the routing source
of truth and the host remains the secret source of truth.

## Choose the hostname

Set the dashboard host in `config/domum-media.conf`:

```bash
TRAEFIK_DASHBOARD_HOST="traefik-media.ladomum.com"
```

The default in `config/domum-media.conf.example` is
`traefik-media.${DOMUM_DOMAIN}`.

If you run `sudo domum-media configure`, the wizard can set this key and write
the dashboard credential file for you.

## Create the credential file

Generate a bcrypt htpasswd entry and write it to the secret path used by the
compose stack:

```bash
sudo mkdir -p /etc/domum-core-media/secrets
sudo chmod 700 /etc/domum-core-media/secrets
sudo docker run --rm --entrypoint htpasswd httpd:2.4-alpine -nB admin | \
  sudo tee /etc/domum-core-media/secrets/traefik_dashboard_users >/dev/null
sudo chmod 600 /etc/domum-core-media/secrets/traefik_dashboard_users
sudo chown root:root /etc/domum-core-media/secrets/traefik_dashboard_users

### or manually:
sudo docker run --rm httpd:2.4-alpine htpasswd -nbB adminuser 'YOUR_PASSWORD_HERE' | sudo tee /etc/domum-core-media/secrets/traefik_dashboard_users >/dev/null
sudo chmod 600 /etc/domum-core-media/secrets/traefik_dashboard_users
sudo chown root:root /etc/domum-core-media/secrets/traefik_dashboard_users
```

If you want a different path, set `TRAEFIK_DASHBOARD_USERS_FILE` in
`config/domum-media.conf`.

## Apply

```bash
sudo domum-media apply
```

## Verify

```bash
curl -u admin "https://${TRAEFIK_DASHBOARD_HOST}/api/version"
```
