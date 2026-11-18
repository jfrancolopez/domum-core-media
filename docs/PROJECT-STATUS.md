# Project status — the one authoritative summary

**What this file is for.** One place that answers *what is deployed, what is
merged but not deployed, what is blocked and on what kind of blocker, and what
comes next*. Everything else is detail: `backlog/QUEUE.md` holds the per-item
record, `docs/DEPLOYMENT-PLAN.md` holds the deployment measurements, `CLAUDE.md`
holds the durable rules.

**Every figure here carries the date it was measured, and the command that
re-derives it.** A running tally written into prose rots -- this project has
corrected the same stale count three times -- so nothing below should be
repeated to the operator without re-running the check beside it.

Last reconciled: **2026-11-18**, after the reporting deployment.

```
git rev-parse origin/main                      # what "current" means today
git -C /opt/domum-core-media rev-parse HEAD     # what production runs
git rev-list --count $(git -C /opt/domum-core-media rev-parse HEAD)..origin/main
```

---

## 1. Position

| | value | measured |
|---|---|---|
| `origin/main` | `f647aa2` | 2026-11-18 |
| production checkout | `f647aa2` (clean, on `main`) -- **equal to `origin/main`** | 2026-11-18, after the deployment |
| installed binaries | sha256-identical to the production checkout, all four files re-verified against the `origin/main` blobs | 2026-11-18, after the deployment |
| CI on `main` | green, 113 steps, one workflow (`compose-validate`) | 2026-11-18 |
| open pull requests | none | 2026-11-18 |
| development worktrees | one: the primary checkout, on `main` | 2026-11-18 |

---

## 2. DEPLOYED and working

Measured read-only on 2026-11-18. No unit is in the failed state and every
domum service's last run exited 0.

| | state |
|---|---|
| containers | 11 of 11 up; every service with a healthcheck is healthy |
| nightly backup | ran 02:31, heartbeat 10 h old at the time of measurement |
| weekly repository check + retention | ran Sun 2026-11-15, exit 0 |
| snapshot prune | ran Sun 2026-11-15 |
| host update check | ran Mon 2026-11-16 |
| five migrated services | real Btrfs subvolumes with retained proof snapshots |
| Btrfs scrub timer | installed and **enabled** by the operator 2026-11-03; next firing Sun 2026-12-06; no scrub has run from it |
| image-refresh timer | `disabled`, `inactive` -- as required |
| weekly report + alert unit | **three `ExecStart` lines installed** (`report --write`, `report weekly --email --scheduled`, `health-notify --unless-reported`); timer `enabled, active`, next firing Sun 2026-11-22 08:10 EST |
| backup-freshness reader | an empty or whitespace-only heartbeat now answers *cannot tell* (rc=1) instead of fabricating *today 00:00* -- driven against the installed binary with `DOMUM_LOG_DIR` redirected |
| selective-backup surface | all eleven `capabilities --has` tokens answer **0**; they answered **2** (token unknown) before the deployment |
| protected tier | `/srv/data` 24 % used |

---

## 3. MERGED BUT UNDEPLOYED

**The three reporting consequences are CLOSED.** Deployed 2026-11-18 via
`operator/domum-media-deploy-reporting-fixes.sh --confirm`, which installed
three binaries and the weekly-report unit, handed over to its own replacement
exactly once, verified every file by sha256, and recreated no container,
enabled no timer and deployed no image. Each is re-derived rather than
asserted:

| # | former consequence | now |
|---|---|---|
| 1 | an emptied backup heartbeat read as a successful backup | **closed** -- empty, whitespace-only and absent all answer rc=1; a valid marker still answers rc=0 |
| 2 | a scrub already running when the timer fires would mail a CRITICAL | **closed before its date** -- `btrfs_scrub_running` is in the installed binary; the Sun 2026-12-06 firing is no longer a known false alarm |
| 3 | the weekly HTML report was never sent | **closed** -- the unit's second `ExecStart` is `report weekly --email --scheduled`. First send: Sun 2026-11-22 08:10 EST |

The deployment also retired a prerequisite: every `capabilities --has` token of
the selective-backup surface answered **2** (token unknown) before it and
answers **0** now, so `docs/OPERATOR-GATED-ACTIONS.md` items 2-5 are reachable
where they previously would have produced a usage error.

### What is still undeployed, and it is one deployment kind

The fast-forward moved the production **checkout** to `f647aa2`, so the Compose
change set is now *present in production and not applied*. Measured 2026-11-18:

| | in the checkout | in effect |
|---|---|---|
| `no-new-privileges` | 11 fragments | **no** -- traefik, plex and immich_server all report `SecurityOpt=[]` |
| Traefik behind a read-only Docker socket proxy | fragment present | **no** -- no `docker-socket-proxy` container exists |
| `domum-media-state-capture.{service,timer}` | present | **no** -- absent from `/etc/systemd/system` |

**This is sharper than it was before the fast-forward, not softer.** Any
command that reconciles -- `domum-media apply`, and therefore `update` --
would now apply the hardening to every container as a side effect, because the
fragments it reads are already there. `compose up -d` recreates any container
whose image changed, and two running images are dangling with newer images
staged under the same tag, so such a reconcile would carry an unreviewed
application upgrade for traefik and uptime-kuma. Pin the running image IDs
before any deliberate rollout, and do not reach for `apply` as a convenience
in the meantime.

---

## 4. BLOCKED, by kind of blocker

A blocker recorded as the wrong kind sends the next reader down the wrong path:
a privilege blocker is retired by one privileged command, an approval blocker
only by the operator deciding, and an instruction blocker not at all until the
instruction changes. **A blocker is a property of a STEP, not of a command or a
feature.**

| kind | items |
|---|---|
| **privilege** (root; `sudo -n` answers *a password is required*, 0 NOPASSWD entries, measured 2026-11-18) | reading the image-archive sizes; traversing the Docker volume root; installing the state-capture units; running any `storage` subcommand |
| **approval** (production boundary) | the Compose hardening rollout; the kernel reboot; activating a backup target; a real quiesced capture; a production image upgrade |
| **instruction** (standing prohibition) | copying the off-host recovery key; capturing live production state to a scratch directory, because the capture's declared purpose is to copy credentials |
| **hardware / scale** | a fresh-host restore (a second machine); a full Immich restore (~130 GiB) |

**Disaster-recovery position, unchanged.** The cloud repository is
immich-only by design, so the five media services' state and the image
archives have no off-site copy; no encrypted state pack has ever left this
SSD; the operator's own key has never opened one; nothing is
`FULL RECOVERY VERIFIED`. The mechanism is proven end to end against a
disposable key and a disposable repository -- which is a proven mechanism, not
off-site protection.

---

## 5. NEXT ACTIONS, in order

1. **Confirm Sunday's report arrived.** The first scheduled send is
   Sun 2026-11-22 08:10 EST and it is the only part of the reporting work no
   check here can stand in for -- a delivery failure is recorded by
   `--scheduled` and raised as a CRITICAL by `checkup_weekly_report_delivery`,
   so silence after that date means the mail arrived or the unit did not run,
   and `systemctl list-timers` tells the two apart. Nothing to do before then.
2. **Plan the kernel reboot** -- 6.12.117 is installed and 6.12.111 is
   running. Every timer is `Persistent=true`, so missed jobs run immediately
   on boot, `snapshot prune` among them; check each timer's last trigger
   against its next elapse first. *Needs approval.*
3. **Stage the Compose security rollout** -- per service, with each running
   image ID pinned so a configuration change cannot carry an upgrade, Immich
   last in its own phase. More urgent to schedule than before, because the
   fragments now sit in production's checkout where a reconcile would apply
   them unreviewed. *Needs approval.*
4. **Finish off-site application-state backup** -- the commands are now
   deployed, so `docs/OPERATOR-GATED-ACTIONS.md` items 2-5 are runnable. What
   remains is the operator's: a destination for the packs, installing and
   enabling the capture timer, and the key-custody step that no work on this
   host can replace.
5. **Verify recovery independently** -- a fresh-host restore needs a second
   machine, and a full Immich restore is ~130 GiB. Nothing on this host is
   `FULL RECOVERY VERIFIED` and nothing here changes that.

---

## 6. What this file deliberately does not do

- **It asserts no per-service protection state.** Which service is protected is
  live state that changes; pinning it in a document is how a stale invariant
  aborted a correct production deployment at its own verification stage.
- **It carries no commit count and no baked revision in prose.** Section 1
  gives the commands instead.
- **It does not promote a weaker claim.** "The mechanism is proven" is not "the
  data is protected off-site", and "the capture restores" is not "the
  application runs against it".
