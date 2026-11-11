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

## Result (continued) — 2026-11-10, the inert class

**Step 2 and step 3 are now DOCUMENTED AND ENFORCED rather than done**, and a
third inert key this task did not list was found and removed.

`tests/config-example-inert-keys-audit.py` covers the class this task actually
describes — a key that IS referenced but whose value nothing reads. It joins line
continuations, which is not optional: a `config_set` whose prompt default sits on
the next physical line puts `${KEY:-...}` on a line with no `config_set` on it,
so a line-at-a-time scan found **0** inert keys where joining finds **3**.

| key | outcome |
|---|---|
| `DOMUM_TS_IP` | **REMOVED** — not listed by this task. Its comment claimed "used by docs and dynamic routes"; both halves measured false, while its neighbour `DOMUM_LAN_IP` under the same comment genuinely is used. Prompt and export removed with it; the CI compose render was measured identical with and without it |
| `IMMICH_HOST` | exempt with a printed reason — step 2's wiring is a compose change |
| `IMMICH_BUNDLE_ROLLBACK_ENABLED` | exempt with a printed reason — step 3 wires a ROLLBACK gate to a never-obeyed value, and the production config is `0600 root` |

Both exemptions carry `# inert-audit: <reason>` on the key's own line and the
audit FAILS if the key stops being inert, so a marker cannot outlive its defect.

**Step 4 was stale in this task**: `PLEX_ENABLE_HW_TRANSCODE` is no longer in the
example at all (it is only exported in `bin/domum-media:1534`), so it is outside
both audits' scope by construction. The underlying observation still holds —
`compose/media/plex.yml:11` passes `/dev/dri` unconditionally — and task 39
owns it.
