# Task 39 — Jellyfin/Plex QuickSync

## Objective
Make Intel QuickSync hardware transcoding configurable and verified:
`PLEX_ENABLE_HW_TRANSCODE` actually gates the `/dev/dri` mapping, Jellyfin
gets an equivalent toggle and mapping, and `doctor` verifies the device,
driver, and group plumbing end-to-end.

## Files involved
- `compose/media/plex.yml` — `/dev/dri` currently passed unconditionally
  (~9–10)
- `compose/media/jellyfin.yml` — no device mapping today
- `bin/domum-media` — `export_env_for_compose()` (~982 exports the Plex
  var), `doctor`
- `config/domum-media.conf.example`, `docs/SETUP-N100.md`

## Reason
The N100's iGPU is its best feature for a media host — HW transcode is the
difference between 2 smooth streams and a pegged CPU. Today the toggle var
is dead (task 25 deferred it here), Plex gets the device unconditionally,
and Jellyfin — the service that benefits most — gets nothing. Nothing
verifies the host side (intel-media-driver, `vainfo`, render group), so
"HW transcode enabled" can silently mean software transcode.

## Implementation plan
1. Compose: gate `/dev/dri` via the profiles/override mechanism the repo's
   compose layering supports (a conditional fragment or an env-selected
   device list — follow the existing layering style); default ON for both
   Plex and Jellyfin on this hardware, toggles to disable.
2. Wire `PLEX_ENABLE_HW_TRANSCODE` and add `JELLYFIN_ENABLE_HW_TRANSCODE`.
3. `doctor` verification chain: `/dev/dri/renderD128` exists on host →
   render group id matches what the containers run with → `vainfo`
   succeeds on host (if installed) → device visible *inside* each enabled
   container (`docker exec ... ls /dev/dri`).
4. Docs: driver install (`intel-media-va-driver-non-free`, `vainfo`) and
   the in-app settings step (Jellyfin dashboard → playback → VAAPI/QSV;
   Plex settings → transcoder) — the compose mapping alone doesn't enable
   it in-app.

## Operator runbook
One-time:
1. `apt install intel-media-va-driver-non-free vainfo` (if missing);
   `vainfo` lists VA profiles.
2. `domum-media apply`; `domum-media doctor` → QuickSync chain green.
3. Enable HW transcode in Jellyfin and Plex settings; play a transcoded
   stream and confirm low CPU (`intel_gpu_top` or load comparison).

## Testing plan
- Compose render with toggles on/off shows/omits the device mapping.
- `doctor` on the live host passes the full chain; unplugged fixture
  (toggle on, device path missing) produces a pointed finding.
- Real transcode session: CPU stays low, stream plays.

## Rollback plan
Toggle off (config) or revert; software transcoding resumes.

## Dependencies
Task 25 (left the var with a deferral comment), task 37 (`/dev/dri`
checkup probe complements this).

## Risk / complexity / token size
Low (worst case: transcode falls back to software). Small. ~6k tokens.

## Suggested order
Phase 6, after task 38.
