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

Reconciled **2026-11-06** against `origin/main` = `302e26d`. The delta has
grown 16 -> 30 -> 38 -> **44 commits**. The installable surface is the same
FIVE paths as at 38 -- all three binaries plus the two comment-only
`systemd/` files -- so nothing new has to be carried; what changed is the
content of the three binaries.

An earlier reconciliation recorded `bin/domum-media-report` as *unchanged since
2026-10-11*, which by then was false: it carries the recovery-pack contents
reader. That is exactly what re-measuring is for -- the stale table would have
told an operator that file did not need deploying. It is checked on its own
path every time now, because it installs to `/usr/local/lib/domum-media/`
rather than `/usr/local/bin/`.

---

## 1. Current state, measured

Production has **no drift**: every installed file matches the revision the
checkout is on, and that revision was identified by hash rather than read from
a file that could have been edited.

```
installed domum-media         sha256 5e65f06c8a7a…
installed domum-media-backup  sha256 08a81ba20658…
installed domum-media-report  sha256 d813ae0e4181…   (/usr/local/lib/domum-media/)
                              -> all three equal bin/* at a63ad19, found by
                                 searching the last 60 commits of main by hash

/opt/.../bin/domum-media        == /usr/local/bin/domum-media                    (MATCH)
/opt/.../bin/domum-media-backup == /usr/local/bin/domum-media-backup             (MATCH)
/opt/.../bin/domum-media-report == /usr/local/lib/domum-media/domum-media-report (MATCH)
```

Re-measured 2026-11-06, all three. The report library is checked explicitly
now because it is installed to a **different directory** from the two
binaries: a verification that assumes `/usr/local/bin/<name>` reports it as
ABSENT and reads as drift. That is not hypothetical -- it happened while
writing this refresh.

The installed-vs-checkout equality is the deployment script's own invariant,
and it holds right now — so a run of it starts from a clean base.

## 2. What would change

44 commits, of which the **installable** surface is still small and
UNCHANGED IN SHAPE since the 38-commit reconciliation. Re-measured 2026-11-06
with `git diff --name-only a63ad19..main -- bin systemd install.sh`:

| repository path | installed as | changes? | note |
|---|---|---|---|
| `bin/domum-media` | `/usr/local/bin/domum-media` | **yes** | |
| `bin/domum-media-backup` | `/usr/local/bin/domum-media-backup` | **yes** | |
| `bin/domum-media-report` | `/usr/local/lib/domum-media/domum-media-report` | **yes — new in this delta** | the pack-contents reader; see §2a |
| `systemd/domum-media-btrfs-scrub.timer` | `/etc/systemd/system/…` | **yes, COMMENT-ONLY** | see §3 |
| `systemd/auto-enable.timers` | read from the **checkout**, never installed | **yes, COMMENT-ONLY** | see §3a |
| `operator/rehearsals/*` (9 new files) | **nothing** — checkout only | new | see §3a |
| `domum-media-weekly-report.service` / `.timer` | `/etc/systemd/system/…` | no | |

### 2a. The report library is now in the delta

`bin/domum-media-report` carries the recovery-pack contents reader: the report
used to gate "covered by the recovery pack" on the pack being *available*,
which means the archive exists and not that the item is inside it. It now
distinguishes **confirmed** from **declared** from **absent-and-escalated**,
and a pack that recorded no contents reads as *declared* rather than as
uncovered — so deploying the CLI without the report library would leave the
`PACK_ITEMS` the CLI writes with nothing reading them.

The deployment script already covers it: its `TARGETS` lists
`$LIB_DIR/domum-media-report:bin/domum-media-report`, so no change is needed
there. Only this document was wrong.

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
| the capture manifest's `RESULT`/`ITEMS`/`SCHEMA_VERSION` checks | capture-only, and no capture exists on this host |
| `backup-scope`, and `storage archives` asking it | new subcommand; `storage archives` needs root and is operator-run |
| the recovery-pack contents gate in the report | the installed report cannot write `PACK_ITEMS`, so it reads `null` → *declared*, which is the pre-existing wording |
| `config_set`'s atomic publish | needs an interruption **during** `configure`, which is operator-run and rare |
| `config_set`'s `ENVIRON` quoting fix | **this host's `awk` is mawk 1.3.4, which does not strip the escapes** — measured; the defect is live only on a different `awk` |
| `prompt_choice`'s EOF guard | needs `configure` with stdin at EOF **and** a config value outside its option list |

| `list_latest_snapshots` keeping "cannot tell" apart from "none" | only `--snapshots`, which is operator-run and read-only |
| `traefik_acme_source` / `do_verify_restore` behavioural coverage | tests only; no production code changed |
| the compose `container_name` guard | a test; it asserts an invariant production already satisfies (all 13 services) |
| the stop verification's behavioural test | a test; the function itself is unchanged |

**Two of those deserve a sharper note, because "latent" is doing real work.**

`status`'s tier label and the `storage archives` off-host claim were **not**
latent: both were false statements the installed binary makes today. They are
reporting defects rather than data risks -- nothing is destroyed by them -- but
an operator reading `off-host copy: yes` beneath `this archive is the only
copy`, or `/srv/data = (snapshotted + backed up)`, is being told the wrong
thing right now. That is the strongest argument in this document for deploying.

And the **rollback menu** fix is latent only in the sense that nobody has typed
`0` at it. `domum-media rollback` with no subcommand drops straight into that
menu, and `0` applied the newest rollback point -- a restore over live state.
There is no timer involved; it needs an operator at a prompt.

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
