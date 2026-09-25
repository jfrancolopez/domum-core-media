# Weekly operational report

`domum-media report` answers one question: **can this host be left alone?**

It is read-only. It inspects host, container, storage, backup, update and
snapshot state, renders a verdict, and lists what to act on. It never changes
configuration, never deploys, never touches application data, and never runs
backup retention.

## Commands

```bash
sudo domum-media report            # human-readable text
sudo domum-media report --json     # machine-readable, stable schema
sudo domum-media report --write    # render text, and persist both forms
```

Root is required. The report reads root-owned runtime state under
`/var/lib/domum-media` and the live config; running it unprivileged would
degrade every probe to `unknown`, which is less useful than refusing.

`--write` persists to `/var/lib/domum-media/reports/` as `latest.json` and
`latest.txt`, mode `0600` in a `0700` directory, written atomically.

Plain `domum-media report` writes nothing. Its only outside call is a read-only
`restic snapshots` query per enabled target. Container health is read with
`docker inspect`; a container whose image defines no healthcheck reports
`no healthcheck`, which is a statement of fact and not a finding.

## Truthfulness rules

The report is only worth having if it never overstates safety. It follows
four rules, each covered by `tests/operational-report-smoke.sh`:

1. **Unknown is not healthy.** State that could not be inspected is reported
   as `unknown` or `null` and raises a finding. It is never rendered as
   success. A container Docker cannot be consulted about reports
   `running: null`, not `running: false`.
2. **Absent evidence is not proof.** Where the host records no durable
   evidence, the report says so instead of inferring it from something
   adjacent. Restore verification and per-target backup results are currently
   reported as `unknown` for exactly this reason (see *Known gaps*).
3. **A metric is only shown where it means something.** File and directory
   artefacts carry a `kind`. A file's `age_seconds` is its mtime and is
   meaningful. A **directory's** mtime changes only when its own entries change,
   so it says nothing about content written deeper inside: directories report
   `age_seconds: null`, expose their own mtime as `path_mtime`, and carry an
   `age_basis` saying so. The Immich library is the motivating case — its
   top-level mtime can be months old while photos are being written right now,
   and reporting that as an "age" would imply a stale library.
4. **Snapshot claims must be probed, not assumed.** Each stateful service path
   is tested with `btrfs subvolume show`. An ordinary directory is reported
   `unprotected` with the reason, and raises a critical finding. `/srv/data`
   being Btrfs is never treated as evidence that a service path is protected.

## Container state outside the protected tier

A writable mount outside `/srv/data` does **not** automatically mean a recovery
risk, so the report classifies rather than flags. Warning about a transcode
cache is alert fatigue, and alert fatigue is how a real gap goes unnoticed —
Traefik's ACME store sat unprotected precisely because nothing distinguished it
from noise.

| Class | Meaning | Finding |
|---|---|---|
| `durable` | real recovery cost if lost | **warning** |
| `media` | the replaceable tier, by architecture | listed only |
| `cache` | regenerable (`*/.cache/*`) | listed only |
| `ephemeral` | nothing meaningful to protect | listed only |

Detection is dynamic — every writable mount on every expected container — so a
volume added later cannot hide. Only the *class* consults a short declared
table, and **anything unrecognised defaults to `durable`**, so a new volume
fails loud rather than silent. An empty volume is classified `ephemeral`
because there is demonstrably nothing in it; that is measured, not assumed.

Current durable gaps on this host: Traefik's `acme.json` (ACME account key and
issued certificates) and Uptime Kuma's `kuma.db` (monitor definitions and
history). Neither is under the data root nor inside a backup include path.

## Finding severity

Severity follows the actual operational risk, not the bare absence of a
snapshot. The inputs are the snapshot gate's policy and the service's own risk
tier (`service_strict_backup_required`, which the CLI already uses to decide
whether a backup is mandatory before an update).

| Condition | Level | Why |
|---|---|---|
| Unprotected, `SNAPSHOT_POLICY` **not** `REQUIRED` | `critical` | A stateful operation can proceed with no rollback point. |
| Unprotected, gate enforcing, **strict** service (Immich) | `warning` | Degraded: risky operations are refused, but recovery would depend on restic alone. |
| Unprotected, gate enforcing, standard service | `info` | Known absence for rebuildable state; risky operations are refused. |

Severity therefore **escalates** if the gate is turned off. It is never softened
to make the report look healthy.

The same principle applies to the image-refresh freeze. The freeze is enforced
by the **timer**, not by `IMAGE_AUTO_UPDATE_ENABLED`, so the report reads the
timer:

| Condition | Level |
|---|---|
| Image-refresh timer enabled | `critical` — automatic deployment is no longer frozen |
| Policy set but timer disabled | `warning` — the freeze holds, but the config disagrees with intent |

Staged update candidates are reported as **one** aggregate finding with a count
and the oldest age, not one warning per image. A deliberate freeze must not
generate seven warnings every week; that is the alert fatigue the severity model
exists to prevent. The wording says whether they can actually deploy, derived
from the timer rather than assumed.

`overall` is `critical` if any finding is critical, `warning` if any is a
warning, otherwise `healthy`. An `info` finding records a known, accepted
absence and does not move the verdict — otherwise the report would read as
degraded permanently and stop carrying information.

## Schema

`--json` emits a stable document. Consumers should key off `schema_version`.

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Bumped on incompatible change. Currently `2`. |
| `generated_at` | ISO-8601 generation time. |
| `overall` | `healthy`, `warning`, or `critical`, derived from `findings`. |
| `host` | Uptime, load, memory, temperature, pending reboot. |
| `filesystems[]` | Capacity and used percent per mount. |
| `failed_systemd_units` | Count and unit names; `count: null` when undeterminable. |
| `containers[]` | Expected container, running state, health (`no healthcheck` when the image defines none), restarts, image identity. |
| `immich.library` / `immich.database_dump` | `kind` (`file`/`directory`/`missing`), size, `path_mtime`, `age_seconds` (null for directories), `age_basis`. |
| `immich` | Enablement (from config), library and validated dump artefacts. |
| `backups` | Heartbeat, timers, latest snapshot per target, per-target state, restore verification. |
| `recovery_pack` | Presence and age. |
| `updates` | Image refresh policy and timer, plus staged candidates. |
| `snapshot_protection` | `policy`, `enforced`, and per-service `protected` / `unprotected` / `unknown` with a reason and a risk `tier`. |
| `findings[]` | `level` (`critical` / `warning` / `info`), `message`, `action`. |

Every finding carries a remediation `action`. `overall` is `critical` if any
finding is critical, `warning` if any finding exists, otherwise `healthy`.

## Weekly timer

`domum-media-weekly-report.timer` runs `domum-media report --write` on Sundays
at 08:00 with a 45-minute randomised delay.

**It is disabled by default and is not enabled by the installer.** Enable it
deliberately once the output has been reviewed on the host:

```bash
# The unit is NOT installed by default -- it is in the repository but not in
# /etc/systemd/system, so this would fail with "Unit not found" as written.
# Install it first:
sudo install -m 0644 /opt/domum-core-media/systemd/domum-media-weekly-report.service \
                     /opt/domum-core-media/systemd/domum-media-weekly-report.timer \
                     /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now domum-media-weekly-report.timer
```

## Known gaps

These are reported honestly as `unknown` rather than guessed. Closing them
means recording new durable state, which is separate work.

- **Per-target backup results** are now recorded. After each target the backup
  wrapper writes `/var/lib/domum-media/backups/<target>-run.env` atomically with
  the target name, result, start and finish times, the snapshot id it created,
  the pinned repository identity, and the **scope** — which configured include
  paths were actually backed up, and which were skipped because they do not
  exist. A success that cannot name its scope can overstate what it protected.

  The attempt is marked `running` before anything that can abort, so a killed
  or rejected run reads as `incomplete` rather than leaving the previous
  success in place. The report reads the record directly and never infers a
  target's result from the aggregate heartbeat.

  A target reports `unknown` until its first recorded run — evidence appears
  after the next scheduled backup. That is the honest state, not a defect.
- **Restore verification** records both what the most recent attempt did and
  when verification last genuinely passed; a failure preserves the latter rather
  than erasing it. The mechanism:
  `domum-media backup verify-restore <target>` restores the Immich dump into an
  isolated scratch directory, revalidates it, and records the result. See
  [RESTORE-VERIFICATION.md](RESTORE-VERIFICATION.md).

  It reports `unknown` until that command has actually run and passed. The P0
  scratch restore is valid historical evidence but left no machine-readable
  state, and is deliberately not converted into a record.

## Related

- [P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) — accepted backup baseline and
  the degraded local-snapshot record.
- [CORE-MEDIA-OPERATIONS-AUDIT.md](CORE-MEDIA-OPERATIONS-AUDIT.md) — the
  capability audit this report implements.
- [CHECKUP.md](CHECKUP.md) — the immediate, interactive health sweep.
