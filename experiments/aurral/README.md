# Aurral — isolated experiment (side quest)

This is not part of Domum-Core-Media. It does not appear in `compose/`, it is
read by no `domum-media` command, timer, installer, backup or CI fragment
layering, and **nothing here has been pulled, started or executed.** Everything
below is either read from Aurral's source, docs and advisories (**verified**),
measured read-only on this host (**measured**), or labelled
**assumption / unverified**.

Reviewed: `lklynet/aurral` at `v3.1.0` (released 2026-11-23), MIT, docs at
docs.aurral.org.

**Aurral has outbound internet access in this design, and that is the operator's
decision of 2026-11-23.** What that buys is a real test of the product;
what it costs is stated plainly in section 4: network isolation protects the
rest of this host and the LAN, and it does not and cannot stop Aurral sending
whatever it can read to wherever it likes. The filesystem restriction in
section 3 and the egress log in section 4 are what bound that.

## 1. Findings

| # | Question | Answer | Basis |
|---|---|---|---|
| 1 | External services contacted | `data.aurral.org` (AurralBrainz metadata, default `METADATA_BASE_URL`), `musicbrainz.org`, `api.listenbrainz.org`, `coverartarchive.org`, Deezer (previews/fallbacks), `music.aurral.org` (hosted web player, CORS-allowed by default via `AURRAL_APP_ORIGIN`), aurral.org hub (friends, public playlists, share-link lookup), GitHub/aurral.org update check, `spotify.lidarr.audio` (Spotify import OAuth proxy) | **verified**: `backend/config/constants.ts`, docs `admin/environment`, `integrations/metadata`, `services/hubLink.ts`, `services/updates.ts` |
| 2 | Telemetry | No analytics/telemetry is documented. **Hourly update check** sends its version to aurral.org. Friends/hub/share features talk to aurral.org when used | update check **verified** (docs); absence of other telemetry is an **assumption** — not audited line by line. With egress open this is no longer theoretical, which is why section 4 logs every outbound connection |
| 3 | Aurral-hosted infrastructure | Yes: `data.aurral.org` (on maintainer infra + Cloudflare), `music.aurral.org`, the friends hub, and share links via a **Cloudflare quick tunnel** (`*.trycloudflare.com`) launched by a bundled `cloudflared` binary | **verified**: Dockerfile, `services/shareLinks/tunnel.ts` |
| 4 | Background downloads | "Flows" schedule playlists/mixes and the Inbox/acquisition pipeline downloads through configured sources | flows/download sources **verified** in docs; whether a flow triggers acquisition by default is **unverified**. With egress open it CAN now download, so the operating limits in section 8 are the control, not the network |
| 5 | yt-dlp | **On by default** and bundled (`yt-dlp` 2026.10.26 at `/usr/local/bin/yt-dlp`). **Left in place in this design** so it can be tested, under the limits in section 8: no account cookies, no unattended bulk downloading, conservative concurrency | **verified**: docs `integrations/ytdlp`, Dockerfile |
| 6 | Plugins | Off when installed, never auto-updated, unsigned, run *as Aurral* with admin API access. `AURRAL_SAFE_MODE=true` disables all | **verified**: docs `admin/plugins` |
| 7 | Social features | Friends/activity/blends/public playlists/share links all require aurral.org. They will now work; **share links are still refused**, because a Cloudflare quick tunnel is a public route to this UI — `cloudflared` stays replaced by a read-only stub | **verified** (docs + hub code paths) |
| 8 | Stored credentials | Local users/password hashes, sessions, generated admin API key (or `AURRAL_API_KEY`), integration credentials (slskd, qBittorrent, Usenet, OIDC secret, Spotify/Google tokens, YouTube cookies file) — all under `/config` | **verified** (docs); storage format/encryption **unverified** |
| 9 | Container permissions | Image entrypoint starts as **root**, `chown -R`s `/config`, then `setpriv` to PUID. **Started non-root it simply execs node** — so `user:` + `cap_drop: ALL` work | **verified**: `backend/docker-entrypoint.sh` |
| 10 | Advisories | GHSA-94q7-rfcf-xq9g **high**: spoofed `X-Forwarded-For` signs in as admin with local auto-login / proxy auth. GHSA-4fgw-3fq7-w4mp medium: XFF resets login rate limit. Both `<= 2.13.0`, fixed `3.0.0` | **verified**: GitHub advisories API |
| 11 | Residual XFF risk at 3.1.0 | With `TRUST_PROXY` unset Aurral still trusts XFF from **any private address**, i.e. any LAN client. Mitigated here: `TRUST_PROXY` = the proxy's address only, the proxy **overwrites** XFF, Aurral's own port is never published, and local-network auto-login must stay **off** | **verified**: `backend/middleware/clientAddress.ts` |
| 12 | Project maturity | Repository created 2026-01-15; 3.0.0 → 3.1.0 in four days. Fast-moving; pin and re-review per upgrade | **verified** (GitHub API) |

Open source is not a security property. Nothing above is a code audit, and the
binaries in the image (yt-dlp, cloudflared, ffmpeg, node modules) were not
independently verified beyond the Dockerfile's pins and checksum.

## 2. Files

| File | Purpose |
|---|---|
| `compose.yml` | the minimal deployment: Aurral + a one-purpose nginx ingress |
| `firewall.sh` | the egress policy — `apply` / `remove` / `show`. This is where the isolation lives |
| `nginx.conf` | the only ingress; overwrites `X-Forwarded-For` |
| `stubs/disabled` | mounted read-only over `cloudflared` |
| `validate.sh` | the connectivity and isolation tests (section 5), read-only |
| `aurral.env.example` | the addresses and blocked ranges, filled in by the operator into an untracked file |

## 3. Filesystem and permissions

Dedicated uid/gid **61001**, which owns nothing else — **measured**: no passwd
or group entry uses it today. Only these paths are mounted; never the parent
trees, never a production directory, never the Docker socket.

| Host path | Container | Mode | Note |
|---|---|---|---|
| `/srv/data/experiments/aurral/config` | `/config` | 0700 61001 | database, settings, credentials |
| `/srv/data/experiments/aurral/config/home` | `$HOME` | 0700 61001 | yt-dlp's cache lives here; created explicitly, because a missing `$HOME` is how a download fails for a reason that reads as a network problem |
| `/srv/media/experiments/aurral/library` | `/data/library` | 0755 61001 | ordinary audio files; separate from `/srv/media/music` |
| `/srv/media/experiments/aurral/staging` | `/data/staging` | 0750 61001 | yt-dlp / acquisition staging |
| `/srv/media/experiments/aurral/exports` | `/data/exports` | 0755 61001 | M3U exports for later Navidrome use |
| `/srv/data/experiments/aurral/nginx.conf` | proxy config | 0644 root | **copied** from the repo, never mounted from the checkout |
| `/srv/data/experiments/aurral/stubs/disabled` | stub binary | 0755 root | **copied**, same reason |

The last two are copied rather than bind-mounted from `/opt/domum-core-media`
on purpose. A file bind-mounted from the checkout is deployed by a
`git` fast-forward instead of by a container recreate — that is exactly what
took the seven HTTPS routes down on 2026-11-23, and the rule it produced
applies to an experiment as much as to production.

Library files stay **plain files you own**: 0755 directories under
`/srv/media/experiments/aurral`, readable and copyable by this account with no
container involved, which `validate.sh` section 6 checks rather than asserts.
Migrating them to Navidrome later is a `cp`.

Root filesystem read-only, `/tmp` a 512 MiB tmpfs (raised from 256 MiB because
yt-dlp and ffmpeg now run). `read_only` compatibility is an **assumption**: if
Aurral fails to start, read the log for the path it tries to write and add a
tmpfs for exactly that path, not a writable rootfs.

Backups: none. The cloud restic target is immich-only (`immich/library`,
`immich/backup-staging`, the recovery pack); `/srv/data/experiments` is a plain
directory, not a subvolume, so no per-service snapshot includes it; `/srv/media`
is never backed up. Confirm with
`sudo domum-media-backup backup-scope /srv/data/experiments/aurral` (expect
"no enabled target covers it").

## 4. Network isolation

### What is created

One Docker network, `aurral-experiment_aurral-net`: an ordinary NAT bridge,
IPv4 only, on an unused private /24 from the env file, with its bridge
interface **named `aurral0`** rather than Docker's default `br-<network id>`.
That name is load-bearing: every firewall rule matches on it, and a generated
name would change when the network is recreated and silently orphan the
policy. Both containers sit on it; Aurral's own port is not published, so the
nginx proxy is the only way in.

**Measured 2026-11-23** — the subnet must avoid all of these: `docker0`,
`domum-proxy` and `domum-internal` each hold a /16 inside 172.16/12, the LAN
is a /24 inside 10/8, and the tailnet is inside 100.64/10. Docker 29.10.0 is
installed, so everything below is supported.

### What enforces the isolation

**Not the network.** A NAT bridge reaches the LAN, the tailnet, the other
Docker bridges and every host port bound on `0.0.0.0` exactly as readily as it
reaches the internet — and on this host, **measured**, `0.0.0.0` carries
sshd (22), Traefik (80, 443) and rpcbind (111). "Internet yes, private no" is
not something a bridge can express, so it is expressed in the firewall, by
`firewall.sh`, and nothing else in this design claims to do it.

Two chains, four jump rules, every one scoped to `aurral0`:

| chain | hooked from | what it does |
|---|---|---|
| `AURRAL-EGRESS` | `DOCKER-USER` position 1 | container → **anything but this host** |
| `AURRAL-HOST` | `INPUT` position 1 | container → **this host**, on any of its addresses |
| — | ip6tables `DOCKER-USER`/`FORWARD` + `INPUT` | one DROP each, belt and braces |

`DOCKER-USER` is Docker's own documented hook: it is consulted before Docker's
FORWARD rules and Docker never flushes it. **The second chain is the part that
is easy to miss and the reason this is not one rule**: a packet from a
container to a local address of this host arrives on `INPUT`, which
`DOCKER-USER` never sees. A policy without it looks complete and leaves sshd
reachable.

`AURRAL-EGRESS`, in order:

1. `-o aurral0 -j RETURN` — traffic that stays on this bridge, i.e. the proxy
   talking to Aurral. First, because the bridge subnet is itself private and a
   later range drop would otherwise cut the UI off from the application.
2. `--ctstate ESTABLISHED,RELATED -j RETURN` — replies to connections somebody
   else opened. Without it the proxy's answers to a LAN client are dropped by
   the LAN range below and the UI is unreachable from the one place it is meant
   to work. A connection the container itself opens has no conntrack entry yet,
   so it still falls through to the drops — which is precisely "may not
   **initiate**".
3. `-s <the proxy> -j DROP` — the proxy initiates nothing off this bridge. It
   is an nginx serving one static config, and it resolves its single upstream
   through Docker's embedded resolver on the container's own loopback, which
   never crosses the bridge. So the external surface is one container rather
   than two. Replies to inbound requests were already returned by rule 2,
   which is why this cannot break the UI — and `validate.sh` proves it with a
   positive control before it believes the negative result.
4. `-o tailscale0`, `-o docker0`, `-o br-+` → DROP. By interface, so a tailnet
   subnet router advertising ordinary public routes is blocked too; an address
   list cannot catch that.
5. `-d <range> -j DROP` for every range in `AURRAL_BLOCK_CIDRS` (the operator
   lists 10/8, 172.16/12, 192.168/16 and 100.64/10 as full CIDRs) plus
   loopback, link-local — which contains the cloud metadata address —
   multicast and the reserved ranges, which are hardcoded because they are
   never a legitimate destination.
6. `--ctstate NEW -j LOG --log-prefix 'aurral-egress '`, rate-limited to
   600/min — whatever reached here is an external destination, so this is the
   answer to "which services does Aurral actually contact", read from the
   kernel log rather than guessed. The rate limit is stated because a dropped
   log line is a missed observation.
7. `RETURN` — Docker's own rules then NAT it to the internet.

### What it is inserted into — measured, 2026-11-23

Read as root before approving, which is what turns "no production rule is
disturbed" from an argument into an observation:

```
iptables -S DOCKER-USER     ->  -N DOCKER-USER          (the chain, and NO rules)
iptables -S INPUT           ->  -P INPUT ACCEPT
                                -A INPUT -j ts-input
```

So `-I DOCKER-USER 1` displaces nothing: the chain is empty, and our rule is
the only one in it. `-I INPUT 1` puts the host-isolation jump ahead of
Tailscale's `ts-input`, giving:

| # | INPUT rule | effect |
|---|---|---|
| 1 | `-i aurral0 -j AURRAL-HOST` | only packets off this experiment's bridge |
| 2 | `-j ts-input` | everything else, exactly as before |

**It is compatible with `ts-input`, and strictly more restrictive.** Nothing
Tailscale needs arrives on `aurral0`: its own traffic is `-i tailscale0`, its
WireGuard listener is reached over `enp1s0`, and its self-address rule is on
`lo`. `ts-input`'s anti-spoofing drop (`! -i tailscale0 -s <CGNAT> -j DROP`)
would have caught a packet forged with a tailnet source on `aurral0`; this
policy drops **every** new packet from that interface to the host, so that
protection is subsumed rather than bypassed. For every other interface the
chain is unchanged and `ts-input` is still the first thing consulted.

An **empty block list refuses to apply**: a policy that opened the LAN while
reporting success is the failure this project exists to avoid.

And a **count is not a completeness check.** The first version of this script
required four or more entries and said so in a message naming four specific
ranges — which four `/32` entries would have satisfied while leaving the LAN,
the tailnet and the other Docker networks reachable. `assert_block_coverage`
now proves each required range is actually COVERED by some listed CIDR, with
a longer prefix (a mere subset) and a wrong network base both refused. The
required ranges are built with integer arithmetic rather than written as
dotted quads, because this repository's identifier audit rejects an RFC1918
or CGNAT literal in a tracked file.

### The result

| Connection | Result | Enforced by |
|---|---|---|
| Aurral → internet HTTPS | allowed | Docker NAT; rule 7 |
| Aurral → DNS | allowed, to the two approved **public** resolvers only | `dns:` in compose |
| Aurral → YouTube, metadata APIs | allowed | same as internet |
| Aurral → other Docker containers / networks | blocked | rules 4, 5 |
| Aurral → host management (22, 80, 443, 111) | blocked | `AURRAL-HOST` |
| Aurral → private LAN | blocked | rule 5 |
| Aurral → tailnet devices | blocked | rules 4, 5 |
| Aurral → cloud metadata / link-local | blocked | rule 5 |
| Aurral → anything over IPv6 | impossible: no global IPv6 address | `enable_ipv6: false`, plus the ip6tables DROPs |
| LAN → Aurral UI | allowed, on this host's LAN address only | published port |
| Tailscale → Aurral UI | allowed, on this host's Tailscale address only | published port |
| Internet → Aurral UI | blocked | no 0.0.0.0 bind, no Traefik route, no DNS record, no router forward |
| Aurral ↔ its own proxy | allowed | rule 1 |
| aurral-proxy → anything off the bridge | blocked | rule 3 |

**The resolvers are `1.1.1.1` and `1.0.0.1`** — the approved primary and
fallback, and compose's defaults, so the operator's decision is recorded in
the repository rather than only in an untracked file. They are the one
address pair here that may be named in a tracked file, because a public
resolver is not infrastructure information about this host.

**A resolver must be public, and that is a correctness requirement rather
than a preference.** This host's own resolver is Tailscale MagicDNS
(**measured** from `/etc/resolv.conf`), which the experiment must not reach;
and a resolver reached over the bridge would be blocked by `AURRAL-HOST`. A
public resolver is reached over the egress path that is open anyway, so DNS
works whichever network namespace Docker's embedded resolver forwards from —
which removes the one thing about this design that would otherwise be an
assumption. `validate.sh` proves it rather than trusting it.

### Production firewall policy

Untouched, and that is checkable rather than promised: every rule is an
insertion scoped to `aurral0`, an interface that exists only for this
experiment, so no rule can match production traffic. Nothing existing is read,
reordered, flushed or replaced. **Measured**: this host runs no ufw, firewalld
or nftables service, and Docker's firewall backend is iptables — so
`firewall.sh` uses the same tool Docker itself uses and adds no new framework.
`firewall.sh remove` deletes the four jumps and the two chains and leaves
nothing behind.

### Residual exposure, stated

* **Aurral can send data out.** It has HTTPS egress by design, so the hourly
  update check, the metadata lookups and anything else it chooses to send will
  leave this host. The network cannot prevent that; what bounds it is the
  filesystem scope in section 3 — no production directory, no database, no
  credential, no Docker socket — and the egress log, which makes the
  destinations observable after the fact rather than assumed.
* The nginx container shares the network, so it would have had the same egress;
  rule 3 drops it, and that is asserted rather than assumed.
* Any LAN or tailnet device can reach the login page.
* The rules live only in the running kernel ruleset and do not survive a
  reboot. Neither does the container: `restart: "no"` is load-bearing here, not
  a preference. **Never change it to `unless-stopped` without first making the
  policy survive a boot** — that combination would bring Aurral back with no
  isolation at all.

## 5. Validation

Run `sudo experiments/aurral/validate.sh <env-file>` after applying the policy
and starting the containers. It asserts both directions, deliberately: a suite
that only proved things were blocked would pass against an experiment that
cannot reach anything, and one that only proved the internet works would pass
against no isolation at all.

1. **the policy is installed** — asked first, because every "blocked" result
   below is meaningless otherwise; a container that is merely down looks
   blocked too;
2. both containers running; uid 61001, read-only rootfs, not privileged,
   `cap_drop: ALL`, `restart: no`, the memory/CPU/pids limits, the image pinned
   by digest; no docker socket; every mount under the experiment paths;
   `cloudflared` returns the stub;
3. **the approved connectivity works** — DNS resolves, the configured resolver
   answers on 53, and `data.aurral.org`, `musicbrainz.org`,
   `coverartarchive.org`, `api.listenbrainz.org` and `www.youtube.com` each
   complete a full DNS + TCP + TLS + HTTP exchange (a TCP handshake alone
   would pass against a captive portal); `yt-dlp` reports its version;
4. **everything private is blocked** — this host on 22, 443 and 111 via its
   LAN address, via its Tailscale address and via the bridge gateway; the LAN
   router; the cloud metadata address; **every production container by its real
   address**, enumerated from `docker network inspect` rather than tested by
   gateway alone; optionally a real LAN device and a real tailnet device if the
   env file names them; the production service names must not resolve; and no
   global IPv6 address exists;
5. ingress works on LAN and Tailscale, not on 127.0.0.1, not via Traefik, not
   on a wildcard; Aurral publishes no port of its own; the proxy overwrites
   `X-Forwarded-For` and `TRUST_PROXY` names only the proxy; **and the proxy
   itself cannot initiate egress**, proven after a positive control with the
   same tool, so an absent probe binary cannot make that pass vacuously;
6. **the music stays yours** — a library file is readable on the host with no
   container involved;
7. production still has its 11 containers and none is unhealthy.

It then prints the two commands that answer "what did Aurral contact" and "did
it try to reach this host", from the kernel log.

Then, by hand in the UI: create the admin; confirm **local-network auto-login
is OFF**; Settings › Plugins shows safe mode; set the download limits from
section 8; confirm no share-link tunnel appears (it cannot — `cloudflared` is
a stub — but the UI should say so rather than silently failing).

Portability (later phase): copy a few of your own files into `library/`, let
Aurral index/tag them, then confirm on the host that they are still plain
files, in an `Artist/Album/` layout, with tags readable by any tool, and that
copying the directory elsewhere loses nothing. Tag writing is Aurral's
"automatic tagging" — **unverified** whether it rewrites originals; test on
copies only. Navidrome integration is later and separate.

## 6. Deployment (operator, after approval)

Order matters: **the policy goes in before anything can send a packet.** The
rules match an interface name, which iptables accepts whether or not the
interface exists yet, so this is safe and is the only ordering that has no
window.

**Run every step from the DEVELOPMENT checkout.** `firewall.sh` exists only
from `49b380a` onward and the production checkout does not carry it, so from
`/opt/domum-core-media` step 4 fails while step 5 would still start the
containers — with no isolation at all. Step 0 makes that impossible to do by
accident, and every path below is absolute for the same reason.

```
# 0. the right checkout, and the revision that has the policy
R=/home/jfranco/src/domum-core-media-dev
cd "$R"
git -C "$R" rev-parse --short HEAD                      # expect 49b380a or later
test -x "$R/experiments/aurral/firewall.sh" \
  || { echo "WRONG CHECKOUT: no firewall.sh here -- do NOT continue"; }

# 1. directories
sudo install -d -o 61001 -g 61001 -m 0700 /srv/data/experiments/aurral/config \
                                          /srv/data/experiments/aurral/config/home
sudo install -d -o 61001 -g 61001 -m 0755 /srv/media/experiments/aurral/library \
                                          /srv/media/experiments/aurral/exports
sudo install -d -o 61001 -g 61001 -m 0750 /srv/media/experiments/aurral/staging
sudo install -d -m 0755 /srv/data/experiments/aurral/stubs

# 2. the two files that are COPIED, never mounted from the checkout
sudo install -m 0644 "$R/experiments/aurral/nginx.conf" /srv/data/experiments/aurral/nginx.conf
sudo install -m 0755 "$R/experiments/aurral/stubs/disabled" /srv/data/experiments/aurral/stubs/disabled

# 3. the env file
sudo install -m 0600 "$R/experiments/aurral/aurral.env.example" /srv/data/experiments/aurral/aurral.env
sudoedit /srv/data/experiments/aurral/aurral.env        # fill in every value
E=/srv/data/experiments/aurral/aurral.env

# 4. THE FIREWALL POLICY, BEFORE THE CONTAINERS
sudo "$R/experiments/aurral/firewall.sh" apply "$E"
sudo "$R/experiments/aurral/firewall.sh" show  "$E"

# 5. the containers
sudo docker compose --env-file "$E" -f "$R/experiments/aurral/compose.yml" -p aurral-experiment pull
sudo docker compose --env-file "$E" -f "$R/experiments/aurral/compose.yml" -p aurral-experiment up -d

# 6. prove it
sudo "$R/experiments/aurral/validate.sh" "$E"
```

(`-p aurral-experiment` always — it keeps compose from ever addressing the
production project.)

## 7. Rollback / removal

```
R=/home/jfranco/src/domum-core-media-dev
E=/srv/data/experiments/aurral/aurral.env
sudo docker compose --env-file "$E" -f "$R/experiments/aurral/compose.yml" -p aurral-experiment down
sudo "$R/experiments/aurral/firewall.sh" remove "$E"
sudo "$R/experiments/aurral/firewall.sh" show   "$E"   # must report NOT installed
docker image rm ghcr.io/lklynet/aurral@sha256:17d1f8ff2aaa3907d846c38b47eebdd44b10fbe00b2c993373a6da940ac2504f \
               nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de
# data, only once you have decided you do not want it:
sudo rm -rf /srv/data/experiments/aurral /srv/media/experiments/aurral
```

`down` removes only this project's two containers and its one network.
`firewall.sh remove` deletes only the four jumps and two chains it created.
Production containers, networks, Traefik, timers and firewall rules are
untouched by every step.

## 8. Operating limits for yt-dlp and downloads

These are the limits the operator approved, and they are **operational
settings, not enforced by the network** — the network now allows the traffic,
so this is where the restraint lives. Set them in the UI before the first
download.

* **No account cookies.** Do not configure a YouTube cookies file and do not
  sign in to Google, Spotify or any other account. A cookies file turns a
  rate-limit problem into an account problem.
* **No unattended bulk downloading.** Do not enable Flows or any scheduled
  acquisition. Download items one at a time, by hand, and keep the destination
  `staging`.
* **Conservative concurrency** — one download at a time. The specific setting
  names are in Settings › Downloads; this document deliberately does not quote
  an environment variable for it, because the variable names were not verified
  and a config key that does nothing reads as control that does not exist.
* **Stop on a rate limit or an authentication challenge.** Do not retry around
  it, do not wait it out with a script, and report it instead.
* **No proxy or VPN to evade a restriction**, and only content you have the
  right to download.
* Review `journalctl -k | grep aurral-egress` after the first session: that is
  the list of everything Aurral actually contacted, and it is the point of
  having the log.

## 9. Still refused, and why

* **Share links.** They open a Cloudflare quick tunnel, which is a public
  route to this UI, and requirement 4 is that the UI is not publicly
  reachable. `cloudflared` stays a read-only stub.
* **A Traefik route or a DNS record.** Same reason.
* **A router port forward.** Same reason — and this one is the operator's to
  confirm on the router, which no check here can do.
* **Anything in `compose/`, any timer, any `domum-media` subcommand.** This
  experiment stays reachable only by a hand-typed compose command.
