# Task 38 — Weekly health report  [shared-philosophy]

## Objective
Add a weekly operational report (text + retro-terminal HTML email) adapted
from domum-core's, with N100-specific sections: per-target backup
freshness, restore-verification status, NVMe wear trend, btrfs status,
capacity, pending updates, and findings/suggested actions.

## Files involved
- `bin/domum-media` — new `report` subcommand family
- `systemd/domum-media-report.service` + `.timer` (new; disabled per task
  21)
- `docs/` — report doc (mirroring the sibling's operations doc)

## Reason
Checkup answers "is anything wrong right now"; the weekly report answers
"what direction is this host heading" — wear trends, capacity growth,
update debt, backup-cadence drift — and lands in the inbox without being
asked. Porting source: `domum-core/bin/domum-core:4001-4137`
(`report_render_weekly`: boxed header + Verdict, BACKUPS, SYSTEM, TRENDS,
DRIVE HEALTH, SERVICES, UPDATES, LOG ERRORS, FINDINGS, SUGGESTED ACTIONS)
and `:4154-4226` (`report_render_weekly_html`, the line-parser that
re-skins the text into the dark retro-terminal HTML). Keep that exact
visual style — it's the house style.

## Implementation plan
1. Port the text renderer structure; replace Pi sections with N100 ones:
   BACKUPS reads task 30's per-target heartbeats + task 32's
   restore-verify state; DRIVE HEALTH reads task 37's NVMe/btrfs probes;
   SERVICES/UPDATES read the catalog and update state.
2. Port the HTML renderer as-is (it parses the text output — section
   divider convention must match).
3. Email via the existing recovery-pack email plumbing if SMTP is
   configured; otherwise write to the state dir and note in checkup.
4. Trend history: reuse the sibling's simple state-file history approach
   (record weekly values, render sparklines) for disk usage and NVMe wear.
5. systemd pair, disabled by default; document the enable step.

## Testing plan
- Fixture state files → text and HTML render deterministically; HTML
  validates (well-formed, renders in a mail client).
- Live host run end-to-end; email received if SMTP configured.
- Missing-state grace: fresh host with no history renders without errors.

## Rollback plan
Disable timer, revert. State history files are additive.

## Dependencies
Task 37 (probes), tasks 30/32 (the backup states it reports), task 21
(timer policy), task 16 (catalog for service/update sections).

## Risk / complexity / token size
Low (read-only + email). Medium. ~12k tokens.

## Suggested order
Phase 6, after task 37.
