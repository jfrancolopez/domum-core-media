# Cloudflare DNS-01 token

Traefik gets Let's Encrypt certs via Cloudflare DNS-01. No inbound ports
required.

## Create the token

In the Cloudflare dashboard → My Profile → API Tokens → Create Token →
**Custom token**:

- Permissions:
  - `Zone:DNS:Edit` for the zone(s) you host (e.g., `ladomum.com`)
  - `Zone:Zone:Read` for those zones
- Zone Resources: include the specific zone(s), not "all zones"
- TTL: no expiry, or set a calendar reminder to rotate.

## Place the token on the host

```
sudo mkdir -p /etc/domum-core-media/secrets
sudo chmod 700 /etc/domum-core-media/secrets
echo 'YOUR_TOKEN_HERE' | sudo tee /etc/domum-core-media/secrets/cloudflare_api_token >/dev/null
sudo chmod 600 /etc/domum-core-media/secrets/cloudflare_api_token
sudo chown root:root /etc/domum-core-media/secrets/cloudflare_api_token
```

## Apply

```
sudo domum-media apply
```

Traefik will resolve, request a cert per Host rule, and store it in the
`traefik-letsencrypt` named volume. Watch `docker logs traefik` for the
ACME flow on first run.

## DNS records (UniFi LAN + Tailscale split DNS)

The DNS-01 challenge doesn't require *public* A records — but you do need
LAN/Tailscale resolution to point clients at the box.

LAN (UniFi → Settings → DNS): create local A records for the hostnames you
expose, e.g. `photos.ladomum.com` → `10.0.0.x`. Wildcard works if your
controller supports it.

Tailscale (admin console → DNS → Split DNS):
- Domain: `ladomum.com`
- Nameserver: your LAN DNS resolver (UniFi gateway, AdGuard, whatever)
