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

Last reconciled: **2026-11-18**.

```
git rev-parse origin/main                      # what "current" means today
git -C /opt/domum-core-media rev-parse HEAD     # what production runs
git rev-list --count $(git -C /opt/domum-core-media rev-parse HEAD)..origin/main
```

---

## 1. Position

| | value | measured |
|---|---|---|
| `origin/main` | `9824e48` | 2026-11-18 |
| production checkout | `a63ad19` (clean, on `main`, an ancestor of `origin/main`) | 2026-11-18 |
| installed binaries | sha256-identical to the production checkout | 2026-11-18 |
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
| protected tier | `/srv/data` 24 % used |

---

## 3. MERGED BUT UNDEPLOYED

Production is behind `origin/main`. Three consequences are live rather than
theoretical, and the second has a date attached.

| # | consequence of the gap | severity |
|---|---|---|
| 1 | **An emptied backup heartbeat reads as a successful backup.** The installed `backup_last_success_epoch` predates the fix: `date -d ""` is not an error, so a truncated marker becomes *today 00:00* and the stateful-update gate passes on an invented timestamp | latent; the realistic trigger is a full disk |
| 2 | **A scrub already running when the timer fires mails a CRITICAL for a normal condition.** The installed binary predates `btrfs_scrub_running`, so the refusal lands in the generic failure arm and fails the oneshot unit. Mail delivery is proven, so the alarm would arrive | **dated: Sun 2026-12-06** |
| 3 | **The weekly HTML report is never sent.** The deployed unit has two `ExecStart` lines and does not invoke the report at all; `health-notify`'s silence gate mails only on an action or a critical, so a healthy week produces nothing and cannot be told apart from a broken reporter | the operator receives no weekly report |

Also merged and undeployed, and deliberately a **separate** deployment kind
because it recreates every container:

| | note |
|---|---|
| `no-new-privileges` on 11 Compose fragments | deployed containers report an empty `SecurityOpt` |
| Traefik behind a read-only Docker socket proxy | Traefik still binds the Docker socket directly; no proxy container exists |
| `domum-media-state-capture.{service,timer}` | **new units, deliberately not in the narrow deploy script's target list.** Installing a unit is what makes its job available, and these carry a capture that writes credential-bearing artefacts plus a prune that deletes packs -- neither has run against production |

**Deployment hazard that governs the Compose rollout.** Two running images are
dangling (no tags, no digests) *and* have newer images staged under the same
tag, so recreating either for a configuration-only change deploys an
application upgrade as a side effect. Pin the running image IDs first.

---

## 4. BLOCKED, by kind of blocker

A blocker recorded as the wrong kind sends the next reader down the wrong path:
a privilege blocker is retired by one privileged command, an approval blocker
only by the operator deciding, and an instruction blocker not at all until the
instruction changes. **A blocker is a property of a STEP, not of a command or a
feature.**

| kind | items |
|---|---|
| **privilege** (root; `sudo -n` answers *a password is required*, 0 NOPASSWD entries, measured 2026-11-18) | reading the image-archive sizes; traversing the Docker volume root; installing units; the reporting deployment itself |
| **approval** (production boundary) | the reporting deployment; the Compose hardening rollout; the kernel reboot; activating a backup target; a real quiesced capture; a production image upgrade |
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

1. **Deploy the reporting fixes** -- three binaries and the weekly-report unit,
   via the narrow operator script. Recreates no container, enables no timer,
   deploys no image. Closes consequences 1 and 3 above, and consequence 2
   before its date. *Needs approval.*
2. **Verify after deployment**: that the weekly report renders, that the
   backup-freshness reader rejects an empty marker, and that the unit's new
   steps are the ones installed. No external mail is sent to verify this.
3. **Plan the kernel reboot** -- a newer kernel is installed and not running.
   Every timer is `Persistent=true`, so missed jobs run immediately on boot,
   `snapshot prune` among them; check each timer's last trigger against its
   next elapse before rebooting. *Needs approval.*
4. **Stage the Compose security rollout** -- per service, with each running
   image ID pinned so a configuration change cannot carry an upgrade. Immich
   last, in its own phase. *Needs approval.*
5. **Finish off-site application-state backup** -- the artefacts and the whole
   chain are proven; what remains is activating a target for them, which needs
   the deployment first, and the operator's key custody step, which no work on
   this host can replace.

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
