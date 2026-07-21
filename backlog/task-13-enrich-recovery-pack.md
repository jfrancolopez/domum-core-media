# Task 13 — Enrich the recovery pack  [shared-philosophy]

## Objective
Port the useful extras domum-core's recovery pack has and this one lacks:
service inventory with image digests, backup-target metadata, a dry-run flag,
and tighter file permissions on the archive. Additionally (2026-07-21 audit):
stage the Immich DB password fingerprint — without it a fresh-host restore is
deadlocked — and add an interruption-safe cleanup trap so a failed pack run
can never leave plaintext secrets behind.

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

Two additions found by the 2026-07-21 audit:
- **Fingerprint deadlock:** `apply` dies when Immich postgres data exists
  but `/var/lib/domum-media/immich/db_password.sha256` is absent
  (`validate_immich_db_password_state`, bin/domum-media ~629–633), and pack
  staging (~2964–2972) only copies config + `/etc/domum-core-media/secrets`
  — never state root. A host rebuilt from pack + restic restores the DB but
  not the fingerprint, and `apply` refuses to start. Stage the fingerprint
  file under `meta/` and document restoring it in the pack's RESTORE
  instructions.
- **Plaintext trap:** staging assembles plaintext secrets in a mktemp dir;
  an interrupted run leaves them on disk. domum-core has the same gap —
  add the trap here, don't copy the omission.

## Implementation plan
1. Add the two meta files to the staging dir, adapted to this CLI's helpers
   (`service_lifecycle_specs` for enabled services + `docker inspect` digests;
   `grep -E '^BACKUP_TARGET_[A-Z]+_(REPOSITORY|ENABLED|TYPE)=' "$CFG_FILE"`).
2. Stage `$DOMUM_STATE_ROOT/immich/db_password.sha256` (via
   `immich_db_password_fingerprint_file()`) into `meta/`; skip with a loud
   warning if absent (Immich disabled is fine, Immich enabled without it is
   a finding).
3. Wrap staging in a `trap ... EXIT INT TERM` that removes the mktemp dir,
   so no failure mode leaves plaintext secrets; write the encrypted archive
   atomically (`.tmp` + `mv`).
4. `chmod 600 "$archive_enc"` after encryption.
5. Add `--dry-run` to `recovery-pack create` (list what would be staged, no
   writes) and an `inspect` subcommand mirroring domum-core's.
6. Update the pack's `RESTORE` instructions (including "restore the
   fingerprint to `/var/lib/domum-media/immich/` before running apply") and
   `docs/disaster-recovery.md` contents list.

## Testing plan
- `recovery-pack create --dry-run` prints the plan, writes nothing.
- Real run on the host: decrypt with the offline key, verify the meta files
  (including the fingerprint) and MANIFEST entries; archive mode is 600.
- Kill the pack run mid-staging (SIGINT): no plaintext staging dir remains,
  no partial archive lands.
- Fresh-host simulation: restore fingerprint per the RESTORE instructions →
  the `apply` guard passes.
- Smoke test + shellcheck pass.

## Rollback plan
Revert; packs return to the current contents (older packs stay valid).

## Dependencies
None.

## Risk / complexity / token size
Low (additive to staging). Small–medium. ~9k tokens.

## Suggested order
Phase 4, after task 31.
