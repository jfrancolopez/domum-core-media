# Decisions

Owner for every decision: the server's owner. Record the answer and the date in
the row's **Selected** line; a worker never fills one in on the owner's behalf.

## Resolved

### D-1 — Repository visibility

- **Question:** the repository is public and names real infrastructure. Private, or public and scrubbed?
- **Selected (2026-11-10):** keep it public and scrub identifiers.
- **Consequence:** SEC-00, SEC-01 and SEC-02 remove the identifiers from tracked files and keep them out. Git history still contains them.
- **Sub-decision D-1a, default applied:** history is **not** rewritten. A rewrite invalidates every open branch and clone, and cannot recall copies already fetched. The exposed values are identifiers, not credentials, and none is reachable from the internet. Say so if you want the rewrite instead; it would be a new task.

### D-2 — LAN trust

- **Question:** should the home LAN reach this server directly, or only the tailnet?
- **Selected (2026-11-10):** the LAN has full access; Tailscale is for remote use only.
- **Consequence:** no host firewall task. The absence of one (finding F-04) is an accepted risk for the LAN. What remains is to make the services that listen worth trusting: SEC-04 (SSH keys only) and SEC-07 (close the unused RPC port).
- **Residual risk, stated:** any device on the home network, including guests and smart devices, can reach the login pages of every app and the SSH port. A guest or IoT VLAN on the router is the fix if that ever matters; it is outside this repository (see `../task-40-future-network-segmentation.md`).

### D-3 — Docker group membership

- **Question:** the operator account is in the `docker` group, which gives root without the sudo password. Keep it?
- **Options:**
  1. **Keep, and document it (recommended).** Development, the rehearsals and every agent session depend on it. `CLAUDE.md` §10 would be corrected to say the sudo prompt is a speed bump for this account, not a boundary, and that the real control is who can log in as it (SEC-04, SEC-05).
  2. **Remove it.** Docker then needs `sudo`. Restores the boundary and stops agents running containers at all, which breaks most of the test and rehearsal workflow.
  3. **Rootless Docker for development, rootful for production.** The strongest answer and a real project: two daemons, two image stores.
- **Also decide:** whether the `beszel` monitoring account needs the group. It does only for per-container statistics.
- **Selected (2026-11-10):** option 1 — keep and document the operator account's membership. Keep `beszel` in the group for per-container statistics for now; SEC-12 tracks a least-privilege path through the SEC-08 proxy before its membership is reconsidered.
- **Consequence:** the sudo prompt is not a security boundary for the operator account; Docker access is root-equivalent. The §5/§11 approval and stop rules still bind. The effective access boundary is who can log into the account. Beszel's current group access is retained pending SEC-12.

## Open

### D-4 — Which overlapping apps stay

- **Question:** two video servers (Plex, Jellyfin) and two book servers (Kavita, Calibre-Web) run against a media tier of 5.1 GB of music and almost no books. Which stay?
- **Options:**
  1. **Keep Jellyfin, Navidrome and one book server; retire Plex and the other (recommended, pending APP-01).** Jellyfin needs no vendor account and never leaves the tailnet, which matches how this server is used. Each retired app removes an image to patch, a database to capture, and a login page.
  2. **Keep Plex instead of Jellyfin**, if the family's TVs and phones already use Plex's apps.
  3. **Keep all four.** No work, same surface.
- **Evidence to gather first:** APP-01 measures which apps were actually opened.
- **Note:** retiring an app means stopping it and keeping its state and recovery point. Deleting data is a separate approval under `CLAUDE.md` §11.
- **Blocks:** APP-02 (Audiobookshelf also reads ebooks, which may settle the book question), APP-05, and makes SEC-11 unnecessary if Plex goes.
- **Selected:** _open_

### D-5 — Where phone alerts go

- **Question:** alerts are a weekly email plus mail on failure. Where should instant alerts go? The family phones are iPhones.
- **Options:**
  1. **Self-hosted ntfy, with the public ntfy service used only to wake the phone (recommended).** Message text stays on this server; the public service sees an opaque "check now" poke. iOS cannot deliver instant notifications from a self-hosted server any other way.
  2. **A hosted push service** (ntfy's public server with a long random topic, or Pushover). Nothing to run. Alert text leaves the house, so alerts must stay free of detail.
  3. **Uptime Kuma's own notifications only.** Already installed; covers "is it up", not backup or disk health.
  4. **Email only.** No change.
- **Blocks:** APP-03.
- **Selected:** _open_
