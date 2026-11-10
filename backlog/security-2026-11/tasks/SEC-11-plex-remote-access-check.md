# domum-core-media/SEC-11 Check Plex remote access and relay

| Field | Value |
| --- | --- |
| Status | BLOCKED — owner action in the Plex web UI; SUPERSEDED if D-4 retires Plex |
| Priority and reason | P2 — the one app here designed to reach outside the tailnet |
| Effort and change risk | 5 min; none |
| Target and baseline | `domum-core-media`, branch off `origin/main`, inspected at `e0754a8` (2026-11-10) |
| Owner and evidence | owner; finding F-15 (inferred, unverified) |
| Dependencies | D-4 may make this unnecessary |

## Outcome

Plex signs in through its vendor's cloud and, when remote access or relay is
on, can stream through that vendor's servers to anyone the account has shared
with. Nothing observed says it is on. After this task it is known and off.

## Scope and setup

Plex web UI → Settings. No host or Git change.

## Before editing

If D-4 selects retiring Plex, set this task to SUPERSEDED and stop.

## Implementation and checkpoints

1. Settings → Remote Access.
   - **Expected** "Not available outside your network", or disabled. If enabled, disable it.
2. Settings → Network → "Enable Relay".
   - **Expected** unchecked
3. Settings → Network → "List of IP addresses and networks that are allowed without auth".
   - **Expected** empty
4. Account → Authorized devices and shared users.
   - **Expected** only devices and people you recognise

## Acceptance

- All four as expected. Playback over the LAN and the tailnet still works.

## Rollback and stop conditions

Re-enable the setting.

## Verification handoff

- **Result** _not started_
- **References** _base, commit, PR_
- **Evidence** _per checkpoint: PASS / FAIL / BLOCKED / NOT RUN_
- **Next model** none; not machine-checkable
- **Open items** —
