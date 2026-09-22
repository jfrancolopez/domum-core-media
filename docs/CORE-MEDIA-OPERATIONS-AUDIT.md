# Core and Media operational visibility audit

Audit date: September 8, 2026

Reference revisions:

- `domum-core-media`: `4b45e7ed4653233eb9289cc9833139b7a645543f`
- `domum-core`: `ef65daef76e5177a95c28d6e234607f5f3ca4894`

`domum-core` is a read-only pattern reference. The repositories remain separate
and platform-specific behavior is not copied blindly.

## Capability matrix

| Capability | Classification | Recommendation | Finding |
|---|---|---|---|
| Basic human status | EQUIVALENT | ADAPT FOR MEDIA | Both show containers, storage, and backup freshness, but Media suppresses inspection failures and neither gives sufficient systemd detail. |
| Immediate checkup | WEAKER | ADAPT FOR MEDIA | Media has categorized findings and prose-array JSON, but lacks failed units, timer results, Btrfs truth, SMART/NVMe, inode, and mount probes. |
| Specialist doctor commands | WEAKER | KEEP MEDIA | Media's Immich/SFTP diagnostics are useful; add aggregate systemd/storage evidence rather than replacing them. |
| Weekly text/HTML report | MISSING | PORT FROM CORE | Reuse the plain-text-first structure, verdict, trends, and multipart email shape with N100-specific data. |
| Expected-service catalog | EQUIVALENT | KEEP MEDIA | Media already has lifecycle/image tables; consolidate reporting reads without a broad catalog rewrite first. |
| Failed-unit detection | MISSING | REDESIGN | Neither implementation reports it adequately. Add explicit unit/result/exit evidence. |
| Backup target visibility | WEAKER | ADAPT FOR MEDIA | Media has strong transport and identity pinning but only one aggregate heartbeat and no per-run state. |
| Atomic Immich dump | MEDIA BETTER | KEEP MEDIA | Preserve pipeline status, structural validation, fsync, and atomic replacement. |
| Restore verification | MISSING | PORT FROM CORE | Build a guarded Media-specific scratch restore and durable result state; never restore into live paths. |
| Recovery pack | MEDIA BETTER | KEEP MEDIA | Preserve strict allowlisting, repository metadata, fingerprint, atomic encryption, and offline age identity. Improve truthful status/inspection. |
| Storage reporting | WEAKER | ADAPT FOR MEDIA | Report capacity, filesystem, Btrfs device/scrub state, and explicit lack of service-subvolume protection. |
| Container health | WEAKER | ADAPT FOR MEDIA | Report expected/running/health/restarts. Do not treat Docker `starting` as healthy or require Docker for the diagnostic unit. |
| Update candidate state | EQUIVALENT | ADAPT FOR MEDIA | Media tracks first-seen candidates and Immich bundles; add age, running/staged identity, and last-check evidence without deploying. |
| Update rollback | WEAKER | REDESIGN | Current ordinary directories and previous-image behavior do not provide a safe rollback. Keep image refresh disabled. |
| Pending reboot | EQUIVALENT | KEEP MEDIA | Both inspect `/var/run/reboot-required`; label it pending reboot, not reboot detection. |
| Stable machine state | WEAKER | REDESIGN | Prose arrays are not a stable API. Add schema, generated time, verdict, component IDs, numeric metrics, and state timestamps. |
| CLI discoverability | WEAKER | ADAPT FOR MEDIA | Preserve existing command families, add coherent status/report/backup/update/recovery status help, and reject unknown options. |
| systemd automation | INTENTIONALLY DIFFERENT | ADAPT FOR MEDIA | Keep timer policy explicit and image deployment disabled. Avoid clock-only sequencing and concurrent Restic operations. |
| Pi hardware probes | INTENTIONALLY DIFFERENT | DO NOT PORT | Replace `vcgencmd` and Pi power probes with discovered N100/NVMe/Btrfs probes. |

## Patterns to reuse

- Collect health findings once and render them as terminal, JSON, and report
  output.
- Use expected enabled services rather than arbitrary Docker container counts.
- Keep plain text as the canonical report and derive HTML/email from it.
- Record positive evidence alongside warnings and failures.
- Persist per-target backup results and restore-verification state.
- Preserve candidate `FIRST_SEEN_TS` when a mutable image tag is unchanged and
  reset it when the digest moves.
- Include stable schema versions in machine-readable state.
- Install report timers disabled by default and require explicit operator
  enablement.

## Core behavior not to port

- Aggregate backup heartbeats that become fresh after only partial success.
- Nonfatal failed or stale service exports.
- Restore verification that assumes disabled services are enabled.
- Missing expected containers reported only as warnings.
- `status` creating Docker networks or reports mutating history during preview.
- Claims that all images are current without a recent successful registry
  check.
- Pi-specific temperature, throttling, and PMIC probes.
- Hardcoded NVMe device names; critical devices must be derived from mounts.
- Docker `Requires=` on diagnostics intended to report Docker failure.
- Time-gap-only sequencing and jobs without mutual-exclusion locks.
- Prose-only JSON without schema, timestamps, stable finding IDs, or metrics.

## Media implementation order

1. Finish the unattended scheduled-backup acceptance and persist its result.
2. Make snapshot and backup claims truthful in status/checkup.
3. Add stable status data collection and JSON rendering.
4. Add fast systemd, container, storage, Immich, backup, and update findings.
5. Build weekly text output from the same collected data.
6. Add optional HTML/email and a disabled-by-default weekly timer.
7. Validate live output before auditing update deployment gates.

No Btrfs migration, image deployment, automatic image refresh, repository
cleanup, or application upgrade is part of this visibility phase.
