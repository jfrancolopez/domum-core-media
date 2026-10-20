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

## 2. Expected duration

Not hours. The device is a SATA SSD with a sequential read ceiling of
~550 MB/s (SATA 6 Gb/s link), and btrfs scrub on a SATA SSD typically sustains
300–500 MB/s while checksum-verifying.

| sustained rate | 215.9 GiB takes |
|---|---|
| 550 MB/s (link ceiling) | ~7 min |
| 400 MB/s (likely) | ~10 min |
| 250 MB/s (contended) | ~16 min |
| 100 MB/s (pessimistic) | ~40 min |

**Plan for 10–20 minutes; treat anything past 45 as worth investigating.**

This is an estimate from the device class, not a measurement — nothing on this
host has ever scrubbed, so there is no local rate to quote. **The first run is
the measurement**: `btrfs scrub status /srv/data` reports the achieved rate and
`btrfs scrub status -R /srv/data` the raw counters. Record the real figure here
afterwards and delete the table above if it turns out to be wrong.

`checkup`'s remedy used to say *"takes hours"*. That is wrong by roughly an
order of magnitude for this device, and it is the mistake this project already
has a rule about: *a remedy that reads as expensive does not get run*. A
10-minute read-only verification of 23,155 irreplaceable originals is the
cheapest safety work available here.

It is now derived rather than asserted. `btrfs_scrub_estimate` reads the
`Total to scrub:` line out of `btrfs scrub status` — so the operator is told
the size **this** filesystem reported, not a guess — and picks the rate from the
device's own `/sys/block/<dev>/queue/rotational` flag, 400 MB/s solid-state
against 100 MB/s spinning. The production remedy now reads:

```
btrfs scrub start /srv/data   # read-only, ~10 min for the 215.87GiB it reports;
                              # detects checksum errors but cannot repair
                              # without a second copy
```

Dividing bytes by a rate is legitimate here, unlike the `verify-large` estimate
that had to simulate its own packing: a scrub is one pass over the allocated
extents, with no per-run count cap and nothing it cannot split, so the division
*is* the mechanism. When the size cannot be parsed the clause is omitted
entirely rather than printed as `~0 min`.

## 3. IO impact and which applications feel it

A scrub is **read-only**. It never writes, never moves data, and cannot be the
cause of corruption. It can be cancelled (`btrfs scrub cancel`) and resumed
(`btrfs scrub resume`); cancelling loses only progress.

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

**Recommendation for the first run: do not limit it.** Ten unthrottled minutes
at a quiet time is less disruption than twenty-six throttled ones, and an
unthrottled run is also the clean measurement that section 2 is missing. Keep
`--limit` for the recurring schedule, or for a re-run if the first one proves
disruptive in practice.

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

## 7. Proposed recurring schedule — not enabled

Monthly, read-only, throughput-limited, outside every existing window:

```
# domum-media-btrfs-scrub.timer
# first Sunday of the month, 05:30 -- after the Sun 04:30 prune has finished
OnCalendar=Sun *-*-01..07 05:30:00
RandomizedDelaySec=20m
Persistent=true

# domum-media-btrfs-scrub.service
Type=oneshot
RequiresMountsFor=/srv/data
ExecStart=/usr/bin/btrfs scrub start -B --limit 150M /srv/data
```

`systemd-analyze calendar 'Sun *-*-01..07 05:30:00'` confirms the expression
normalizes and next elapses Sun 2026-11-01 05:30 EST.

`-B` (do not background) is required: without it `btrfs scrub start` returns
immediately and the unit would report success before the scrub had read
anything — a unit that is green because it did not wait. With `-B` the exit
status is the scrub's own, and `btrfs-scrub(8)` documents **exit 3 as "scrub
found uncorrectable errors"** (1 = could not be performed, 2 = nothing to
resume). So the unit fails exactly when there is something to say, and
`checkup_systemd_health` reports a failed domum unit as CRITICAL — which is
what turns a kernel message nobody reads into one mail.

`RequiresMountsFor=/srv/data` and nothing else: this job touches no other root,
and declaring `/srv/snapshots` would let a failure of a filesystem it does not
read stop it. (It is the same filesystem anyway — section 1.)

Rationale, and why monthly rather than weekly:

- At ~10–20 minutes read-only, the cost is near zero, so the schedule is driven
  by how long silent corruption is allowed to go unnoticed, not by expense.
  Monthly bounds that at 31 days.
- Weekly would collide with the three jobs already on Sunday and buys little:
  bit-rot on an SSD at 24% capacity is a slow-moving risk.
- **`Persistent=true` means a missed run fires at the next boot.** For a
  read-only job that is harmless — unlike `snapshot prune`, which deletes.
  Still, a scrub starting unexpectedly after a reboot is surprising, so the
  randomized delay keeps it off the boot critical path.
- No `OnBootSec`/`OnStartupSec`, and no `WantedBy` on the service: the rule that
  a reboot must not become an image-deployment vector applies to every unit this
  project installs.

**This unit does not exist and is not installed.** Writing and installing it is
separate work, and enabling a timer is an operator action. The first scrub
should be run by hand and its real rate recorded in section 2 before any
schedule is committed to.

## 8. The one operator command

```
sudo btrfs scrub start /srv/data
```

Then, whenever convenient:

```
sudo btrfs scrub status /srv/data
```

`scrub start` returns immediately; the work runs in the kernel. Nothing needs to
stay open, no service needs stopping, and the result is persistent — it survives
a reboot and is what `checkup` reads afterwards.

Add `--limit 150M` if the host is busy and the latency matters more than
finishing in ten minutes.
