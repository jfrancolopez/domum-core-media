# Task 14 — Docs index and naming normalization  [shared-philosophy]

## Objective
Adopt the sibling repo's docs structure — the one pattern where domum-core is
clearly ahead: a `docs/README.md` index and a nested layout
(`getting-started/`, `operations/`, `backups/`, `reference/`, `services/`)
with consistent lowercase-kebab filenames.

## Files involved
- Every file under `docs/` (moves + link updates)
- `docs/README.md` (new index)
- `README.md`, `install.sh` next-steps text, `systemd/*.service`
  `Documentation=` lines, and all in-repo references to `docs/...` paths
- `bin/domum-media` + `bin/domum-media-backup` (grep for `docs/` strings in
  log messages and warnings — there are several, e.g. SETUP-N100.md,
  SETUP-NAVIDROME.md, SETUP-PLEX-BOOKS-STORAGE.md)

## Reason
Current docs mix three conventions in one flat directory: `SETUP-*.md`
screaming-case, `add-new-service.md` lowercase, `CHECKUP.md` bare screaming.
There is no index, so discovery is `ls docs`. The sibling's nested layout has
proven more navigable, and converging the *shape* of docs is core
sibling-foundation work. Content is good — this is a move-and-relink job,
not a rewrite.

Suggested mapping:
- `SETUP-N100.md`, `SETUP-CLOUDFLARE.md`, `SETUP-TRAEFIK.md` → `getting-started/`
- `CLI-CHEATSHEET.md`, `CHECKUP.md`, `SETUP-UPDATES.md`, `SECURITY-PATCHES.md`,
  `ROLLBACK.md` → `operations/`
- `SETUP-RESTIC.md`, `SETUP-HETZNER-STORAGE-BOX-B11.md`,
  `disaster-recovery.md` → `backups/`
- `SETUP-IMMICH.md`, `SETUP-NAVIDROME.md`, `SETUP-PLEX-BOOKS-STORAGE.md` → `services/`
- `add-new-service.md`, `service-template.md` → `reference/`

## Implementation plan
1. `git mv` per the mapping, renaming to lowercase-kebab
   (`SETUP-RESTIC.md` → `backups/restic.md`, etc.).
2. `grep -rn 'docs/' README.md install.sh bin systemd docs` and fix every
   reference — this is the step that prevents the stale-reference debt the
   sibling accumulated after its own docs reorg. Finish with the checker:
   every referenced path must exist.
3. Write `docs/README.md` mirroring domum-core's index format.
4. Note in the commit: systemd `Documentation=` changes land on the host at
   the next `apply` (converge_local_installation reinstalls units).

## Testing plan
- Reference checker from step 2 returns clean.
- `git log --follow` still tracks each doc's history (verify one).
- CI green (yamllint ignores docs; nothing executable changed).

## Rollback plan
Revert the commit (git mv is cleanly revertable).

## Dependencies
Best after tasks that edit docs text (04, 06, 07, 11, 13) to avoid rebase
churn — or before all of them; just not interleaved.

## Risk / complexity / token size
None functional; medium effort (many small edits). ~12k tokens.

## Suggested order
14.
