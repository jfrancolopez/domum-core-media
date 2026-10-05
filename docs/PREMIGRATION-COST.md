# What the retained `.premigration` copies actually cost

Three services are migrated, so there are three retained originals. Measured
2026-10-05 with `btrfs filesystem du -s`, which reports extent sharing rather than
apparent size.

| | total | **exclusive** | shared |
|---|---|---|---|
| `jellyfin.premigration` | 488 KiB | **0 B** | 488 KiB |
| `kavita.premigration` | 4.32 MiB | **0 B** | 3.81 MiB |
| `navidrome.premigration` | 50.19 MiB | **0 B** | 50.07 MiB |

**Every byte is shared. Deleting all three would free nothing.**

That is not a quirk of timing. `.premigration` is the original directory, renamed;
the live subvolume was made from it with `cp -a --reflink=always`; the proof
snapshot is a read-only snapshot of that. So each extent has at least two
references, and the proof snapshot — which is the recovery point and therefore
stays — holds one of them. `.premigration` will **never** accumulate exclusive
extents, because nothing writes to it.

The live trees show the inverse, which is the useful contrast:

| | total | exclusive | shared |
|---|---|---|---|
| `jellyfin` | 496 KiB | 488 KiB | 8 KiB |
| `kavita` | 4.62 MiB | 1.00 MiB | 3.16 MiB |
| `navidrome` | 50.24 MiB | 68 KiB | 50.06 MiB |

Jellyfin's live tree has diverged most (488 KiB exclusive — ten days of log
rotation), Navidrome's least (68 KiB, migrated six days ago).

## The real cost is the scan, and it is small

```
files under /srv/data        65,781
of which in .premigration     1,120   = 1.7%
```

Restic must `stat` those 1,120 extra files every night. Their content is
byte-identical to each service's proof snapshot, so the repository stores it once
— the cost is the walk, not the storage.

## So there is no cost argument for removing them

Which changes the question. The lifecycle in
[PREMIGRATION-LIFECYCLE.md](PREMIGRATION-LIFECYCLE.md) asks what evidence should
exist before an operator removes one. All of it now holds for all three:

- `.premigration == proof snapshot`, re-verified independently
- the proof snapshot is read-only and its databases open cleanly
- at least one nightly backup has included the migrated tree (six for Navidrome)
- the services have run for days, through a host upgrade and a fleet restart

But the evidence being sufficient is not a reason to act. **Removing them frees
zero bytes and removes one of two independent copies of the pre-migration state.**
The only things it buys are 1.7% off the backup scan and a tidier directory
listing.

The one scenario that would change the calculus: if a proof snapshot were ever
pruned, its `.premigration` would immediately become the sole holder of those
extents — and the only copy of that state. That is an argument for keeping them,
not removing them.

**Recommendation: keep all three. No cleanup is warranted.** Revisit if the
backup scan becomes a real constraint, or if a service's tree grows by orders of
magnitude. Nothing removes them automatically, and nothing should.
