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

## Notification: silence means healthy (added 2026-10-20)

The weekly unit now has a second step:

```
ExecStart=/usr/local/bin/domum-media report --write
ExecStart=-/usr/local/bin/domum-media health-notify
```

Writing a report nobody reads is not monitoring. Before this, every scheduled
job on the host wrote to the journal, the weekly report wrote a file, and
**nothing read either** — the operator learned the state of the server by
running commands by hand.

`health-notify` runs the host, storage and off-site checks and mails the
operator **only when something needs attention**:

| state | behaviour |
|---|---|
| healthy | **no mail at all** — silence is the healthy signal |
| expected activity (new photos awaiting the nightly backup) | recorded in the summary, not mailed |
| action required | one mail, naming the remedy |
| critical (data-loss or recovery risk) | one mail, named first |

Silence is only trustworthy if the checks cannot fail quietly, so **an input
that cannot be read is a WARNING naming the remedy — never a pass.** The host
has no `smartmontools`, so disk health currently reports
`UNKNOWN: smartmontools is not installed` with the `apt-get` line, rather than
"no disk warnings" from a host that cannot read SMART at all.

### What it checks that nothing checked before

- **failed systemd units**, and separately the **last exit status of every
  domum timer's service** — `systemctl --failed` lists only units *currently*
  failed, so a weekly restic integrity check that failed and was restarted was
  completely invisible;
- **Btrfs device error counters** per Btrfs root; a non-zero `corruption_errs`
  is a checksum failure on the photo tier and is reported as such;
- **Btrfs scrub age**, because a library that is never scrubbed has nothing
  looking for silent bit-rot;
- **physical disk health** via `smartctl` when present;
- **Immich off-site coverage**, read from the recorded evidence: only a
  `BACKUP GAP` is a defect; originals ingested after the backup window are
  reported as healthy, because a report that flags normal uploads every day is
  one the operator stops reading.

### Before enabling it

```
sudo domum-media health-notify --dry-run     # see the summary, send nothing
sudo domum-media health-notify --force       # prove delivery works
```

The timer stays **out of `systemd/auto-enable.timers`** deliberately: it sends
mail, so enabling it is an operator decision. Delivery reuses the SMTP
transport the recovery pack already uses — `smtp_send_message` is now the one
implementation — so there is no new dependency and no second place to get
credentials wrong. With delivery disabled it prints the summary and says so; it
never reports mail as delivered when it was not.

**But "says so" meant the journal, and nothing read the journal.** With delivery
disabled `health_notify_cmd` warns and returns **0**, so the unit stays green —
and `RECOVERY_PACK_EMAIL_ENABLED` **defaults to 0**. A host with this timer
enabled and that flag unset would write every alert it ever raised to a log,
discard it, and look perfectly healthy. `checkup_notification_path` now reports
that contradiction — timer enabled, delivery off — as CRITICAL, in
`checkup_collect_all` so all three consumers see it. It fires only on the
contradiction: an operator who does not want mail disables the timer, and that
is not a finding. When the flag is set it reports the transport as
**configured**, which is deliberately not a claim that anything was delivered.

## Delivery — PROVEN 2026-10-25, by the weekly timer rather than by a test

This section used to say no mail had ever been sent and that `health-notify` had
only run with `--dry-run`. That was wrong, and the paragraph below contained the
reason: *"neither can the weekly timer while the host is healthy."* **The host
was not healthy.**

`domum-media-check.service` entered the failed state at **2026-10-25 03:36:56**
(restic exit 11, a stale lock). `domum-media-weekly-report.service` ran at
**08:25:56** that morning with `Result=success`, `ExecMainStatus=0`. So:

| step | established by |
|---|---|
| mail delivery enabled (`RECOVERY_PACK_EMAIL_ENABLED=1`) | the **root-run** off-host audit printed `off-host delivery ENABLED` on 2026-10-12, which is emitted only when the flag is 1; the config's mtime is 2026-09-23, so it had not changed |
| a CRITICAL was present, so the silence gate could not be taken | the check unit failed five hours earlier; the then-installed binary (`383f9e6`, hash `8760cfa51f3d`) emitted a critical for a non-zero timer exit |
| `--dry-run` was not in play | the unit's `ExecStart` passes no flag |
| a delivery failure would have failed the unit | `health-notify` is the second `ExecStart` with no `-` prefix, and a failed `smtp_send_message` calls `die` |
| the unit exited 0 | `ExecMainStatus=0`, `Result=success` |

Every zero-exit path is accounted for, so **the message was delivered**. The
operator independently confirms receiving mail from this host.

**Enumerate every zero-exit path before an exit status proves anything.** The
first version of this conclusion checked two of the three and would have claimed
proof from a status equally consistent with *delivery being switched off* — and
the production config is `0600 root`, so an unprivileged account cannot tell the
two apart without the flag measurement above.

What this does and does not establish: the transport worked **once**, to one
address, proven by inference from an exit status. It is sound only because the
delivery failure is fatal, and it would collapse the moment anyone put a `-` on
that `ExecStart`. Silence now means "nothing needed attention" rather than
"nothing needed attention OR mail is broken".

### The controlled real-email test — STILL REQUIRES OPERATOR APPROVAL

`--force` remains the way to re-prove delivery on demand, and it still sends a
real message, so it still needs approval.

### Why a real send still needs proving

Everything up to the transport is verified: the checks run, the verdict is
computed, the silence gate works in both directions (observed in production
2026-10-21, HEALTHY → ACTION REQUIRED → HEALTHY on real state), the message is
assembled, and the unit's `ExecStart` prefixes make a delivery failure fail the
unit.

A dry run cannot prove the transport. Neither can the weekly timer **while the
host is healthy**, because a healthy host sends nothing — which is the contract.
That qualifier is what made the old claim wrong: on 2026-10-25 the host was not
healthy, the timer sent, and the send succeeded. A single real send in response
to a real finding is better evidence than a test, because it exercises the path
the operator actually depends on.

### The test

```
sudo domum-media health-notify --force
```

`--force` is the only thing that bypasses the silence gate. It sends the real
summary, through the real transport, to the configured recipient.

**What to expect, given the host is currently healthy:**

| | |
|---|---|
| subject | `domum-media: healthy` |
| body | the same text `--dry-run` printed: `VERDICT: HEALTHY`, the check counts, and the two follow-up commands |
| recipient | `RECOVERY_PACK_EMAIL_TO`, falling back to `DOMUM_EMAIL` |
| exit 0 | `health-notify: sent -- <subject>` |
| exit non-zero | the send failed; the message is removed and nothing claims it was delivered |

**Preconditions.** `RECOVERY_PACK_EMAIL_ENABLED` must be `1` and the SMTP host,
port and credential files must be configured. If email is disabled the command
reports that and does **not** fail the timer — deliberately, so a host with no
mail configured does not show a failed unit every week, but it never pretends
the mail was delivered either.

**It prints no credentials.** `smtp_send_message` is the one transport and reads
the username and password from their files; neither the summary, the message
headers nor any log line contains them.

### Why `--force` and not a separate test mode

A dedicated test path would prove a dedicated test path works. `--force` sends
the *real* message through the *real* function the timer calls, so the only
difference from a genuine alert is the verdict it happens to be carrying.

### After it succeeds

Nothing to undo — `--force` changes no state and sets no flag. The next weekly
run returns to the normal contract: silence while healthy, one mail when
something needs attention. Record the date here so a future reader knows
delivery was proven and when.

**Delivery proven:** not yet.
