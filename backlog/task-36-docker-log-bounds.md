# Task 36 — Docker log bounds  [shared-philosophy]

## Objective
Bound Docker container logs on the N100 (json-file, max-size/max-file) via
the CLI's converge path, using domum-core's non-destructive merge behavior:
create `/etc/docker/daemon.json` if absent; if present but different, leave
it alone and show the diff.

## Files involved
- `bin/domum-media` — new daemon.json helpers in the init/converge path
  (`apply` or `doctor --fix`-style step)
- `docs/SETUP-N100.md` (note the setting)

## Reason
Container logs are currently unbounded; a chatty container (Plex transcode
logging, a crash-looping service) can eat the NVMe. Porting source:
`domum-core/bin/domum-core:54-73` (`docker_daemon_json_expected` =
`{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}`
+ matcher) and `:635-661` (create-if-absent; if present and non-matching,
print a diff and change nothing — never clobber an operator-managed
daemon.json).

## Implementation plan
1. Port the expected-config + matcher + converge functions verbatim
   (values identical; media host has more disk but 10m×3 per container is
   still right).
2. Call from the converge path; when the file is created or would need
   changing, print that a Docker restart is required — never restart the
   daemon automatically (it takes every service down).
3. `doctor`: report current log-driver settings and whether they match.

## Operator runbook
One-time, brief full-stack downtime:
1. Run `domum-media apply` (or the converge command) → daemon.json created.
2. `systemctl restart docker` during a quiet moment; verify services come
   back (`domum-media status`).
3. Note: only *new* containers get the bounds; recreate long-lived
   containers (`domum-media apply` after any compose change does this) to
   apply everywhere.

## Testing plan
- Fixture: no daemon.json → created with expected content, valid JSON
  (`docker` config check or `python3 -m json.tool`).
- Existing non-matching daemon.json → untouched, diff printed.
- After operator restart: `docker inspect` on a recreated container shows
  the log-opts.

## Rollback plan
Remove/restore `/etc/docker/daemon.json` from the printed pre-change state
and restart Docker; revert the commit.

## Dependencies
None hard.

## Risk / complexity / token size
Low (never modifies an existing file; restart is manual). Small. ~5k
tokens.

## Suggested order
Phase 5, last task of the phase.
