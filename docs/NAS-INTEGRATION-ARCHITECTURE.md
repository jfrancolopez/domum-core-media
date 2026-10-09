# NAS integration — architecture, not implementation

**Status: PLANNING ONLY.** Nothing here is implemented, no mount is configured,
no path is moved. Measured 2026-10-09.

---

## 1. The question is not capacity

The obvious reason to add a NAS is space. On this host that reason does not
exist yet:

| Filesystem | Device | Size | Used | Avail | Use% |
|---|---|---:|---:|---:|---:|
| `/srv/data` (btrfs `@data`) | `/dev/sda1` | 931.5 GiB | 214.7 | 715.4 | 24% |
| `/` (ext4, holds `/srv/media` and `/var/lib/docker`) | `/dev/sdb2` | 452 GiB | 59 | 371 | 14% |
| `/srv/snapshots` (btrfs `@snapshots`) | `/dev/sda1` | same filesystem as `/srv/data` | | | |

And the "replaceable media" tier is tiny:

```
/srv/media/music   975 MiB
/srv/media/books   496 KiB
```

`/srv/media` is **not a separate mount**. It is a plain directory on `/`, which
is why `RequiresMountsFor=/srv/media` would resolve to `-.mount` and add
nothing. The library that *would* grow — films, television — does not exist on
this host yet.

So the real question is **which tier a NAS would serve, and what protection
that tier would gain or lose**. Space is not the constraint; the protection
model is.

---

## 2. What currently binds the media tier

Measured across all running containers:

| Container | Bind | Mode |
|---|---|---|
| plex | `/srv/media` → `/media` | **ro** |
| plex | `/srv/media/.cache/plex-transcode` → `/transcode` | rw |
| jellyfin | `/srv/media` → `/media` | **ro** |
| jellyfin | `/srv/media/.cache/jellyfin` → `/cache` | rw |
| kavita | `/srv/media/books` → `/books` | **ro** |
| navidrome | `/srv/media/music` → `/music` | **ro** |
| calibre-web | `/srv/media/books` → `/books` | rw |

Five services read it; only `calibre-web` writes to the library itself, and the
two rw `.cache` paths are regenerable transcode/cache scratch.

This is the tier a NAS fits: **mostly read-only, reacquirable, and the one that
grows without bound.**

---

## 3. The three failure modes that must be designed against

These are not hypothetical. Each is a defect this project has already hit on
local storage, and a network filesystem makes every one of them easier.

### 3.1 A silent backup of an empty directory

`BACKUP_INCLUDE_PATHS` is `/srv/data`. restic walks paths; it does not verify
that a path is *mounted*. If a protected-tier path were moved onto a NAS and
that NAS were absent at 02:31, restic would back up an **empty directory** and
report `snapshot … saved` with a tiny incremental. The daily log would look
normal — current runs add 10–60 MiB, so a near-empty run is not visibly
anomalous.

This is the same shape as the `--one-file-system` hazard already banned in
`CLAUDE.md`: one condition silently drops the highest-value data while the
backup still reports success.

**Requirement:** any backup root that can be a network mount must be asserted
*mounted and non-empty* before the run, and the run must **refuse**, not warn.
A mount check is not optional metadata; it is a precondition.

### 3.2 Containers creating bind sources on the OS disk

Containers are `restart: unless-stopped`, so the Docker daemon starts them at
boot without compose. `systemd/docker.service.d/10-domum-require-mounts.conf`
makes `docker.service` require `/srv/data` for exactly this reason: with the
mount absent, Docker would create the bind-mount sources as empty directories
on `/` and every service would come up as a fresh install — hidden later when
the real mount lands.

A NAS mount has a strictly worse failure profile than a local disk: it can be
absent because of a cable, a switch, a DHCP lease or a NAS reboot, none of which
stop this host from booting.

**Requirement:** every NAS path bound into a container gets an explicit
`RequiresMountsFor=` on `docker.service`, scoped to what it needs, and the fstab
entry **never** carries `nofail`. The existing rule — *a mount dependency
belongs on the unit that needs the path, scoped to what it needs* — applies
unchanged. Note that this couples Docker's availability to the NAS: if the NAS
is down, **no container starts**. That is the correct trade for a path whose
silent absence corrupts state, and the wrong trade for one whose absence is
merely inconvenient, which is why the scope matters more here than anywhere
else.

### 3.3 Losing Btrfs protection by moving a protected path

NFS and SMB have no subvolumes, no snapshots and no reflinks. Moving any
migrated service's state onto a NAS would **silently undo** the migration work:
`domum_is_subvolume` would return false, `create_service_snapshot` would skip,
and per-service rollback protection would revert to DEGRADED.

`storage protection` would report this correctly — it exits 0 only for
genuinely protected state — but only if someone ran it.

**Requirement:** the protected tier (`/srv/data`) **stays on local Btrfs**.
This is not a performance preference; a NAS cannot host the snapshot model the
recovery design rests on.

---

## 4. The architecture that follows

```
LOCAL  /dev/sda1  btrfs  @data      -> /srv/data       PROTECTED TIER
                                       Immich (213.26 GiB, 99.3% of the tier),
                                       all service state, image archives.
                                       Snapshots, reflinks, restic source.
                                       NEVER on a NAS.

LOCAL  /dev/sda1  btrfs  @snapshots -> /srv/snapshots  recovery points
                                       Zero containers bind this. Stays local
                                       with the subvolumes it snapshots.

LOCAL  /dev/sdb2  ext4              -> /  (/var/lib/docker, /srv/media today)
                                       Docker volumes for traefik and
                                       uptime-kuma live here.

NAS    network                      -> /srv/nas/media  REACQUIRABLE TIER
                                       Films, television, music, books.
                                       Mounted read-only into plex, jellyfin,
                                       kavita, navidrome. Not in the restic set.
```

The split is by **recovery cost**, which is the split the project already uses:

- `/srv/data` is irreplaceable, small enough to back up off-host (212.4 GiB
  today, ~130 GiB if the derivative exclusion is applied), and must keep
  snapshots.
- A NAS media library is large and reacquirable, so it is backed up by *being
  reacquirable* — not by restic. Putting it in the restic set would multiply the
  Hetzner bill for data whose recovery plan is "download it again".

**Immich originals stay local.** They are the one large dataset that is
irreplaceable, and they are the reason the protected tier exists. Moving them to
a NAS would trade the entire snapshot and backup model for space this host does
not need. If Immich ever outgrows 931 GiB, the answer is a larger local Btrfs
device, not a network filesystem.

---

## 5. What `/srv/media` becomes

Today's `/srv/media` is ~976 MiB of music and books on `/`, bound read-only into
four services and read-write into `calibre-web`.

Two options, and the second is preferred:

1. **Move `/srv/media` to the NAS.** Saves ~1 GiB of a disk with 371 GiB free —
   no benefit — while adding a mount dependency to five containers. Rejected on
   those grounds.
2. **Leave `/srv/media` where it is; mount the NAS at a new path
   (`/srv/nas/media`) and add it as an additional, read-only source.** No
   existing bind changes, no existing service gains a new failure mode, and the
   NAS can be absent without affecting anything that works today. The rw
   `calibre-web` books path and the two `.cache` paths stay local, which is
   where writable and regenerable things belong.

Option 2 keeps the blast radius of a NAS outage to "the new library is
unavailable", rather than "four media services fail to start".

---

## 6. Open questions, to be answered before any implementation

| Question | Why it blocks |
|---|---|
| NFS or SMB? | Determines UID/GID mapping, which determines whether `ro` binds actually work for the container users. |
| Does the NAS stay powered and reachable at this host's boot time? | Decides whether `RequiresMountsFor=` is safe or turns a NAS outage into a total service outage. |
| What is the NAS's own backup/redundancy story? | "Reacquirable" must be *true*. If the NAS holds the only copy of something irreplaceable, it is a protected tier and this whole design changes. |
| Will anything write to the NAS? | A writable NAS path is state, and state needs a recovery model. The design above assumes read-only. |
| Does `restic` need to see any of it? | If yes, §3.1's mount precondition must be built **first**. |

---

## 7. Explicitly not decided here

- No mount is configured and no fstab entry is proposed.
- No path is moved.
- Immich originals are **not** moving to the NAS.
- `/srv/data` and `/srv/snapshots` stay on local Btrfs.
- No change to `BACKUP_INCLUDE_PATHS` or any exclusion.

Implementation requires operator approval and, by §3.1, a mounted-and-non-empty
precondition on any backup root that could become a network mount — which does
not exist yet and would be the first thing to build.
