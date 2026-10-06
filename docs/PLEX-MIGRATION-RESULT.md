# Plex migration result — 2026-10-06

`/srv/data/plex` is a Btrfs subvolume with a verified recovery point, and Plex is
still running the image it was running before. The staged upgrade was **not**
deployed.

That last clause was the point. Plex's image upgrade had been correctly blocked
because its state was `unprotected`; this migration creates the recovery point
that makes the upgrade a separate, recoverable decision.

## What was proven

| claim | evidence |
|---|---|
| state is a subvolume | inode **256**, `st_dev` 56 vs parent 45 |
| proof snapshot | `plex-20261006-133511-post-migration`, `ro=true` |
| previous state retained | `/srv/data/plex.premigration`, 116 files, 260,388,960 B |
| copy verified before cutover | `116 → 116` files, `260389181 → 260389181` bytes, content manifest identical |
| metadata verified | `type, mode, owner, group and symlink targets identical` |
| **WAL gate exercised** | 93,304-byte `-wal` → clean stop → `no non-empty WAL` |
| **container object preserved** | `7a917ab1f387`, `Created 2026-06-12T13:04:34Z` — unchanged |
| **image preserved** | `sha256:58f13a1df833…`; the tag still resolves to `7f9a1d574958…`, **staged, not deployed** |
| runtime state | `running` → `running` |
| readiness | answered `GET /identity`, reported version `1.43.2.10687-563d026ea` |
| live tree | **0 lost**, 0 pruned, 36 expected-churn, 2 changed |
| integrity | `.premigration == proof snapshot`, both databases `ok`, 0 FK violations |

Topology is now four services: `jellyfin`, `kavita`, `navidrome`, `plex`, each
with its own proof snapshot, and all four `.premigration` trees retained.

## The file count moves, and should

121 files before the stop → **116** migrated → 121 again once Plex restarted.
The clean shutdown removed four SQLite sidecars and `plexmediaserver.pid`; Plex
recreated them on startup. The migration copies the *quiesced* tree, which is
the whole reason the stop happens first.

## Symlinks: what the 221 bytes are

`migrate_measure` uses `du -sb --apparent-size`, which counts regular files **and
symlink target strings**, but not directory entries. So:

```
files only          260,388,960
symlink targets          +  221   (7 links: 124+14+18+13+20+11+21)
                    ───────────
du --apparent-size  260,389,181   <- what both sides reported
directories           ( 8,384 )   <- excluded from both sides
```

Six links are relative and in-tree. The seventh is absolute:

```
Cache/va-dri-linux-x86_64/iHD_drv_video.so
  -> /config/Library/.../Drivers/imd-a5431fbbff9ce9568f94ae21-linux-x86_64/dri/iHD_drv_video.so
```

`/config` is the **container's** mount point for `/srv/data/plex/config`, so that
path resolves inside the container and dangles on the host. Lexically it escapes
the state tree; semantically it points back into it. Its 124-byte target string
is preserved byte-for-byte — rewriting it to a host path would break Plex, and
dereferencing it from the host would either fail or read an unintended tree.
`migrate_manifest` uses `find -type f`, which excludes symlinks, so nothing is
hashed through them; `migrate_metadata_manifest` compares `%y`/`%m`/`%U`/`%G`/`%l`.

## The two reported changes

```
CHANGED .LocalAdminToken
CHANGED Plug-in Support/Data/com.plexapp.system/Dict
```

Both are rewritten by Plex on startup. They are deliberately **not** on the
expected-churn allowlist: `.LocalAdminToken` is security-relevant and an operator
should see it change, and neither is a database. `0 lost` is the claim that
matters, and the integrity claim compares two static trees so it is unaffected.

## It first reported INCOMPLETE, and that was a false negative

```
recovery point  : DID NOT VERIFY
WARN: sqlite …com.plexapp.plugins.library.db: failed: unknown tokenizer: collating
```

Plex's databases carry FTS virtual tables built with its own `collating`
tokenizer, which only Plex's bundled SQLite registers. Measured against copies
from the read-only proof snapshot:

| | result |
|---|---|
| python `sqlite3` 3.46.1 — `integrity_check`, `quick_check` | `unknown tokenizer: collating` |
| …`page_count` (412 / 357), `page_size`, `schema_version`, `journal_mode=wal` | read fine |
| …`sqlite_master` rows | 254, readable |
| …objects using that tokenizer | **exactly 2** |
| **Plex's own SQLite** — `integrity_check` | **`ok`** |
| …`foreign_key_check` | **0 violations** |

The data was sound; the checker could not read the schema.
`migrate_sqlite_integrity` already promised it never fails a database it could
not check, and its `case` sent anything unrecognised to `bad=1`. See
`docs/RECOVERY-POINT-IDENTITY.md` and `tests/sqlite-unsupported-smoke.sh`.

After the fix, on the real recovery point:

```
sqlite …library.db: this SQLite cannot read the schema; used the application's own
sqlite …library.db: ok
sqlite …library.blobs.db: ok
sqlite: 2 checked, 0 not checked
integrity proven: /srv/data/plex.premigration == /srv/snapshots/plex-20261006-133511-post-migration
deep verification : integrity re-proven
```

## Recoverability of the application half

`identity,local` — and this is the weakest pairing of the four services:

```
image id      : sha256:58f13a1df833…
created from  : lscr.io/linuxserver/plex:latest   (MUTABLE: may point elsewhere now)
version label : 1.43.2.10687-563d026ea-ls308
availability  : identity,local
  -> the object is on THIS HOST today; no immutable reference for later
```

`RepoTags` **and** `RepoDigests` are both empty: the image is dangling, because a
newer `:latest` moved the tag. It survives only because a running container
references it.

**This matters for the upgrade.** The moment Plex is recreated on the newer
image, `58f13a1df833…` becomes unreferenced and prunable — so the application
half of this recovery point becomes fragile exactly when it starts to matter.
Preserving it deliberately (an export, or a digest-pinned reference) belongs in
the upgrade plan, not after it.

## What this does not establish

- The library database **opened**. `/identity` does not touch it, and anything
  that does needs an `X-Plex-Token`. The SQLite checks answer the structural
  question from the other side, on copies.
- That a restore works end to end. The recovery point is verified; a rehearsed
  restore is separate work.
- Anything about Calibre-Web, which remains an ordinary directory with a staged
  image and is therefore still correctly blocked from upgrading.
