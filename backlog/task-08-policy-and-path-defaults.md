# Task 08 — Align BACKUP_POLICY defaults and state-root paths

## Objective
One default for `BACKUP_POLICY` across both scripts, and no hardcoded
`/var/lib/domum-media` where `$DOMUM_STATE_ROOT` exists.

## Files involved
- `bin/domum-media` — `load_cfg()` (STRICT default, ~line 48)
- `bin/domum-media-backup` — `do_daily_backup()` (`${BACKUP_POLICY:-BALANCED}`,
  ~line 510), `REPO_META_DIR` (~line 13), `immich_only_include_paths()`
  (~line 45)
- `bin/domum-media` — checkup's `meta_file="/var/lib/domum-media/backups/..."`
  (~line 3126)
- `config/domum-media.conf.example` (comment clarifying the default)

## Reason
Two quiet inconsistencies:
1. If the live conf ever loses its `BACKUP_POLICY` line, the CLI gates
   updates as **STRICT** while the backup script treats a failed Immich
   pg_dump as **BALANCED** (warn-and-continue). Same knob, two defaults —
   the failure mode is a backup run that soft-passed while the update gate
   believes policy is strict.
2. `REPO_META_DIR`, `immich_only_include_paths()`, and checkup's meta-file
   path hardcode `/var/lib/domum-media` instead of `$DOMUM_STATE_ROOT` /
   `$RECOVERY_PACK_DEST`. Anyone overriding `DOMUM_STATE_ROOT` (the CI env
   does exactly this) gets split state.

## Implementation plan
1. Pick STRICT as the shared default (the safer one; the example config
   explicitly sets BALANCED anyway, so live behavior doesn't change).
   Change the backup script's fallback to STRICT.
2. In `domum-media-backup`: derive `REPO_META_DIR` from
   `${DOMUM_STATE_ROOT:-/var/lib/domum-media}/backups` (note: load order —
   `DOMUM_STATE_ROOT` comes from the conf, so move the derivation into or
   after `load_cfg`). Use `$RECOVERY_PACK_DEST`-equivalent
   (`$DOMUM_STATE_ROOT/recovery-pack`) in `immich_only_include_paths`.
3. In checkup, build `meta_file` from the same derivation.
4. Confirm the example config's `BACKUP_TARGET_CLOUD_INCLUDE_PATHS` comment
   (which hardcodes the recovery-pack path) still matches.

## Testing plan
- Default paths unchanged on a host with stock config (`/var/lib/domum-media/...`).
- CI env (`DOMUM_STATE_ROOT=/tmp/domum-state`): smoke test still passes and
  no path under `/var/lib` is touched.
- Unset `BACKUP_POLICY` in a sandbox conf: both scripts report/behave STRICT.

## Rollback plan
Revert.

## Dependencies
None.

## Risk / complexity / token size
Low (defaults preserved for stock installs). Small. ~7k tokens.

## Suggested order
8.
