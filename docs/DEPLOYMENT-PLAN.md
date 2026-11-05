# Deployment plan — production `a63ad19` → current `origin/main`

**Reviewed, not executed.** Changing `/opt/domum-core-media` or anything running
on the host is an approval boundary of its own; landing code on `main` is not.
Nothing below has been run.

**This file used to be `DEPLOYMENT-PLAN-2026-11-02.md`, and the date in the
filename was the problem.** A plan is a living document about two revisions,
and a dated name implies it was reviewed for whatever `main` is now. It was
not: between 11-02 and 11-04 the delta grew a **unit file**, which falsified
the old plan's central claim ("two binaries, no unit files"), and the operator
installed and enabled the scrub timer, which falsified one of its latency
claims. Re-read the measurements below against `git rev-parse origin/main`
rather than trusting the heading.

Reconciled **2026-11-05** against `origin/main` = `1bbab11`. The delta has
grown from 16 commits to **30**, and the installable surface is unchanged in
shape -- which is the point of re-measuring rather than assuming.

---

## 1. Current state, measured

Production has **no drift**: every installed file matches the revision the
checkout is on, and that revision was identified by hash rather than read from
a file that could have been edited.

```
installed domum-media         sha256 5e65f06c8a7a…
installed domum-media-backup  sha256 08a81ba20658…
                              -> both equal bin/* at a63ad19, found by
                                 searching the last 60 commits of main by hash
/opt/.../bin/domum-media        == /usr/local/bin/domum-media        (byte-identical)
/opt/.../bin/domum-media-backup == /usr/local/bin/domum-media-backup (byte-identical)
```

The installed-vs-checkout equality is the deployment script's own invariant,
and it holds right now — so a run of it starts from a clean base.

## 2. What would change

30 commits, of which the **installable** surface is still small. Re-measured
2026-11-05 with `git diff --name-status a63ad19..main -- bin/ systemd/ operator/
install.sh`:

| repository path | installed as | changes? | note |
|---|---|---|---|
| `bin/domum-media` | `/usr/local/bin/domum-media` | **yes** | |
| `bin/domum-media-backup` | `/usr/local/bin/domum-media-backup` | **yes** | |
| `bin/domum-media-report` | `/usr/local/lib/domum-media/domum-media-report` | no | unchanged since 2026-10-11 |
| `systemd/domum-media-btrfs-scrub.timer` | `/etc/systemd/system/…` | **yes, COMMENT-ONLY** | see §3 |
| `systemd/auto-enable.timers` | read from the **checkout**, never installed | **yes, COMMENT-ONLY** | see §3a |
| `operator/rehearsals/*` (9 new files) | **nothing** — checkout only | new | see §3a |
| `domum-media-weekly-report.service` / `.timer` | `/etc/systemd/system/…` | no | |

Both `systemd/` changes were verified comment-only by diffing with comments and
blank lines stripped: **no directive changed in either**. `bin/domum-media-report`
is unchanged, so the report library is not redeployed.

Target hashes are deliberately **not** quoted here. One goes stale the moment
`main` moves — the same mistake as storing a revision constant, and an earlier
draft of this plan quoted one that was wrong within the hour. Read the target
side from the dry run, which computes it against the revision you are actually
deploying.

## 3. The unit file: changed, comment-only, and NOT carried by the script

`systemd/domum-media-btrfs-scrub.timer` differs from the installed copy. Every
**directive** is byte-identical — `Description`, `OnCalendar`,
`RandomizedDelaySec`, `Persistent`, `Unit`, `WantedBy`. The only change is the
comment block, which used to justify `Persistent=true` with *"unlike `snapshot
prune` this job deletes nothing"*: true of the comparison and not the same
claim as "safe to fire unattended", because **a default scrub is read-write**
and repairs DUP metadata.

Two consequences, both stated rather than left to be discovered:

- **the narrow deployment script does not install it.**
  `operator/domum-media-deploy-reporting-fixes.sh` never mentions
  `btrfs-scrub`; its `UNIT_TARGETS` holds only the two weekly-report units. So
  a run installs the two binaries, no unit changes, `UNITS_CHANGED=0`, and
  therefore **no `daemon-reload` happens at all**. The enabled, active scrub
  timer is not touched and its next elapse cannot be re-randomised.
- **the script's "installed == checkout" invariant does not cover it.** Step 5
  iterates `$TARGETS $UNIT_TARGETS`, so the invariant is true of the files it
  lists and silent about the rest. It will report success while the installed
  scrub timer still carries the old comment. That is acceptable **here** only
  because the change is comment-only — and it is the same shape as the
  2026-10-20 incident where a deployment "installed one binary, skipped BOTH
  unit files, and printed `== deployed ==`". A substantive unit change would
  need adding to `UNIT_TARGETS` first.

`install.sh` and `converge_local_installation` install `systemd/*.service` and
`systemd/*.timer` wholesale, so they *would* carry it — which is exactly why
neither is the mechanism for a narrow deployment.

### 3a. Two things the fast-forward carries that are not "installed"

`systemd/auto-enable.timers` is **read from the checkout** by `install.sh` and
by `sync_timer_overrides`; it is never copied into `/etc`. So the fast-forward
is the whole of its deployment, and its change here is comment-only — it
corrects a stale description of what a Btrfs scrub does, which had survived in
the one file that decides what installation may enable unattended. (The
accurate statement, and why the old one was wrong, is in `CLAUDE.md`. It is
paraphrased here rather than quoted, so the repository-wide check that hunts
that claim keeps its full strictness.) Nothing about which timers are listed
changed.

The nine new `operator/rehearsals/*` files are the same: they land in the
checkout and nothing installs them. They are shellchecked by CI and
deliberately **not run** by it, because they need the production images and a
Docker daemon.

**And it is the ONLY unit that differs, measured rather than inferred.** Every
installed `domum-media-*.service` and `domum-media-*.timer` was compared by
sha256 against the repository copy, 2026-11-04:

```
16 units compared        15 same, 1 DIFFERS
differing                domum-media-btrfs-scrub.timer   (comment-only, §3)
```

That matters because §2 derives the installable surface from
`git diff a63ad19..main`, which is a claim about the *repository*. This is the
same claim checked from the other end — against what is actually on the host —
and the two agree. The other 15 include `domum-media-image-refresh.timer`,
which is byte-identical and remains `disabled, inactive`.

## 4. THE ONE DATED ITEM: the scrub timer is now enabled, and production lacks
the duplicate-run protection

This is the only part of this plan with a deadline, and it exists because of a
change the operator made on 2026-11-03, not because of anything in the code.

```
domum-media-btrfs-scrub.timer   enabled, active
next elapse                     Sun 2026-12-06 05:34:39 EST
LAST                            -   (never fired)
ExecStart                       /usr/local/bin/domum-media storage scrub start --limit 150M
```

The installed binary **does** implement `storage scrub start --limit`, verified
statically — so the timer will work. What it does **not** have is the
duplicate-run protection:

```
btrfs_scrub_running  in /usr/local/bin/domum-media : 0 occurrences
btrfs_scrub_running  in bin/domum-media at main    : 2 occurrences
```

`btrfs scrub start` **refuses** when a scrub is already running on that
filesystem, returning non-zero. In the installed binary that lands in the
generic arm:

```sh
*) echo "  result          : scrub FAILED on $root (exit $rc)"
   (( worst < 1 )) && worst=1 ;;
```

`return 1` → the oneshot `ExecStart` carries no `-` prefix → the unit **fails**
→ `checkup_systemd_health` reports a failed domum unit as **CRITICAL** →
`health-notify` mails it. Mail delivery is proven working (2026-10-25). So a
scrub already in progress at 05:34 on the first Sunday of a month would send a
CRITICAL for an entirely normal condition — the precise false alarm the fix in
`main` exists to prevent, in the one path whose whole value is that silence
means something.

Probability is low: it needs a manual scrub, or a previous run, overlapping a
monthly window against a ~25-minute throttled pass. The consequence is what
matters, not the odds. **Deploying before 2026-12-06 retires it; after that the
window reopens monthly.**

Nothing else in the delta is urgent, which §6 states plainly.

## 5. What the deployment does NOT do

- **no container** is created, recreated, restarted or stopped. It installs
  files; it never calls compose;
- **no timer is enabled or started.** The scrub timer is already enabled (by
  the operator) and the deployment neither re-enables nor starts it; the
  image-refresh timer stays absent from `auto-enable.timers`;
- **no `daemon-reload`** — see §3, `UNITS_CHANGED` stays 0;
- **no handover.** `operator/domum-media-deploy-reporting-fixes.sh` is itself
  unchanged between `a63ad19` and `main`, so "a script cannot deploy its own
  replacement" does not arise. The dry run says so;
- **no data, snapshot, image or repository is touched**, and no restic
  operation runs.

## 6. What it fixes that is LATENT, not firing

Stated plainly because urgency would be the wrong conclusion. The one
non-latent item is §4.

| fix | why it is not firing now |
|---|---|
| `checkup`'s `waiting_count` abort | `$DOMUM_STATE_ROOT/image-updates` exists here — the operator's recent `checkup` produced output, which it could not have if this were aborting |
| `quiesce_immich_postgres` abort | needs the Docker daemon to be unreachable |
| `dr_immich_summary` abort | needs `thumbs/` or `encoded-video/` absent, i.e. a freshly restored host |
| phase-B live-photo abort | needs a user with no live photo; the admin has 7,432 |
| readiness log in the upgrade | only runs during `updates apply --service <s>`, which no timer invokes |
| recovery-pack off-host check | reports healthy on this host; a regression guard |
| volume dump/restore naming its cause | `VOLUME_UPGRADE_ENABLED=0`; nothing reaches it |
| capture / verify / restore / pack / unpack / verify-pack / archive identity / `pack-offhost` | new subcommands; nothing invokes them, and no timer references any |
| helper-based consistent capture for jellyfin and kavita | only reachable through `storage capture-state`, which nothing schedules |
| the visible `UNPROVEN` reason, and `SQLITE_HELPER` in the manifest | same: capture-only |

**`health-notify`'s two reporting fixes are already deployed** — they landed in
`a63ad19` itself (#145/#146 are in production). This plan is not carrying them,
and the earlier draft that said it was had the revision boundary wrong.

## 7. Rehearsal evidence

`tests/deploy-reporting-rehearsal-smoke.sh`, run 2026-11-04 at `ca9bcc9`:
**PASS**, 13 sections. It proves, against a disposable fixture with a fake git
upstream and a recording `systemctl` stub, that the script refuses a wrong
`--expect-revision` before mutating anything; refuses a dirty or diverged
checkout; installs only what differs and verifies it; installs a unit 0644 and
enables/starts **nothing**; does not reinstall an unchanged unit; leaves the
untracked production config alone; asserts the `--json` classification contract
and refuses a regressed build; treats a reported BACKUP GAP as a finding rather
than a deployment failure; hands over exactly once when the script itself
changes; and runs nothing on a dry run.

A wrapper that has only been read has not been tested — so this is the evidence
that matters, not the review above it.

## 8. The run, and the verification after it

Both need root, which this account cannot obtain (`sudo -n true` → *a password
is required*, 0 NOPASSWD entries). They are the operator's to run.

```sh
# 1. Dry run. Mutates nothing and prints the file table with both hash sides.
sudo /opt/domum-core-media/operator/domum-media-deploy-reporting-fixes.sh

# 2. The real run, pinned to the revision that was reviewed.
sudo /opt/domum-core-media/operator/domum-media-deploy-reporting-fixes.sh \
     --confirm --expect-revision=<the sha the dry run named>
```

`--expect-revision` is supplied by the operator and deliberately not stored: a
revision constant inside the repository it pins goes stale by construction.

Afterwards, read-only:

```sh
sudo domum-media checkup                      # expect the pack line to answer, not "could not ask"
sudo domum-media-backup pack-offhost          # expect: off-host mail enabled, verdict offhost, exit 0
systemctl list-timers domum-media-btrfs-scrub.timer   # expect next elapse unchanged
sha256sum /usr/local/bin/domum-media /opt/domum-core-media/bin/domum-media

# And the new capability. It writes only under /srv/data, starts no
# container, and resolves no service's image tag:
sudo domum-media storage capture-state navidrome   # expect CAPTURE_MODE=consistent
sudo domum-media storage capture-state jellyfin    # expect consistent too, via the helper
#   -- if jellyfin says UNPROVEN it will now SAY why, which is the thing to read
```

The first is the one that proves the deployment did something observable: on
`a63ad19` the pack check does not exist, and on this revision it asks the
backup CLI and reports `A recovery pack is delivered off-host…`. Before the
deployment the same check correctly reports *"could not be checked: …
pack-offhost did not answer (exit 1)"* — measured today, with zero criticals.
