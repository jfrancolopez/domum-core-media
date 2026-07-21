# Task 32 — Monthly restore verification  [shared-philosophy]

## Objective
Prove recoverability automatically: a monthly timer restores a
representative subset from restic into a scratch directory and validates it
— sample media files, the Immich SQL dump (integrity + importability
check), config, and the recovery-pack decryption path. Failures surface in
checkup.

## Files involved
- `bin/domum-media` — new `backup verify-restore` subcommand
- `systemd/domum-media-restore-verify.service` + `.timer` (new; installed
  disabled per task 21)
- `bin/domum-media` `checkup` — read the verification state file
- `docs/SETUP-RESTIC.md`, `docs/disaster-recovery.md`

## Reason
`restic check` proves repository consistency, not recoverability — it
cannot detect "the dump we've been shipping is truncated" or "the include
list stopped covering the library." Porting source:
`domum-core/bin/domum-core:1477-1535` (`verify_restore_cmd`: pick target,
restore latest snapshot into staging with `--include` filters, validate
staging, write `last-restore-verify` state, skip with a free-space guard)
and `restore_verify_validate_staging` (:1440-1475), plus its systemd pair
(`OnCalendar=*-*-01`, `Persistent=true`, long `TimeoutStartSec`).

## Implementation plan
1. Port the command shape; media-specific validation set:
   - `immich-postgres.dump.sql.gz` present, `gzip -t` passes, contains a
     `CREATE TABLE` for a core Immich table (cheap grep — full import drill
     stays a manual/quarterly exercise via task 31).
   - N sample files from the Immich library restore byte-identical
     (checksum against live copies).
   - Config + rendered compose restore and parse.
   - Latest recovery pack decrypts with the configured AGE key material
     available on-host (structure check only; the offline-key fire drill
     remains manual).
2. Free-space guard and scratch-dir cleanup (trap) like the sibling.
3. Write `last-restore-verify` state (timestamp, target, result); `checkup`
   flags a missing/old/failed verification.
4. New systemd service+timer following task 21's disabled-by-default
   policy; monthly, persistent.

## Operator runbook
One-time after landing: `systemctl enable --now
domum-media-restore-verify.timer`, then run it once manually
(`domum-media backup verify-restore`) and confirm checkup shows the fresh
state.

## Testing plan
- Live host manual run: passes end-to-end, state written, scratch dir gone.
- Sabotage fixture (delete the dump from a staging copy / corrupt a sample
  checksum): run fails, checkup flags it.
- Low-space simulation: clean skip with a visible warning, no partial
  state.

## Rollback plan
Disable the timer, revert; verification state files are ignored by old
code.

## Dependencies
Tasks 30 (per-target state to pick a target), 31 (import machinery it
spot-checks), 21 (timer policy), 01 and 24 (restore paths it exercises must
be safe first).

## Risk / complexity / token size
Low (read-only against production data; writes only to scratch + state).
Medium. ~10k tokens.

## Suggested order
Phase 4, last task of the phase.
