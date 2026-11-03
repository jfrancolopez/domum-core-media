# Volume upgrade rehearsal — what it would prove, and why it needs root

**Status: NOT WRITTEN. Blocked on root, measured rather than assumed.**

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
| readiness | that uptime-kuma logs `Connected to the database` then `Listening on:` across a real restart, which is what makes its declared pattern stronger than a TCP-listener probe |
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

## To unblock

Write the rehearsal as a gated subcommand following `immich-phase-a`'s pattern
(unique disposable names refused if taken, images pinned by ID, no production
path or volume mounted, teardown asserted) with a stub-based smoke test in
`tests/` that CI can run, and have the operator run the real-container pass
once as root.
