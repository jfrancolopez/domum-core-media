# Task 21 — Installer timers disabled-by-default  [shared-philosophy]

## Objective
Stop `install.sh` from enabling systemd timers automatically. Install
unit/timer files and `daemon-reload` only; the operator enables timers
explicitly once the host is configured — the same policy domum-core uses.

## Files involved
- `install.sh` — `install_systemd_units()` (~lines 141–147) currently runs
  `systemctl enable --now` on all six timers
- `bin/domum-media` — the systemd install path, if it duplicates the enable
- `docs/SETUP-N100.md`, `docs/CLI-CHEATSHEET.md` — post-install enable step

## Reason
The installer arms all six timers before any config exists; `load_cfg`
`die`s on the missing config, so early firings just fail — noise at best,
a masked real failure at worst. The old backlog README defended auto-enable
as "documented intent (resettable checkout, timers as part of bootstrap) —
revisit only if it ever surprises you." It surprised: timers firing and
failing on an unconfigured host is exactly the surprise, so the stance is
reversed (decision 2026-07-21). Porting source:
`domum-core/bin/domum-core:4629-4665` (`install_maintenance_unit_files`
installs and reloads only; `schedule_install_maintenance` logs
"NOT enabling" and prints the manual `systemctl enable --now` list).

## Implementation plan
1. In `install.sh`, replace `systemctl enable --now` with `install` of the
   unit files + `systemctl daemon-reload`, then print the explicit enable
   commands for each timer (copy the domum-core output shape).
2. Mirror the same behavior in any `bin/domum-media` systemd-install
   subcommand; on update, reinstall changed unit files without touching
   enablement state.
3. Update docs: post-configure step "enable the timers you want" with the
   full list.
4. Idempotency: re-running the installer must preserve the operator's
   current enable/disable choices.

## Operator runbook
One-time, on the live N100 after this lands (the update will NOT disable
already-enabled timers):
1. `systemctl list-timers 'domum-media-*'` — confirm current state.
2. Nothing to do if all six are already enabled and wanted. On any future
   reinstall/rebuild, enable explicitly:
   `systemctl enable --now domum-media-backup.timer domum-media-check.timer
   domum-media-btrfs-snapshot.timer domum-media-image-refresh.timer
   domum-media-host-update.timer domum-media-dr-reminder.timer`
   (drop any you don't want armed).

## Testing plan
- Fresh-checkout install into a scratch prefix: unit files installed, zero
  timers enabled, enable-command list printed.
- Re-run installer on a host with timers already enabled: enablement
  untouched.
- `systemd-analyze verify` passes on installed units.

## Rollback plan
Revert; installer returns to auto-enabling. Already-enabled timers are
never touched either way.

## Dependencies
None. Blocks task 32 (new restore-verify timer must follow the
disabled-by-default convention).

## Risk / complexity / token size
Low (installer behavior only; production host already has timers enabled).
Small. ~5k tokens.

## Suggested order
Phase 1, after task 20.
