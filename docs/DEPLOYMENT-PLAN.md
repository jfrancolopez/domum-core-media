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

Reconciled **2026-11-10** against `origin/main` = `bddab55`, **61 commits**
ahead of production. The count is recorded once, here, and is re-derived with
`git rev-list --count a63ad19..origin/main` -- a running tally in prose rots the
same way a baked hash does, and this paragraph had grown one.

What matters is not the count but the SHAPE, which has changed twice in a week:
the installable surface went from five paths to **six** when
`systemd/domum-media-weekly-report.service` gained a directive change, and then
grew a whole second KIND of change when the security workstream added compose
files -- see §10, which is the part to read before sizing any of this.

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

The delta (count in the header) has an **installable** surface that is still
small, but it has NOT kept its shape: it went from five paths to six when the
weekly-report unit gained a directive change, and then gained a second KIND of
change -- compose -- which §10 covers and this table does not. The table below
is the NARROW surface, i.e. what the deploy script carries. Re-measure with
`git diff --name-only a63ad19..origin/main -- bin systemd compose config`:

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

## 3. The SCRUB timer's unit: changed, comment-only, and NOT carried by the script

This section is about one unit. There are now THREE changed unit files and they
are not alike: `auto-enable.timers` and the scrub timer are comment-only and the
narrow script does not carry them, while
`systemd/domum-media-weekly-report.service` is a **directive** change that the
script does carry (§9). The heading used to say "the unit file", which read as a
statement about all of them.

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
OnCalendar                      Sun *-*-01..07 05:30:00
RandomizedDelaySec              20m        -> fires 05:30-05:50
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

---

## 9. THE WEEKLY NOTIFICATION CHANGE, and the timer activation

### 9.1 Why the operator received no report on 2026-11-08

Diagnosed from the production journal, not inferred:

```
domum-media-weekly-report.service  Main PID 646759 (code=exited, status=0/SUCCESS)
                                   finished Sun 2026-11-08 08:02:14 EST
report generated 08:01:56 -> 08:02:08, every section present
[domum-media] health-notify: nothing needs attention; no mail sent
```

**The job ran and succeeded; delivery was suppressed by policy** — 2 warnings,
0 actions, 0 critical, and the silence gate held as designed. Not SMTP, not a
missed timer.

The defect underneath is larger: **no unit has ever invoked the HTML report.**
The installed unit runs `report --write` (the report *library*, which writes
evidence to disk) and then `health-notify`. The comprehensive multipart report
exists only behind a manual `report weekly --email`. Raising an alert threshold
would not have delivered it.

### 9.2 What this deployment changes about notifications

| | before | after |
|---|---|---|
| weekly report | never sent by any timer | sent **every Sunday**, healthy or not |
| health alert | silent unless action/critical | **unchanged** |
| both in one run | n/a | one message, not two |
| a failed report | would stop the unit and suppress the alert | tolerated, recorded, raised as CRITICAL |
| a missed Sunday replayed at boot | n/a | one report; a second same-day send is refused |

### 9.3 Exact hashes — measured, and how to re-derive them

**A hash baked into a document goes stale exactly like a baked-in revision** --
this section said so while baking one anyway, and the baked column then went
stale FOUR times in two days (`a5c3578`, `896cac5`, `df2e849`, and again at
`bddab55`), twice in two different tables carrying two different revision
labels. The target column is therefore gone. What is listed below is the
INSTALLED side, which is stable because production has not moved, plus the one
fact that matters: all three files differ, so all three are deployed.

The target is whatever `origin/main` is when the script runs; the operator pins
it with `--expect-revision=<sha>`, and the script asserts for itself that each
installed file's sha256 equals that file in the checkout. Re-derive with:

```sh
for p in bin/domum-media:/usr/local/bin/domum-media \
         bin/domum-media-backup:/usr/local/bin/domum-media-backup \
         bin/domum-media-report:/usr/local/lib/domum-media/domum-media-report; do
  printf '%-26s installed=%s  new=%s\n' "${p%%:*}" \
    "$(sha256sum "${p#*:}" 2>/dev/null | cut -c1-16)" \
    "$(sha256sum "${p%%:*}" | cut -c1-16)"
done
```

| file | installed at `a63ad19` | differs from `origin/main`? |
|---|---|---|
| `bin/domum-media` → `/usr/local/bin/domum-media` | `5e65f06c8a7a4bf4` | yes |
| `bin/domum-media-backup` → `/usr/local/bin/domum-media-backup` | `08a81ba2065850c4` | yes |
| `bin/domum-media-report` → `/usr/local/lib/domum-media/domum-media-report` | `d813ae0e4181a7d5` | yes |

Re-verified 2026-11-10 at the revision named in the header: production is
`a63ad19` with no drift on any of the three installed files.

Unit files, compared with comments and blank lines stripped:

| unit | directives |
|---|---|
| `domum-media-weekly-report.service` | **CHANGED** — the three `ExecStart` lines. Must be installed. |
| `domum-media-weekly-report.timer` | identical |
| `domum-media-btrfs-scrub.timer` | identical (comment-only) |
| `systemd/auto-enable.timers` | identical (comment-only), and never installed — read from the checkout |

`operator/domum-media-deploy-reporting-fixes.sh` already carries all four
paths it needs: its `TARGETS` lists the three binaries (the report library at
`$LIB_DIR`, **not** `$BIN_DIR`) and its `UNIT_TARGETS` lists both
weekly-report units.

### 9.4 THE TIMER NEEDS NO `enable` — only a reload

```
domum-media-weekly-report.timer   enabled, active (waiting)
                                  next: Sun 2026-11-15 08:15:21 EST
```

It has been enabled since 2026-10-20. So this is **not** a timer activation in
the usual sense: the schedule is already live and has been firing weekly. What
changes is what the unit *does* when it fires. systemd reads the service unit
at activation time, so `daemon-reload` is sufficient and **no restart and no
`enable` is required**.

Consequence worth stating plainly: once deployed, the **first automatic report
arrives Sun 2026-11-15 at ~08:15 EST** with no further operator action.

### 9.5 Deployment

```sh
# 0. Preserve what is about to be replaced. The deploy script keeps no .bak and
#    relies on git, so this is what makes rollback a straight copy rather than
#    a checkout dance.
sudo install -d -m 0700 /root/domum-rollback-$(date +%F)
sudo cp -a /usr/local/bin/domum-media \
           /usr/local/bin/domum-media-backup \
           /usr/local/lib/domum-media/domum-media-report \
           /etc/systemd/system/domum-media-weekly-report.service \
           /root/domum-rollback-$(date +%F)/

# 1. Dry run. It says what it WOULD do and mutates nothing.
sudo /opt/domum-core-media/operator/domum-media-deploy-reporting-fixes.sh

# 2. Deploy, pinning the revision the operator reviewed.
sudo /opt/domum-core-media/operator/domum-media-deploy-reporting-fixes.sh \
     --confirm --expect-revision=<the sha you reviewed>
```

The script fast-forwards the checkout, installs only files whose hash differs,
runs `daemon-reload`, enables nothing, and asserts that each installed file's
sha256 equals that file in the checkout.

### 9.6 Verification — all read-only

```sh
# the unit now has THREE ExecStart lines, with the prefixes the design needs
sudo systemctl cat domum-media-weekly-report.service | grep -n '^ExecStart'
#   expect: -report --write / -report weekly --email --scheduled /
#           health-notify --unless-reported   (only the last is unprefixed)

# the schedule is untouched and still enabled
systemctl list-timers domum-media-weekly-report.timer

# the report renders, WITHOUT sending anything
sudo domum-media report weekly --stdout | head -40

# what a real run would do, still without sending
sudo domum-media report weekly --dry-run
sudo domum-media health-notify --dry-run

# the new delivery check, before any scheduled run has happened:
#   expect ADVICE ("no SCHEDULED weekly report is recorded yet"), never a critical
sudo domum-media checkup | grep -iA1 'weekly report'
```

### 9.7 Rollback

```sh
R=/root/domum-rollback-<date>
sudo install -m 0755 "$R/domum-media"        /usr/local/bin/domum-media
sudo install -m 0755 "$R/domum-media-backup" /usr/local/bin/domum-media-backup
sudo install -m 0755 "$R/domum-media-report" /usr/local/lib/domum-media/domum-media-report
sudo install -m 0644 "$R/domum-media-weekly-report.service" \
                     /etc/systemd/system/domum-media-weekly-report.service
sudo systemctl daemon-reload
```

Nothing else needs undoing: no timer state changed, no data was written outside
`$DOMUM_STATE_ROOT/weekly-report.env`, and that file is only read by the new
code — an older binary ignores it.

### 9.8 One thing that needs an explicit decision

1. **A real delivery test sends a real email.**
   `sudo domum-media report weekly --email` would prove end-to-end delivery and
   is the only way to do so. It is NOT in the verification list above and was
   not run: sending external mail needs operator approval.

### 9.9 The SMTP transport: retry added, and two security claims corrected

This section previously said *"there is no SMTP retry, and there never was"* and
described the credentials as *"read from files rather than argv"*. The first is
now out of date and **the second was wrong**: they were read from files into
shell variables and then passed to curl on the COMMAND LINE. The plan asserted
the exact property that was missing, which is why it is called out here rather
than quietly edited.

What landed, all in `smtp_send_message`, with the function driven by a test for
the first time (`tests/smtp-transport-smoke.sh`, 17 sections, 4 mutants):

| before | now |
|---|---|
| one `curl` attempt | `--retry 2 --retry-delay 10 --retry-connrefused`, `RECOVERY_PACK_SMTP_RETRIES=0` restores the single attempt |
| no bound on an attempt | `--connect-timeout 15 --max-time 60 --retry-max-time 60` |
| `--user "$user:$pass"` in argv | a 0600 `--config` file, removed on every path out |
| default `.curlrc` honoured | `-q` first, `--config` before the security flags |

**Why the bounds are part of the retry, not a nicety.** curl sets no connect
timeout of its own, so a black-holed SMTP port hangs for the OS TCP timeout
(~130s). The weekly unit now has TWO senders, so three unbounded attempts each
could approach `TimeoutStartSec=10m` and have systemd kill the job mid-way --
a transient fault converted into a failed report. `--max-time` alone is not
enough: curl(1) says its counter "is reset each time the transfer is retried".
Worst case is now ~120s per send, ~240s for two, against 600s.

**Why the argv change is not cosmetic.** Measured on this host: `/proc` carries
no `hidepid` option and 75 root-owned processes' argv read fine as the
unprivileged account, while `/etc/domum-core-media/secrets` is
`drwx------ root root` -- unreadable and unlistable by it. So the argv form took
a secret that account cannot otherwise reach and made it readable by any local
account for the duration of each send.

**Why `-q`.** curl(1): the default config file is read "even when `--config` is
used". Measured with one planted, `CURLOPT_SSL_VERIFYPEER` and `VERIFYHOST` both
went to 0 and an extra `CURLOPT_MAIL_RCPT` appeared -- certificate verification
on the mail send defeated and a second recipient added for a report full of host
state. The credential itself was never at risk there, because a command-line
`--config` is parsed after the default config and wins.

Failure propagation is unchanged and asserted: curl still returns non-zero once
retries are exhausted, and every caller that died on a failed send still dies.

---

## 10. THERE ARE NOW TWO DEPLOYMENTS, AND ONLY ONE OF THEM IS THIS PLAN

The revision and commit count are stated once, in the header, and not repeated
here -- two copies of one number is how this document came to carry two
different revision labels for the same question. What this section is about does
not depend on the count: a security workstream (#196-#203) added **13 compose
files**, two config files and two of the three binaries, which changes the *kind*
of deployment the repository contains rather than its size.

| | A -- the narrow deployment | B -- the security compose change set |
|---|---|---|
| files | 3 binaries + 2 weekly-report units | 13 `compose/*`, `config/ci.env`, `config/domum-media.conf.example` |
| carried by `operator/domum-media-deploy-reporting-fixes.sh` | **yes** | **no** -- `TARGETS`/`UNIT_TARGETS` name neither compose nor config |
| containers touched | **none** | **every one whose config changed** |
| mechanism | `install` + `daemon-reload` | `docker compose up -d` |
| approval | narrow, reviewed here | **§11 stop condition** (broad container recreation) |

**§5's "no container is created, recreated, restarted or stopped" is true of A
and must not be read as a claim about deploying `main`.** It was written when
the delta was binaries and units only. It still describes what the script does;
it no longer describes everything the repository now contains, and that
difference is in the dangerous direction for an operator sizing the work.

### 10.1 What B would actually do

Measured from the diff: **14** services gain
`security_opt: [no-new-privileges:true]`, one gains `read_only`, and a **new
service** appears -- `docker-socket-proxy`, with a new `traefik-docker` network,
so Traefik reaches the Docker API through a read-only proxy instead of the
socket. Applying any of it means `compose up -d`, which recreates a container
whose configuration changed. There are 11 running containers.

### 10.2 AND `up -d` WOULD DEPLOY TWO STAGED IMAGES AS A SIDE EFFECT

This is the part that is easy to miss, because it has nothing to do with the
security change itself. Measured 2026-11-10, read-only:

```
traefik      running sha256:9c3b91d5fb77   traefik:latest        -> sha256:9c2a54d87f76
uptime-kuma  running sha256:a8610b3b4c38   louislam/uptime-kuma:2 -> sha256:3e24e96c89ef
plex jellyfin kavita navidrome calibre-web  tag resolves to the running image
```

`up -d` *reconciles*, so recreating traefik and uptime-kuma to pick up
`no-new-privileges` resolves their tags and lands them on the newer images --
an unreviewed application upgrade smuggled inside a security change. These are
also the two services this project records as running **dangling** images
(`RepoTags: []` and `RepoDigests: []`), so the image they are on now survives
only because a container references it.

**The pin is available and is the same mechanism `rollback_upgrade` uses.**
`compose/proxy/traefik.yml` and `compose/monitoring/uptime-kuma.yml` both read
`image: ${TRAEFIK_IMAGE}` / `${UPTIME_KUMA_IMAGE}`, and
`export_env_for_compose` resolves them as `${VAR:-default}` -- so a value
exported first is preserved. Demonstrated:

```
export TRAEFIK_IMAGE="sha256:PINNED"; export TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:latest}"
  -> sha256:PINNED
unset TRAEFIK_IMAGE;                  export TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:latest}"
  -> traefik:latest
```

So B can be applied **without** deploying those two, by exporting each running
image id before `up -d`. Whether to take the image upgrades is a separate
decision from whether to take the security hardening, and they must not be
made by accident.

### 10.3 Hashes

Deliberately NOT repeated here. A second copy of the same table is a second
thing to go stale, and that is exactly what happened: this section carried
`df2e849` while §9.3 carried `896cac5`, two labels for one question. §9.3 is the
single statement, and the operator re-derives at run time.

Production is still `a63ad19` with **no drift** on any of the three installed
files, so A starts from a clean base. Re-derive with the loop in §9.3 rather
than trusting this table -- it has gone stale twice in a week, which is why the
command is given beside it.

### 10.4 Recommendation

Deploy **A** on its own, as this plan already describes: it fixes the weekly
report, the notification policy and the SMTP transport, touches no container,
and retires the 2026-11-15 and 2026-12-06 dated items. Review **B** separately
and on its own merits, with the image question decided explicitly rather than
inherited from a tag.
