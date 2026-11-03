# Deployment plan — production `a63ad19` → current `origin/main`

**Reviewed, not executed.** Changing `/opt/domum-core-media` or anything running
on the host is an approval boundary of its own; landing code on `main` is not.
Nothing below has been run.

## Current state, measured

```
production checkout   a63ad199bfa2   (read from .git/refs/heads/main)
installed domum-media         sha256 5e65f06c8a7a…  == a63ad19's blob
installed domum-media-backup  sha256 08a81ba20658…  == a63ad19's blob
installed domum-media-report  sha256 d813ae0e4181…  == a63ad19's blob
```

So production has **no drift**: every installed file matches the revision the
checkout is on. (The report library's mtime is 2026-10-11, which is not
staleness — that file simply has not changed since. The hash settled it; the
mtime would have misled, as it has three times before in this project.)

## What would change

Exactly **two files**. Verified by hashing each deployment target's blob at both
revisions:

Measured **2026-11-02** against `origin/main` at `dcf943a`. The *shape* of the
change — two binaries, no units, no handover — is what this plan rests on;
re-read the dry run's own table before confirming, because these figures are a
dated measurement and not a promise about a later revision.

| file | |
|---|---|
| `/usr/local/bin/domum-media` | `5e65f06c8a7a` → `aea3fcd552f2` |
| `/usr/local/bin/domum-media-backup` | `08a81ba20658` → `2c6aec3afd82` |
| `/usr/local/lib/domum-media/domum-media-report` | **unchanged** |
| `domum-media-weekly-report.service` / `.timer` | **unchanged** |

Consequences of that:

- **no `daemon-reload`**, because no unit file changes;
- **no timer is enabled or started** — the deployment never does this, and the
  scrub timer and the image-refresh timer both stay absent from
  `auto-enable.timers`;
- **no container is created, recreated, restarted or stopped**. The deployment
  installs files; it does not call compose;
- **no handover** — `operator/domum-media-deploy-reporting-fixes.sh` is itself
  unchanged between the two revisions, so the "a script cannot deploy its own
  replacement" case does not arise. The dry run will say so.

## What it fixes that is live in production today

Two reporting defects the operator has already seen, both from `f7e6d5d` (#146):

1. **`health-notify --dry-run` described the wrong action.** On a host with
   warnings and zero actions it printed `no mail was sent (subject would be:
   domum-media: WARNINGS (6))`, which reads as "a real run WOULD send this".
   It would not — the silence gate holds and there is no subject at all. The
   gate's decision is now computed once and both the preview and the run read
   it.
2. **Two verdict ladders.** The body printed `VERDICT: ATTENTION` under a
   subject of `WARNINGS (6)`: two answers to one question inside one message.
   `health_summary_text` now calls `health_verdict`.

## What it fixes that is LATENT, not firing

Everything else. Stated plainly because urgency would be the wrong conclusion:

| fix | why it is not firing now |
|---|---|
| `checkup`'s `waiting_count` abort | `$DOMUM_STATE_ROOT/image-updates` exists on this host — `ensure_dirs` has run, and the operator's recent `checkup` produced output, which it could not have if this were aborting |
| `quiesce_immich_postgres` abort | needs the Docker daemon to be unreachable |
| `dr_immich_summary` abort | needs `thumbs/` or `encoded-video/` to be absent, i.e. a freshly restored host |
| phase-B live-photo abort | needs a user with no live photo; the admin has 7,432 |
| scrub duplicate-run CRITICAL | the scrub timer is not installed or enabled, so only a manual second scrub could trigger it |
| readiness log in the upgrade | only runs during `updates apply --service <s>`, which no timer invokes |
| capture / restore / quiesce / archive identity | new subcommands; nothing invokes them |

## Blast radius and the safety argument

**Every change to `domum-media-backup` strictly REMOVES a failure mode.** The
whole diff for that file is four logical changes — three `|| true` additions
and two first-line extractions rewritten from `head -1` to `sed -n '1p'`. None
adds a condition under which a previously working path can now fail. The
`lp_img` rewrite is the only one that changes an extraction mechanism, and the
phase-A/B suite's happy path exercises it (`livephoto image match` and
`livephoto video match` both still assert).

For `domum-media`, the only change on a **scheduled** path is one `|| true` in
`checkup`. Everything else is reachable only from operator-invoked subcommands
or is new code.

## Rollback

The deployment fast-forwards the checkout and then installs narrowly, so the
installed files are the thing to be able to put back. **Before deploying, save
them:**

```
sudo cp -a /usr/local/bin/domum-media        /root/domum-media.a63ad19
sudo cp -a /usr/local/bin/domum-media-backup /root/domum-media-backup.a63ad19
sudo sha256sum /root/domum-media*.a63ad19
```

Rollback is then one `install` per file, and the saved hashes must match
`5e65f06c8a7a…` and `08a81ba20658…`. No data, no container, no snapshot and no
repository is touched by either direction.

## Evidence

- 82 suites and audits pass locally; CI green on the branch.
- shellcheck clean with CI's flags on `bin/*`, `install.sh`, `operator/*.sh`,
  and all suites now pass `--severity=error`.
- `bash -n` on all three entrypoints.
- New mutation coverage: 1 for the scrub gate, 1 for the quiesce gate, 1 for
  the `find` guard, 4 for the capture/restore, 2 for archive identity.

## The command

**No revision is written down here.** A revision constant stored in the
repository it pins goes stale by construction — this project's own rule — so
the operator reads the sha and supplies it:

```
git -C /opt/domum-core-media fetch origin              # read-only
git -C /opt/domum-core-media rev-parse --short origin/main

sudo bash /opt/domum-core-media/operator/domum-media-deploy-reporting-fixes.sh \
  --expect-revision=<that sha>
```

`--expect-revision` is what makes the deployment refuse if `origin/main` has
moved since you looked. Passing a sha you did not just read defeats it.

Run it **without** `--confirm` first. The dry run states the fast-forward in
the subjunctive (`WOULD fast-forward: … (not done yet)`) and lists each file's
installed and target hash, and it is asserted not to mutate anything. Compare
its file list against the two-file table above before re-running with
`--confirm`.

## Afterwards

Read-only verification, in this order:

```
sudo domum-media checkup
sudo domum-media health-notify --dry-run
sudo domum-media report weekly --stdout
```

Expect: `checkup` prints its header and all four sections; the dry run says a
real run would send **nothing** and names no subject; the report's verdict word
matches the dry run's. A reported `BACKUP GAP` is a finding about the backup,
not about the deployment.

**Do not** run `systemctl start domum-media-check.service` as a convenience:
its second `ExecStart` is `--weekly-retention`, i.e. `restic forget --prune`.
