# Task 37 — Checkup enrichment (NVMe, btrfs, headroom)

## Objective
Extend `domum-media checkup` with the N100-specific hardware and filesystem
probes it lacks: NVMe SMART health and wear, drive temperatures, btrfs
scrub/device-error status, disk and inode headroom on `/srv/data` and
`/srv/media`, and `/dev/dri` presence.

## Files involved
- `bin/domum-media` — `checkup` implementation
- `docs/CHECKUP.md`
- `install.sh` / docs — note the `smartmontools` dependency if not present

## Reason
Checkup covers services and backups but is blind to the layer that actually
kills a media host: NVMe wear-out under Immich ML + transcode churn, btrfs
device errors that scrubs would catch, and full filesystems. domum-core's
checkup/report has SMART and temperature probes for the Pi's storage; this
is the N100 equivalent (NVMe via `smartctl -H` + wear/percentage-used,
btrfs via `btrfs scrub status` and `btrfs device stats`).

## Implementation plan
1. NVMe: `smartctl -H` verdict, `percentage_used`, media errors,
   temperature — degrade gracefully when `smartctl` is missing (report
   "not installed", don't fail checkup).
2. btrfs: `btrfs device stats` (non-zero counters = finding),
   `btrfs scrub status` (never run / stale > 45 days = finding).
3. Capacity: percent-used and inode headroom for the data and media roots;
   thresholds warn at 80%, flag at 90%.
4. `/dev/dri/renderD128` presence when any HW-transcode service is enabled
   (feeds task 39).
5. Each probe is read-only and individually fault-isolated (one failing
   probe never aborts checkup — match the existing checkup style).

## Testing plan
- Live host run: new sections render with real values.
- Missing-tool path: `smartctl` absent → graceful note.
- Threshold fixtures: fake a >90% filesystem via a small loopback mount →
  finding appears.
- Read-only guarantee: no file/dir/network mutation during checkup (this
  repo's checkup is clean today — keep it that way; the sibling's is not).

## Rollback plan
Revert; checkup returns to current sections.

## Dependencies
None hard. Blocks task 38 (the report reuses these probes).

## Risk / complexity / token size
Low (read-only probes). Small–medium. ~7k tokens.

## Suggested order
Phase 6, after tasks 14/15.
