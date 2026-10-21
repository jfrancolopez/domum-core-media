# Btrfs scrub plan — `/dev/sda1` (the protected tier)

Planning document. **No scrub has been started.** Running one is an operator
action; this file exists so the decision is made from measurement rather than
from the word "hours".

## 1. What is being scrubbed, and how much of it

Measured 2026-10-20, read-only, no root required:

```
$ findmnt -no SOURCE,FSTYPE,UUID,TARGET --target /srv/data
/dev/sda1[/@data] btrfs 211e06b3-6aaf-40d8-8646-9361b8399eb2 /srv/data
$ findmnt -no SOURCE,FSTYPE,UUID,TARGET --target /srv/snapshots
/dev/sda1[/@snapshots] btrfs 211e06b3-6aaf-40d8-8646-9361b8399eb2 /srv/snapshots

$ btrfs filesystem df /srv/data
Data, single: total=218.01GiB, used=215.26GiB
System, DUP: total=8.00MiB, used=48.00KiB
Metadata, DUP: total=1.00GiB, used=313.98MiB
GlobalReserve, single: total=242.33MiB, used=0.00B
```

`/srv/data` and `/srv/snapshots` are two subvolumes of **one** filesystem on
**one** partition on **one** physical device — a `Samsung SSD 870 EVO 1TB`
(SATA, non-rotational). So:

- **One scrub covers both roots, every subvolume, and every snapshot.** Scrub
  works on the filesystem, not the directory tree, and reads each allocated
  extent once. Extents shared between a service subvolume, its `.premigration`
  copy and its proof snapshot are read once, not three times.
- **Scrubbing `/srv/snapshots` separately would re-read the same 215.87 GiB for
  nothing.** This is already enforced in `checkup_btrfs_health`, which dedups on
  the filesystem UUID; before that fix it emitted two identical warnings and told
  the operator to run two scrubs.

Total to scrub ≈ **215.9 GiB** = 215.26 GiB of data + both DUP copies of the
313.98 MiB of metadata.

## 2. Duration — MEASURED

**The first scrub ran 2026-10-21 and the plan no longer needs an estimate.**

```
Scrub started:    Wed Oct 21 10:24:23 2026
Status:           finished
Duration:         0:07:14
Total to scrub:   215.87GiB
Rate:             509.34MiB/s
Error summary:    no errors found
```

**7 minutes 14 seconds. 215.87 GiB. Zero errors.** `worst result 0`, exit 0.
That is 23,155 irreplaceable originals verified against their stored checksums
for the first time in this host's life.

509.34 MiB/s is about 534 MB/s — close to the ~550 MB/s SATA 6 Gb/s link
ceiling, i.e. the scrub is link-bound, not CPU- or checksum-bound.

The estimate `btrfs_scrub_estimate` produced beforehand was **~10 minutes**, from
a conservative 400 MB/s constant for a non-rotational device. It over-stated the
cost by about 38%, which is the safe direction for a planning figure: an
estimate that under-promises does not deter the operator from running the thing.
The *mechanism* — one sequential pass over the allocated extents, divided by a
rate chosen from the device's rotational flag — was correct.

The 400 MB/s constant is deliberately **not** raised to match. It is a generic
figure for any SATA SSD this code might run on, and a conservative planning
number is worth more than one tuned to a single measurement. (A self-calibrating
version is possible — once a scrub has completed, `btrfs scrub status` reports
the achieved `Rate:`, so the estimate could use the last real figure and fall
back to the constant. That is deliberately not built: it is churn, and the
constant is already honest about being an estimate.)

## 3. IO impact and which applications feel it

**A scrub is READ-WRITE, and this document said the opposite.** The claim
"read-only ... never writes ... cannot be the cause of corruption" was wrong,
and the implementation does **not** pass `-r`:

```
btrfs scrub start -B ${limit:+--limit "$limit"} "$root"
```

`btrfs-scrub(8)`: *"read-write scrub will also automatically repair any damage
by copying verified good data from one of the other replicas."* Metadata and
System here are **DUP** — a replicated profile — so a default scrub **writes**:
a corrupt metadata block is rewritten from its second copy.

What that means per profile, from section 1:

| profile | on a checksum error | writes? |
|---|---|---|
| `Metadata: DUP` | **corrected** from the second copy, counted in `corrected_errors` | **yes** |
| `System: DUP` | corrected, same mechanism | **yes** |
| `Data: single` | reported, counted in `uncorrectable_errors` — no second copy exists | no |

So on this host a scrub **repairs metadata and cannot repair data**, and
`exit 3` ("uncorrectable errors found") means **data** corruption specifically,
because a metadata error would have been corrected and exited 0.

**`-r` is deliberately not passed.** Refusing to fix metadata the filesystem
*can* fix would leave it knowingly damaged. If a read-only detection pass is
ever wanted — on a disk already suspected of failing, where writing is the
thing to avoid — `sudo btrfs scrub start -r -B /srv/data` does that directly;
the CLI does not wrap it, because a second mode is a second thing to get wrong.

It can be cancelled (`btrfs scrub cancel`) and resumed (`btrfs scrub resume`);
cancelling loses only progress.

Every container that binds `/srv/data` shares the device: Immich (library and
PostgreSQL), Plex, Jellyfin, Kavita, Navidrome, Calibre-Web. On an SSD at 24%
used, with these workloads being light and seek-free, the expected impact is
small — but a scrub saturating the SATA link will add latency to a Plex
transcode or an Immich ML job.

**Do not reach for `ionice`. On this host it does nothing.** The obvious
throttle is `btrfs scrub start -c 3 …` (ionice class idle), and it would be
silently ineffective here:

```
$ cat /sys/block/sda/queue/scheduler
none [mq-deadline]
```

`btrfs-scrub(8)` is explicit — ionice "may not be generally supported by all IO
schedulers and the options to btrfs scrub start may not work as expected", the
only scheduler known to support it is BFQ, and for mq-deadline it recommends
the cgroup2 IO controller instead. A flag that describes a protection it does
not provide is the defect family this project keeps correcting, so it is named
here rather than quietly included in the command.

The lever that **does** work on any scheduler is btrfs-progs' own throughput
limit (`btrfs-progs v6.14` here, so it is available):

```
btrfs scrub start --limit 150M /srv/data     # 150 MB/s per device
```

It resets to the previous value when the scrub finishes, so it leaves no
persistent state. The cost is duration: at 150 MB/s the 215.9 GiB takes ~26
minutes instead of ~10.

**That recommendation was followed, and the measurement is in.** The first run
was unthrottled, at 10:24 on a working day, **with all eleven containers up**,
and finished in 7m14s at 509.34 MiB/s.

**The scheduled unit keeps `--limit 150M` anyway, deliberately.** One
unthrottled run proves the scrub *completes* quickly; it does not measure what
it cost the eleven containers sharing the device, and nobody was watching
latency at the time. A manual run is supervised — the operator is sitting there
and can cancel it — while a scheduled one fires unattended at 05:30 on a
Sunday. Those are different risk profiles, and the conservative figure is the
right default for the unattended one.

At 150 MB/s the monthly pass is about 26 minutes instead of 7. That is the price
of not having measured the contention, and it is cheap.

**What would justify raising or removing it**, in order of strength:

1. a scheduled run completing with no observed effect on any service — which
   needs the timer enabled first, so this is evidence that accumulates *after*
   the decision, not before it;
2. an unthrottled run performed deliberately while watching service latency,
   rather than incidentally;
3. nothing else. "It finished fast once" is not evidence about contention.

Until one of those exists, the limit stays. This is the "quote the figure for
the cap that BINDS" rule applied to a different kind of cap: the binding
constraint on an unattended job is not how fast it *can* run.

**Avoid these windows**, which are the host's own scheduled IO:

| window | job |
|---|---|
| 02:31 – ~02:40 daily | restic backup (`domum-media-backup`) |
| Sun 04:30 +20m | `snapshot prune` — a live deleting job |
| Sun (weekly) | restic integrity check |
| Sun (weekly) | host update, weekly report + `health-notify` |

Also avoid running it during an active photo upload: originals ingested
mid-scrub are simply not in the scrubbed set, which is not a defect but makes
the result harder to reason about.

## 4. How to monitor it

```
btrfs scrub status /srv/data          # progress, rate, ETA, error summary
btrfs scrub status -R /srv/data       # raw per-counter detail
btrfs device stats /srv/data          # persistent error counters
journalctl -k --since "1 hour ago" | grep -i btrfs   # the kernel names bad files
```

All four need root. `btrfs filesystem df` does not, which is why the facts in
section 1 could be measured without privilege.

Status is persistent: the result survives a reboot and is what
`checkup_btrfs_health` reads afterwards to replace *"has NEVER been scrubbed"*
with an age in days.

**`Error summary: no errors found` is printed for a scrub that never ran.** It
must never be read as a clean result on its own — check for a `Scrub started:`
line first. `checkup` already does.

## 5. What a checksum error actually means here

Btrfs stores a checksum for every data block and every metadata block and
verifies it on read. A scrub reads all of them deliberately, instead of waiting
for an application to happen to touch the bad one.

The profiles in section 1 decide what can be done about a failure, and they
differ:

| profile | what it holds | repairable by scrub? |
|---|---|---|
| `Metadata: DUP` | directory structure, extent tree, checksums | **Yes** — a second copy exists and scrub rewrites the bad one |
| `System: DUP` | chunk tree | **Yes**, same reason |
| `Data: single` | **the photo library and all service state** | **No** — there is no second copy |

So an unrepairable data error is the realistic case, and the honest statement
is: **a scrub on this host detects silent corruption in the family photo
library but cannot repair it.** Detection is still the point — a corrupt
original that nothing ever reads is a file that silently fails to restore years
from now, and the only thing that can repair it is a copy from somewhere else.

Both DUP metadata copies are on the same physical SSD, so DUP protects against
a bad block, not against the device failing.

A non-zero `corruption_errs` in `btrfs device stats` is a checksum failure on
the photo tier. `checkup_btrfs_health` reports it as one.

## 6. If a scrub finds something

1. **Do not run another scrub, and do not reboot.** Capture the evidence first:
   `btrfs scrub status -R`, `btrfs device stats`, and the kernel log, which
   names the affected file as
   `csum failed ... path: /srv/data/immich/library/...`.
2. **Classify it by profile**, per section 5. A metadata error that scrub
   already corrected is reported as fixed (`corrected_errors`); an uncorrectable
   data error names a file.
3. **Restore the named file from restic** — and here the backup scope
   decides whether that is possible:

   | the corrupt file is under | restorable from Hetzner? |
   |---|---|
   | `/srv/data/immich/library` | **Yes** — in the cloud target's include set |
   | `/srv/data/immich/backup-staging` | **Yes** |
   | `$RECOVERY_PACK_DEST` | **Yes** |
   | `/srv/data/backups/images` (exact-image archives) | **No — NOT COVERED** |
   | `/srv/data/{plex,jellyfin,kavita,navidrome,calibre-web}` | **No — NOT COVERED** |

   That is the finding from the backup-scope correction: the cloud target is
   immich-only by design. For the five migrated services the local proof
   snapshot and `.premigration` copy are the only other copies, and they are on
   the same SSD.
4. **Check SMART** (`smartctl -a /dev/sda`). A checksum error with a clean SMART
   report is a different situation from one alongside reallocated sectors.
5. A single corrected metadata error is not an emergency. **Repeated or growing
   counters are a device-replacement signal**, not a scrub-again signal.

## 7. The recurring schedule — written, NOT installed, NOT enabled

`systemd/domum-media-btrfs-scrub.service` and `.timer` now exist in the
repository. Neither is installed on the host and the timer is **not** in
`systemd/auto-enable.timers`, so installation and convergence cannot enable it.

```
# domum-media-btrfs-scrub.timer
OnCalendar=Sun *-*-01..07 05:30:00     # first Sunday, after the 04:30 prune
RandomizedDelaySec=20m
Persistent=true

# domum-media-btrfs-scrub.service
Type=oneshot
RequiresMountsFor=/srv/data
ExecStart=/usr/local/bin/domum-media storage scrub start --limit 150M
TimeoutStartSec=6h
```

`systemd-analyze verify` passes on both, and
`systemd-analyze calendar 'Sun *-*-01..07 05:30:00'` next elapses
Sun 2026-11-01 05:30 EST.

Four deliberate decisions, each asserted by a test:

- **No `-` prefix on `ExecStart`.** `storage scrub start` exits 3 when
  uncorrectable errors are found, which must leave the unit **failed** —
  that is what `checkup_systemd_health` reports as CRITICAL and what
  `health-notify` mails. Tolerating it would make the one thing worth being
  told about invisible.
- **It blocks.** `storage scrub start` passes `-B` internally. Without it
  `btrfs scrub start` returns immediately and the unit would go green before
  reading a single block. A mutation removing `-B` is required to fail.
- **`RequiresMountsFor=/srv/data` only.** `/srv/data` identifies the
  filesystem and the scrub covers every subvolume on it, so requiring
  `/srv/snapshots` could only block a scrub of a filesystem that is mounted
  and healthy — trading this host's one corruption-detection pass for a
  dependency it does not need. Asserted in both directions.
- **Not auto-enabled.** It is protective and low-cost, which would normally
  qualify it, but enabling it means a scrub *will* start unattended. A test
  requires the unit file to exist and the timer to be absent from the list, so
  the assertion cannot pass vacuously.

Why monthly rather than weekly:

- At ~10–26 minutes the cost is near zero, so the interval is set by
  how long silent corruption may go unnoticed, not by expense. Monthly bounds
  that at 31 days.
- Weekly would collide with the three jobs already on Sunday and buys little:
  bit-rot on an SSD at 24% capacity is slow-moving.
- `Persistent=true` means a missed run fires at the next boot. Harmless for a
  job that deletes nothing — unlike `snapshot prune`, which does — and the randomized
  delay keeps it off the boot critical path. No `OnBootSec=`/`OnStartupSec=`,
  and no `WantedBy=` on the service.

**That precondition is now satisfied.** The first scrub was run by hand on
2026-10-21, came back clean, and its real rate is recorded in section 2. The
monthly schedule is therefore justified by measurement rather than by argument:
a 7-minute verification pass, once a month, over the only copy of the family photo
library.

Enabling it is still an operator action, and it needs the unit files
**installed** first — `operator/domum-media-deploy-reporting-fixes.sh` does not
carry them, deliberately, so a deployment cannot install a timer nobody asked
for. Installing a unit is not enabling it; both steps are the operator's.

## 8. The one operator command

`domum-media storage scrub` is **not in the deployed binary yet** — production
is at `8054ea0` and the subcommand lands with the next deployment. Until then,
and this works today:

```
sudo btrfs scrub start /srv/data
sudo btrfs scrub status /srv/data
```

`scrub start` without `-B` returns immediately; the work continues in the
kernel and the result is persistent, so `scrub status` can be checked whenever
convenient. Nothing needs to stay open and no service needs stopping. Add
`--limit 150M` if the host is busy and latency matters more than finishing in
ten minutes.

After the next deployment, the same thing with the dedup, the estimate, the
profile warning and a meaningful exit status:

```
sudo domum-media storage scrub status     # genuinely read-only: reports, scrubs nothing
sudo domum-media storage scrub start      # blocks; 0 clean, 1 failed, 3 errors found
```

The CLI form is what the timer uses, and it is the one implementation of the
per-filesystem dedup — `checkup` reads the same `btrfs_unique_roots`, so the
two cannot disagree about how many filesystems there are.
