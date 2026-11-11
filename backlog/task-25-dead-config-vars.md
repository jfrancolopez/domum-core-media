# Task 25 — Remove or wire dead config vars

## Objective
Every variable in `config/domum-media.conf.example` either does something or
doesn't exist. Remove the dead ones, wire the one that guards a real
behavior, and explicitly defer one to its feature task.

## Files involved
- `config/domum-media.conf.example` (`IMMICH_UPDATE_CHANNEL` ~line 171)
- `bin/domum-media` — exports at ~964 (`IMMICH_BUNDLE_ROLLBACK_ENABLED`),
  ~965 (`IMMICH_HOST`), ~982 (`PLEX_ENABLE_HW_TRANSCODE`); configure
  prompts at ~1812 (`IMMICH_HOST`) and ~1844–1845
  (`IMMICH_BUNDLE_ROLLBACK_ENABLED`); bundle rollback gating at
  ~2085/2089 (currently keys off `AUTO_ROLLBACK_ENABLED` only)
- `compose/photos/immich.yml` (`Host(\`photos.${DOMUM_DOMAIN}\`)` at ~28)

## Reason
Four config vars have no functional effect, which is worse than missing
config — the operator believes they changed behavior:
- `IMMICH_UPDATE_CHANNEL`: fully unreferenced outside the example file.
- `IMMICH_HOST`: exported and prompted for, but the Immich route hardcodes
  `photos.${DOMUM_DOMAIN}`. Setting it changes nothing.
- `IMMICH_BUNDLE_ROLLBACK_ENABLED`: exported and prompted for, never read;
  bundle rollback actually follows `AUTO_ROLLBACK_ENABLED`.
- `PLEX_ENABLE_HW_TRANSCODE`: exported, but `compose/media/plex.yml`
  passes `/dev/dri` unconditionally.

## Implementation plan
1. Remove `IMMICH_UPDATE_CHANNEL` from the example config (bundle updates
   follow upstream releases; a channel concept doesn't exist here).
2. `IMMICH_HOST`: wire it — the route becomes
   `Host(\`${IMMICH_HOST}\`)` with the export defaulting to
   `photos.${DOMUM_DOMAIN}` — matching how other services handle hostnames.
   (Wiring is cheaper than removing the prompt and keeps parity with
   sibling services.)
3. `IMMICH_BUNDLE_ROLLBACK_ENABLED`: honor it in the bundle rollback path
   (`AUTO_ROLLBACK_ENABLED && IMMICH_BUNDLE_ROLLBACK_ENABLED`), documented
   in the example config.
4. `PLEX_ENABLE_HW_TRANSCODE`: leave in place with a comment
   "wired by task 39 (QuickSync)" — removing then re-adding is churn.
5. `configure` prompts updated to match.

## Testing plan
- Compose render (CI env) unchanged for defaults; custom `IMMICH_HOST`
  changes the Traefik rule and only that.
- Bundle rollback fixture: `IMMICH_BUNDLE_ROLLBACK_ENABLED=0` skips the
  bundle rollback with a clear log line; `=1` behaves as today.
- Grep proves `IMMICH_UPDATE_CHANNEL` no longer appears anywhere.

## Rollback plan
Revert; vars return to dead-but-present. Existing live configs keep working
either way (removed var is simply ignored).

## Dependencies
None hard. Soft-blocks task 39 (which wires `PLEX_ENABLE_HW_TRANSCODE`).

## Risk / complexity / token size
Low. Small. ~6k tokens.

## Suggested order
Phase 2, after task 24.

## Result (partial) — 2026-11-10

**Step 1 DONE and enforced.** `IMMICH_UPDATE_CHANNEL` is removed from the
example, and so is `IMMICH_UPDATE_MODE`, which this task did not list but is the
same defect: measured, **zero references anywhere in the repository**, sitting in
a documented "Update policy — Class C" section beside keys that are read. The
section now states that bundle-only is STRUCTURAL — there is no non-bundle
Immich update path and `immich` is absent from `managed_image_specs` — so nobody
re-adds a mode switch expecting it to do something.

`tests/config-example-dead-keys-audit.py` stops this class coming back. It scans
the example against the CONSUMERS only (`bin/`, `install.sh`, `compose/`,
`systemd/`, `operator/`) — `tests/` is excluded because a test naming a key
would make it read as live, which would make the audit unable to fail. The
`BACKUP_TARGET_*` family is recognised by DERIVING the prefix from the code's own
`BACKUP_TARGET_$(uppercase_token "$target")_${field}`, so it covers 30 keys
without an edit and reports no false positives. Negative-controlled in three
directions: both removed keys coming back, an invented key, and both vacuity
guards.

**Step 3 NOT done, deliberately, and the reason is a safety one.** This task is
right that `IMMICH_BUNDLE_ROLLBACK_ENABLED` is inert — verified, it is only
exported (`bin/domum-media:1516`) and prompted for (3202-3203), and
`AUTO_ROLLBACK_ENABLED` is what gates rollback (3494, 3503). `configure` asks for
both on adjacent lines, one real and one inert. But wiring it means a rollback
gate starts honouring a value that has never been honoured, and the production
config is `0600 root` — unreadable from this account — so wiring it could
silently turn bundle rollback OFF on this host. That is an operator-reviewed
change, not a cleanup. The example now says so where an operator will read it.

Steps 2 (`IMMICH_HOST`) and 4 (`PLEX_ENABLE_HW_TRANSCODE`) are untouched. Both
are the same "exported but inert" class, which the audit cannot see — a key that
IS referenced but whose value changes nothing needs a different check.
