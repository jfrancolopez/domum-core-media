# Migration lifecycle states — and which comparison proves integrity

The first production pilot (Jellyfin, 2026-09-25) **aborted on a migration that
was in fact perfect.** The migration itself returned 0 after hashing all 37 files
and comparing metadata; the outer pilot harness then compared the wrong two
states and refused.

This document exists so that mistake is not made again.

## The six states

| | state | written by |
|---|---|---|
| **A** | pre-stop observational baseline | taken while the service is running |
| **B** | source after clean shutdown | the service, shutting down |
| **C** | `.premigration` | B, preserved unchanged by the cutover |
| **D** | the copied subvolume at cutover | `cp -a --reflink=always` |
| **E** | the proof snapshot | D, captured while still quiesced |
| **F** | the live tree after restart | the service, running again |

## What must be equal, and what must not

**The integrity claim is `C == E`.**

Both are static — nothing writes to a directory that has been moved aside, or to
a read-only snapshot — so that comparison cannot be disturbed by the application
running. It is strictly stronger evidence than anything involving F.

| comparison | status |
|---|---|
| `C == E` | **asserted.** The original against a snapshot of the copy that replaced it. |
| `B == D` | asserted *inside* `migrate_verify`: counts, bytes, all content hashes, and type/mode/owner/group/symlink targets. |
| `A == B` | **must not be asserted.** A clean shutdown legitimately writes. |
| `E == F` | **must not be asserted.** A restarted application legitimately writes. |
| `A == F` | **must not be asserted.** Both of the above, compounded. |

## What "legitimately writes" meant in practice

On the first pilot, the pre-stop baseline was 501,219 bytes and the quiesced
source was 501,962 — a difference of **743 bytes**. Accounted for exactly: the
shutdown sequence in `config/log/log_20260925.log`, from
`Sending shutdown notifications` to EOF, is 743 bytes. It includes

```
Running query planner optimizations in the database... This might take a while
```

so Jellyfin also runs a SQLite optimize on the way down.

After the restart, the live tree diverged from the proof snapshot in exactly
seven paths — and **not one of them was the database**:

```
changed   config/log/log_20260925.log                 4842 -> 15333 bytes
changed   config/data/data/ScheduledTasks/*.js        3 files, same size, new timestamps
added     config/log/.jellyfin-log
added     config/data/data/jellyfin.db-wal
added     config/data/data/jellyfin.db-shm
```

`jellyfin.db` was byte-identical across `.premigration`, the proof snapshot and
the live tree (`sha256 4ab756ca…`), with `PRAGMA integrity_check = ok` and zero
foreign-key violations in all three.

## How F is handled instead

Not ignored — **classified**:

This is **migration stage 10**, `migrate_report_live_tree`, which classifies
rather than compares. Every differing path gets exactly one record:

| record | meaning | fails the stage? |
|---|---|---|
| `CHURN` | changed or appeared, and is expected runtime state | no |
| `PRUNED` | gone from the live tree, and is expected runtime state | no |
| `CHANGED` | in both, content differs, **not** runtime state | no — reported |
| `ADDED` | only in the live tree, **not** runtime state | no — reported |
| `LOST` | gone from the live tree, **not** runtime state | **yes** |

Expected runtime state is `migrate_runtime_expected`:

| pattern | why it is expected |
|---|---|
| `*/log/*`, `*/logs/*`, `*/Log/*`, `*/Logs/*`, `*.log`, `*.log.*` | a running service logs |
| `*/ScheduledTasks/*`, `*/temp/*`, `*/tmp/*`, `*/Temp/*` | task timestamps and scratch |
| `*/cache/*`, `*/cache-*/*`, `*/Cache/*`, `*/caches/*` | regenerable |
| `*/thumbnails/*`, `*/covers/*`, `*/favicons/*`, `*/bookmarks/*` | regenerable |
| `*/Crash Reports/*`, `*/Codecs/*`, `*/Updates/*` | Plex: regenerable or re-downloadable |
| `*.pid`, `*.lock`, `*.sock` | runtime locks |
| `*-wal`, `*-shm`, `*-journal` | SQLite sidecars exist only while the DB is open |

Anything outside that list is printed for review.

### It was documented here long before it existed in the CLI

This section described the classification as part of the migration while the CLI
had no such stage: stages ran 1–9, ending at the recovery-point proof. The only
implementation lived in the operator wrapper, outside CI — the same shape as the
topology invariant that aborted a correct deployment. It is now
`migrate_classify_live_tree` / `migrate_report_live_tree` in `bin/domum-media`,
covered by `tests/live-tree-classification-smoke.sh` (12 cases, 9 mutants), and
the wrapper invokes it instead of carrying a copy.

### Two things Plex broke that the wrapper's version got wrong

**Paths with spaces.** The wrapper iterated `for f in $CHANGED $ADDED`, which
word-splits. Measured on real Plex paths, two entries became **eleven
fragments** — and because `Server.2.log` matches `*.log` while `Support/Plex`
matches nothing, pieces of a single path were classified differently from each
other. `config/Library/Application Support/Plex Media Server/…` makes that
output meaningless. Everything is NUL-delimited now.

**"Missing is a hard failure" is false for Plex.** The wrapper aborted
unconditionally when a snapshotted file was absent from the live tree. That held
for Jellyfin, Kavita and Navidrome. Plex rotates `Plex Media Server.N.log` and
prunes its own dated database backups (`com.plexapp.plugins.library.db-YYYY-MM-DD`,
four retained) — so ordinary log rotation would have failed a correct migration.
A disappearance is now split the same way an addition is: `PRUNED` when it is
expected churn, `LOST` otherwise, and only `LOST` fails.

A dated backup is still a *database*, so its removal reports `LOST` rather than
being filed as churn: the operator sees it, and decides.

The **database file itself is deliberately not on that list.** Sidecars appearing
proves the service opened its database; the `.db` content changing is a different
claim and the operator should always see it.

## The implementation now asserts C == E itself

`C == E` was stated here and enforced only in a hand-written operator script, so a
migration run straight from the CLI never made its own central claim — and the one
copy of the check lived in a file CI never sees. `migrate_verify_recovery_point`
closes that: the snapshot must be read-only, both trees must exist, content and
metadata must match in full, and every SQLite database **in the snapshot** must
open and pass `integrity_check` and `foreign_key_check`.

The database check is not redundant with the hashes. A torn write that predates
the migration copies perfectly and verifies perfectly; two byte-identical trees
holding the same broken database satisfy `C == E` and are still an unusable
recovery point. Hashes prove the copy is faithful, not that what was copied is
loadable.

It is always done on a **disposable copy**. Opening a WAL-mode database creates
`-shm` and `-wal` beside it and leaves them there even with `mode=ro` (measured),
so checking in place would make `C` differ from `E` — the act of verifying the
claim would break it — and would simply fail against the read-only snapshot.

It runs **after** the restart. Both C and E are static, so holding the service
down to hash them buys nothing.

## Regression coverage

`tests/integration/btrfs-migration-integration.sh` models a service that writes
during **both** clean shutdown and startup, precisely so a harness asserting
`A == F` fails there instead of in production. Reinstating that assertion makes
the test fail.

Three implementation mutations prove the replacement assertions are load-bearing:

| mutation | caught by |
|---|---|
| the copy silently corrupts a file | `migrate_verify` (rc=1) |
| corruption injected **after** `migrate_verify` passes | **`C == E`** — nothing else can see this |
| the restart writes a non-runtime file | the F classifier, by name |

The middle one is why `C == E` is not redundant with the migration's own
verification.
