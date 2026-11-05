# Live work queue

**This is the execution queue. `backlog/task-*.md` is the 2026-07 audit
evidence and is NOT an execution order** (CLAUDE.md §12). This file is the
thing to read first in a new session or after a context compaction.

Reconciled against the repository and the live host on **2026-11-03**.

| | |
|---|---|
| production | `a63ad19` — **verified by hash, not repeated**: the installed `/usr/local/bin/domum-media` is `5e65f06c…`, which is `bin/domum-media` at exactly that commit, and the installed and checkout copies of both CLIs are byte-identical (the deployment's own invariant) |
| development / `main` | `accc366` — this line said `f7e6d5d`, thirteen commits stale. A revision constant inside the repository it pins goes stale by construction, which is why the deployment script refuses to carry one; here it is a header a new session reads first, so check it against `git rev-parse origin/main` rather than trusting it |
| rule | an item is only `done` with evidence named here |
| caution | **`581d94a`'s subject describes a premise that same PR corrected** — `gh pr merge --squash` took the FIRST commit's subject, not the PR title. `git log --oneline` therefore reads as though the pack check asks "is it in the backup set"; it does not. See `CLAUDE.md`, which is the authority, and pass `--subject` explicitly when squashing a branch whose first commit was later corrected |

Statuses: `open` · `in progress` · `done (sha)` · `BLOCKED (reason)`.
A blocker must name what would unblock it, and blocked items stay in the queue
rather than being deleted.

---

## Why the remaining items are unavailable to an agent — MEASURED

**`sudo` requires interactive authentication that this account cannot supply.**
Measured 2026-11-03:

```
$ sudo -n true
sudo: a password is required
$ sudo -n -l | grep -c NOPASSWD
0
```

That is not a judgement call, and it settles every remaining row at once.
`/srv/data/backups/images` (P2.1), installing a unit (P4.6), traversing
`/var/lib/docker` (P3.4), the deployment that P1.7 and P1.8 depend on, and
`install.sh` for P5.3 all need root, and root is unobtainable here. CLAUDE.md
§10 says so and now the queue has the measurement.

**A command existing in the installed binary is not the same as being runnable
by this account**, and an earlier note conflated them: "works against the
installed binary today" meant the command would not give a usage error, not
that the agent could execute it. Both halves have to hold.

So each remaining item is blocked by at least one of:

| | measured-unavailable | explicitly prohibited |
|---|---|---|
| P1.7 activate a target | needs the deployment (root) | "activate production backups" |
| P1.8 real quiesced run | needs root; `need_root` is now first in that path | "restart services"; downtime |
| P2.1 `du` the archives | root | — |
| P3.4 volume rehearsal | root; `/var/lib/docker` denies traversal | — |
| P3.5 production upgrade | — | "upgrade production applications" |
| P4.6 enable the scrub timer | root | "enable timers" |
| P5.2 off-host key copy | — | "do not make credential copies" |
| P5.3 fresh-host restore | root + a second machine | — |
| P5.5 full Immich restore | ~130 GiB + the UGREEN hardware | — |

## Deployment — and what depends on it

**`capture-state`, `verify-state` and `restore-state` are NOT in the installed
binary.** Production is `a63ad19`, which predates every one of them. So the
operator-approval items split into two groups, and the order matters:

| needs the deployment FIRST | works against the installed binary today |
|---|---|
| **P1.7** (activate a target for the captures) | **P4.6** (install + enable the scrub timer) |
| **P1.8** real run (`capture-state --quiesce`) | **P5.2** (off-host key copy — no command on this host at all) |
| | **P3.5** (`updates apply --service …`; `volume-pre-upgrade-point` is installed) |

Recommending a capture command today would give the operator a usage error —
the recorded defect from when `storage verify-recovery` was suggested off an
unmerged branch. `QUIESCED_CAPTURE_ENABLED` is read from the environment and is
**not** set by `load_cfg` (checked), so `sudo env QUIESCED_CAPTURE_ENABLED=1 …`
is the right form once it is deployed.

## Deployment

Production is at `a63ad19` with **no drift** — every installed file's sha256
matches that revision's blob, and the revision itself was identified BY HASH
rather than read from a file (re-verified 2026-11-04). The reviewed plan is
`docs/DEPLOYMENT-PLAN.md` — renamed from `DEPLOYMENT-PLAN-2026-11-02.md`,
because a date in the filename implies a review of whatever `main` is now.

**It has ONE dated item, and it comes from the operator enabling the scrub
timer rather than from the code.** The timer is `enabled, active`, first elapse
**Sun 2026-12-06 05:34:39**, and the INSTALLED binary has **zero** occurrences
of `btrfs_scrub_running` (main has 2). `btrfs scrub start` refuses when a scrub
is already running, which lands in the generic arm, sets `worst=1`, fails the
oneshot unit, and `health-notify` mails a CRITICAL for a normal condition — the
false alarm the fix exists to prevent, and mail delivery is proven. Deploying
before 2026-12-06 retires it; after that the window reopens monthly.

The installable surface is **two binaries plus one COMMENT-ONLY unit file**
(every directive in `domum-media-btrfs-scrub.timer` is byte-identical). The
narrow deploy script does not carry that unit, so `UNITS_CHANGED` stays 0 and
no `daemon-reload` happens — stated in the plan rather than left to be
discovered, together with the fact that the script's `installed == checkout`
invariant covers only the files it lists. No container is touched, no timer is
enabled, no handover. Not executed — that is an approval boundary.

---

## P1 — Selective off-site protection for media-service state

Design: `docs/SELECTIVE-STATE-PROTECTION.md`. **This header used to say "no
implementation exists", contradicting its own table below.** Verified
2026-11-04: `service_essential_state`, `service_state_capture`,
`service_state_verify` and `service_state_restore` are all defined in
`bin/domum-media`, with `storage capture-state` / `verify-state` /
`restore-state` arms in the dispatcher. They are NOT in the installed binary
(production predates them), which is the real caveat and a different one — see
the deployment section.

| # | item | status |
|---|---|---|
| P1.1 | declare navidrome's in-image sqlite3 | **done** — ships 3.45.3, was undeclared; its db is WAL-mode with a live 20,632-byte `-wal`, so a file copy is torn |
| P1.2 | declare per-service essential state (what to capture) | **done** — `service_essential_state`; `sqlite`/`file`/`dir` kinds, and the big regenerable trees (plex `Drivers/` 230.6 MiB, navidrome `cache/` 95.4 MiB, kavita `backups/` 3.5 MB) are deliberately excluded |
| P1.3 | `service_state_capture` — SQLite-consistent where possible, reusing the `.backup` pattern | **done** — `.backup` + `integrity_check` run INSIDE the container for the three services that ship sqlite3; jellyfin/kavita are recorded `unproven`, never claimed consistent |
| P1.4 | capture manifest: sha256, sizes, image identity, capture mode | **done** — `MANIFEST` carries `CAPTURE_MODE`, `IMAGE_ID` and a digest per item; `service_state_verify` re-reads them, and a missing declared item is `RESULT=INCOMPLETE` with exit 1 |
| P1.5 | restore into a scratch target, never over live state | **done** — `service_state_restore` + `storage restore-state`. Refuses a target that overlaps the live state root (resolved paths, so a symlink or `..` cannot walk in), refuses a non-empty target, refuses a capture that does not verify, re-proves every restored item's digest and mode, and integrity-checks restored databases. 4 mutants, all killed |
| P1.6 | disposable-fixture tests + mutations | **done** — `tests/state-capture-smoke.sh`, wired into CI; 2 mutants, both killed. A `docker` stub that exits non-zero is on PATH, so reaching the real daemon fails rather than quietly succeeding |
| P1.8 | jellyfin/kavita are WAL-mode with no sqlite3 anywhere — a quiesced capture is the only way to make their mode consistent | **rehearsed against the REAL Kavita image; gated off** — measured 2026-11-03: Kavita's clean stop folds its 4,132,392-byte WAL into the main database and removes the `-wal` outright, so quiescence passes on its merits and the captured database opens with 84 tables and `integrity_check: ok`. Image pinned by ID, production untouched, teardown asserted. `docs/SELECTIVE-STATE-PROTECTION.md` Phase E (mechanism, busybox) and Phase F (real image). **Jellyfin rehearsed too, same day and same result** — a 3,188,912-byte `jellyfin.db-wal` before the clean stop and nothing after it, so both services with no sqlite3 behave alike; that rehearsal is also what exposed `capture-state` missing `need_root` (it stopped the service for a capture that could never succeed, because the `0600 root` DataProtection key is unreadable unprivileged) and what showed the six declared items appearing in STAGES during startup. **Still gated:** production Kavita and Jellyfin have populated libraries and days of uptime, so their shutdown has more to finish, and the real run causes downtime — an operator decision |
| P1.10 | rehearse the CONSISTENT capture path against the REAL images — the half jellyfin and kavita could not reach | **done 2026-11-04, and it found a bug.** jellyfin and kavita have no sqlite3, so their rehearsals proved only the `unproven` path. **navidrome and plex** were rehearsed against their production images pinned by ID, unprivileged, disposable compose projects, teardown asserted, production untouched (11 containers before and after, container ids unchanged, `fixture left behind: 0`). navidrome is the decisive measurement: a 4,096-byte main database with a live **2,195,992-byte `-wal`** captured to **450,560 bytes / 24 tables**, so `.backup` demonstrably walked the WAL — a file copy would have yielded a 4 KB shell. plex additionally proved the fail-closed path (it creates `blobs.db` LAST, and a mid-startup capture correctly reported INCOMPLETE naming it), space-containing paths folding with no collision, and `Preferences.xml` — the server token — captured and restored at mode **600**. The bug: the restore's comment claimed databases are checked by the application's own sqlite and the code never called `domum_sqlite_check_via_container`, so plex reported `0 checked sound, 2 not checked` for databases that answer `ok` with 82 tables under `Plex SQLite`. Fixed; 1 mutant, killed. **Not proven and stated: that either service RUNS against a restored capture** |
| P1.11 | the tier the restore itself called unproven: does the APPLICATION start against a restored capture? | **done for navidrome, 2026-11-04.** Capture from one disposable navidrome, restore, then a SECOND disposable navidrome started with `/data` holding ONLY the restored database: `----> Navidrome server is ready!` in 671 ms, stayed running, no panic or fatal, `integrity_check: ok` afterwards. A MARKER ROW is what makes it meaningful — a fresh navidrome also creates tables (24 before startup, 46 after), so only a row the restored copy carried can distinguish REUSED from RECREATED. **Ceiling stated: it does not SERVE a library** — no music, no users, nothing fetched. Tiers stay apart as for Immich: capture restores < application starts against it < application serves it. Script: `operator/rehearsals/navidrome-capture-restore-start.sh` |
| P1.13 | calibre-web's declaration missed the key that decrypts its own database | **fixed 2026-11-04 — a real gap, found by inspecting production.** It declared `config/app.db` and `config/gdrive.db` only. Measured from the production schema (column names only; no value read, and the key's bytes never printed): `config/.key` is **44 bytes — a Fernet key** — and app.db carries `settings.mail_password_e`, `settings.config_ldap_serv_password_e` and `settings.config_reverse_proxy_login_header_secret_e`; the `_e` suffix is calibre-web's own convention for a Fernet-encrypted value. So a capture of the database alone restores those as **undecryptable bytes** and calibre-web comes up looking healthy while silently unable to send mail or bind to LDAP — the exact case jellyfin's `.aspnet/DataProtection-Keys` is declared for. `.key` and `client_secrets.json` are now declared; measured against a fresh disposable calibre-web, which creates all four, so this cannot make a capture fail closed. The MODE is the other half: a digest covers contents, so the manifest records `44|600` and the restore returns it at 600. Rehearsed against the real image (`operator/rehearsals/calibre-web-capture-restore.sh`): 4 items, `journal_mode delete` — the only no-WAL service, so it proves `.backup` does not depend on a WAL — and 3 `_e` columns in the restored database. 1 mutant on the ANSWER, killed. **Note for the operator:** production's `.key` is mode 644 while a fresh install creates it 600; reported, not changed |
| P1.14 | sweep ALL five declarations against the real production directories — the calibre-web key was not isolated | **done 2026-11-04; two more found.** **kavita** was missing `config/appsettings.json`, which holds the JWT **TokenKey** (measured 338 characters; key names and lengths only, no value read) — restore kavita.db without it and Kavita mints a new key, so every session and API key silently stops working. **jellyfin** was missing `config/data/data/device.txt`, 35 bytes, the server's IDENTITY — the same artefact class as plex's `Preferences.xml`, which this project already declares because without it every client must re-pair. **navidrome verified COMPLETE** rather than assumed: production holds only the database plus regenerable `artwork/`/`cache/` and an empty `plugins/`, and `ND_CONFIGFILE`'s `navidrome.toml` does not exist — configuration comes from the compose environment, which the recovery pack carries. Both additions were checked against a FRESH install first (634 and 35 bytes), because a declared item an install does not create makes every capture INCOMPLETE forever. 2 mutants on the CAPTURE rather than on declaration text, both killed |
| P1.15 | the captures now contain credentials, so prove they are protected at rest and do not leak | **done 2026-11-04.** Measured by driving a capture and listing every path: `install -d -m 0700 "$dest/files"` applies the mode to the LEAF only, so `backups/`, `backups/state/`, `<service>/` and `<stamp>/` came out **0755** (install's own default, not the umask — the mutation returns 0755 under a umask of 0002) and calibre-web's Fernet key sat at 0644 behind a single 0700 directory. The whole chain from `state/` down is 0700 now; `<data>/backups` is created if absent and deliberately NOT re-moded, being shared with `images/` and `volumes/`. Stored files keep their SOURCE mode on purpose: the restore `cp -a`s and then verifies against the manifest's recorded mode, so normalising to 0600 would fail every non-0600 item and make that check circular. Leak question asked with a SENTINEL — a unique string in a fixture key must appear in exactly the stored and restored copies and nowhere in stdout, stderr or the MANIFEST. No workflow uploads artifacts (checked). 2 mutants, killed |
| P1.16 | calibre-web's production `.key` is 0644 | **OPERATOR ACTION, one command.** Measured 2026-11-04: the key is `-rw-r--r-- jfranco:jfranco`, 44 bytes, and **every parent directory is world-traversable** (`/srv`, `/srv/data`, `/srv/data/calibre-web`, `.../config` are all `drwxr-xr-x`), so the mode is genuinely effective — any local account can read that Fernet key. **But the only non-system account is `jfranco` (uid 1000), which OWNS it**, so today's reader set is root plus the owner: the same set as at 0600. Practical exposure nil; what is wrong is that it is looser than the application's own default (a fresh calibre-web creates it 0600, measured) and a second account or a wider bind mount would change that silently. Remedy: `sudo chmod 600 /srv/data/calibre-web/config/.key`. NOT done — a production file's mode is an operator change. The capture preserves whatever mode is there rather than normalising it |
| P1.17 | prove the capture does not re-mode SHARED production paths | **done 2026-11-04.** `install -d -m MODE` sets the mode on an EXISTING directory too, so hardening the chain could have silently re-moded `<data>/backups`, which `images/` (`drwxr-x--- root` in production) and `volumes/` share. The capture creates it if absent and never passes `-m` for it. Tested rather than intended: the fixture pre-creates `backups` 0755, `images` 0750 and `volumes` 0751, runs a capture, and requires all three unchanged (755→755, 750→750, 751→751) while asserting the capture's own root IS 0700, so it cannot pass by doing nothing |
| P1.18 | jellyfin and kavita without downtime — the `--quiesce` conclusion was WRONG | **done 2026-11-04; the operator was right to challenge it.** Both ship no sqlite3 and the host has none, so CLAUDE.md said closing their `unproven` mode needed a quiesce (downtime) or a writable `-shm`. Measured against disposable live databases of the REAL images with a helper container that ships sqlite3: kavita main 966,656 / `-wal` 4,132,392 → `.backup` 1,105,920 with 84 tables `ok`; jellyfin main **4,096** / `-wal` 3,188,912 → 475,136 with 33 tables `ok` — so jellyfin's whole schema came out of the WAL. Both stayed RUNNING with no database error and nothing written into their data dirs. **The live directory mounts READ-ONLY and that suffices** (the `-shm` exists because the service holds it open), so the helper never needs write access to live data. Never pulls — resolved from a running container pinned by image ID, plex excluded because only its own binary reads `collating`. Labelled `sqlite-backup-helper`, distinct from `sqlite-backup`. In-image binary preferred and the helper not even tried when one exists. 8 fixture sections + `operator/rehearsals/kavita-helper-consistent-capture.sh`; 2 mutants, killed. `--quiesce` stays gated, now as the fallback for a host with no helper image rather than the only route |
| P1.19 | ONE complete workflow: capture → encrypted pack → independent restore → application start | **done 2026-11-05**, which is what the operator asked for instead of more manifest tests. `storage pack-state` encrypts a VERIFIED capture into one `age` artefact (gate first — a tampered byte makes it refuse); `storage unpack-state` opens it with an operator-supplied identity, checking the recorded sha256. Measured: 679,936-byte database with a 4,140,632-byte live `-wal` → 696,680-byte pack → unpack → restore → `Navidrome server is ready!` in **50 ms**, marker row read back out of the started service. **Independence is ENFORCED**: the source capture, data directory and service are destroyed and asserted gone before the restore half runs, so the only inputs are the pack, its `.sha256` and the identity. Same age recipient as the recovery pack on purpose — one off-host private key, not two. **This host cannot decrypt what it writes** (only the public key is here), so the round trip uses a disposable keypair and says so: it proves the MECHANISM, not that a production pack can be opened. Plaintext tar staged inside the 0700 destination, never `/tmp`, and removed on the failure path too. 7 fixture sections + `operator/rehearsals/navidrome-offsite-roundtrip.sh`; 2 mutants killed. **Still an operator decision:** putting a pack anywhere off-site — `pack-state` writes a file and stops |
| P1.20 | calibre-web: application start against a restored capture, AND the credential still usable | **done 2026-11-05, measured in both directions.** Declaring `config/.key` had been justified by an argument; this measures it. A known plaintext encrypted through calibre-web's OWN Fernet (`cryptography` 43.0.3 in its image) is stored in `settings.mail_password_e`, asserted not to be plaintext, the source destroyed, the capture restored, and a second disposable calibre-web started on it — the value decrypts to the original 34 characters. **The negative control is the evidence:** with the key deleted, calibre-web **regenerates one and starts perfectly happily** while the stored secret fails with `cryptography.fernet.InvalidToken`. That is the silent failure the declaration exists to prevent — a restore reports success and the credential is permanently unreadable. Restored key asserted mode 600 before startup. `operator/rehearsals/calibre-web-encrypted-settings-survive.sh`. **Not proven:** that calibre-web SERVES a library — no books, no users, nothing fetched |
| P1.21 | plex: application start against a restored capture, and the server IDENTITY | **done 2026-11-05, both directions.** `MachineIdentifier` `37be53c1-6233-4500-8c23-0dd7eec684d5` before the restore and **identical** after. **Negative control:** with `Preferences.xml` deleted, Plex starts just as happily and mints `655118fa-c396-43e2-84e8-e6beb6c42fcb` — a restore that reports success and is a DIFFERENT server to every paired client, with nothing in Plex's behaviour revealing it. Restored `Preferences.xml` asserted mode 600 before startup. The restored library database opens in **Plex's own SQLite** (`ok`, 82 tables), which the host's sqlite3 cannot do because of the `collating` tokenizer. `operator/rehearsals/plex-identity-survives-restore.sh`. **Not proven:** that it SERVES a library |
| P2.5 | re-verify the exact Docker image recovery dependencies | **done 2026-11-05; position UNCHANGED, which is the useful result.** traefik (`9c3b91d5fb77`) and uptime-kuma (`a8610b3b4c38`) are still `RepoTags: []` / `RepoDigests: []` — dangling and prune-exposed. The five media services are tagged but every `RepoDigest` equals its image Id, so none has an independent registry reference. The `docker save` archive therefore remains the only PROVEN copy of the application half for all seven, and `/srv/data/backups/images` is still not in the cloud target. All five capture-relevant image ids resolve locally, so a manifest's `IMAGE_ID` names an object that exists — whether it could be re-obtained is a different question and the answer is still no |
| P1.22 | audit the jellyfin/kavita consistency evidence | **done 2026-11-05, and it found a gap.** `unproven` had acquired a SECOND meaning without saying so: "no sqlite3 anywhere" versus "a helper exists on this host and was not found". Measured: `sqlite_helper_image` does not resolve unprivileged (`tracked_service_container_id_any` is `compose_cmd ps -qa`, which needs the compose environment), so jellyfin and kavita report `unproven` here and nothing said why. **And the rehearsal proved the MECHANISM, not the RESOLVER** — it set `SQLITE_HELPER_IMAGE` explicitly, so helper discovery in production remains unproven and needs root. Fixed: the manifest records `SQLITE_IN_IMAGE` and `SQLITE_HELPER`, the capture says which case it is in, and unproven-with-a-helper-available is a WARNING because a consistent capture was possible and not taken. 3 sections |
| P1.23 | `storage verify-pack` — the only claim this host can make about a production pack | **done 2026-11-05.** It holds only the public key, so it can say the FILE matches its recorded sha256 and carries age's header, and nothing more — which the output states. Four states driven: verified `0`, **UNKNOWN with no recorded checksum `2`**, MISMATCH `1`, not-a-pack `1`; the last reports file integrity separately because "intact" and "is a pack" are independent claims. A missing checksum is deliberately not a pass. 1 mutant, killed. Found by the documented-commands audit, which caught the command being cited in the activation plan before it existed |
| P1.24 | off-site scheduling, retention, verification, secret handling and activation plan | **designed, NOT activated** — `docs/OFFSITE-STATE-BACKUP-DESIGN.md`. Weekly Sun 04:00 (+15m) between the 02:30 backup and the 04:30 prune, `Persistent=true`, and deliberately NOT in `auto-enable.timers`. Retention: newest 4 per service, never the newest, never an unverifiable pack (it is evidence), nothing deleted on a failed run. Recommends a **separate** backup target rather than widening the immich-only cloud scope, so coverage keeps one unambiguous answer. **It opens by stating what is NOT proven:** the mechanism works with a DISPOSABLE key, no pack has left this SSD, and the real age key has never opened one — so the five applications do NOT have off-site protection. **BLOCKED on operator approval** for the destination, the timer, and the one step no work here can replace: decrypting a real pack with the operator's own key, off this host |
| P1.25 | fresh-environment recovery rehearsal for ALL FIVE services | **done 2026-11-05.** All five captured **`consistent`** from their own live instances — navidrome 1 item, calibre-web 4, kavita 3, jellyfin 7, plex 3; packs 154 KB–758 KB. jellyfin and kavita reaching `consistent` is the helper path on their real images. Every source then destroyed and **asserted gone**, leaving only 5 packs, 5 `.sha256` and one identity; all five verified without decrypting, all five unpacked and restored with digests and modes re-verified, and the credentials and identities confirmed present (calibre-web key 600, kavita TokenKey, jellyfin DataProtection-Keys + `device.txt`, plex token 600). navidrome then started on pack-derived state in 676 ms. Production untouched: 11 containers, all five ids unchanged. **The first run FAILED in the right direction** — it refused to call the environment fresh while a source survived; cause was kavita's image ignoring `PUID` (a linuxserver.io convention, not a Docker one), so its tree is root-owned. **Still NOT proven:** the operator's key opening a pack, any pack existing off this SSD, or any service serving its library |
| P1.12 | rehearsal scripts were reviewed by nothing | **fixed** — Kavita, Jellyfin and the first Plex rehearsal existed only as output pasted into `docs/`, so nobody could re-run them or review how they established what they claimed: the identical argument that moved the operator wrappers into `operator/`. Now `operator/rehearsals/` with a README stating what a rehearsal must do and what these do NOT establish; shellchecked and `bash -n`'d by CI and deliberately NOT run by it (they need the production images and a daemon). Bringing them into `tests/pipefail-grep-audit.py`'s scope immediately found `docker logs | grep -q <readiness line>` in BOTH — under pipefail a readiness line that IS present reads as absent. Tenth instance |
| P1.9 | surface `CAPTURE_MODE` in the restore report | **done** — printed with its reason; a consistent capture reports distinctly so the unproven wording cannot be boilerplate, and an absent key reads `unknown`, never the reassuring value |
| P1.6b | a DEFAULT capture destination, so captures are schedulable | **done** — `state_capture_dir()` -> `<data>/backups/state/<service>/<stamp>`, a sibling of the service directory and never inside it (a capture written under `/srv/data/<service>` would duplicate into every per-service snapshot of that service). Proven end to end, not just in the dispatcher. It puts nothing off-site: the cloud target is immich-only, so the default is on the protected local tier and nowhere else |
| P1.6c | a stale protection claim in `image_archive_dir`'s comment | **fixed** — it asserted an archive there was covered off-site because restic is given `$DOMUM_DATA_ROOT`. True of the GLOBAL include set, false of the target that runs. The operator found the same error in `dr-status` by listing the Hetzner snapshot; the code comment still carried it |
| P1.7 | activate a production backup target for the captures | **BLOCKED — requires operator approval.** The action is "change backup configuration" / "activate production backups", both explicitly prohibited. Everything short of it is done: the capture has a default destination (`<data>/backups/state/<service>/<stamp>`), a measured size (**8.90 MiB** of state), a rehearsed restore, and §4a of `docs/OFFSITE-COVERAGE-CLASSIFICATION.md` states the two remaining choices (where the captures live; a third include root on `cloud` versus a separate target). The archive cost this row used to wait on is now measured (**1.68 GiB**, P2.1), so nothing technical is outstanding |

### Measured capture capability, 2026-11-03

Taken by exec'ing each running container. **The host has no `sqlite3` at all**,
so every consistent capture depends on the service's own binary.

| service | in-image sqlite3 | live `-wal` | consistent capture |
|---|---|---|---|
| plex | `/usr/lib/plexmediaserver/Plex SQLite` 3.39.4 | **911,792 B** + `-shm` | `.backup` — and only this binary can read its `collating` FTS tokenizer |
| navidrome | `/usr/bin/sqlite3` 3.45.3 | **20,632 B** + `-shm` | `.backup` |
| calibre-web | `/usr/bin/sqlite3` 3.45.1 | none (`journal_mode delete`) | `.backup`, and a copy is already sound |
| jellyfin | **none** | WAL-mode, sidecars removed at close | **not in place** — quiesce; proven to checkpoint on a clean stop |
| kavita | **none** | WAL-mode, sidecars removed at close | **not in place** — quiesce; proven to checkpoint on a clean stop |

The two services with no sqlite3 are exactly the two that showed no WAL
sidecars, and **that absence is not proof of non-WAL mode** — SQLite removes
the `-wal` when the last connection closes. An earlier version of this table
read it the other way and called their mode *unprovable without a
`PRAGMA journal_mode`*. Both halves of that were wrong, and `CLAUDE.md` records
the measurements:

- **the mode is readable without any binary.** Bytes 18/19 of the SQLite file
  header are `write_version`/`read_version`; measured 2026-11-02 as a pure read
  — no open, no lock, no privilege — both are `2`, i.e. **WAL**. navidrome is
  WAL too; calibre-web is `1`/`1`, a rollback journal;
- **a clean stop checkpoints.** Measured 2026-11-03 against both production
  images pinned by ID: kavita folded a 4,132,392-byte WAL into its main
  database and jellyfin a 3,188,912-byte one, each removing the `-wal` outright.

So an *in-place* capture of either is torn rather than merely crash-consistent,
which is why `CAPTURE_MODE=unproven` is the honest word for it, and
`--quiesce` is the path that earns `file-copy-quiesced`. Declaring a sqlite
path they do not have would still turn "not checked" into a check that always
fails.

---

## P2 — Image recovery

| # | item | status |
|---|---|---|
| P2.1 | measure the image-archive cost | **MEASURED 2026-11-03, and it did not need root** — the directory needs root to *list*, but what gates the recommendation is the size of one archive per service, and `docker save \| wc -c` measures that exactly without touching `/srv/data`. **1.68 GiB for all seven** (53 MiB traefik … 573 MiB uptime-kuma, 246 MiB mean), i.e. 26–30% of image size and **190×** the 8.90 MiB of state. Against the 207.5 GiB already in the repository: **+0.8%**, so coverage is affordable and §4b's recommendation is no longer withheld. Still root-only: how many archives exist on disk NOW — a retention question, not a cost one |
| P2.2 | identify which archives a *still-valid* recovery point names | **done in code** — `storage archives` names the point per archive and now also says whether the archive actually holds that image. Still needs root to run against production |
| P2.3 | off-site preservation + retention procedure for archives | **designed** — `docs/OFFSITE-COVERAGE-CLASSIFICATION.md` §4b: retain off-site only an archive a *still-valid* recovery point names, verify it holds that image (`domum_archive_identity`, read-only) before counting it as coverage, never select by filename or mtime, keep the newest valid point per service, and treat off-site retention and on-disk retention as separate decisions. Every rule is answerable by the CLI today. §4a is now the selective capture (8.90 MiB) rather than whole directories. Activation still gated on P2.1 |
| P2.4 | restore-from-archive procedure, proven on a disposable image | **done for the MECHANISM, not for the project's archives** — four separate claims, measured 2026-11-02 against a disposable busybox archive: FILE INTACT, HOLDS THE IMAGE (content-addressed, read-only), LOADS TO THAT IMAGE (`docker load` reports the same id), THE IMAGE RUNS (a disposable container from the image id, `--network none`). Loading an archive of an image the store already holds is a no-op, which is what made it safe to measure. The project's own archives are `root 0750` and have never been loaded — a fixture-backed probe is not production evidence. `docs/RECOVERY-POINT-IDENTITY.md` |

Measured 2026-10-28 and still true: **traefik and uptime-kuma run images with
`RepoTags: []` and `RepoDigests: []`**, and every tagged image's `RepoDigest`
equals its image Id, so no service has an independent registry reference. The
`docker save` archive is the only *proven* copy of the application half of any
recovery point.

---

## P3 — Traefik / Uptime Kuma volume upgrades

Largely complete. `volume-recovery-point-smoke` covers 11 properties and
`volume-upgrade-dispatch-smoke` covers the dispatch, both verifiers, rollback
dispatch, the closed gate, and phase 4's model-awareness.

| # | item | status |
|---|---|---|
| P3.1 | phase-4 model awareness (a volume upgrade could not succeed) | **done** (`b67eee1`) |
| P3.2 | readiness reported as UNPROVEN where it cannot be evidenced | **done** (`b67eee1`) |
| P3.3 | readiness log pattern consulted by the upgrade, with a bounded wait | **done** — `UPGRADE_READY_LOG_WAIT` (default 60 s, 5 s steps) with ONE attempt before any sleep, so a wait of 0 means look-once. Deliberately asymmetric: found strengthens the claim, absent is reported and never sets `rc`, because escalating on absence is what got the first attempt reverted. The boundary is captured before the deploy and the ORDER is asserted. The UNPROVEN sentence is now built from what is actually absent, so it cannot claim a service has no declared pattern when it has one |
| P3.4 | end-to-end rehearsal against **real disposable containers** (not fixtures) | **BLOCKED on root — and the blocker is ONE LINE narrower than this row used to claim.** It said fixtures cannot prove `dump_volume_to_file` / `restore_volume_from_file`. They do: `volume-recovery-point-smoke` drives both with **real tar, real checksums, real xattrs/ACLs, real file modes, real quiescence and a real restore** — its own comment calls `docker_volume_mountpoint` "the ONE stubbed seam". And **half of that seam is now measured unprivileged**: `docker volume inspect --format '{{.Mountpoint}}'` resolves correctly here for both production volumes. Genuinely root-only is the other half — whether `tar -C <mountpoint>` can READ it, since `/var/lib/docker` is `drwx--x--- root root` (verified: `ls -ld` and `tar` both say Permission denied). So the unblock is one privileged command, not a whole rehearsal. Isolation was checked too: a `domum-rehearsal` project yields `domum-rehearsal_*`, production is `domum-media_*`. See `docs/VOLUME-UPGRADE-REHEARSAL.md`, including why a rootless variant was rejected |
| P3.5 | production upgrade of traefik / uptime-kuma | **BLOCKED — requires operator approval.** The action is "upgrade production applications" and setting `VOLUME_UPGRADE_ENABLED=1`, both explicitly prohibited ("keep volume-upgrade gates disabled"). Everything short of it is done and tested: model-aware dispatch, both verifiers, rollback restoring BOTH halves, a model-aware phase 4, and a gate that refuses before the lock and before any container is stopped |

---

## P4 — Storage

| # | item | status |
|---|---|---|
| P4.1 | scrub unit + timer written, not installed | **done; schedule now TESTED too** — `systemd-analyze calendar` resolves `Sun *-*-01..07 05:30:00` to the first Sunday monthly (next elapse 2026-12-06), which is the only part of a timer testable without installing it. Both units verify clean and neither is installed. The timer's comment justified `Persistent=true` with "this job deletes nothing" — true but the wrong reason for a READ-WRITE job; corrected to the real mitigations (`RandomizedDelaySec=20m`, and `--limit 150M` making it ~25 min rather than the measured 7m14s) |
| P4.2 | per-filesystem dedup so one filesystem is scrubbed once | **done** — `btrfs_unique_roots`, both directions tested |
| P4.3 | exit status contract (`0`/`1`/`3`) and a failed scrub failing the unit | **done** |
| P4.4 | SMART wear reaching the notifier | **done, and re-verified against the real host 2026-11-03** — driving the checks unprivileged confirmed a permission failure reports `UNKNOWN` as a WARNING with **zero CRITICAL** (the recorded defect, fixed), and exposed a new one: `mreport_smart_interpretable` collapsed "no table at all" into "placeholders", so /dev/sda — interpretable as root — was reported as holding vendor placeholders. Three states now (0/1/2), advice worded per cause, pinned by a section no fixture could have reached |
| P4.5 | duplicate-run protection *while a scrub is already running* | **done** — measured: `btrfs scrub start` on a busy filesystem returns non-zero and landed in the generic branch, so it reported `scrub FAILED`, failed the unit, and would have mailed a CRITICAL for an entirely normal condition. `btrfs_scrub_running` reads the `Status:` field and btrfs's own `already running` error closes the race; a skip does not fail the unit; the summary narrows its claim instead of saying `clean`; an unreadable status is `unknown`, never `not running`; an unrecognised error stays a failure. 1 mutant, killed |
| P4.6 | install + enable the scrub timer | **DONE BY THE OPERATOR, 2026-11-03** — both units installed, timer `enabled, active`, service `static, inactive`. Verified no missed run fired: `LAST` is `-` and the service has never started, so `Persistent=true` on a first enable schedules forward rather than catching up. Next elapse **Sun 2026-12-06 05:34:39 EST** (05:30 + ~4m39s randomised). No scrub has run |

---

## P5 — Disaster recovery

| # | item | status |
|---|---|---|
| P5.1 | credential-custody review + checklist | **done** — `docs/RECOVERY-KEY-CUSTODY.md` |
| P5.2 | off-site copy of the restic password / age private key | **BLOCKED — requires operator action, and it is the single highest remaining risk.** The action is making a credential copy, explicitly prohibited ("do not make or transmit credential copies automatically"; "do not access or display private key material"). 37 encrypted recovery packs exist and every one is unopenable without the age private key, which is deliberately not on this host. `docs/RECOVERY-KEY-CUSTODY.md` is the checklist; the custody decision is the operator's |
| P5.3 | fresh-host restore runbook validated end to end | **corrected, NOT validated** — `docs/disaster-recovery.md` now opens with a per-step proven/never-executed table and four stale claims are fixed: it offered **`nas` as the primary restore example** (a target with zero snapshots across 107 nightly runs and no mount on this host), said service-level Btrfs rollback is unavailable (five services have been subvolumes since 2026-09-25), said no guided PostgreSQL import exists (`verify-db-restore` is proven), and never mentioned that the cloud target is immich-only — so a fresh host comes up with the photo library and five media services as fresh installs. End-to-end validation needs a second machine (P5.5) |
| P5.4 | hidden recovery dependencies enumerated (pgvecto.rs, Jellyfin DataProtection-Keys, image identity) | **done** — `docs/HIDDEN-RECOVERY-DEPENDENCIES.md`, 12 entries, each citing the measurement and the document holding it. 8 are closed in code and still listed, because each was closed *after* giving the wrong answer first |
| P5.5 | full Immich restore → `FULL RECOVERY VERIFIED` | **BLOCKED — unavailable hardware.** A whole-tier restore is ~130 GiB from Hetzner plus a rebuilt Immich serving it, which needs the UGREEN machine. Proven instead, and deliberately not promoted: the dump imports (`verify-db-restore`), Immich OPENS the recovered database (phase A), and it SERVES 8 of 23,033 recovered originals byte-identically (phase B). Never claim the tier without doing the restore |
| P5.6 | the recorded off-site coverage proof is STALE, and the mechanism to say so is deployed-pending | **OPERATOR ACTION, read-only and free.** Measured 2026-11-04 without privilege: the nightly heartbeat `/var/log/domum-media/last-success` reads `2026-11-04T02:31:27-05:00`, so the backup chain is healthy and ran 6h ago — but the last recorded reconciliation is **2026-10-29 against snapshot `fb948da5`**, which is now **6 nightly windows old**. Any original ingested since then is NOT RECONCILED (which is not the same as not backed up — it is very likely already in the newer snapshots and nothing has checked). The staleness detection itself is built and tested, in both `dr-status` and the weekly report; it just needs a run. Remedy: `sudo domum-media-backup verify-snapshot-coverage cloud` — reads snapshot metadata only, downloads NO file content. The evidence file is `root`-only, so this account cannot read the proof to confirm the date independently; the 10-29/`fb948da5` figures come from the 2026-11-02 production report recorded in `CLAUDE.md` |

---

## P6 — Reliability

Found and fixed this session: see `CLAUDE.md`. Ongoing hunt, no fixed list.

| # | item | status |
|---|---|---|
| P6.1 | dry run must consult the silence gate | **done** (`f7e6d5d`) |
| P6.2 | one verdict ladder shared by body and subject | **done** (`f7e6d5d`) |
| P6.3 | audit remaining CLI paths for the defect families CLAUDE.md records | **pass 1 and pass 2 done; continuous** — pass 1: boolean `//` reads and trailing-field arity reads clean, three real aborts found and fixed (P6.4), audit shipped (P6.5). pass 2: the unbound-config-variable family **does not warrant an audit** — 14 of `load_cfg`'s 26 variables are read without a default across 160+ sites, all 24 dispatch arms reach a handler that calls `load_cfg`, and 20 suites stub it deliberately, so a rule would reject twenty suites and almost every CLI path. Recorded so it is not re-derived |
| P6.4 | three `set -euo pipefail` aborts where the producer may legitimately find nothing | **done** — the nightly dump's `docker ps` (an unreachable daemon aborted the backup instead of reporting the database absent), `dr-status`'s three `find`s on derivative subtrees that need not exist (the report died on a freshly restored host), and phase-b's live-photo selection (a user with no live photo aborted before the branch written for it). All three reproduced standalone before fixing; 1 mutant, killed |
| P6.5 | an AUDIT for that family, not just the three fixes | **done** — `tests/find-abort-audit.py` + smoke test, in CI. The cry-wolf worry was measured rather than assumed: 18 command substitutions contain a `find` and only **three** lacked a guard, all three real. One was `checkup`'s `waiting_count` over `image-updates`, which does not exist until `ensure_dirs` has run — the shape that blanked the report in production once already, still live in a second place. `bin/*` only, continuations joined, quoted heredocs skipped, and a `# find-audit:` marker exempts its own line and is printed |
| P6.6 | let `checkup` ask whether the recovery pack can leave this host | **done** — `domum-media-backup pack-offhost [target] [--json]`, exit 0 delivered off-host / 1 none or CIRCULAR / 2 not answerable, consumed by `checkup_recovery_pack_offhost`. The question was CORRECTED on the way: "is the pack in the backup set" was the wrong one (the cloud scope includes it deliberately) and it contradicted `dr-offhost-audit`, whose circularity row read the GLOBAL include paths and so reassured about production. `recovery_pack_coverage` is now the one implementation for all three readers. `circular`/`none` are critical with an action, so they mail; a non-answer is a warning, which is why the caller requires the JSON and not just the status. 2 mutants, killed |
| P6.7 | nothing enforced the remedy pairing for CRITICALS, and a critical is the one that MAILS | **done** — measured: 25 `checkup_add critical` sites, 7 bare, **three real**. The legacy image pins named neither the variables nor the file (and measured, **nothing in this repository reads them**, so they pin nothing); "No backup targets are enabled" gave no way to see why the photographs might be unbacked-up; and the missing backup password file did not name the path although `$pw_file` was resolved the line above. A critical with no remedy is worse than a warning with none, because a warning stays quiet. `tests/lib-critical-pairing-audit.py`, standalone in CI, with a printed `# critical-bare:` exemption for the three that name their own variable and legal values. 1 mutant, killed |
