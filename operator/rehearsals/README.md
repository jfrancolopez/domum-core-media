# Rehearsals

Scripts that drive production code against **real production images** in
**disposable** compose projects. They are here for the same reason the operator
wrappers are: a script that lives in `/tmp` or in a transcript is reviewed by
nothing. Three rehearsals (Kavita, Jellyfin, and the first Plex run) existed
only as output pasted into `docs/`, so nobody could re-run them or review how
they established what they claimed.

**CI shellchecks these and deliberately does not run them.** They need the
production images, a Docker daemon, and several minutes; a runner has none of
those. `tests/ci-coverage-audit.sh` governs `tests/` and does not apply here —
these are not hermetic suites and must never be presented as if they were.

They are also covered by `tests/pipefail-grep-audit.py`, which is not a
formality: the first versions of three of these scripts
contained `docker logs … | grep -q <readiness line>`, and under `pipefail` that
makes a readiness line that IS present read as absent — the dangerous
direction, and intermittent. The volume-upgrade rehearsal added seven more
sites, two of them **teardown assertions** (`docker ps -a | grep -qx "$SVC" &&
fail`), where a container that still exists reads as gone: an assertion that
cannot fail, in the script whose whole claim is that it left production alone.

## What a rehearsal must do

Every one of these was learned by getting it wrong once:

- **assert isolation BEFORE anything mutates** — the disposable project name is
  free, and the production container id is absent from the project's scope;
- **pin images by ID** read from the running container, never by a mutable tag;
- **pass `PUID`/`PGID` (or `user:`) as the invoking account.** The Jellyfin
  rehearsal ran as root and left 39 root-owned files the development account
  could not delete;
- **no production path, volume or network.** `network_mode: none` is the only
  honest guarantee that nothing leaves the host, and the logs prove it: the
  navidrome run shows `network is unreachable` reaching for its background
  images;
- **measure the readiness line from the image's own output.** The first version
  looked for "accepting requests"; navidrome logs
  `----> Navidrome server is ready!`, so a correct start was reported as a
  failure;
- **assert the teardown**, including that the fixture directory could be
  removed, and that the production container count and ids are unchanged.

## The scripts

| script | what it establishes |
|---|---|
| `plex-capture-restore.sh` | the `consistent` capture path against the real Plex image: three declared items, paths containing spaces, a sqlite binary whose own path has a space, `Preferences.xml` (the server token) at mode 600, and the **fail-closed** case — Plex creates `blobs.db` last, so a mid-startup capture correctly reports `INCOMPLETE` and names it |
| `navidrome-capture-restore-start.sh` | capture → restore → **the application starts against the restored capture**. A marker row proves navidrome opened *that* database rather than creating a fresh one, which a table count cannot show because a fresh navidrome also creates tables |
| `plex-identity-survives-restore.sh` | **does a restored Plex remain the SAME SERVER?** The `MachineIdentifier` is read before and after. The **negative control**: with `Preferences.xml` deleted, Plex starts just as happily and mints a *different* identifier — a restore that looks successful and is a new server to every paired client |
| `calibre-web-encrypted-settings-survive.sh` | **does declaring `config/.key` buy anything?** A known plaintext is encrypted through calibre-web's own Fernet, stored in `settings.mail_password_e`, captured, restored, and decrypted after the service starts on the restored state. The **negative control** is the evidence: with the key deleted, calibre-web regenerates one, starts perfectly happily, and the stored secret fails with `InvalidToken` |
| `calibre-web-capture-restore.sh` | the `consistent` path on the only service whose database is `journal_mode delete`, so it proves `.backup` does not **depend** on a WAL; plus the Fernet key captured and restored at mode 600 |
| `five-service-fresh-environment-recovery.sh` | **the whole set reconstructs.** All five captured and packed from their own live instances, every source destroyed and *asserted* gone, each pack verified without decrypting, all five unpacked and restored with digests and modes re-verified, the credentials and identities checked present with their modes, and one application started on what came out. Sequential on purpose — five media servers at once on an N100 would make the timings meaningless |
| `navidrome-offsite-roundtrip.sh` | **the complete workflow**: live service → capture → **encrypted** pack → *independent* restore → **the application starts against what came back**. Independence is enforced, not described: the source capture, data directory and service are destroyed before the restore begins, and the fixture asserts they are gone. A marker row proves navidrome opened the database that came out of the pack. Uses a **disposable** age keypair, because production packs are encrypted to a key this host deliberately does not hold |
| `kavita-helper-consistent-capture.sh` | **an application-consistent capture with NO DOWNTIME** for a service that ships no sqlite3, through a helper image that does. Drives the real `service_state_capture` and asserts `mode=consistent`, the distinct `sqlite-backup-helper` label, that kavita is never stopped (same container id), that no helper artefact lands in the live directory, and that the captured database is sound and larger than the main file |
| `traefik-socket-proxy.sh` | **the Docker API boundary**: a disposable Traefik, socket proxy and labeled whoami route use only unique internal networks; GET routing succeeds and a container-create POST receives 403. It records the running Traefik image ID and asserts all existing container IDs/names are unchanged after teardown |
| `no-new-privileges.sh` | **startup under `no-new-privileges`**: pinned running image IDs for a LinuxServer service, Navidrome, Kavita, and the Immich server/database/Redis. Standalone probes have no network; the Immich fixture uses an internal-only project network and tmpfs state. It checks readiness/health and inspects the security option on every disposable container |
| `volume-resolver-real-objects.sh` | the two UNPRIVILEGED steps of the volume recovery-point chain against real Docker objects: `service_named_volumes` resolves from a real `docker inspect` and **excludes a read-only mount** (a recovery point cannot be built from a volume the service cannot write), and an **absent** volume resolves to nothing rather than a plausible path. Measures production read-only: both `docker-volume` services resolve to exactly one rw volume each — the ACME key's and `kuma.db`'s |
| `volume-upgrade-rollback-real-containers.sh` | **the upgrade and rollback driven against real containers and two real image ids.** Real pre-upgrade point, real image archive, a real deploy onto a moved tag, scope proven over the 11 production containers, cleanup withholding the old image, an injected dump failure refusing *before* the deploy, and a rollback that pins the recorded **id** back. The one stubbed call is `docker_volume_mountpoint`, which returns a `/var/lib/docker` path needing root — and section 3 asserts that `tar -C` on it is **still denied**, deriving the first unreadable component at run time, so the blocker FAILS the rehearsal if it ever retires. It found a real defect: the uptime-kuma readiness pattern was version-specific, and a rollback crosses versions by definition |

Every one of them leaves production untouched and asserts it.

## What they do NOT establish

That a recovered service **serves its library**. navidrome starts, reports
ready, and opens the restored database; it has no music, no users and no client
has fetched anything. The tiers are kept apart deliberately, as they are for
Immich: `capture restores` < `application starts against it` < `application
serves it`.
