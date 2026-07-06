# Task 13 — Enrich the recovery pack  [shared-philosophy]

## Objective
Port the useful extras domum-core's recovery pack has and this one lacks:
service inventory with image digests, backup-target metadata, a dry-run flag,
and tighter file permissions on the archive.

## Files involved
- `bin/domum-media` — `recovery_pack_create()` (~line 2944),
  `recovery_pack_cmd()`, `usage()`
- `docs/disaster-recovery.md` (contents list)

## Reason
Both repos build AGE-encrypted packs, but domum-core's additionally captures:
- `meta/service-inventory.txt` — enabled services + running image digests
  (what exactly was deployed at pack time — gold during a rebuild);
- `meta/backup-targets.txt` — restic repository URLs (not passwords), so the
  rebuild host knows where the data lives without guessing;
- a `--dry-run` mode that shows what would be staged;
- `chmod 600` on the encrypted archive.

This pack runs nightly (refreshed by the backup timer), so improvements
compound. domum-core's richer subcommands (`send-latest`, `email-test`,
`inspect`) are nice-to-have — include `inspect` (trivial, prints the age
command to list contents) and skip the email extras unless email is enabled
here (`RECOVERY_PACK_EMAIL_ENABLED` defaults 0 and SMTP host is unset —
check the live conf before bothering).

## Implementation plan
1. Add the two meta files to the staging dir, adapted to this CLI's helpers
   (`service_lifecycle_specs` for enabled services + `docker inspect` digests;
   `grep -E '^BACKUP_TARGET_[A-Z]+_(REPOSITORY|ENABLED|TYPE)=' "$CFG_FILE"`).
2. `chmod 600 "$archive_enc"` after encryption.
3. Add `--dry-run` to `recovery-pack create` (list what would be staged, no
   writes) and an `inspect` subcommand mirroring domum-core's.
4. Update the pack's `RESTORE` instructions and `docs/disaster-recovery.md`
   contents list to mention the new meta files.

## Testing plan
- `recovery-pack create --dry-run` prints the plan, writes nothing.
- Real run on the host: decrypt with the offline key, verify both meta files
  and MANIFEST entries; archive mode is 600.
- Smoke test + shellcheck pass.

## Rollback plan
Revert; packs return to the current contents (older packs stay valid).

## Dependencies
None.

## Risk / complexity / token size
Low (additive to staging). Small. ~8k tokens.

## Suggested order
13.
