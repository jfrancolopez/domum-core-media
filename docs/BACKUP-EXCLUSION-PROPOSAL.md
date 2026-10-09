# Backup exclusion proposal — Immich regenerable derivatives

**Status: PROPOSED, not applied.** `backup_proposed_exclude_patterns` is read
only by `domum-media-backup exclusion-audit --proposed`. Nothing in the backup
path reads it. Applying it is an operator decision and a separate change.

Measured on the live host, 2026-10-09.

---

## 1. What is in the Immich library

Host path `/srv/data/immich/library`, mounted into `immich_server` at
`/usr/src/app/upload` (read from `docker inspect`, not assumed — the audit
depends on that prefix and a wrong one would make it pass vacuously).

| Subtree | Files | Bytes | GiB |
|---|---:|---:|---:|
| `upload/` (originals) | 22,976 | 139,760,456,394 | 130.2 |
| `encoded-video/` | 9,087 | 82,974,254,661 | 77.3 |
| `thumbs/` | 32,423 | 5,813,720,985 | 5.4 |
| `backups/` (Immich's own DB dumps) | 15 | 405,012,818 | 0.4 |
| `library/`, `profile/` | 1 each | 26 | 0 |

`upload/` holds 22,975 originals plus one 13-byte `.immich` marker. Extensions:
11,769 heic, 9,047 mov, 861 jpeg, 738 jpg, 260 dng, 251 png, 34 mp4, 11 cr2,
2 gif, 1 webp, 1 m4v.

`library/` and `profile/` contain only marker files, so there is **no external
library** (`select count(*) from library` → 0) and no profile image. Every
original is Immich-managed.

---

## 2. The finding: `encoded-video/` is not purely derivative

The obvious proposal is "exclude `thumbs/` and `encoded-video/`; Immich can
regenerate both". The second half is **false**, and it would have removed the
only backed-up copy of 58 irreplaceable files.

Against the live `asset` table:

```
assets                              : 23,033  (13,893 IMAGE, 9,140 VIDEO, 0 trashed)
originals NOT under upload/upload   :     58
originals' distinct paths            : 23,033  (no two assets share a path)
```

Those 58 assets have their **`originalPath` under `encoded-video/`**. They are
motion-photo parts — the short video inside a live photo — extracted by Immich
and registered as standalone assets. Every one is named `<uuid>-MP.mp4`:

```
/usr/src/app/upload/encoded-video/6a835020-…/67/68/676850ba-…-MP.mp4   IMG_0286.mp4
```

All 58 are present on disk, total **229,479,319 B (218.9 MiB)**, and they have
**no derivative rows of their own** (`asset_file` join → empty), so nothing else
references them. They are originals in every sense that matters.

### The accounting closes exactly

| Subtree | DB rows | Anomalous originals | Marker | Disk files |
|---|---:|---:|---:|---:|
| `encoded-video/` | 9,028 `encoded_video` | 58 | 1 | **9,087** |
| `thumbs/` | 16,211 `preview` + 16,211 `thumbnail` | 0 | 1 | **32,423** |

Nothing is unaccounted for in either subtree, in either direction:

```
asset_file rows with no asset                       : 0
asset_file rows whose asset has no originalPath     : 0
asset_file rows outside thumbs/ or encoded-video/   : 0
```

So `thumbs/` is **100% derivative** and safe to exclude wholesale.
`encoded-video/` is 9,028 derivatives **plus 58 originals**, intermixed in the
same directories, all with the `.mp4` extension.

---

## 3. The proposed patterns

```
/srv/data/immich/library/thumbs/**
/srv/data/immich/library/encoded-video/**/*[0-9a-f].mp4
```

The second pattern partitions the subtree on the one structural difference:
a derivative is `<uuid>.mp4` and a UUID's last character is a hex digit, while
a motion-photo original ends in `P`. Verified both ways:

```
total mp4 in encoded-video/   : 9086
match *[0-9a-f].mp4           : 9028   == the derivative row count
match *-MP.mp4                :   58   == the anomalous original count
match BOTH                    :    0
match NEITHER                 :    0

derivative rows not ending in a hex digit : 0
derivative rows ending in -MP.mp4         : 0
anomalous originals not ending in -MP.mp4 : 0
```

### Why not a negation pattern

restic 0.18.0 **does** support `!`-prefixed re-include patterns in an exclude
file, and the obvious formulation is "exclude `*.mp4`, re-include `*-MP.mp4`".
Measured in a disposable scratch repository, it works — and it is **order
dependent, and fails silently in the dangerous direction**:

| Pattern order | mp4 files kept |
|---|---:|
| exclude, then `!` re-include | 1 (the `-MP.mp4` original) ✅ |
| `!` re-include, then exclude | **0** ❌ |

With the patterns reversed, restic excluded the original too, printed
`snapshot … saved`, and warned about nothing. One editing mistake would have
dropped all 58 files with a green backup report.

The character-class pattern has **no ordering semantics at all** — verified by
passing it twice and by reversing the pattern list, with identical results. It
is preferred for that reason, not for brevity.

restic honours the character class: measured against realistic UUID filenames,
the derivative was excluded and both `-MP.mp4` files were kept.

---

## 4. What the proposal would save

| | Bytes | GiB |
|---|---:|---:|
| `thumbs/` (all) | 5,813,720,985 | 5.4 |
| `encoded-video/` derivatives | 82,744,775,342 | 77.1 |
| **Total no longer backed up** | **88,558,496,327** | **82.5** |
| Still backed up: the 58 `-MP.mp4` originals | 229,479,319 | 0.2 |

Against a 130.2 GiB original library, the backup set would fall by roughly 40%.

---

## 5. How the proposal is kept honest

`domum-media-backup exclusion-audit [--proposed]` evaluates every pattern
against the **live asset table** and reports whether any pattern matches an
original. Read-only: it contacts no repository, writes nothing, and changes no
exclusion.

```
exit 0  no original is matched
exit 1  an original is matched -- the offending paths are printed
exit 2  the question could not be answered
```

Current result (`--proposed`): `MATCHED ORIGINALS : 0 of 23033`.

Three properties make the negative result worth something:

- **The matcher is conservative.** restic's `**` matches zero or more path
  components; bash's `*` crosses `/` but a literal `**/` still demands one
  separator, so the zero-component case is tested as a separate collapsed
  variant. The audit can over-report, never miss.
- **The database is the only authority.** A filesystem walk of `upload/` cannot
  find the 58 anomalies, so an audit reasoned from directory names would have
  confirmed the broken proposal.
- **It refuses to pass vacuously.** If the container-to-host prefix translation
  fails, every path keeps its container shape, matches no host pattern, and a
  naive implementation reports a clean `0 matched` having compared nothing. The
  audit requires that originals actually resolve under the library root and
  returns UNKNOWN otherwise. `tests/backup-exclusion-audit-smoke.sh` mutates
  that guard away and requires the false clean verdict to appear.

The active exclusions and the proposal are now read from
`backup_exclude_patterns` / `backup_proposed_exclude_patterns`. The restic
invocation builds its `--exclude` argv from the first of those, so the audit and
the backup cannot disagree — previously the patterns were written inline in the
restic call where nothing could read them.

---

## 6. Recovery consequence, stated plainly

Excluding these files means a restore returns **originals only**. Immich
regenerates thumbnails and transcodes through its own jobs ("Regenerate
thumbnails", "Transcode videos"), so the library becomes fully usable again —
but **not instantly**, and that is a deliberate trade:

| | Before the proposal | After |
|---|---|---|
| Originals restored | yes | yes |
| Motion-photo originals restored | yes | yes |
| Thumbnails immediately available | yes | no — regenerated |
| Transcodes immediately available | yes | no — regenerated |
| Backup set | ~213 GiB | ~130 GiB |

The regeneration cost has **not** been measured on this hardware. Until it is,
the honest statement is that recovery remains complete but slower, by an
unmeasured amount.

---

## 7. Status of the claims in this document

| Claim | Status |
|---|---|
| The subtree sizes and file counts above | MEASURED 2026-10-09 |
| 58 originals live under `encoded-video/` | MEASURED (live asset table) |
| `thumbs/` is 100% derivative | MEASURED (row counts close exactly) |
| The character-class pattern partitions the subtree | MEASURED, both directions |
| restic honours the class, and negation is order dependent | MEASURED (scratch repo) |
| No original is matched by the proposal | MEASURED (`exclusion-audit --proposed`) |
| 82.5 GiB would stop being backed up | MEASURED |
| Immich can regenerate the excluded derivatives | **INFERRED** from Immich's job model; not tested by restoring and regenerating on this host |
| Regeneration time after a full restore | **UNKNOWN** |

The last two are why this is a proposal. Excluding 82.5 GiB is safe with respect
to *data loss* — that is now proven and re-checkable. It is not yet proven with
respect to *recovery time*.
