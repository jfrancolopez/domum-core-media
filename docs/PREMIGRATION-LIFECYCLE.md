# `.premigration` — what it costs, and when it may go

A migration moves the original service directory aside to
`/srv/data/<service>.premigration` and **never deletes it**. Neither does any
scheduled job. Removing it is always an operator decision.

## What it actually costs on disk: nothing, at first

Measured on the real Jellyfin artefacts with `btrfs filesystem du`:

```
     Total   Exclusive  Set shared  Filename
 488.00KiB       0.00B   488.00KiB  /srv/data/jellyfin.premigration
 528.00KiB    44.00KiB   484.00KiB  /srv/data/jellyfin
 488.00KiB       0.00B   488.00KiB  /srv/snapshots/jellyfin-…-post-migration
```

**`Exclusive` is 0 B.** The migration copies with `cp -a --reflink=always`, so
every extent in `.premigration` is shared with the live subvolume and the proof
snapshot. Deleting it today would free essentially nothing.

That changes over time. As the live service writes, shared extents un-share and
`.premigration` begins holding data nothing else references. For Jellyfin — 490 KB
and largely static — that is negligible. **For Immich (213 GB, actively written)
it is not**, and a retained `.premigration` there would grow toward a second full
copy. Size the decision per service, not once.

## Who sees it

| subsystem | sees it? | consequence |
|---|---|---|
| restic (nas/archive targets) | **yes** — it is inside `BACKUP_INCLUDE_PATHS` (`/srv/data`) | content dedups, so repo growth is minimal; **file count and scan time grow** |
| `snapshot prune` | **no** — it lives in `/srv/data`, not `/srv/snapshots` | cannot be pruned or mistaken for a snapshot |
| `snapshot_subvolumes` / `snapshot create` | **no** — candidates resolve through `service_data_path` | never snapshotted |
| `report` | **yes** — counted under `migration_leftovers` with total size, as `info` | visible, with the note that it is in every backup |
| `cleanup` | **no** | nothing automatic can remove it |

For a large service the file-count effect is the one that matters: retaining
Immich's `.premigration` would add ~64,000 file entries to every nightly backup
scan, and to restore-verification sampling.

## Evidence required before an operator is offered cleanup

All of these, for the specific service:

1. `.premigration` and the proof snapshot have **identical** manifests — type,
   mode, `uid:gid`, path, size, SHA-256. This is the migration integrity proof.
2. The report shows the service `protected` — meaning a subvolume **and** at least
   one snapshot, not merely a subvolume.
3. The application has been confirmed working *by use*, not only by the container
   running: for Jellyfin, actually playing something.
4. At least one **successful backup run has completed since the migration**, so
   the post-migration state exists somewhere other than this host.
5. For a database-backed service, an integrity check passed against the *live*
   database or a copy of it.

Point 4 is the one most easily skipped and the least recoverable if wrong.

## Cleanup must stay explicit

The project must **never** remove `.premigration` automatically — not on a timer,
not as a side effect of a later migration, not during `cleanup`.

If a command is ever added it must be: service-specific (never "all"), refuse
unless every item above is satisfied, print what it is about to delete and the
evidence it verified, require an explicit confirmation token, and take the
operation lock. Until then, the operator removes it by hand:

```bash
sudo rm -rf /srv/data/<service>.premigration
```

## Current status

`/srv/data/jellyfin.premigration` is **retained**. Conditions 1, 2, 3 and 5 are
satisfied (`docs/JELLYFIN-PILOT-RESULT.md`). Condition 4 is satisfied once the
first nightly backup after 2026-09-25 completes. It costs 0 B exclusive, and
there are 717 GB free, so there is no reason to hurry.
