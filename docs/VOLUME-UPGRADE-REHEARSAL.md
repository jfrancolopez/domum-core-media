# Volume upgrade rehearsal — written, passing, and what it still does not cover

**Status: WRITTEN AND PASSING — `operator/rehearsals/volume-upgrade-rollback-real-containers.sh`,
8 sections, rc=0, 2026-11-12.** It drives the real `service_upgrade` against
REAL containers and two REAL uptime-kuma image ids, with exactly one stubbed
call. Production was 11 containers before and after, with unchanged ids.

**The second blocker was retired STRUCTURALLY, not by privilege — and the way
it was retired is the point.** This document previously recorded it as
something *"no privilege retires"*, which was true of the question as asked:
the two `docker-volume` services both run in production under container names
that are unique per daemon, so a disposable project cannot use either name, and
renaming one in a fixture would defeat `stop_compose_services_verified` — it
compares compose SERVICE names against `docker ps` NAMES and is correct only
because every service sets `container_name` equal to its key. A renamed
container would read as STOPPED while running, the dangerous direction.

What was never required was *hosting the rehearsal on traefik or uptime-kuma*.
The rehearsal **declares its own `docker-volume` service** whose container name
equals its service key: the invariant stays intact, nothing collides, and the
production code under test is unchanged. The blocker was a property of one
phrasing of the question, not of the feature — the fourth time in this project
that a blocker turned out to belong to a neighbouring question.

**The root blocker is real and is now checked LIVE rather than quoted.**
Section 3 resolves the volume unprivileged and then asserts that `tar -C` on
the mountpoint docker reports is still denied, deriving the first unreadable
path component at run time. If that ever succeeds the rehearsal FAILS, so the
blocker can notice its own retirement instead of going stale as prose.

**It found a defect no fixture could.** `service_ready_log_pattern uptime-kuma`
declared `Listening on:` — with the colon — which is version-specific:

```
uptime-kuma:2   [SETUP-DATABASE] INFO: Listening on:
uptime-kuma:1   [SERVER]         INFO: Listening on 3001
```

A rollback restores the OLD image, so it crosses versions by definition. After
one, phase 4 would have reported readiness UNPROVEN for a service that was
perfectly ready — safe in direction, and still a claim about the wrong thing.
The declaration drops the colon; `Listening on` is the only line containing
those words in either image.

**A measurement worth keeping:** a cross-major uptime-kuma upgrade takes about
**two minutes** to reach its readiness line, because v2 migrates a v1 database
on startup, against a default `UPGRADE_READY_LOG_WAIT` of 60 s. That is the
designed behaviour — absence is reported and never sets `rc` — but an operator
who sees `NOT logged within 60s` after upgrading uptime-kuma should know it is
expected. The rehearsal asserts the CONTRACT (reported either way, upgrade
still exits 0) rather than requiring the line, because requiring it would be
stricter than the code and flaky by design.

**Still NOT covered, and no amount of work here changes it:** an upgrade of the
actual production traefik or uptime-kuma. That is `VOLUME_UPGRADE_ENABLED=1`
plus an application upgrade, both operator-gated. The gate is untouched.

`traefik` and `uptime-kuma` are the two `docker-volume` services. Their upgrade
and rollback path is implemented and covered against fixtures —
`tests/volume-recovery-point-smoke.sh` pins 11 properties and
`tests/volume-upgrade-dispatch-smoke.sh` covers the dispatch, both verifiers,
the rollback dispatch, the closed gate, and phase 4's model-awareness. What no
fixture can establish is that the real Docker volume dump and restore work.

## What the rehearsal would prove that fixtures cannot

| | |
|---|---|
| `dump_volume_to_file` | that a tar of a live volume is complete, and that `--numeric-owner --xattrs --acls` really preserves `acme.json` at mode 0600 owned by root. Restoring the Let's Encrypt **account private key** world-readable would turn a recovery into a disclosure |
| WAL handling | that `kuma.db` plus a **non-empty `-wal`** survives a dump and restore as a database the application opens, not merely as bytes |
| `restore_volume_from_file` | that it sets the failed state aside as `.failed-<stamp>` before writing, and that restoring is idempotent |
| exact images | that `rollback_volume_upgrade` pins the recorded image **id** and recreates on it, rather than resolving a tag |
| readiness | that uptime-kuma logs `Connected to the database` then a listening line across a real restart, which is what makes its declared pattern stronger than a TCP-listener probe. The DECLARED pattern is `Listening on` with **no colon**, because the line is version-specific -- v2 logs `Listening on:` and v1 logs `Listening on 3001`, and a rollback crosses versions by definition |
| failure injection | that a dump which fails mid-write leaves no `.tar` under its final name, and that a corrupted dump is refused rather than restored |

## Why it needs root — measured 2026-11-02

Both primitives `tar -C "$mp"` where `$mp` comes from
`docker volume inspect --format '{{.Mountpoint}}'`, i.e. a path under
`/var/lib/docker/volumes/<name>/_data`.

```
$ ls -ld /var/lib/docker
drwx--x--- 12 root root 4096 Oct 26 05:54 /var/lib/docker

$ docker volume create domum-rehearsal-probe
$ ls /var/lib/docker/volumes/domum-rehearsal-probe/_data
  -> NOT readable unprivileged
$ docker volume rm domum-rehearsal-probe
```

The probe used a volume created for the purpose and removed afterwards, so this
is not an artefact of production ownership: **no** volume mountpoint is readable
without root on this host.

## The isolation IS sound, and was checked first

The danger in a rehearsal of this path is that an override fails to take effect
and the real functions dump or restore a **production** volume.
`storage_volume_pre_upgrade_point uptime-kuma` resolves volumes from
`docker inspect` of the running container, so the compose **project** is the
isolation boundary:

```
production : domum-media_traefik-letsencrypt, domum-media_uptime-kuma-data
rehearsal  : domum-rehearsal_traefik-letsencrypt, domum-rehearsal_uptime-kuma-data
```

Both rehearsal names were verified **free**. A rehearsal must assert, before
anything mutating, that every resolved volume name carries the disposable
prefix and that none of them exists yet — the "every root a fixture uses must be
redirected into it, and asserted to be" rule applied to Docker objects rather
than to filesystem paths.

## A rootless variant was considered and REJECTED

A volume can be read without host root by mounting it into a helper container
and tarring it from inside. That would let a rehearsal run unprivileged — and
it would not be driving the production primitives, so it would prove something
adjacent rather than the real path. A fixture-backed probe is not production
evidence, and a helper container reading the volume is a fixture.

Changing the production code to use a helper container was also rejected: the
CLI already runs as root in production, so it would buy nothing there, and it
would change the semantics of a **restore** path — `--numeric-owner`, xattrs
and ACLs behave differently inside a container's user namespace, and
`acme.json`'s mode is exactly what must not change. A restore path is the worst
place to trade correctness for testability.

## A SECOND BLOCKER — structural, and RETIRED 2026-11-12 without privilege

Measured 2026-11-11, and every measurement below is still true. What was wrong
was the conclusion drawn from them: that the rehearsal therefore could not be
written. **It was retired by declaring a NEW `docker-volume` service whose
container name equals its service key, rather than by borrowing a production
one** — see the header. The measurements are kept because they are what forbids
the obvious shortcut of renaming a production container in a fixture.

**The only two `docker-volume` services are traefik and uptime-kuma, and both
are running in production under container names that are unique per daemon.**

```
docker create --name uptime-kuma busybox:latest true
  -> Error response from daemon: Conflict. The container name "/uptime-kuma"
     is already in use by container "823c31d71946…"
  -> rc=1, nothing created, production still 11 containers, uptime-kuma
     Up 41 hours (healthy)
```

So a disposable compose project cannot host either service, because
`compose/monitoring/uptime-kuma.yml` and `compose/proxy/traefik.yml` both set
`container_name` equal to the service key — which is itself a load-bearing
invariant, not an accident.

**And renaming the container in the fixture would defeat the very check the
rehearsal exists to drive.** `stop_compose_services_verified` compares COMPOSE
SERVICE names against `docker ps --format '{{.Names}}'`, and those are the same
only because every service sets `container_name` to its key — measured across
every fragment, and guarded by `tests/operation-lock-smoke.sh` with a negative
control. A fixture that renamed the container would make a running container
read as stopped, which is the dangerous direction and is exactly the failure
the stop verification prevents.

**No managed service offers a way round it.** The three whose names are free —
`docker-socket-proxy`, `tailscale`, `restic-rest-server` — are all declared
`stateless` in `service_state_models`, so none of them reaches the
docker-volume path at all. Taking one and stubbing its state model would add a
second seam on top of `docker_volume_mountpoint`, at which point the "real
container" claim is doing very little work.

## What IS covered, enumerated rather than claimed

The goal's six aspects each have a driven section against real artefacts. The
gap is specifically "against a real disposable CONTAINER", not the behaviours.

| aspect | where | what is real |
|---|---|---|
| ACME key / modes | `volume-recovery-point-smoke` §3, §10 | a real `acme.json` at mode 0600, real `tar --numeric-owner --xattrs --acls`, modes re-checked after restore |
| SQLite / WAL | §5, §6 | a real non-empty `-wal` refuses; a real open handle refuses |
| exact images | §4, §14, §17 | the image id is recorded, loaded FROM the archive, and the loaded id compared to the record; no recorded identity refuses |
| readiness | `volume-upgrade-dispatch-smoke` | the real `service_upgrade` phase 4, including the all-absent UNPROVEN wording |
| failure injection | §5–§8, §11, §15–§17, §20–§23 | bad checksum, missing dump, no identity, wrong model, unreadable volume, failed unpack — each refusing, and the pre-stop verification mutation-tested |
| rollback | §13, §14, §18, §19 | both halves restored, image loaded from the archive, the two rollbacks refusing each other's points |

`docker_volume_mountpoint` is the ONE stubbed seam, and that is the half root
blocks. Everything above runs against real files.

## So the honest status

**Written and passing.** One call is stubbed — `docker_volume_mountpoint`,
which returns a path under `/var/lib/docker` that needs root to read.
Everything it feeds (quiesce, tar, checksum, verify, restore) runs for real
against a real directory, here and in `tests/volume-recovery-point-smoke.sh`
with real xattrs, ACLs and modes.

What a privileged run would add is narrow and worth naming precisely: that
`tar -C` on the path **docker itself reports** behaves as it does on the
equivalent directory. Not the dump logic, not the restore logic, not the
upgrade or the rollback — those are driven here against real containers and
real image ids.

What NO amount of work here retires is upgrading the actual production traefik
or uptime-kuma. That is `VOLUME_UPGRADE_ENABLED=1` plus an application upgrade,
both operator-gated, and the gate is untouched.

A future session should not re-derive the blockers. Both probes are one command
each and both are quoted above; the rehearsal re-checks the root one at run
time and fails if it ever stops being true.

## To unblock

Two things, and they are not the same step.

**For the dump/restore half** (`tar -C <mountpoint>`), one privileged run is
enough: the fixtures already drive both primitives with real tar, real
checksums, real xattrs and ACLs and real modes, and `docker_volume_mountpoint`
is the one stubbed seam. An operator running that half as root closes it.

**For the real-container half there is no privileged step that helps**, because
the blocker is container-name uniqueness rather than permission — see the
section above. It needs one of:

- a service whose container name is free AND whose declared state model is
  `docker-volume`. None exists today: the two volume services are both running,
  and the three free names are all `stateless`;
- or the operator stopping traefik or uptime-kuma for the duration, which is
  application downtime and an approval boundary of its own;
- or accepting a second stub (the state model) on top of
  `docker_volume_mountpoint`, which would make the exercise prove less than the
  fixtures already do — so it is not recommended.

Written as a gated subcommand it would still follow `immich-phase-a`'s pattern:
unique disposable names refused if taken, images pinned by ID, no production
path or volume mounted, teardown asserted.

---

## The two resolution steps are now PROVEN against real Docker objects

Added 2026-11-11: `operator/rehearsals/volume-resolver-real-objects.sh`.

The volume recovery-point chain has three steps, and they do not have the same
blocker:

| step | what it does | privilege |
|---|---|---|
| 1 | `service_named_volumes` -- `docker inspect` of the container | none |
| 2 | `docker_volume_mountpoint` -- `docker volume inspect` | none |
| 3 | `dump_volume_to_file` -- `tar -C <mountpoint>` | **root** |

`tests/volume-recovery-point-smoke.sh` drives 1-3 with real tar, checksums,
xattrs, ACLs and modes -- against a **directory**, with
`docker_volume_mountpoint` as its one stubbed seam. **That stub is now removed
from the chain**: steps 1 and 2 are exercised against a real disposable
container and a real named volume, and the rehearsal additionally asserts that a
**read-only** mount is excluded (a recovery point cannot be built from a volume
the service cannot write) and that an **absent** volume resolves to nothing
rather than to a plausible path, which would otherwise make a dump tar the wrong
directory.

It also makes the **production** measurement read-only, which no fixture can:
both declared `docker-volume` services resolve to exactly one named rw volume
each, and to the ones this design names --
`domum-media_traefik-letsencrypt` at `/letsencrypt` (the ACME account key) and
`domum-media_uptime-kuma-data` at `/app/data` (`kuma.db`).

### Why step 3 needs root, measured rather than asserted

The reason is narrower than "`/var/lib/docker` needs root":

```
/var/lib/docker        drwx--x--- root:root
```

**The group is `root`, not `docker`.** Membership of the `docker` group -- which
this account has -- gives nothing here, so `other` (`---`) applies and `statx`
is denied at `/var/lib/docker/volumes` itself, two components above the
mountpoint. A **bind-type** volume does not help: docker reports the
`/var/lib/docker` Mountpoint whatever the device is, and
`docker_volume_mountpoint` returns the Mountpoint.

The rehearsal **derives** that stopping point at run time rather than hardcoding
it, and if `tar -C` ever succeeds it **fails** with a message saying this
document's claim must be re-measured. A blocker that cannot notice its own
retirement is the stale-claim defect.

### What is still not proven

The tar read, the dump, the restore, and any upgrade or rollback against a real
volume. Those need the one privileged run described above. The container-name
half of the blocker is unchanged and is not retired by privilege: both
`docker-volume` services are running and hold the names a disposable project
would need.
