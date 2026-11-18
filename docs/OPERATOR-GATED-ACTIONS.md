# Operator-gated actions — the exact commands, in dependency order

Every item below is blocked for this session and runnable by the operator.
Nothing here has been executed. The point of the document is that each entry
names the **smallest** privileged command, what it changes, what it does **not**
change, how to verify it afterwards, and how to undo it.

Two things decide the order, and both were measured rather than assumed.

## 0. The deployment is DONE, and that is what makes 2-5 runnable

Deployed 2026-11-18. Re-measured against the installed binary immediately
afterwards -- every token of the selective-backup surface:

```
$ for t in state-capture state-capture-quiesced state-capture-consistent-via-helper \
           state-verify state-restore state-pack state-unpack verify-state-pack \
           state-pack-retention state-capture-all image-archive-retention; do
    /usr/local/bin/domum-media capabilities --has "$t"; echo "$t -> $?"
  done
  -> all eleven exit 0
```

Exit **0** is "supported". Before the deployment all eleven exited **2**,
"token unknown": the installed binary had never heard of them, so items 2-5
would have produced a usage error even with approval. That is why the ordering
was stated rather than assumed, and re-running the loop above is how a later
session confirms it rather than trusting this paragraph.

`capabilities --has` remains the right question because it distinguishes three
answers -- `0` supported, `1` implementation absent, `2` token unknown -- so an
older binary cannot be mistaken for a missing feature.

**Item 1 below is retained as the record of what was deployed**, not as work
outstanding.

---

## 1. Deploy the binaries  (DONE 2026-11-18 -- kept as the record)

See `docs/DEPLOYMENT-PLAN.md` §9 for the reviewed plan. Deployment **A** only:
three binaries and the weekly-report unit, via
`operator/domum-media-deploy-reporting-fixes.sh`.

**Executed 2026-11-18** with `--expect-revision=f647aa2e197c --confirm`.
`a63ad199bfa2 -> f647aa2e197c`; the script handed over to its own replacement
exactly once, as designed; four files installed and all five verified by
sha256; `systemd reloaded; no unit was enabled or started`; the behaviour check
reported `covered, 23267 of 23267, gap 0`. The weekly timer was already enabled
beforehand, so the deployment's first visible effect is the Sun 2026-11-22
08:10 EST firing. One measured side effect worth knowing: `daemon-reload`
re-rolls `RandomizedDelaySec=45m`, so the next elapse moved from 08:14:26 to
08:10:55 although the timer file is byte-identical.

- **changes**: `/usr/local/bin/domum-media`, `/usr/local/bin/domum-media-backup`,
  `/usr/local/lib/domum-media/domum-media-report`, two unit files, one
  `daemon-reload`.
- **does NOT change**: no container is created, recreated, restarted or
  stopped; no compose file; no backup configuration; no timer enabled.
- **verify**: `domum-media capabilities --has state-capture` -> `0`.
- **undo**: the plan's rollback section; preserve the four files first, because
  the script keeps no `.bak`.

**Deployment B (the security compose change set) is deliberately NOT recommended
with it** -- it means `compose up -d`, which recreates every container whose
configuration changed, and traefik and uptime-kuma still have newer images
staged under the same tag, so a configuration-only change would deploy two
application upgrades as a side effect unless each image is pinned.

---

## 2. Install the state-capture unit  (needs 1)

```
sudo install -m 0644 -o root -g root \
  /opt/domum-core-media/systemd/domum-media-state-capture.service \
  /opt/domum-core-media/systemd/domum-media-state-capture.timer \
  /etc/systemd/system/
sudo systemctl daemon-reload
```

- **changes**: two unit files exist and systemd knows about them.
- **does NOT change**: nothing runs. Installing is not enabling, and this
  repository keeps those separate deliberately.
- **verify**: `systemctl cat domum-media-state-capture.service` prints the unit;
  `systemctl is-enabled domum-media-state-capture.timer` prints `disabled`.
- **undo**: `sudo rm /etc/systemd/system/domum-media-state-capture.{service,timer}`
  then `daemon-reload`.

---

## 3. Take the first capture by hand  (needs 1; do this BEFORE enabling anything)

```
sudo domum-media storage capture-all-state --pack
sudo domum-media storage prune-state-packs            # dry run, deletes nothing
```

- **changes**: writes captures under `/srv/data/backups/state/` and encrypted
  packs under `/srv/data/backups/state-packs/`, both `0700`. **These artefacts
  contain credentials** -- calibre-web's Fernet key, kavita's JWT TokenKey,
  jellyfin's DataProtection keys, plex's server token -- which is why this
  session is forbidden from producing them.
- **does NOT change**: no service is stopped (the default mode never stops one),
  nothing is transmitted, no backup target or include path is touched.
- **verify**: the command prints `captured : 5` and `packed : 5`;
  `sudo domum-media storage verify-pack <pack>` returns 0 for each.
- **undo**: `sudo rm -rf /srv/data/backups/state /srv/data/backups/state-packs`.

A capture of jellyfin or kavita will record `CAPTURE_MODE=consistent` only if a
helper image with `sqlite3` is resolvable; otherwise it records `unproven` and
says why. Both outcomes are honest; the second is a warning, not a failure.

---

## 4. Enable the weekly timer  (needs 2 and a successful 3)

```
sudo systemctl enable --now domum-media-state-capture.timer
```

- **changes**: captures and packs are produced unattended every Sunday 04:00
  (+15m), and the unit's second step deletes superseded packs.
- **does NOT change**: nothing is transmitted. No backup target includes the
  pack directory, so enabling this does **not** create off-site protection.
- **verify**: `systemctl list-timers domum-media-state-capture.timer`.
- **undo**: `sudo systemctl disable --now domum-media-state-capture.timer`.

Do 3 by hand first. A timer whose first run is also its first test tells you it
failed a week later, in a mail.

---

## 5. Give the packs an off-site target  (needs 3; the step that creates real protection)

This is a backup-configuration change and the design deliberately does **not**
pick it for you: `docs/OFFSITE-STATE-BACKUP-DESIGN.md` §5 recommends a
**separate** target rather than widening the immich-only cloud scope, so that a
coverage question keeps one unambiguous answer.

- **changes**: `/opt/domum-core-media/config/domum-media.conf`, and the nightly
  or weekly run begins sending ~9 MiB off-site.
- **does NOT change**: the Immich paths. Any new coverage must be additive and
  must never displace or slow them.
- **verify**: `sudo domum-media-backup backup-scope /srv/data/backups/state-packs`
  returns 0 and names the target.
- **undo**: revert the config and re-run; restic retention will forget the
  snapshots on its own schedule. **Never prune to realise a saving sooner.**

**Until this step, no pack has left this host and the five services have no
off-site protection.** Everything before it produces artefacts that are *proven
reconstructible from nothing but themselves and a key* -- which is not the same
claim.

---

## 6. The credential that makes all of it worth anything

The age **private** key is held by the operator and deliberately not on this
host. 37 encrypted recovery packs and every state pack are equally useless
without it, and this host cannot decrypt what it writes -- `pack-state` says so
in its own output.

- **the action**: keep a copy somewhere that survives this machine, and prove it
  opens a pack **elsewhere**.
- **why this session cannot do it**: making or transmitting a credential copy is
  prohibited, and the key is not here to copy.
- **verify**: on another machine, `age -d -i <identity> <pack> | tar -t | head`.

This is the single highest remaining risk in the whole recovery story.

---

## 7. Privilege-only items (no approval question, just root or a group)

| item | command | blocked by |
|---|---|---|
| reconcile the 23,267 originals against a snapshot | `sudo domum-media-backup verify-snapshot-coverage cloud` | root; downloads no file content |
| a real scrub of `/srv/data` | `sudo domum-media storage scrub start --limit 150M` | root; ~25 min throttled |
| the volume dump/restore rehearsal | `sudo bash operator/rehearsals/volume-resolver-real-objects.sh` plus a tar step | root -- `/var/lib/docker` is `drwx--x--- root:root`, so `tar -C` on a volume mountpoint returns status 2 |
| a disposable btrfs for corruption injection | needs a loop device | membership of group `disk`; `/dev/loop-control` is `crw-rw---- root:disk` and this account's membership is 0 |
| `chmod 600` calibre-web's Fernet key | `chmod 600 /srv/data/calibre-web/config/.key` | **not** privilege -- the file is owner-writable by this account. Blocked only by the instruction not to chmod production files |

Measured: `sudo -n true` answers `a password is required` with **zero** NOPASSWD
entries, so none of the first four can be attempted here.

### How that is demonstrated rather than asserted

The three CLI entry points cannot be invoked from this session at all -- the
harness refuses them, because with privilege they would start a scrub, stop a
production service, and write credential-bearing artefacts. So the claim is
assembled from observations that could each be made:

| observation | result |
|---|---|
| `id -u` | **1000**, and `need_root` requires 0 |
| `need_root` driven in isolation | `REFUSED: Run as root (use sudo).` |
| `need_root` in `storage_scrub_start` | statement **2** |
| `need_root` in `storage_volume_pre_upgrade_point` | statement **2** |
| the `capture-all-state` dispatcher arm | contains `need_root` |
| `sudo -n true` | `a password is required`, **0** NOPASSWD |

The guard refuses for this uid, the guard runs first, and uid 0 is
unobtainable -- so each command refuses before acting.

`service_state_capture` has no `need_root` of its own: the guard is in the
dispatcher arm, and separately at the top of the `--quiesce` path, where it was
added after a rehearsal found that an unprivileged operator could otherwise
take real downtime for a capture that could never succeed.
