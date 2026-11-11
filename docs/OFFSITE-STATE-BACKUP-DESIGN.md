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

**WRITTEN 2026-11-11, not installed and not enabled.**
`systemd/domum-media-state-capture.{service,timer}` exist, and
`systemd/auto-enable.timers` deliberately does not list the timer -- which
`tests/timer-auto-enable-safety-smoke.sh` now asserts for it by name, and the
assertion was proved to bite by adding the timer to that file and watching the
suite fail. `systemd-analyze` accepts both, and the schedule resolves to
`Sun 2026-11-15 04:00:00 EST`.

The unit has **two** `ExecStart` lines and **the order is §3's fourth retention
rule**, not a detail:

```
ExecStart=/usr/local/bin/domum-media storage capture-all-state --pack
ExecStart=/usr/local/bin/domum-media storage prune-state-packs --confirm
```

Neither carries a `-` prefix, so a failed capture or pack fails the unit and
systemd never reaches the prune -- which is exactly "delete nothing on a run
that failed to produce a new pack". A `-` on the first would break it silently,
so the test asserts both the ordering and the absence of the prefix, and both
assertions were proved to bite. `--confirm` is supplied **here** rather than
being the command's default, so the only thing that ever deletes a pack is a
unit that says so in its own text.

`storage capture-all-state [--pack]` is the entry point this needed and did not
have. Its service set is **derived** -- `protected-tier` in
`service_state_models` *and* a non-empty `service_essential_state` -- which is
why immich is absent: it is protected-tier and declares nothing, because its
library is the restic backup's job rather than a 9 MiB state capture. Deriving
it means a declaration change is followed automatically; three of these five
gained a declared credential or identity in a single week, and a hardcoded list
would have had to be edited each time or quietly fallen behind.

It **continues past a failing service and fails at the end**, so one service's
problem does not cost the other four their capture -- the shape of the retention
failure that once aborted before `heartbeat` and made a successful backup report
as stale. A failed pack leaves its capture intact and says so. An empty service
set is refused rather than reported as a clean run.

**Installing and enabling remain the operator's**, and enabling it means
encrypted packs holding a Fernet key, a JWT signing key and a server token will
be written unattended on a schedule.

## 3. Retention — newest N per service, and never the only one

```
keep the newest 4 packs per service        (~1 month at weekly cadence)
never delete the newest, whatever its age
never delete a pack whose .sha256 is missing or does not match
             -- an unverifiable pack is EVIDENCE, not garbage
delete nothing on a run that failed to produce a new pack
```

The last two are the important ones. This project has already corrected a
retention rule that deleted on the basis of filename and mtime, and a pack that
cannot be verified is kept and reported rather than removed.

**IMPLEMENTED 2026-11-11 as `storage prune-state-packs [--confirm] [dir]`, and
one sentence of this section had to be corrected first: it said selection is
"by service name read from the manifest, never by the filename".** That is
unimplementable here. The manifest is INSIDE the encrypted pack, and this host
holds only the public key -- `pack-state` says so in its own output -- so
nothing on this machine can read it. The only unencrypted things beside a pack
were the artefact and its `.sha256`, which left the filename as the sole source
of the service name: exactly what the rule exists to forbid.

So `pack-state` now writes an **unencrypted sidecar**, `<pack>.meta` at 0600,
recording `SERVICE`, `CAPTURED_AT`, `CAPTURE_MODE`, `MANIFEST_SHA` and
`PACK_SHA`. That is this project's own remedy -- *if something needs a fact,
give it a way to state the fact* -- and it holds nothing secret: the service
name and timestamp are already visible in the filename, the mode is a property
of the capture rather than data from it, and the other two are digests. A test
drives a real `age` pack and asserts the sidecar contains no item path and no
digest from the manifest body.

Retention then reads the sidecar, so ranking is by recorded `CAPTURED_AT` and
never by mtime or the filename. **The test inverts mtime order against
`CAPTURED_AT`** -- the newest capture is given the oldest mtime -- so a selector
that read mtime would return the opposite answer, and the mutation that ranks by
`stat -c %Y` must supersede the newest pack.

Four verdicts, and only one of them deletes:

| verdict | meaning |
|---|---|
| `retain` | among the newest `STATE_PACK_KEEP` (default 4) for its service |
| `superseded` | older than that -- the only deletable class |
| `unverifiable` | `.sha256` absent or not matching. **KEPT**: an unverifiable pack is evidence |
| `unknown` | no readable sidecar, so its service cannot be established. **KEPT** |

It is a **DRY RUN by default**; `--confirm` is required before anything is
removed, as `cleanup images` requires it, and the command is on no timer of its
own. An absent or empty directory is reported as explicitly **not a finding** --
that is what an unscheduled host looks like. The fourth rule above ("delete
nothing on a run that failed to produce a new pack") is not enforced inside the
command: it belongs to the unit ordering, where the pack step precedes the prune
step without a `-` prefix, so a failed pack never reaches it.

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

---

## The SCHEDULED path has now been through a repository, 2026-11-11

The per-service chain had been proven through a scratch restic repository. The
path the **unit** runs had not, and it is a different claim: it invokes
`capture-all-state --pack` and then `prune-state-packs --confirm`, neither of
which existed when that proof was written.

`tests/pack-repository-roundtrip-smoke.sh` sections 11-18 now drive it for
**every declared service**:

```
11  capture-all-state --pack      5 services captured and packed, each with a sidecar
12  restic backup                 the whole pack directory
13  destroy                       every local pack, sidecar and capture removed
14  restic restore                5 packs byte-identical, 5 sidecars intact
15  verify / unpack / restore     5 verified, 5 unpacked, 5 restored to state
16  prune-state-packs --confirm   5 retained, 0 superseded, none unknown
```

**Section 14 is the sharp one.** Retention reads `<pack>.meta` for the service
name, because the manifest is inside the encrypted pack and this host holds
only the public key. Had the sidecar not survived a round trip, every restored
pack would read as `unknown` after a real disaster -- kept, correctly, but
retention could do nothing with them, and nothing would have said so until the
day it mattered. The mutation in section 17 removes the sidecar write and
requires exactly that: 0 retained, every pack unknown.

**Section 16 proves the "never delete the only one" rule where it counts.**
After a disaster each service has exactly one pack, and `STATE_PACK_KEEP=1` is
the configuration most likely to delete something. Nothing is superseded.

### What this still does not prove

Unchanged, and both operator-gated:

- **that any pack has left this host.** The repository is a scratch directory
  under the test's own temp dir, asserted before anything is written, and no
  production target, repository, credential or configuration is read.
- **that the operator's age key opens a pack.** The identity is generated for
  the test; the real key is deliberately not on this host.

So the transfer medium is proven not to corrupt the artefacts and the whole
scheduled chain is proven to work end to end. The two claims that need a real
target and a real key are exactly where they were.
