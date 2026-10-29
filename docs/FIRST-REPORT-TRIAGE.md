# What the first real HTML report found — 2026-10-27

The report was deployed and emailed from production, and its first run surfaced
two genuine problems and five reporting defects. Everything below is measured.

## 1. `domum-media-check.service` exited 11 — the repository was LOCKED

**Not corruption. Not authentication. Not a missing repository.**

restic 0.18.0's own exit-status table, read out of the binary:

```
Exit status is 10 if the repository does not exist.
Exit status is 11 if the repository is already locked.
Exit status is 12 if the password is incorrect.
```

The project contains no `exit 11` anywhere, so the status came from restic
itself. The unit runs:

```
ExecStart=/usr/local/bin/domum-media-backup --check
ExecStart=/usr/local/bin/domum-media-backup --weekly-retention
```

`--check` → `do_check` → `restic_check_for` → `restic … check`. So **the
integrity check never ran** on 2026-10-25; it could not take the lock.

### Two consequences, one of them easy to miss

- **Repository integrity is UNVERIFIED since then**, not damaged. Nothing
  examined the repository, so nothing found anything wrong — and nothing
  confirmed anything right either.
- **`--weekly-retention` never ran.** It is the *second* `ExecStart` with no
  `-` prefix, and systemd stops a `oneshot` unit at the first failing
  unprefixed line. So retention was skipped that week. That direction is safe
  — it keeps *more* snapshots, not fewer — but it is a silent consequence of a
  transient lock.

### The cause, from the journal: a STALE LOCK left by the Mac

```
Oct 25 03:37:04  create exclusive lock for repository
Oct 25 03:37:10  repo already locked, waiting up to 0s for the lock
Oct 25 03:37:11  unable to create lock in backend: repository is already locked
                 by PID 14058 on lamac by franco.lopez (UID 501, GID 20)
Oct 25 03:37:11  lock was created at 2026-10-20 10:47:46 (112h49m24.776935342s ago)
Oct 25 03:37:11  the `unlock` command can be used to remove stale locks
```

The lock was created **2026-10-20 10:47:46 from the operator's Mac** — the
independent Hetzner recovery test — and was still present **112h49m** later. It
is not a timer collision and not corruption.

### A WRONG INFERENCE, corrected

An earlier revision of this document claimed the lock was *not* still held,
reasoning that the nightly backup takes the same repository lock and had
succeeded. **That was wrong**, and the error is instructive:

- `check` logs `create exclusive lock for repository` — it needs an **exclusive**
  lock.
- The nightly backup kept succeeding *alongside* the Mac's lock, every night
  from 2026-10-21 to 2026-10-27.

So the Mac's lock **coexists with `backup` and blocks the exclusive lock the
check needs**. "A successful backup" proves only that no *exclusive* lock is
held; it says nothing about the one that was. Reasoning from "the same lock"
when two commands take different lock types produced a confident wrong answer
about whether a problem was still live.

### It recurs, and it blocks retention too

Because the lock is still there, **the check fails every Sunday until it is
removed**. And `--weekly-retention` is the second `ExecStart` with no `-`
prefix, so it never runs — *and* `forget`/`prune` need an exclusive lock
themselves, so they would fail anyway.

Measured from the journal: retention last ran successfully on **2026-10-18**
(removed 7 snapshots, pruned 17.044 MiB). It has not run since. That direction
is safe — snapshots accumulate rather than disappear — but it is silent.

### How the report now says this

Exit 11 on `domum-media-check.service` is no longer reported as a bare
non-zero exit, which read like possible corruption. It now reads:

```
✗ domum-media-check.service could not LOCK the repository (restic exit 11), so
  the integrity check never ran. This is not evidence of damage -- and not
  evidence of health either.
  1. journalctl -u domum-media-check.service -n 30 --no-pager
  2. a stale lock blocks every EXCLUSIVE restic operation -- the weekly check
     AND retention -- while still allowing backups, so it recurs until removed.
     Removing it is 'restic unlock', which needs operator approval.
```

The wording is scoped to that unit: exit 11 only means "already locked" for the
check, and any other status or unit is still reported generically.

### The remedy, which needs approval

`restic unlock` removes stale locks. It is in this project's
approval-required list, so it is **not** run automatically. The operator-facing
form is:

```
sudo domum-media-backup --unlock cloud
```

**This is new and ships with the next deployment** — it did not exist when the
lock was found, which is why the first version of this document offered a
command that does not run. It is a thin wrapper, because `restic unlock` needs
the repository credentials and only `restic_for_target` knows how to assemble
them (password file, SFTP command, env files).

**Why it is safe**, from restic's own help:

> The "unlock" command removes stale locks that have been created by other
> restic processes.

Only locks restic considers **stale** are removed — a lock held by a live
process is left alone — and restic 0.18.0 has no flag to force-remove a live
one. So it cannot interrupt a running backup. It lists the locks before and
after, read-only, and is on no timer.

### Separately: the timers are close together

`backup` daily 02:30 `+15m`, `check` Sun 03:30 `+20m` — as little as ~45
minutes apart. That was *not* the cause here, and the 2026-10-27 backup took 37
seconds, so the gap is normally ample. Worth knowing, not worth changing on
this evidence.

## 2. `immich_machine_learning` is unhealthy — the photos are fine

`immich_server`, `immich_postgres` and `immich_redis` are all **healthy**. All
eleven containers are **running**. Only the machine-learning container is
unhealthy, and the cause is specific:

```
Oct 19:  Starting gunicorn → Listening at :3003 → Booting worker with pid 17
         → Started server process → Application startup complete
Oct 26:  Starting gunicorn → Listening at :3003 → Control socket listening
         → (nothing)
```

The gunicorn **master bound the socket but the worker never finished booting**.
The worker process exists — and has consumed **`00:00:00` CPU in 28 hours**, in
state `S`. It is blocked, not spinning.

```
RestartCount : 0          (not a crash loop)
OOMKilled    : false      (not memory)
FailingStreak: 3018       (~29 h — it has NEVER passed since this start)
Started      : 2026-10-26T09:54:55Z
```

That start time matches `domum-media-host-update.service` running Mon 05:53
EDT, which restarted the stack. Network from the container is fine (outbound
443 connects) and the model-cache volume is mounted `rw`.

**What it costs:** smart search, face detection and CLIP embeddings are not
running, and new uploads get no ML-derived metadata. **No data is at risk** —
originals are served by `immich_server`, which is healthy, and 23,262 of 23,262
originals are in the latest off-site snapshot with zero gap.

**The remedy is a restart of that one container, and it deploys nothing.**
Measured: the running image id equals what `immich-machine-learning:release`
currently resolves to, so `compose restart` resolves no new image. `up -d` must
still not be used — it reconciles.

## 3. Reporting defects found and fixed

| defect | what it said | why it mattered |
|---|---|---|
| systemd bullet | `systemd unit ● has failed.` | `--no-legend` keeps the leading `●`, so `$1` was the bullet. And because `●` does not match `domum-media*`, a **failed domum unit was downgraded from CRITICAL to a warning** |
| placeholder | `systemctl status <unit>` | shipped a literal placeholder the operator had to fill in |
| ambiguous counts | `Up 7 of 8` | counted *logical services*; immich is one service and four containers, so it read as though three of eleven containers were missing |
| unsafe remedy | `host-upgrade --force` | installs packages and may reboot, recommended merely because a reboot was pending |
| wrong wrapper | `docker compose logs …` | bypasses the project's layered compose fragments; `domum-media compose` is the wrapper |
| vague finding | `immich is UNHEALTHY` | four containers, one unhealthy, and no indication which |

All fixed. The reboot remedy is now read-only and names the consequence that
actually matters — every timer is `Persistent=true`, so a reboot runs missed
jobs immediately, **including `snapshot prune`, which deletes**.

Findings are now also **de-duplicated** by exact text: a failed unit is found
both in `systemctl --failed` and in its timer's last exit status, and printing
it twice made the host look twice as bad as it was.

## 4. What is NOT wrong

- Btrfs scrub: clean, zero errors, 216.42 GiB verified.
- Btrfs device error counters: all zero.
- Both SMART self-assessments: passed.
- Immich off-site coverage: 23,262 of 23,262, gap 0, pending 0, unknown 0.
- Backup: completed 6 h before the report.
- Email delivery: the multipart HTML report arrived.

## 5. Open, needing an operator decision

1. **Remove the stale lock.** `restic unlock`, after confirming from the journal
   that PID 14058 on `lamac` is not a live process. Until then the weekly
   integrity check and retention both fail every Sunday.
2. **Nothing else.** The lock holder is identified, the condition is understood,
   and `immich_machine_learning` was restarted and is healthy
   (`/ping` → `200 pong`, `FailingStreak 0`).

## 6. Resolved during this triage

- `immich_machine_learning` restarted: `healthy`, startup completed, endpoint
  answering. Smart search, face detection and OCR will resume; the queued jobs
  that failed while it was down are visible in `immich_server`'s log as
  `failed for all URLs` and Immich will retry them.
- The lock holder identified from the journal.
- Six reporting defects fixed, and exit 11 given its own actionable finding.

---

## 7. Outcome, measured 2026-10-28

The lock was removed and the repository verified. Both runs are the operator's,
quoted from their terminal:

| when | command | result |
|---|---|---|
| 2026-10-27 16:32 | `--unlock cloud` | listed 1 lock (`49249f2e…`), `successfully removed 1 locks` |
| 2026-10-27 16:32 | `--check` | repo `c1d39ac9`, 14 index files, **22 snapshots**, `no errors were found` |
| 2026-10-28 10:48 | `--unlock cloud` | **no locks remained** |
| 2026-10-28 10:49 | `--check` | repo `c1d39ac9`, 15 index files, **23 snapshots**, `no errors were found` |

The second pair is the one that matters: with no lock present beforehand, the
check still passed, so the Oct 27 result was not a one-off. The snapshot count
rising 22 → 23 is the nightly backup, which never stopped.

What these two runs prove, and what they do not. `restic check` without
`--read-data` verifies the repository's **structure** — indexes, trees, blob
metadata, snapshot reachability. It does **not** read pack contents, so it is
not a read-data verification and certainly not a restore test. Those are
`--check-deep` (a subset) and `--check-cloud-deep` (everything), and the
recovery claims that rest on actual restores are tracked separately in
`docs/DISASTER-RECOVERY-STATUS.md`. The evidence record this triage added keeps
the distinction in a `MODE` field for exactly that reason.

### The failure survived its own cause, and the report said so in the present tense

`systemd` keeps a unit's failed state until **that unit** runs again. A manual
`domum-media-backup --check` does not clear it. So on 2026-10-28, three days
after the lock was removed and two successful checks later, this was still live:

```
$ systemctl --failed
● domum-media-check.service   loaded failed failed   domum-media: restic repository integrity check
$ systemctl show -p ExecMainStatus --value domum-media-check.service
11
```

and `checkup_systemd_health`, driven against that real state, still produced:

```
✗ domum-media-check.service could not LOCK the repository (restic exit 11), so
  the integrity check never ran. This is not evidence of damage -- and not
  evidence of health either.
  ...
  2. a stale lock blocks every EXCLUSIVE restic operation ... Removing it is
     'restic unlock', which needs operator approval
```

Every word of that was true of the 2026-10-25 run and false of the present. The
host was telling the operator to perform an approval-gated operation they had
already completed twice, and giving them no way to see that their remediation
had worked. It would have gone on saying it until the next scheduled run on
2026-11-01.

This is the project's recurring defect family — a stale proof stated as a
present-tense claim — arriving in the opposite direction: a stale **failure**.
The unit state was real and still worth reporting. The **diagnosis** was stale.

### Why nothing could know

Neither `do_check` nor `do_weekly_retention` recorded anything. The per-target
backup run evidence (`<target>-run.env`) had existed for months; the two
exclusive operations had no equivalent, so a successful check left no trace
anywhere but the journal and the operator's scrollback. There was no input from
which the report could have drawn a different conclusion.

### What changed

`restic_check_for` and `restic_forget_for` now record per-target evidence in
`$REPO_META_DIR` — the same directory, ownership and `0600` mode as the existing
run records:

```
SCHEMA_VERSION=1
TARGET=cloud
OPERATION=check          # or retention
RESULT=success           # or failure
MODE=structure           # read-data-subset | read-data | forget-prune
STARTED_TS=…
FINISHED_TS=…
```

A manual run is recorded exactly like a scheduled one. That is the point: the
operator's remediation becomes evidence the report can read.

`check_unit_verdict` is the one implementation of the comparison, consulted by
both places that report this unit. It reads the unit's own
`ExecMainExitTimestamp` and asks whether every enabled target has a recorded
successful check newer than it:

| verdict | meaning | reported as |
|---|---|---|
| `superseded` | **every** enabled target verified since the failed run | warning, named and dated, remedy `systemctl reset-failed` |
| `outstanding` | at least one target has not been verified since | unchanged: critical, `restic unlock` advice stands |
| `unknown` | no target enumerable, or the timestamp unreadable | unchanged: critical |

Three properties are deliberate:

- **`superseded` requires every target, never one.** One repository's clean
  check says nothing about another's, which is the same reasoning that makes the
  upgrade gate per-service rather than counted.
- **Absent evidence changes nothing.** This is production as it stands today —
  the recording is not deployed, so the finding behaves exactly as it did
  before. A fix that only reads correctly once new evidence appears would have
  silenced a live finding in the meantime.
- **An unreadable timestamp is `unknown`, not `superseded`.** That direction
  would quietly downgrade a live failure.

The `restic unlock` advice is **not** repeated in the superseded case. Retention
is now stated with its recorded date instead of in the abstract, because
"retention is blocked" does not tell the operator how many weeks of snapshots
have accumulated.

### A standalone "retention is overdue" check was deliberately NOT added

It is the obvious next step and it is wrong today. The record cannot exist
until retention next runs, and a check that fires on an absent input would mail
"retention status unknown" on a healthy host the moment it was deployed — a
false alarm manufactured on purpose, in the one notification path whose value
rests on silence meaning something. Retention recency is therefore surfaced
*inside* the already-critical check-failure finding, where it costs no new
alert. Once evidence exists on this host the standalone check becomes possible,
and it can then distinguish "never recorded" from "recorded and stale".

### Coverage

- `tests/restic-op-evidence-smoke.sh` — the writer and reader driven, never
  grepped: evidence recorded, `0600`, three distinct modes, restic's exit status
  preserved both ways, a recorded failure never read as a success, `superseded`
  requiring every target, `unknown` as its own answer, and a drift guard proving
  both CLIs default the evidence directory to the same path. 3 mutations, all
  killed.
- `tests/monitoring-completeness-smoke.sh` — five production-shaped sections
  plus a mutation: the staleness gate forced always-open must report an
  unverified repository as stale, and does.

### Still open for the operator

`systemctl reset-failed domum-media-check.service` clears the stale state. It
touches no repository, no data and no container, and the next scheduled run on
2026-11-01 is unaffected. Leaving it alone is also fine: that run will clear it
by succeeding.

---

## 8. Scheduled backup and retention audit, 2026-10-29

Read-only. No Restic operation was run for this audit.

### The two schedules, from systemd rather than from memory

| unit | `OnCalendar` | delay | `Persistent` | `ExecStart` |
|---|---|---|---|---|
| `domum-media-backup` | `*-*-* 02:30` | +15m | yes | `domum-media-backup` |
| `domum-media-check` | `Sun *-*-* 03:30` | +20m | yes | `--check`, then `--weekly-retention` |

`backup_target_retention` defaults **`cloud` to weekly** and `nas` to daily.
Only `cloud` is enabled (measured from the root-run `checkup`, where every
per-target line names `cloud` and none names `nas`). Therefore:

- `retention_targets daily` is **empty** — no daily retention runs on this host;
- retention happens **only on Sundays, only via the check unit**, and only if
  `--check` succeeds, because `--weekly-retention` is the second `ExecStart`
  and carries no `-` prefix.

### Backup success and retention success are different events

The daily run records **per-target backup evidence** (`<target>-run.env`,
`RESULT=success`) before retention is attempted, and writes the aggregate
heartbeat `$DOMUM_LOG_DIR/last-success` **after**. Retention records its own
`<target>-retention.env`. So the two are separately observable — which is the
point, and was not true before 2026-10-28.

### Was 2026-10-18 a missed operation or a missing record?

**Both, about different things, and the distinction matters.**

- **A genuinely missed operation.** The 2026-10-25 check exited 11, so the
  second `ExecStart` never ran and that Sunday's retention did not happen.
  Oct 18 → Oct 29 is therefore exactly **one** missed weekly run, not a long
  silent drift. The next opportunity is **Sun 2026-11-01 ~03:30–03:50**.
- **A missing record.** Retention recording shipped on 2026-10-28 and retention
  has not run since, so `no successful retention run is recorded` is literally
  true and deliberately does not claim retention has never happened.

Snapshots accumulating is the safe direction, and nothing was pruned.

### Exit 11 is reported as superseded without claiming the unit succeeded

Verified in the production report of 2026-10-29:

> `domum-media-check.service` exited 11 (repository already locked) **on its
> last scheduled run**, so **THAT run's** check never ran — but the repository
> has since been verified successfully (`cloud@…(structure)`).

It attributes the failure to that run, names the later verification with its
timestamp and **mode**, and never says the unit succeeded. The separate
`No systemd unit is in the failed state` line is a true statement about
`systemctl --failed` after the operator's `reset-failed`, which is a different
fact. The action states that the recorded exit status is replaced only when the
unit next runs.

### Will the next scheduled check update its recorded result?

Yes, and the installed binary was checked rather than assumed: `restic_check_for`
in `/usr/local/bin/domum-media-backup` calls `record_restic_operation` on both
the success and failure paths and returns restic's status unchanged. The unit
invokes `--check`, so `do_check` records once per enabled target. systemd
replaces `ExecMainStatus` on that run independently. If `--check` succeeds,
`--weekly-retention` then runs and records retention too.

### The defect this audit found

`do_daily_backup` called `restic_forget_for` unguarded under `set -e`, so a
retention failure aborted the run **before `heartbeat`** — reporting a fully
successful backup as a **stale** one and skipping the recovery-pack refresh.
`do_weekly_retention` had the same shape, letting the first target's failure
skip the rest. Latent on this host only because `retention_targets daily` is
empty. Fixed: every target is attempted, the must-happen steps complete, and
the run then fails naming retention.

### Two things deliberately NOT changed

- **`export TZ="${TZ:-UTC}"`** leaks the containers' timezone into the CLI, so
  `epoch_to_iso` prints UTC while the backup CLI records local time. Both denote
  the same instant. That `TZ=UTC` is load-bearing for the journal `--since`
  window, which carries a measured comment showing 1 match under `TZ=UTC` and 0
  under `TZ=America/New_York`. Tidying a timestamp is not worth breaking it.
- **No standalone "retention is overdue" check.** Its input only begins existing
  after the next retention run, so shipping it now would mail a false alarm on a
  healthy host. It becomes possible once Nov 1 has recorded a result.

### One read-only check still outstanding

`cloud`'s cadence is inferred from the code **default**, because the config is
`0600 root`. If it is overridden to `daily`, the daily retention path is live
rather than latent. The non-secret confirmation is:

```
sudo grep -nE '^BACKUP_TARGETS=|^BACKUP_TARGET_[A-Z]+_RETENTION=' \
  /opt/domum-core-media/config/domum-media.conf
```
