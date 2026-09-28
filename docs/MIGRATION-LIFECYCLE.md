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

1. **Hard failure** if any file present in E is *missing* from F. Files may be
   added or rewritten by a running service; a file that vanished is different.
2. **Reported** otherwise, split into expected runtime state and anything else:

   | pattern | why it is expected |
   |---|---|
   | `*/log/*`, `*.log`, `*/.*-log` | a running service logs |
   | `*/ScheduledTasks/*` | task run timestamps are rewritten on startup |
   | `*.pid`, `*.lock`, `*.sock` | runtime locks |
   | `*-wal`, `*-shm`, `*-journal` | SQLite sidecars exist only while the DB is open |

   Anything outside that list is printed for review.

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
