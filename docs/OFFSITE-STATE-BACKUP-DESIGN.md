# Encrypted off-site application-state backup — design and activation plan

**Reviewed, not activated.** Nothing in this document has been switched on, no
backup target was changed, and no pack has left this host. Activating any of it
is an operator decision with its own approval.

**Status of the claim, stated first because it is the thing most easily
overstated:**

| claim | state |
|---|---|
| the capture mechanism works | **proven** for all five services against their real images |
| a capture restores | **proven**, digests and modes re-verified on restore |
| an application starts against a restored capture | **proven** for navidrome, calibre-web, plex |
| a capture can be encrypted and decrypted | **proven — with a DISPOSABLE key** |
| a pack survives a backup REPOSITORY round trip | **proven** — `tests/pack-repository-roundtrip-smoke.sh`, a real restic 0.18.0 scratch repository: pack → `restic backup` → the local pack and capture DESTROYED → `restic restore` → byte-identical sha256 → `verify-pack` → unpack → state restored with the Fernet key still 0600 and its bytes intact, and the database opening with `integrity_check ok`. A corrupted stored pack is refused before anything is decrypted |
| a pack can be decrypted with the REAL production age key | **NOT proven** |
| packs exist anywhere other than this SSD | **NO** |
| the five applications have off-site protection | **NO** |

**What the repository round trip does and does not add.** It removes one
genuine unknown: a repository stores, deduplicates and re-assembles bytes, and
an encrypted, content-addressed artefact is exactly the kind of thing where a
silent truncation would pass every local check until the day it was needed. That
is now tested end to end, with the local copies destroyed in between so the
restore can only be reading the repository. It adds **nothing** to the three
rows below it: the repository is a scratch directory under the test's own temp
directory, no production target or credential is read, and the identity is
generated for the test. A mechanism proven against a disposable repository is
still a mechanism.

The last three are the gap. Everything above them is mechanism; off-site
protection is a property of where the bytes are, and today they are on the one
Samsung 870 EVO that also holds every snapshot and every `.premigration` copy.

---

## 1. What is being protected, and why it is small

Measured 2026-11-02 across the five migrated services: **8.90 MiB of
irreplaceable state against 352.28 MiB of directories** — 2.5%. The rest is
regenerable (plex `Drivers/` 230.6 MiB, navidrome `cache/` 95.4 MiB, kavita
`backups/` 3.5 MB, logs, thumbnails).

Each capture carries the databases, the configuration, **and the credentials and
identities that make them usable** — the part a naive backup misses:

| service | the item a database-only backup would lose |
|---|---|
| calibre-web | `config/.key` — the Fernet key. Measured: without it the service **starts normally** and `settings.mail_password_e` fails with `InvalidToken` |
| kavita | `config/appsettings.json` — the JWT **TokenKey** (338 chars). Without it Kavita mints a new one and every session and API key silently stops working |
| jellyfin | `config/.aspnet/DataProtection-Keys` (0600) and `data/data/device.txt` — the server identity |
| plex | `Preferences.xml` — the server token. Measured: without it Plex **starts normally** as a *different* server (`MachineIdentifier` changes) |
| navidrome | the database alone; verified complete — its configuration comes from the compose environment, which the recovery pack already carries |

So the artefact is ~9 MiB per full set, and a pack of one service is a few
hundred KiB to a few MiB.

## 2. Scheduling — proposed, not installed

A capture is cheap and read-only; a pack is one `age` invocation. The natural
cadence is **weekly**, after the nightly backup window and well clear of it:

```
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=15m
Persistent=true
```

Reasoning, each point learned from something already recorded here:

- **weekly, not nightly.** This state changes slowly — calibre-web's `app.db`
  had not been written for weeks when measured. A nightly pack would produce
  near-identical artefacts and spend retention on them.
- **04:00 Sunday** is after the 02:30 backup (+15m) and the 03:30 check (+20m),
  and before the 04:30 snapshot prune. It does not contend with any of them.
- **`Persistent=true`** is safe here in a way it is not for `snapshot prune`:
  a missed run produces one extra capture, and the job deletes nothing except
  under the retention rule in §3, which never removes the newest.
- **It must not be in `systemd/auto-enable.timers`.** That file is the single
  source of truth for what installation may enable unattended, and a job that
  writes encrypted credentials is an operator decision. The timer would be
  installed and left disabled, exactly as the scrub timer was.

**Not written.** No unit file exists for this yet; writing one is the next
implementation step and installing it is the operator's.

## 3. Retention — newest N per service, and never the only one

```
keep the newest 4 packs per service        (~1 month at weekly cadence)
never delete the newest, whatever its age
never delete a pack whose .sha256 is missing or does not match
             -- an unverifiable pack is EVIDENCE, not garbage
delete nothing on a run that failed to produce a new pack
```

The last two are the important ones. This project has already corrected a
retention rule that deleted on the basis of filename and mtime; selection here
is by recorded checksum and by service name read from the manifest, never by
the filename, and a pack that cannot be verified is kept and reported rather
than removed.

At 4 packs × 5 services × ~1 MiB the whole set is single-digit MiB. **Retention
exists to bound the count, not to reclaim space.**

## 4. Verification — three separate claims, never collapsed

| command | proves | does NOT prove |
|---|---|---|
| `storage verify-pack <pack>` | the FILE matches its recorded sha256, and carries age's header | that it decrypts, or what is inside |
| `storage unpack-state <pack> <identity> <dir>` | it DECRYPTS with that key, and holds a manifest | that the capture restores |
| `storage restore-state <dir> <scratch>` | every item's digest and mode came back, and databases open | that the application runs |
| starting the service on the restored state | the application RUNS against it | that it SERVES its library |

**This host can only make the first claim about a production pack**, because it
holds only the public key. That is deliberate — a host compromise cannot
decrypt the packs it produced — and it is also why the second claim needs the
operator.

## 5. Secret handling

Already implemented and tested:

- the capture's whole directory chain is **0700**, the manifest **0600**, and
  shared parents (`<data>/backups`, shared with `images/` and `volumes/`) are
  **not re-moded** — asserted in both directions;
- the **plaintext tar is staged inside the 0700 destination, never `/tmp`**,
  and removed on every path out including the failure path;
- packs are **0600** in a **0700** directory;
- a sentinel test requires a captured secret to appear in **exactly** the
  stored and restored copies — never in stdout, stderr or the manifest;
- no workflow uploads artefacts, so CI is not a leak path;
- the capture **preserves** a file's mode rather than normalising it, so a
  restore cannot silently differ from the system it came from.

Open, and the operator's: production's `calibre-web/config/.key` is **0644**
where a fresh install writes **0600**. Every parent is world-traversable, so
the mode is effective — though the only non-system account owns the file.
`sudo chmod 600 /srv/data/calibre-web/config/.key` restores the application's
own default.

## 6. Where the packs should go — and why not into the Immich set

**Keep this a separate, small backup set.** The cloud restic target is
immich-only *by design* (`immich/library`, `immich/backup-staging`, the
recovery pack), and this project has already corrected a report that answered
coverage questions against the global include paths rather than that target's.
Quietly widening it would:

- put ~9 MiB of application state into the same retention policy as 207 GiB of
  photographs, whose cadence and keep-counts were chosen for photographs;
- make every future coverage question ambiguous about which set it is about;
- risk slowing or displacing the Immich paths, which keep priority.

Two candidate destinations, both additive:

1. **a third include root on the existing `cloud` target** — simplest, inherits
   working credentials and the proven repository, but shares retention with the
   photographs;
2. **a separate restic target** (`BACKUP_TARGETS` already supports one;
   `archive` is declared and disabled) — its own retention and its own
   cadence, at the cost of a second repository to keep healthy.

**Recommendation: (2), a separate target**, precisely because retention and
cadence should differ. 9 MiB weekly is negligible against a 207.5 GiB
repository either way, so the deciding factor is not cost but whether a
coverage question has a single unambiguous answer.

## 7. The activation plan — for operator approval

Nothing here is done. Each step needs root, which this account cannot obtain
(`sudo -n true` → *a password is required*, 0 NOPASSWD entries).

```
# 1. One capture + pack of one service, by hand, and look at it.
sudo domum-media storage capture-state navidrome
sudo domum-media storage pack-state <the capture dir it names>
sudo domum-media storage verify-pack <the pack it names>

# 2. Prove YOUR key opens it -- off this host, on a machine that has the
#    private key. This is the step that turns "the mechanism works" into
#    "my recovery key works", and nothing here can do it for you.
age -d -i <your identity> -o pack.tar <pack>   &&  tar -tf pack.tar | head

# 3. Only then decide the destination (§6) and enable it.
# 4. Only then install and enable the timer (§2).
```

**Step 2 is the one that matters**, and it is the one no amount of work on this
host can replace. Every round trip proven so far used a keypair generated for
the rehearsal, which demonstrates the packaging and restoration mechanism and
says nothing about whether the key in the operator's custody can open a real
pack. Until step 2 has been done, and until packs actually exist somewhere
other than this SSD, **the five applications do not have off-site
protection** — they have a tested way of producing artefacts that would
provide it.
