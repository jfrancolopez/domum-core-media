# Kavita — migration #2, and what it is being used to prove

Jellyfin proved that the algorithm works on real Btrfs. Kavita is the first
migration where the *implementation* makes its own integrity claim, and the first
where an **application-level** health signal exists to check afterwards.

Measured on 2026-09-28 15:30 EDT, read-only.

## Why Kavita

| | files | bytes | non-empty `-wal` | symlinks | nested subvols | docker health |
|---|---|---|---|---|---|---|
| **kavita** | 82 | 4,529,083 | **0** | **0** | 0 | **healthy** |
| calibre-web | 6 | ~244 K | 0 | 0 | 0 | none |
| navidrome | 1,006 | ~51 M | 1 | 0 | 0 | none |
| plex | 121 | ~271 M | 2 | 7 | 0 | none |

Small, no symlinks, no nesting, no dirty WAL — and the only candidate whose
container healthcheck can actually fail.

## The healthcheck, and the defect finding it exposed

```
Test        ["CMD-SHELL", "curl -fsS http://localhost:5000/api/health || exit 1"]
Interval    30s     Timeout 15s     StartPeriod 30s     Retries 3
Last output "Ok"  (exit 0, FailingStreak 0)
```

That is a real HTTP request to the running application, not a process check.

**It was being thrown away.** `service_is_healthy` rejected only `unhealthy`, so
Docker's `starting` — which is what it reports for the whole 30-second
`StartPeriod` after a restart — read as healthy, and `wait_for_service_health`
returned on its **first** poll before the healthcheck had run even once. The
migration would have reported health it had never observed, on the one service
chosen because its health can be observed.

Health is now three answers, not two:

| state | meaning | `service_is_healthy` |
|---|---|---|
| `healthy` | the container healthcheck passed | yes |
| `starting` | it has not run yet, or not passed yet | **no** — keep waiting |
| `unhealthy` | it failed | no |
| `stopped` | not running, or no container | no |
| `none` | **no healthcheck exists**; running is the whole claim | yes |

`none` stays distinct from `healthy` on purpose: jellyfin, plex, navidrome,
calibre-web and traefik have no healthcheck, so nothing may report their
application as verified. Across a multi-container service the precedence is
`unhealthy > starting > healthy > none`, so one of Immich's four containers still
starting means Immich is still starting.

`checkup` reports `starting` as starting rather than as a warning, or every
restart would make the report cry wolf.

## The databases

Both are WAL mode. `kavita.db` (1,024,000 bytes, 82 tables, 250 pages) is the
library; `cache.db` (16,384 bytes, 2 tables) is disposable.

```
kavita.db   integrity_check=ok   foreign_key_check=0 violations   no sidecars present
cache.db    integrity_check=ok   foreign_key_check=0 violations   -wal 0 bytes, -shm 32768
```

Checked from **copies**, never in place. That is not fastidiousness:

```
before a read-only open :  w.db
while open (mode=ro)    :  w.db  w.db-shm  w.db-wal
after close             :  w.db  w.db-shm  w.db-wal     <- they persist
```

Opening a WAL database **creates and leaves sidecars**, even read-only. Doing
that inside `.premigration` would make the preserved original differ from the
proof snapshot — the act of verifying the integrity claim would break it.

`kavita.db` currently has **no** `-wal`/`-shm` at all, which means no connection
is open: Kavita's connection pool checkpoints and closes. That is convenient and
it is **not** a guarantee — a sidecar can appear at any moment, which is exactly
why the check that matters runs *after* the service has stopped, not before.

## The sequence, and where each step lives

`preflight-only` evidence is evidence, never a substitute for the gates below.
Everything marked *impl* is in `bin/domum-media` and covered by CI.

| # | step | where |
|---|---|---|
| 1 | allowlist, path resolution, media-tier refusal, data-root containment | impl |
| 2 | already-a-subvolume refusal, same-filesystem check | impl |
| 3 | **operation lock**, refused immediately rather than waited on | impl |
| 4 | `.premigration` / `.new` leftovers refused | impl |
| 5 | free space ≥ 1 GiB | impl |
| 6 | scheduled-job window | operator script (the lock is the real mechanism) |
| 7 | topology captured | operator script, via `storage topology` |
| 8 | stop the service | impl |
| 9 | **prove it stopped** (SIGPIPE-proof) | impl |
| 10 | no process holds files open, via `/proc/*/fd` | impl |
| 11 | **no non-empty WAL**, no `postmaster.pid` | impl |
| 12 | create `.new` subvolume | impl |
| 13 | `cp -a --reflink=always` | impl |
| 14 | count, bytes, **all 82 file hashes**, source vs destination | impl |
| 15 | metadata: type, mode, owner, group, symlink targets | impl |
| 16 | preserve the original as `.premigration` | impl |
| 17 | cutover | impl |
| 18 | **read-only proof snapshot, taken while still quiesced** | impl |
| 19 | restart | impl |
| 20 | wait for **`healthy`**, not `starting` | impl |
| 21 | **`.premigration` == proof snapshot** + snapshot database integrity | impl |
| 22 | topology changed by exactly the two intended additions | operator script |
| 23 | report says `protected` | operator script |
| 24 | lock released | impl (trap) |

Steps 14 and 15 compare the **quiesced source** against the destination — both
measured after the stop, which is what makes step 21's claim meaningful.

### The authoritative chain

```
quiesced source  ==  .premigration  ==  new subvolume before any application write  ==  proof snapshot
```

The pre-stop fingerprint is **observational** and is never used as the integrity
comparison: a clean shutdown legitimately writes (Jellyfin appended 743 bytes of
shutdown log and ran a SQLite optimize), and requiring it to match is what
aborted the first pilot. After the restart the live tree is *classified*, not
compared. See [MIGRATION-LIFECYCLE.md](MIGRATION-LIFECYCLE.md).

## Step 21 is new, and it is the one that was missing

`migrate_verify` proves the copy matched the source — but it runs *before* the
snapshot exists, so it cannot say anything about the snapshot. The claim that
matters for recovery, `.premigration == proof snapshot`, previously existed
**only in a hand-written operator script**. A migration run straight from the CLI
never made its own central claim, and the only copy of it sat in a file CI never
sees. That is the same class as the stale topology invariant, with higher stakes.

`migrate_verify_recovery_point` now does it in the implementation: the snapshot
must be read-only, both trees must exist, all content and metadata must match,
and every SQLite database in the snapshot must open and pass
`integrity_check` + `foreign_key_check`.

**Why the database check adds something hashes cannot.** A torn write that
predates the migration copies perfectly and verifies perfectly. Two
byte-identical trees holding the same broken database pass every hash and are
still an unusable recovery point. A `.db` file that is not SQLite is *skipped* —
detected by the 16-byte magic, not the extension — because failing a migration
over a naming convention would be a false positive where false positives are
expensive. A database too large to copy, or no tool to open it with, is reported
as **not checked**, never as checked.

It runs **after** the restart: both trees are static, so holding the service down
to hash them would buy nothing.

## Failure recovery — every phase

The invariant: **no failure may destroy the last valid copy of the state.** Every
`rm -rf` in the migration targets `<path>.new` and nothing else; nothing anywhere
in the codebase deletes `.premigration`.

| phase fails | what happens | state afterwards |
|---|---|---|
| stop | restart attempted, refuse | original at its path, untouched |
| non-empty WAL after stop | restart, refuse | original untouched |
| external file handle | restart, refuse | original untouched |
| subvolume create | restart, refuse | original untouched |
| copy | `.new` removed, restart, refuse | original untouched |
| hash mismatch | `.new` removed, restart, refuse | original untouched |
| metadata mismatch | `.new` removed, restart, refuse | original untouched |
| cutover, moving the original aside | `.new` removed, restart, refuse | original at its path |
| cutover, moving the copy into place | **original moved back**, restart, refuse | original restored |
| proof snapshot | reported, migration stands, exit non-zero | both copies present, no rollback point |
| restart / unhealthy | rollback instructions printed, refuse | both copies present |
| recovery point mismatch | reported loudly, exit non-zero | **both copies intact — neither deleted** |
| snapshot database broken | reported, exit non-zero | both copies intact |

A failed stop now attempts a restart. It previously did not: `started=1` was set
only *after* a successful stop, so a stop that failed part-way left the service
down while printing "nothing has been changed". No data was ever at risk; the
service just stayed off until somebody noticed.

## Two migrated services

`tests/two-migrated-services-smoke.sh` covers what the second migration arms,
written before Kavita exists rather than discovered after:

- the topology lists both, and two captures of it still compare equal
- retention is per service in one prune run — 20 jellyfin + 3 kavita at keep=14
  leaves 14 and 3
- 30 snapshots of one service and 1 of the other, in both directions, never
  deletes the single one, although the global count is 31 against keep=14
- a service with no snapshots is neither pruned nor invented
- `latest_snapshot_for_service` never crosses services
- the report classifies them independently: one `protected`, one `snapshottable`
- `snapshot_create` over two subvolumes is **not** excused by one success when the
  other fails
- a snapshot of one service does not authorise destroying another's data
- `domum-media-backup` still passes no `--one-file-system`, which would drop
  every migrated subvolume from the backup

## Afterwards

`.premigration` is retained. It is the only independent copy of the pre-migration
state and nothing removes it automatically — see
[PREMIGRATION-LIFECYCLE.md](PREMIGRATION-LIFECYCLE.md) for the evidence that
should exist before it goes.
