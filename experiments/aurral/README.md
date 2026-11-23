# Aurral — isolated experiment (side quest)

This is not part of Domum-Core-Media. It does not appear in `compose/`, it is
read by no `domum-media` command, timer, installer, backup or CI fragment
layering, and **nothing here has been pulled, started or executed.** Everything
below is either read from Aurral's source, docs and advisories (**verified**) or
labelled **assumption / unverified**.

Reviewed: `lklynet/aurral` at `v3.1.0` (released 2026-11-23), MIT, docs at
docs.aurral.org.

## 1. Findings

| # | Question | Answer | Basis |
|---|---|---|---|
| 1 | External services contacted | `data.aurral.org` (AurralBrainz metadata, default `METADATA_BASE_URL`), `musicbrainz.org`, `api.listenbrainz.org`, `coverartarchive.org`, Deezer (previews/fallbacks), `music.aurral.org` (hosted web player, CORS-allowed by default via `AURRAL_APP_ORIGIN`), aurral.org hub (friends, public playlists, share-link lookup), GitHub/aurral.org update check, `spotify.lidarr.audio` (Spotify import OAuth proxy) | **verified**: `backend/config/constants.ts`, docs `admin/environment`, `integrations/metadata`, `services/hubLink.ts`, `services/updates.ts` |
| 2 | Telemetry | No analytics/telemetry is documented. **Hourly update check** sends its version to aurral.org. Friends/hub/share features talk to aurral.org when used | update check **verified** (docs); absence of other telemetry is an **assumption** — not audited line by line |
| 3 | Aurral-hosted infrastructure | Yes: `data.aurral.org` (on maintainer infra + Cloudflare), `music.aurral.org`, the friends hub, and share links via a **Cloudflare quick tunnel** (`*.trycloudflare.com`) launched by a bundled `cloudflared` binary | **verified**: Dockerfile, `services/shareLinks/tunnel.ts` |
| 4 | Background downloads | "Flows" schedule playlists/mixes and the Inbox/acquisition pipeline downloads through configured sources. With no source reachable, nothing downloads | flows/download sources **verified** in docs; whether a flow triggers acquisition by default is **unverified** — the test in §5 checks no file appears |
| 5 | yt-dlp | **On by default** and bundled (`yt-dlp` 2026.10.26 at `/usr/local/bin/yt-dlp`). Disable: Settings › Downloads › yt-dlp › off. Here it is additionally **replaced by a read-only stub** so no setting can run it | **verified**: docs `integrations/ytdlp`, Dockerfile |
| 6 | Plugins | Off when installed, never auto-updated, unsigned, run *as Aurral* with admin API access. `AURRAL_SAFE_MODE=true` disables all | **verified**: docs `admin/plugins` |
| 7 | Social features | Friends/activity/blends/public playlists/share links all require aurral.org; unusable with egress blocked | **verified** (docs + hub code paths); behaviour when blocked is **unverified** until §5 runs |
| 8 | Outbound internet needed to start? | Not documented as required; update icon hides if aurral.org is unreachable | **assumption** — §5 proves or refutes it |
| 9 | Stored credentials | Local users/password hashes, sessions, generated admin API key (or `AURRAL_API_KEY`), integration credentials (slskd, qBittorrent, Usenet, OIDC secret, Spotify/Google tokens, YouTube cookies file) — all under `/config` | **verified** (docs); storage format/encryption **unverified** |
| 10 | Container permissions | Image entrypoint starts as **root**, `chown -R`s `/config`, then `setpriv` to PUID. **Started non-root it simply execs node** — so `user:` + `cap_drop: ALL` work | **verified**: `backend/docker-entrypoint.sh` |
| 11 | Advisories | GHSA-94q7-rfcf-xq9g **high**: spoofed `X-Forwarded-For` signs in as admin with local auto-login / proxy auth. GHSA-4fgw-3fq7-w4mp medium: XFF resets login rate limit. Both `<= 2.13.0`, fixed `3.0.0` | **verified**: GitHub advisories API |
| 12 | Residual XFF risk at 3.1.0 | With `TRUST_PROXY` unset Aurral still trusts XFF from **any private address**, i.e. any LAN client. Mitigated here: `TRUST_PROXY` = the proxy's address only, the proxy **overwrites** XFF, and local-network auto-login must stay **off** | **verified**: `backend/middleware/clientAddress.ts` |
| 13 | Project maturity | Repository created 2026-01-15; 3.0.0 → 3.1.0 in four days. Fast-moving; pin and re-review per upgrade | **verified** (GitHub API) |

Open source is not a security property. Nothing above is a code audit, and the
binaries in the image (yt-dlp, cloudflared, ffmpeg, node modules) were not
independently verified beyond the Dockerfile's pins and checksum.

## 2. Files

| File | Purpose |
|---|---|
| `compose.yml` | the minimal deployment: Aurral + a one-purpose nginx ingress |
| `nginx.conf` | the only ingress; overwrites `X-Forwarded-For` |
| `stubs/disabled` | mounted read-only over `yt-dlp` and `cloudflared` |
| `validate.sh` | the isolation tests (§5), read-only |
| `aurral.env.example` | the addresses, filled in by the operator into an untracked file |

## 3. Filesystem and permissions

Dedicated uid/gid **61001**, which owns nothing else. Only these four paths
plus two copied support files are mounted; never the parent trees.

| Host path | Container | Mode | Note |
|---|---|---|---|
| `/srv/data/experiments/aurral/config` | `/config` | 0700 61001 | database, settings, credentials |
| `/srv/media/experiments/aurral/library` | `/data/library` | 0755 61001 | ordinary audio files; separate from `/srv/media/music` |
| `/srv/media/experiments/aurral/staging` | `/data/staging` | 0750 61001 | set as yt-dlp/acquisition staging if ever enabled |
| `/srv/media/experiments/aurral/exports` | `/data/exports` | 0755 61001 | M3U exports for later Navidrome use |
| `/srv/data/experiments/aurral/nginx.conf` | proxy config | 0644 root | **copied** from the repo, never mounted from the checkout |
| `/srv/data/experiments/aurral/stubs/disabled` | stub binary | 0755 root | **copied**, same reason |

Root filesystem read-only, `/tmp` tmpfs. `read_only` compatibility is an
**assumption**: if Aurral fails to start, check the logs for the path it tries
to write and add a tmpfs for exactly that path, not a writable rootfs.

Backups: none. The cloud restic target is immich-only (`immich/library`,
`immich/backup-staging`, the recovery pack); `/srv/data/experiments` is a plain
directory, not a subvolume, so no per-service snapshot includes it; `/srv/media`
is never backed up. Confirm with
`sudo domum-media-backup backup-scope /srv/data/experiments/aurral` (expect
"no enabled target covers it").

## 4. Network isolation

No firewall rule is added or changed; isolation is structural.

* Aurral is attached **only** to `aurral-internal`: `internal: true` (no route
  off the host) and `gateway_mode_ipv4: isolated` (the bridge has no host
  address, so Traefik's `0.0.0.0:443`, sshd and anything else listening on the
  host are unreachable from the container). No IPv6.
* Its only peer is `aurral-proxy` (nginx, pinned by digest), which is also on
  `aurral-edge` solely so its port can be published — on **`$AURRAL_LAN_IP:3001`
  and `$AURRAL_TAILSCALE_IP:3001` only**: LAN and Tailscale, never `0.0.0.0`,
  never IPv6. Addresses live in an untracked env file (`aurral.env.example`).
* No Traefik route (`traefik.enable=false`, no Host rule) and no Cloudflare/DNS
  record. Not reachable from the internet: the router has no forward for 3001
  (**assumption** — verify on the router), and Tailscale is not a funnel.
* Other Docker services, Immich/Postgres and other LAN devices are unreachable
  because Aurral has no route and no DNS for them; `validate.sh` tests each.

Residual exposure, stated: the nginx container has normal egress (it serves a
static config and nothing else), and any LAN or tailnet device can reach the
login page.

## 5. Validation

Run `experiments/aurral/validate.sh` after starting. It checks:

1. both containers running; uid 61001, read-only rootfs, not privileged,
   `cap_drop: ALL`, `restart: no`; no docker socket; every mount under the
   experiment paths; `yt-dlp` and `cloudflared` return the stub;
2. from inside Aurral, **blocked**: internet by IP, Cloudflare, this host via
   LAN IP (443, 22), via Tailscale, the LAN router, both production
   Docker network gateways; **no DNS** for `immich_postgres`, `traefik`,
   `data.aurral.org`, `musicbrainz.org`, `www.youtube.com`;
3. ingress works on LAN and Tailscale, not on 127.0.0.1, not via Traefik, not
   on a wildcard; the proxy overwrites `X-Forwarded-For`;
4. production still has its 11 containers.

Then, by hand in the UI: create the admin; confirm **local-network auto-login
is OFF**; Settings › Downloads › yt-dlp **off**; Settings › Plugins shows safe
mode; no share-link tunnel; after 24 h `find /srv/media/experiments/aurral -type f`
lists only files you added.

Portability (Phase 5): copy a few of your own files into `library/`, let
Aurral index/tag them, then confirm on the host that they are still plain
files, in an `Artist/Album/` layout, with tags readable by any tool, and that
copying the directory elsewhere loses nothing. Tag writing is Aurral's
"automatic tagging" — **unverified** whether it rewrites originals; test on
copies only. Navidrome integration is later and separate.

## 6. Deployment (operator, after approval)

```
sudo install -d -o 61001 -g 61001 -m 0700 /srv/data/experiments/aurral/config
sudo install -d -o 61001 -g 61001 -m 0755 /srv/media/experiments/aurral/library /srv/media/experiments/aurral/exports
sudo install -d -o 61001 -g 61001 -m 0750 /srv/media/experiments/aurral/staging
sudo install -d -m 0755 /srv/data/experiments/aurral/stubs
sudo install -m 0644 experiments/aurral/nginx.conf /srv/data/experiments/aurral/nginx.conf
sudo install -m 0755 experiments/aurral/stubs/disabled /srv/data/experiments/aurral/stubs/disabled
sudo install -m 0600 experiments/aurral/aurral.env.example /srv/data/experiments/aurral/aurral.env
sudoedit /srv/data/experiments/aurral/aurral.env      # fill in the addresses
E=/srv/data/experiments/aurral/aurral.env
sudo docker compose --env-file $E -f experiments/aurral/compose.yml -p aurral-experiment pull
sudo docker compose --env-file $E -f experiments/aurral/compose.yml -p aurral-experiment up -d
sudo experiments/aurral/validate.sh $E
```

(`-p aurral-experiment` always — it keeps compose from ever addressing the
production project.)

## 7. Rollback / removal

```
sudo docker compose --env-file /srv/data/experiments/aurral/aurral.env \
  -f experiments/aurral/compose.yml -p aurral-experiment down
docker image rm ghcr.io/lklynet/aurral@sha256:17d1f8ff2aaa3907d846c38b47eebdd44b10fbe00b2c993373a6da940ac2504f \
               nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
# data, only once you have decided you do not want it:
sudo rm -rf /srv/data/experiments/aurral /srv/media/experiments/aurral
```

`down` removes only this project's two containers and two networks.
Production containers, networks, Traefik and timers are untouched by every
step.

## 8. Later, only with approval: controlled internet

1. **Metadata only.** Add an allow-list egress proxy (e.g. squid on
   `aurral-internal` + `aurral-edge`) permitting `data.aurral.org`,
   `musicbrainz.org`, `coverartarchive.org`, `api.listenbrainz.org`; point
   Aurral at it with `HTTPS_PROXY` (+ `NODE_USE_ENV_PROXY=1` — **unverified**
   that Aurral's fetch honours it; test). Still no YouTube, Deezer, aurral.org
   hub, Cloudflare tunnel or update check. Log every request for a week.
2. **Downloading (yt-dlp) stays off** unless separately approved. If it is ever
   enabled: staging only, manual approval per item, a daily cap (e.g. 10
   tracks), no cookies, no Google/Spotify accounts, no VPN or proxy to work
   around restrictions, and only content you have the right to download.
