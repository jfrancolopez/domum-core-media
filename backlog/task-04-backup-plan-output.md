# Task 04 — Fix misleading `backup plan` output

## Objective
Make `domum-media backup plan <target>` describe what that target actually
backs up, instead of printing a static exclusion list that is wrong for the
NAS target.

## Files involved
- `bin/domum-media-backup` — `do_plan_target()` (~line 646)

## Reason
The "Excluded paths (by design)" section is hardcoded text claiming
`/srv/data/jellyfin`, `/srv/data/plex`, `/srv/data/navidrome`,
`/srv/data/calibre-web`, `/srv/data/kavita` are "not included". That is true
for the **cloud** target (immich-only default) but false for the **nas**
target, whose default include path is `/srv/data` — which sweeps in every one
of those app dirs. An operator planning a restore from the plan output would
have exactly backwards expectations about where app state can be recovered
from. The include-path logic is correct; only the plan's prose lies.

## Implementation plan
1. Compute the exclusion story per target instead of printing static text:
   - Always list the real runtime excludes (`backup-staging/*.tmp`,
     `${DOMUM_MEDIA_ROOT}/.cache/*`) from `restic_backup_to()`.
   - State plainly which tier the include paths cover, derived from
     `backup_target_include_paths()`: if the list covers `$DOMUM_DATA_ROOT`,
     say "all durable app state under /srv/data IS included"; if it is the
     immich-only profile, keep the current media/app exclusion list.
   - Always note `/srv/media` (movies/tv/music/books) is never included by
     default on any target.
2. Keep the output format otherwise unchanged (repo, ID, encryption lines).

## Testing plan
- `backup plan nas` (default include paths): shows /srv/data included, app
  dirs included, media excluded.
- `backup plan cloud`: immich-only story, matches
  `BACKUP_TARGET_CLOUD_INCLUDE_PATHS` in the example config.
- shellcheck + bash -n pass.

## Rollback plan
Revert; output returns to the static text.

## Dependencies
None.

## Risk / complexity / token size
Low (output-only change). Small. ~6k tokens.

## Suggested order
4.
