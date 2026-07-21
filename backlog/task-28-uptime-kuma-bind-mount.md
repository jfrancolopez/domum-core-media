# Task 28 — Uptime Kuma to bind-mounted storage

## Objective
Move Uptime Kuma's data from the Docker named volume `uptime-kuma-data` to
the bind path `$DOMUM_DATA_ROOT/uptime-kuma` that the CLI already expects —
so its monitor history finally lands inside the snapshot and backup plans.

## Files involved
- `compose/monitoring/uptime-kuma.yml` — `uptime-kuma-data:/app/data`
  (~line 9), volume declaration (~24–25)
- `compose/base.yml` — named-volume declaration (~14)
- `bin/domum-media` — no changes expected: `service_data_path` (~783) and
  `snapshot_subvolumes` (~1149) already point at
  `$DOMUM_DATA_ROOT/uptime-kuma`

## Reason
The compose file and the CLI disagree: data lives in a named volume, while
every protection mechanism (snapshots, backup includes, restore) watches
`/srv/data/uptime-kuma` — which stays empty. Monitor configuration and
history are silently unprotected. Moving to a bind mount makes all existing
machinery cover it with zero CLI changes.

Deliberately NOT copying domum-core's named-volume backup approach: its
implementation references unprefixed volume names and silently skips the
real (project-prefixed) volumes — a known defect. Bind mounts sidestep the
whole class.

## Implementation plan
1. Change the compose mount to
   `${DOMUM_DATA_ROOT:?}/uptime-kuma:/app/data`; remove the named-volume
   declarations from the fragment and `base.yml`.
2. Follow task 29's interpolation convention (`:?` guard so an unset root
   fails the render rather than binding a wrong path).
3. Create the dir as a subvolume via the task-26 machinery
   (`ensure_dirs` handles new installs).
4. Document the one-time data copy in the runbook below; the CLI needs no
   migration code for a single service.

## Operator runbook
One-time, ~2 minutes of monitoring downtime:
1. `docker compose -p domum-media stop uptime-kuma` (via
   `domum-media`'s compose wrapper).
2. Provision the target: `domum-media storage convert uptime-kuma` on an
   empty dir is instant (or `btrfs subvolume create /srv/data/uptime-kuma`).
3. Copy: `docker run --rm -v domum-media_uptime-kuma-data:/from
   -v /srv/data/uptime-kuma:/to alpine cp -a /from/. /to/`
   (confirm the actual volume name with `docker volume ls` first — it
   carries the compose project prefix).
4. `domum-media apply` — service comes up on the bind mount; verify
   monitors and history are intact in the UI.
5. Only after verification: `docker volume rm <prefixed-volume-name>`.

## Testing plan
- CI compose render passes with the new mount.
- Fixture host: fresh start creates and uses the bind path; data written by
  the container appears under `/srv/data/uptime-kuma`.
- After the operator migration: snapshot run includes uptime-kuma;
  `backup plan` shows the path.

## Rollback plan
Revert the compose change and `apply` — the named volume still exists until
step 5, so rollback is instant before the volume is removed. That's why the
volume is deleted last, only after verification.

## Dependencies
Task 26 (subvolume provisioning), task 29 (interpolation convention).

## Risk / complexity / token size
Medium risk only during the one-time copy (mitigated: old volume retained
until verified). Small. ~6k tokens.

## Suggested order
Phase 3, after task 27.
