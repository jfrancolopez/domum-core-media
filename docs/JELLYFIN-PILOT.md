# Jellyfin subvolume pilot — runbook

The first directory → Btrfs subvolume conversion on this host. Jellyfin is the
pilot because it is small, fully rebuildable, exercises the real mechanics (a
database, a container bind mount, the snapshot and rollback cycle), and its
valuable data — the media library — lives on `/srv/media`, which this does not
touch.

**Nothing in this document has been executed.**

## Verified before writing this

| Item | Evidence |
|---|---|
| Data path | `service_data_path jellyfin` → `/srv/data/jellyfin` (inode 269, ordinary directory) |
| Size | 600 KB, 37 files |
| Database | `config/data/data/jellyfin.db`, no `-wal`/`-shm` present |
| Container | `jellyfin`, from `service_compose_services` |
| Bind mounts | `/srv/data/jellyfin/config` → `/config` (rw); `/srv/media` → `/media` (ro); `/srv/media/.cache/jellyfin` → `/cache` (rw) |
| Untouched by migration | both `/srv/media` mounts — the media tier is not Btrfs and is out of scope |
| Filesystem | `/srv/data` and `/srv/snapshots` are subvolumes of the same `/dev/sda1` |
| Free space | 717 GB against a 600 KB copy |
| Reflink | proven on this filesystem for one 256 MB file: 0 KiB vs 262,144 KiB. Not proven for the small inline-extent files that make up most of this service — see BTRFS-MIGRATION-PLAN.md |
| Health semantics | Jellyfin defines no healthcheck and no health URL, so `service_is_healthy` means **container running** |

## What the migration proves, and what it does not

`storage migrate-subvolume` hashes **every one of the 37 files** and compares
manifests before cutover, so a successful migration proves the content is
byte-identical. Combined with the container starting, that is strong.

It does **not** prove the application works. With no healthcheck and no health
URL, "healthy" means the container is running. **Open Jellyfin and confirm your
libraries are intact before removing the `.premigration` copy.**

## Step 1 — migrate

```bash
sudo domum-media storage migrate-subvolume jellyfin
```

Expect, in order: preflight → stop → quiesce check → subvolume created →
reflink copy → all 37 files hashed and matched, and type/mode/owner/group and
symlink targets compared across every entry → original preserved at
`/srv/data/jellyfin.premigration` → cutover → restart → container running →
proof snapshot created.

Refuses before changing anything if: the path is already a subvolume, a
`.premigration` or `.new` exists, the snapshot root is on another filesystem,
free space is under 1 GiB, the container will not stop, or a non-empty SQLite
WAL survives the stop.

## Step 2 — confirm the migration

```bash
sudo domum-media report
```

`jellyfin` must move from `unprotected` to `protected` in the snapshot section.
Then open Jellyfin and confirm the libraries load.

## Step 3 — prove rollback, not just snapshots

Creating a snapshot and having a working rollback are **different claims**. This
step exercises the real `domum-media rollback` implementation.

```bash
# a. record the snapshot the migration created
sudo domum-media rollback list

# b. make a harmless, observable change
#    (for example, rename a Jellyfin display collection, or simply:)
sudo touch /srv/data/jellyfin/PILOT-MARKER

# c. confirm the marker exists
ls -l /srv/data/jellyfin/PILOT-MARKER

# d. roll back through the real implementation
sudo domum-media rollback apply <id-from-step-a> --dry-run
sudo domum-media rollback apply <id-from-step-a>

# e. the marker must be GONE, and Jellyfin must start and stay running
ls -l /srv/data/jellyfin/PILOT-MARKER      # expected: No such file
sudo domum-media report
```

The rollback moves the current state aside to
`/srv/data/jellyfin.rollback-<timestamp>` rather than deleting it, so step (e)
is reversible too.

## If anything fails

Every failure path leaves the original readable. The helper cleans up its own
partial artefacts and, if the cutover itself fails, moves the original back.

Manual recovery, if ever needed:

```bash
sudo domum-media compose stop jellyfin
sudo mv /srv/data/jellyfin /srv/data/jellyfin.failed
sudo mv /srv/data/jellyfin.premigration /srv/data/jellyfin
sudo domum-media compose up -d jellyfin
```

> This deliberately does **not** say `docker compose -p domum-media …`. There is
> no `compose.yml` in `/opt/domum-core-media`: the stack is assembled from
> fragments chosen by which services are enabled, so a bare `docker compose`
> there fails with `no configuration file provided: not found` — which is
> exactly the wrong moment to discover that. `domum-media compose` is a
> passthrough that applies the same fragment layering every other command uses.

## Afterwards

`/srv/data/jellyfin.premigration` is retained deliberately and is **never**
removed automatically. Delete it yourself only once Jellyfin has been confirmed
working — it is the only copy of the pre-migration state.

Expected downtime: **seconds**.

## What the proof snapshot proves

The migration's last act before restarting Jellyfin is to take a snapshot of the
newly created subvolume. That is the point of the whole exercise: the service
path could not be snapshotted before, and now it can.

It is taken **while the service is still stopped**, so it is a snapshot of a
cleanly quiesced tree. (It used to be taken after the restart, which made it
crash-consistent — recoverable, since btrfs snapshots are atomic and SQLite
replays its WAL, but weaker than the clean copy for no reason.)

If that snapshot cannot be created the migration still succeeded and the data is
safe, but rollback protection was not established — the command says so and exits
non-zero.

## If the migration aborts

Every abort path restarts the service before exiting, and says so. Nothing is
lost in any of them — the original is at its usual path, or preserved at
`.premigration`.

The one worth expecting is the **quiesce check**. It runs after the containers
have stopped, and refuses if a non-empty SQLite `-wal` remains or
`postgres/postmaster.pid` is still present — evidence the application did not
shut down cleanly. Jellyfin has no `-wal`/`-shm` today, so this is unlikely for
the pilot; Plex (169 KB) and Navidrome (20 KB) carry non-empty WALs while
running, so it is very likely on their turn.

Earlier this check called `die`, which exits the shell outright — so the
recovery branch next to it was unreachable and the service stayed down until
someone noticed. It now returns a failure the caller handles, and the service is
restarted before the command exits. If you ever see the abort message without
the service coming back, start it by hand:

```
sudo domum-media compose up -d jellyfin
```
