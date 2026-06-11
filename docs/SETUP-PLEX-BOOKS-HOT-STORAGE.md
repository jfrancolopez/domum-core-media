# Plex, eBooks, and Hot Storage

This stack now supports an explicit two-tier layout:

- Durable tier: `/srv/data` and the durable media folders under `/srv/media`
- Volatile hot tier: `${DOMUM_HOT_ROOT}` on the OS SSD for caches, transcodes,
  imports, and scratch space

The rule is simple: the hot tier must never become the only copy of
irreplaceable data.

## Durable paths

- `/srv/data/immich`
- `/srv/data/jellyfin/config`
- `/srv/data/plex/config`
- `/srv/data/navidrome`
- `/srv/data/calibre-web/config`
- `/srv/data/kavita/config`
- `/srv/media/photos`
- `/srv/media/music`
- `/srv/media/movies`
- `/srv/media/tv`
- `/srv/media/books`

## Volatile hot paths

- `${DOMUM_HOT_ROOT}`
- `${DOMUM_HOT_ROOT}/jellyfin-cache`
- `${DOMUM_HOT_ROOT}/plex-transcode`
- `${DOMUM_HOT_ROOT}/media-staging`
- `${DOMUM_HOT_ROOT}/books-import`
- `${DOMUM_HOT_ROOT}/music-cache`
- `${DOMUM_HOT_ROOT}/video-cache`

`domum-media hot status` shows current usage.

`domum-media hot prune --dry-run` previews deletions.

`domum-media hot prune` removes files older than
`HOT_STORAGE_PRUNE_OLDER_THAN_DAYS` and then keeps pruning oldest files until
usage drops below `HOT_STORAGE_MAX_PERCENT`.

The pruner refuses to run if `DOMUM_HOT_ROOT` points at a dangerous path such
as `/`, `/srv`, `/srv/data`, or `/home`.

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
PLEX_TRANSCODE_DIR="${DOMUM_HOT_ROOT}/plex-transcode"
PLEX_CLAIM=""
PLEX_ENABLE_HW_TRANSCODE=1
```

Notes:

- The compose fragment mounts `/dev/dri:/dev/dri` for Intel Quick Sync on the
  N100.
- `PLEX_CLAIM` is only needed for initial claim/registration.
- Config is durable; transcode output is intentionally volatile.

## Jellyfin vs Plex storage

- Jellyfin: durable config, volatile cache, read-only `/srv/media`
- Plex: durable config, volatile transcode, read-only `/srv/media`

Neither service should store the only copy of media on the hot tier.

## eBooks

Two optional services are available:

- Calibre-Web: library browsing / OPDS
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
KAVITA_STAGING_DIR="${DOMUM_HOT_ROOT}/books-import"
```

Recommended split:

- Durable: `/srv/media/books`
- Durable config: `/srv/data/calibre-web/config`, `/srv/data/kavita/config`
- Volatile import/staging: `${DOMUM_HOT_ROOT}/books-import`

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

Backups prioritize durable content. By default the wrapper includes:

- `/srv/data`
- `/srv/media/books`

The hot tier is excluded by default. Override `BACKUP_INCLUDE_PATHS` only if
you intentionally want volatile paths in restic.

## Immich

Immich remains durable-only by default:

- `/srv/data/immich/library`
- `/srv/data/immich/postgres`

Do not move Immich uploads, thumbnails, or database state onto the hot tier
unless you are deliberately accepting that risk.
