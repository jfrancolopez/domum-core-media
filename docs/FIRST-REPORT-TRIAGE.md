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

### The design defect: a transient condition fails the week

| timer | schedule | observed 2026-10-25 |
|---|---|---|
| `domum-media-backup` | daily 02:30, `RandomizedDelaySec=15m` | started 02:40:56 |
| `domum-media-check` | Sun 03:30, `RandomizedDelaySec=20m` | started 03:36:56 |

Only **56 minutes** apart, and the gap can be as little as ~45 minutes in the
worst randomisation. A backup still holding the lock when the check starts
produces exit 11.

Measured for scale: the 2026-10-27 backup took **37 seconds**
(`ExecMainStartTimestamp` 02:40:56 → `ExecMainExitTimestamp` 02:41:33), so a
56-minute gap is normally ample. **Which lock holder was present at 03:36:56 on
2026-10-25 cannot be established without the journal**, and the journal is
root-only. It was either a long backup run that night or a stale lock from an
interrupted earlier run.

It is **not** still held: the nightly backup takes the same lock and succeeded
at `2026-10-27T02:41:32-04:00` in 37 seconds, which a stale lock would have
prevented. The condition was transient.

Either way the structural point stands: **a lock collision is transient, and the
current design converts it into a whole week with no integrity check and no
retention, with no retry.** That is worth fixing — and fixing it is a change to
a scheduled job, so it is an operator decision, not something to do silently.

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

## 5. Open, needing root or an operator decision

1. **Which process held the restic lock at 03:36:56 on 2026-10-25.** Needs
   `journalctl -u domum-media-check.service`.
2. ~~Whether the lock is still held.~~ **Answered, and it is not.** The nightly
   backup takes the same repository lock, and it succeeded at
   `2026-10-27T02:41:32-04:00` in 37 seconds. A held or stale lock would have
   failed that run too. **So the 2026-10-25 failure was transient and is not
   currently reproducible** — no `restic list locks` and no credentials
   required to establish it.
3. **Restarting `immich_machine_learning`.** A container restart; deploys
   nothing, but it is a production service action.
4. **Re-spacing the backup and check timers**, or making the check tolerate a
   lock. A change to a scheduled job.
