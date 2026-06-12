# Plex, eBooks, and Durable vs Disposable Storage

This box has two physical disks with two clear roles. Everything in the stack is
placed on exactly one of them based on whether the data is irreplaceable or
regenerable.

## Durable vs disposable

**Durable / protected — `/srv/data` (SDA, 1TB btrfs)**

- Immich photo library and Postgres database
- App config/state (Jellyfin, Plex, Navidrome, Calibre-Web, Kavita configs)
- Recovery pack and backup staging

This tier is snapshotted (btrfs) and swept into restic backups. It is the only
tier that must never be lost.

**Disposable media — `/srv/media` (SDB, on the OS disk)**

- Movies, shows, music, books
- Regenerable caches and transcodes under `/srv/media/.cache/<service>`

This tier is **not** backed up by default. If the OS disk is wiped, the media
can be re-acquired and the caches simply regenerate. The point of keeping it on
a separate disk is so disposable media can never consume the 1TB photo disk.

> The two tiers must live on **separate filesystems**. `domum-media checkup`
> warns if `/srv/media` shares a filesystem with `/srv/data`, and if any Immich
> path is not under `/srv/data/immich`. See `docs/SETUP-N100.md` for the disk
> layout and mounts.

## Service path summary

| Service | Durable (`/srv/data`) | Disposable (`/srv/media`) |
|---|---|---|
| Immich | `immich/library`, `immich/postgres`, `immich/backup-staging` | — |
| Jellyfin | `jellyfin/config` | `.cache/jellyfin`, media (`:ro`) |
| Plex | `plex/config` | `.cache/plex-transcode`, media (`:ro`) |
| Navidrome | `navidrome` (DB/state) | `music` (`:ro`) |
| Calibre-Web | `calibre-web/config` | `books` |
| Kavita | `kavita/config` | `books` (`:ro`) |

## Plex

Enable Plex with:

```bash
ENABLE_PLEX=1
PLEX_IMAGE="lscr.io/linuxserver/plex:latest"
PLEX_AUTO_UPDATE=1
PLEX_AUTO_UPDATE_DELAY_DAYS=20
PLEX_HOST="plex.${DOMUM_DOMAIN}"
PLEX_CONFIG_DIR="/srv/data/plex/config"
PLEX_MEDIA_ROOT="/srv/media"
PLEX_TRANSCODE_DIR="/srv/media/.cache/plex-transcode"
PLEX_CLAIM=""
PLEX_ENABLE_HW_TRANSCODE=1
```

Notes:

- The compose fragment mounts `/dev/dri:/dev/dri` for Intel Quick Sync on the N100.
- `PLEX_CLAIM` is only needed for initial claim/registration.
- Config is durable; transcode output is intentionally disposable and lives on
  the media disk under `.cache/`.

## Jellyfin vs Plex storage

- Jellyfin: durable config, disposable cache, read-only `/srv/media`
- Plex: durable config, disposable transcode, read-only `/srv/media`

Neither service should store the only copy of media on the disposable tier.

## eBooks

Two optional services are available:

- Calibre-Web: library browsing / OPDS / management
- Kavita: comics, manga, PDFs, and reader-first UX

Enable them independently:

```bash
ENABLE_CALIBRE_WEB=1
CALIBRE_WEB_IMAGE="lscr.io/linuxserver/calibre-web:latest"
CALIBRE_WEB_HOST="books.${DOMUM_DOMAIN}"
CALIBRE_WEB_CONFIG_DIR="/srv/data/calibre-web/config"
CALIBRE_WEB_LIBRARY_DIR="/srv/media/books"

ENABLE_KAVITA=1
KAVITA_IMAGE="jvmilazz0/kavita:latest"
KAVITA_HOST="kavita.${DOMUM_DOMAIN}"
KAVITA_CONFIG_DIR="/srv/data/kavita/config"
KAVITA_LIBRARY_DIR="/srv/media/books"
```

Recommended split:

- Books library (disposable media): `/srv/media/books`
- Durable config: `/srv/data/calibre-web/config`, `/srv/data/kavita/config`

Kavita only scans and reads books, so its `/books` mount is read-only — it does
not manage the library. Calibre-Web mounts `/books` read-write because it can
add/convert/edit entries. There is no separate "staging" directory: drop files
straight into `/srv/media/books` (or a subfolder) and let the apps scan them.

### Calibre-Web first-run

Before opening Calibre-Web for the first time you must have a valid Calibre
library (a directory containing `metadata.db`) at `CALIBRE_WEB_LIBRARY_DIR`.

If the directory is empty, bootstrap an empty library inside the container:

```bash
# Create a throwaway EPUB file
docker exec calibre-web bash -c "
  python3 -c \"
import zipfile, os
os.makedirs('/tmp/epub/META-INF', exist_ok=True)
with open('/tmp/epub/META-INF/container.xml', 'w') as f:
    f.write('<container version=\\\"1.0\\\" xmlns=\\\"urn:oasis:schemas:container\\\">'
            '<rootfiles><rootfile full-path=\\\"content.opf\\\" media-type=\\\"application/oebps-package+xml\\\"/>'
            '</rootfiles></container>')
with open('/tmp/epub/content.opf', 'w') as f:
    f.write('<package xmlns=\\\"http://www.idpf.org/2007/opf\\\" unique-identifier=\\\"id\\\" version=\\\"2.0\\\">'
            '<metadata xmlns:dc=\\\"http://purl.org/dc/elements/1.1/\\\">'
            '<dc:title>Init</dc:title><dc:identifier id=\\\"id\\\">init</dc:identifier>'
            '</metadata><manifest/><spine/></package>')
with zipfile.ZipFile('/tmp/init.epub','w') as z:
    z.write('/tmp/epub/META-INF/container.xml','META-INF/container.xml')
    z.write('/tmp/epub/content.opf','content.opf')
\"
"

# Initialize the Calibre database
docker exec -u abc calibre-web calibredb add /tmp/init.epub --library-path /books

# Optionally remove the dummy entry
docker exec -u abc calibre-web calibredb remove 1 --library-path /books
```

Then in the Calibre-Web setup wizard enter `/books` as the database path
(the container-internal mount point, not the host path).

## Backups

Cloud backups default to **Immich-only** to avoid uploading large media libraries:

- `/srv/data/immich/library`
- `/srv/data/immich/backup-staging`
- `/var/lib/domum-media/recovery-pack`

This is the default for the `cloud` target — no configuration required. In the
conf you can pin it explicitly:

```
BACKUP_TARGET_CLOUD_INCLUDE_PATHS="/srv/data/immich/library /srv/data/immich/backup-staging /var/lib/domum-media/recovery-pack"
```

`/srv/media` (movies, shows, music, books) and the `.cache` directories are
never uploaded by default. To back up all durable service data and the books
library to a target, choose **all-data** during `sudo domum-media configure`, or
set that target's `*_INCLUDE_PATHS` manually. `domum-media checkup` warns if a
cloud target's include paths contain a broad `/srv/media` path.

## Immich

Immich is durable-only:

- `/srv/data/immich/library`
- `/srv/data/immich/postgres`

Do not move Immich uploads, thumbnails, or database state onto the disposable
media disk — that data is irreplaceable and must stay on the protected tier.

## Migration from DOMUM_HOT_ROOT

Earlier releases used a `DOMUM_HOT_ROOT` "hot tier" (default
`/var/lib/domum-media/hot`) for caches, transcodes, and a Kavita "staging" mount.
That concept has been removed. Caches/transcodes now live under
`/srv/media/.cache/<service>` on the disposable media disk.

Existing configs that still set `DOMUM_HOT_ROOT` keep working: the value is
ignored and a one-line deprecation warning is printed — no manual edit is
required before `domum-media apply`. To silence it, delete the `DOMUM_HOT_ROOT`,
`KAVITA_STAGING_DIR`, `NAVIDROME_CACHE_DIR`, and `HOT_STORAGE_PRUNE_*` lines from
your conf. If you want the old cache contents removed, delete
`/var/lib/domum-media/hot` manually.
