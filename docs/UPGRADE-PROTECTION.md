# An image upgrade needs a recovery point for the state THAT service mutates

I recommended "the Plex and Calibre-Web image upgrades, through `update`, which is
gated on backup age, health and a snapshot." That was wrong in the way that
matters: **`update` is not the gated path.**

## Two paths deploy a staged image. One was gated.

```
domum-media updates apply   /  domum-media refresh-images
    -> create_service_snapshot "$logical_service" "pre-update"
    -> empty result -> snapshot_protection_unavailable -> die
       (SNAPSHOT_POLICY defaults to REQUIRED)
```

Per service, by name, failing closed. `create_service_snapshot` returns 1 for a
path that is not a subvolume, so this **correctly refuses** Plex and Calibre-Web.

```
domum-media apply
    -> snapshot_create "pre-apply"        <- FLEET-WIDE, and a WARNING on failure
    -> compose up -d --remove-orphans     <- recreates any container whose image changed

domum-media update
    -> repo_update: git fetch + reset --hard origin/main
    -> converge_local_installation
    -> exec /usr/local/bin/domum-media apply
```

`apply` is convergence, and its non-fatal pre-apply snapshot is deliberate — but
`compose up -d` recreates any container whose image has changed, so **`apply` was
an ungated image deployment for every service**, and `update` ends in `apply`.

Measured when this was found:

| | staged image | state path | protection |
|---|---|---|---|
| **plex** | yes | `/srv/data/plex` exists | **unprotected** |
| **calibre-web** | yes | `/srv/data/calibre-web` exists | **unprotected** |
| uptime-kuma | yes | none under `/srv/data` | — (volume, in the recovery pack) |
| traefik | yes | none under `/srv/data` | — (ACME volume, in the recovery pack) |
| jellyfin, kavita, navidrome | no | exist | protected |

So `sudo domum-media apply` would have upgraded four applications, two of them
with no recovery point for the state they were about to migrate.

## The invariant

> An application image upgrade may proceed only when the state **that** application
> may mutate has a recovery point appropriate to **that** application.

A Jellyfin snapshot must never satisfy a Plex upgrade. This is the same defect
class as `immich reset-db` passing on an unrelated snapshot count, so it is
evaluated per service and **never counted**:

- both protected → nothing blocked
- both unprotected → **both** blocked, not just the first
- one protected, one not → the protected one does not clear the other, for
  `unprotected`, `snapshottable` **or** `degraded`

`apply` now refuses before the fleet-wide `up -d`:

```
Refusing: this apply would deploy a staged image for services whose state has no recovery point.
BLOCKED plex unprotected
BLOCKED calibre-web unprotected
...
Either:
  * make the state snapshot-capable first:  sudo domum-media storage migrate-subvolume <service>
  * or deploy through the gated path, which refuses per service:
                                            sudo domum-media updates apply
  * or accept it deliberately:              APPLY_ALLOW_IMAGE_CHANGE=1 sudo domum-media apply
```

**A service with no state path under the protected tier is reported, not blocked.**
Traefik's ACME store and Uptime Kuma's data are Docker volumes that a snapshot
could never cover; what protects them is the recovery pack
([STATE-CLASSIFICATION.md](STATE-CLASSIFICATION.md)). Refusing there would be
refusing the wrong thing. But a path that **exists** whose protection is `unknown`
**is** blocked — "I cannot tell" must never mean "proceed".

Convergence stays usable: no staged image anywhere → no blocker, whatever the
protection states.

## What this changes about Plex

It gives the Plex migration a different purpose. Not another Btrfs experiment —
that is done — but **making a pending application upgrade recoverable**. Plex is
running `ls308` built 2026-06-08 with newer images already pulled; that upgrade is
overdue, and it cannot be done safely while `/srv/data/plex` has no recovery point.

The order is therefore: migrate Plex → its state becomes snapshot-capable → the
upgrade gets a per-service pre-update snapshot and auto-rollback. The same applies
to Calibre-Web, whose 250 KB of state makes the migration cheap even though it
proves nothing new about migration itself.

## Rollback, and what it would actually restore

If an upgrade proceeds with a pre-update snapshot, `refresh_images` records a
rollback entry and, on a failed health check, calls
`restore_snapshot_for_service`. That restores **data**:

- the live tree is moved to `<path>.rollback-<stamp>`, never deleted
- the snapshot is restored in its place
- the service is brought back with `compose start`, so the image cannot change —
  which means it comes back on the **new** image

That is recorded honestly as `rolled_back_data_only`, and it is why a recovery
point is `service + snapshot + the image that wrote it`
([RECOVERY-POINT-IDENTITY.md](RECOVERY-POINT-IDENTITY.md)). For an application
that migrates its schema on startup — as Kavita did, 0.9.0.2 → 0.9.1.0 — a data
rollback under the new image gets forward-migrated again. Backlog task-24 is the
fix; until then the limitation is stated rather than implied.

## Coverage

`tests/upgrade-protection-gate-smoke.sh`. Seven mutants killed: the refusal
disabled, the protection requirement dropped, the no-state case conflated with
the blocked case, the gate moved after the deployment, the per-service snapshot
swapped for the fleet-wide one, `SNAPSHOT_POLICY` defaulted to `WARN`, and the
override forced on.

One equivalent mutant is recorded rather than chased: appending `|| true` to the
refusal's call site. `die` runs `exit`, which `|| true` cannot suppress —
demonstrated, not assumed.

The refusal is a function, `apply_assert_staged_images_recoverable`, so the test
runs it. The first version of the test only checked that `apply` *called* the
blocker list and that the call preceded `up -d`; disabling the refusal survived,
because the list was still built and nothing noticed its result was ignored.
