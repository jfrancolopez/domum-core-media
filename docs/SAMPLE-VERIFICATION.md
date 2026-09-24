# Representative asset restore verification

`domum-media-backup verify-restore <target>` proves the **Immich PostgreSQL
dump** restores. It says nothing about the photo and video originals, which are
the overwhelming majority of the protected bytes.

`domum-media-backup verify-sample <target> [count]` closes part of that gap by
restoring a small, deterministic, deliberately diverse sample of real Immich
originals from the latest snapshot and comparing them byte-for-byte against the
live files.

## What it proves — and what it does not

**Proves, for the sampled objects only:**

- the repository is reachable and its key material decrypts it;
- the latest snapshot indexes those paths;
- the stored data decompresses to bytes **identical** to the live originals
  (SHA-256 on both sides).

**Does not prove:**

- that every file in the library is intact — sampling cannot prove that, and no
  number of samples turns into a whole-library guarantee;
- that a full-scale restore completes (time, space, and throughput are
  untested here);
- that a rebuilt Immich can actually serve the restored library — that needs a
  database restore *and* an import, together.

Never describe a passing sample as "the library is verified".

## Selection

Selection is deterministic: the same library and count produce the same sample,
so two runs are comparable and a regression is visible.

1. Every file above `SAMPLE_MAX_FILE_BYTES` (default 256 MiB) is excluded
   first. The library's largest object is ~1.4 GB; restoring it on every run
   would dominate the cost without adding information.
2. One representative per distinct extension, in sorted extension order,
   choosing that extension's **median-sized** file. A file with no extension is
   typed `none` rather than being given a type derived from its path.
3. The smallest and the largest remaining eligible files, to exercise both
   ends of the size distribution.
4. The remainder filled by even stride across the path-sorted list, then a
   sequential sweep so the quota is always met.
5. Accumulated size is capped by `SAMPLE_MAX_TOTAL_BYTES` (default 1 GiB).

Files whose names contain glob metacharacters (`*`, `?`, `[`, `]`, `\`) are
excluded, because restic's `--include` takes a **pattern**, not a literal path:
such a name would silently select the wrong objects, or none — and a file that
restored perfectly would then be reported as a mismatch. The command prints how
many files were excluded for this reason, so the blind spot is visible rather
than silent.

The library profile that motivated these defaults (20,000 sampled entries):

| type | count |   | percentile | bytes |
|---|---|---|---|---|
| heic | 10190 |  | min    | 13 |
| mov  |  7917 |  | p25    | 1,689,211 |
| jpeg |   778 |  | median | 2,694,789 |
| jpg  |   625 |  | p75    | 4,358,345 |
| png  |   230 |  | max    | 1,380,730,680 |
| dng  |   217 |
| mp4  |    29 |
| cr2  |    10 |
| webp |     1 |
| m4v  |     1 |

## Evidence

One JSON object per sampled file is appended to
`/var/lib/domum-media/restore-verification/<target>-sample.jsonl` (mode 0600),
written atomically:

```json
{"target":"cloud","snapshot_id":"fb4290ca","path":"/srv/data/immich/library/…",
 "media_type":"heic","size_bytes":2694789,"source_sha256":"…",
 "restored_sha256":"…","result":"match","verified_at":"2026-09-23T…"}
```

This is recorded **separately** from the dump verification record. They are
different claims and must never be merged into one "verified" flag.

Any mismatch is fatal: the command exits non-zero and the mismatching row is
kept in the manifest.

## Safety

- Restores go to a `mktemp -d` scratch directory that is removed on exit and on
  `HUP`/`INT`/`TERM`.
- The command refuses to run if the scratch location resolves inside
  `DOMUM_DATA_ROOT` or `DOMUM_MEDIA_ROOT`.
- It is read-only with respect to the live library and the repository: it reads
  originals, reads the snapshot, and writes only scratch and the manifest.

## Test coverage

`tests/sample-verification-smoke.sh` is hermetic (no restic, no network) and
covers determinism, type diversity, both size caps, extensionless-file typing,
the scratch-location refusal, and — most importantly — that a single appended
byte in the restored data fails the run. Every check was confirmed non-vacuous
by mutation testing (six mutants, six killed).

## Reporting

The weekly report carries this as `backups.asset_sample`, next to but never
merged with `backups.restore_verification`:

```
  Sampled originals:    sampled (7 file(s), heic/mov, 1h ago; a sample, not the whole library)
  Restore verification: verified (cloud, 3d ago, checks: gzip,size,footer)
```

The passing state is called **`sampled`**, never `verified`. A reader who sees
`verified` must be able to assume the dump-restore claim; a sample is weaker
and stays lexically distinct.

Findings raised:

| condition | level |
|---|---|
| any sampled file did not restore to identical bytes | critical |
| no sampled verification recorded | info |
| last sampled verification older than 90 days | info |

A missing sample is `info`, not a warning: the dump restore verification is the
load-bearing check, and sampling is an additional assurance rather than a
gate. A **mismatch** is critical, because it means stored bytes differ from the
originals.

A manifest whose timestamps are unreadable is reported using its mtime rather
than being silently indistinguishable from "never sampled" — a truncated or
corrupt manifest must not read as a clean slate.
