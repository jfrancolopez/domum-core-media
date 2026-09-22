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

## Truthfulness rules

The report is only worth having if it never overstates safety. It follows
three rules, each covered by `tests/operational-report-smoke.sh`:

1. **Unknown is not healthy.** State that could not be inspected is reported
   as `unknown` or `null` and raises a finding. It is never rendered as
   success. A container Docker cannot be consulted about reports
   `running: null`, not `running: false`.
2. **Absent evidence is not proof.** Where the host records no durable
   evidence, the report says so instead of inferring it from something
   adjacent. Restore verification and per-target backup results are currently
   reported as `unknown` for exactly this reason (see *Known gaps*).
3. **Snapshot claims must be probed, not assumed.** Each stateful service path
   is tested with `btrfs subvolume show`. An ordinary directory is reported
   `unprotected` with the reason, and raises a critical finding. `/srv/data`
   being Btrfs is never treated as evidence that a service path is protected.

## Schema

`--json` emits a stable document. Consumers should key off `schema_version`.

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Bumped on incompatible change. |
| `generated_at` | ISO-8601 generation time. |
| `overall` | `healthy`, `warning`, or `critical`, derived from `findings`. |
| `host` | Uptime, load, memory, temperature, pending reboot. |
| `filesystems[]` | Capacity and used percent per mount. |
| `failed_systemd_units` | Count and unit names; `count: null` when undeterminable. |
| `containers[]` | Expected container, running state, health, restarts, image identity. |
| `immich` | Enablement (from config), library and validated dump artefacts. |
| `backups` | Heartbeat, timers, latest snapshot per target, per-target state, restore verification. |
| `recovery_pack` | Presence and age. |
| `updates` | Image refresh policy and timer, plus staged candidates. |
| `snapshot_protection.services[]` | Per-service `protected` / `unprotected` / `unknown`, with a reason. |
| `findings[]` | `level`, `message`, `action`. |

Every finding carries a remediation `action`. `overall` is `critical` if any
finding is critical, `warning` if any finding exists, otherwise `healthy`.

## Weekly timer

`domum-media-weekly-report.timer` runs `domum-media report --write` on Sundays
at 08:00 with a 45-minute randomised delay.

**It is disabled by default and is not enabled by the installer.** Enable it
deliberately once the output has been reviewed on the host:

```bash
sudo systemctl enable --now domum-media-weekly-report.timer
```

## Known gaps

These are reported honestly as `unknown` rather than guessed. Closing them
means recording new durable state, which is separate work.

- **Per-target backup results.** The daily backup writes a single aggregate
  heartbeat and no per-target run record, so `backups.targets[].last_run` is
  `unknown`. The aggregate heartbeat is written only after every enabled target
  succeeds, so it is not a false-success signal — but it cannot attribute a
  result to a specific target.
- **Restore verification.** Nothing on the host records a restore drill, so
  `backups.restore_verification` is `unknown`. The P0 scratch restore was
  performed and documented manually; it left no machine-readable state.

## Related

- [P0-BACKUP-BASELINE.md](P0-BACKUP-BASELINE.md) — accepted backup baseline and
  the degraded local-snapshot record.
- [CORE-MEDIA-OPERATIONS-AUDIT.md](CORE-MEDIA-OPERATIONS-AUDIT.md) — the
  capability audit this report implements.
- [CHECKUP.md](CHECKUP.md) — the immediate, interactive health sweep.
