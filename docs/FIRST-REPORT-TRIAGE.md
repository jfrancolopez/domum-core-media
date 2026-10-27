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
