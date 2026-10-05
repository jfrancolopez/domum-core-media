#!/usr/bin/env bash
set -uo pipefail

# An application image upgrade may proceed only when the state THAT application
# may mutate has a recovery point appropriate to THAT application.
#
# Two paths can deploy a staged image, and only one of them was gated:
#
#   domum-media updates apply / refresh-images
#       -> create_service_snapshot <service> "pre-update"
#       -> snapshot_protection_unavailable -> die under SNAPSHOT_POLICY=REQUIRED
#       correctly REFUSES a service whose state is not a subvolume
#
#   domum-media apply            (and `domum-media update`, which is repo_update,
#                                 which ends in `exec domum-media apply`)
#       -> snapshot_create "pre-apply"   <- fleet-wide, and a WARNING on failure
#       -> compose up -d --remove-orphans
#       recreated any container whose image had changed, upgrading the
#       application and migrating its state with nothing to go back to
#
# Measured on this host when the gap was found: plex and calibre-web both had a
# staged image and an unprotected /srv/data path. `domum-media apply` would have
# upgraded both.
#
# This is the `immich reset-db` defect class -- a gate satisfied by an unrelated
# snapshot -- so it is tested per service and never by counting.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# $1 = extra stubs. Two enabled services: `alpha` (protected) and `beta`
# (whatever the scenario says).
blockers() {
  cat > "$TMP_DIR/probe.sh" <<PROBE
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$TMP_DIR/data"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snaps"
need_root() { :; }
load_cfg() { :; }
ENABLE_ALPHA=1
ENABLE_BETA=1
service_lifecycle_specs() {
  printf 'alpha|ENABLE_ALPHA|B|21|alpha|ALPHA_IMAGE|\n'
  printf 'beta|ENABLE_BETA|B|21|beta|BETA_IMAGE|\n'
}
service_data_path() { printf '%s' "\$DOMUM_DATA_ROOT/\$1"; }
service_compose_services() { printf '%s' "\$1"; }
report_snapshot_protection() { printf '{"service":"%s","state":"%s"}' "\$1" "\$(eval printf '%s' \\"\\\$PROT_\$1\\")"; }
$1
apply_staged_image_blockers
PROBE
  # $2 = "nobeta" to leave beta's state path absent. The helper used to create
  # both unconditionally, which quietly undid the one fixture that distinguishes
  # "has unprotected state" from "has no state here at all".
  mkdir -p "$TMP_DIR/data/alpha" "$TMP_DIR/snaps"
  if [[ "${2:-}" == nobeta ]]; then rm -rf "$TMP_DIR/data/beta"; else mkdir -p "$TMP_DIR/data/beta"; fi
  bash "$TMP_DIR/probe.sh" 2>/dev/null
}

STAGED='service_staged_image_changes() { printf "STAGED %s sha256:running sha256:staged\n" "$1"; }'
CLEAN='service_staged_image_changes() { printf ""; }'

# ---------------------------------------------------------------------------
# 1. A staged image for an UNPROTECTED service is a blocker.
# ---------------------------------------------------------------------------
out="$(blockers "$STAGED
PROT_alpha=protected
PROT_beta=unprotected")"
grep -q '^BLOCKED beta unprotected$' <<< "$out" || fail "1: an unprotected service with a staged image was not blocked: [$out]"
grep -q '^BLOCKED alpha' <<< "$out" && fail "1: a PROTECTED service with a staged image was blocked: [$out]"

# ---------------------------------------------------------------------------
# 2. SERVICE SPECIFICITY. alpha being protected must not clear beta.
#    This is the whole defect class: a gate satisfied by someone else's snapshot.
# ---------------------------------------------------------------------------
for beta_state in unprotected snapshottable degraded; do
  out="$(blockers "$STAGED
PROT_alpha=protected
PROT_beta=$beta_state")"
  grep -q "^BLOCKED beta $beta_state\$" <<< "$out" \
    || fail "2: beta=$beta_state was cleared while alpha was protected -- a gate satisfied by another service: [$out]"
done

# ...and it is not a count. Both protected -> nothing blocked; both unprotected ->
# BOTH blocked, not just the first.
out="$(blockers "$STAGED
PROT_alpha=protected
PROT_beta=protected")"
[[ -z "$(grep '^BLOCKED' <<< "$out")" ]] || fail "2: two protected services were blocked: [$out]"
out="$(blockers "$STAGED
PROT_alpha=unprotected
PROT_beta=unprotected")"
[[ "$(grep -c '^BLOCKED' <<< "$out")" == "2" ]] \
  || fail "2: two unprotected services produced $(grep -c '^BLOCKED' <<< "$out") blockers, expected 2: [$out]"

# ---------------------------------------------------------------------------
# 3. No staged image -> no blocker, whatever the protection state.
#    Convergence must stay usable.
# ---------------------------------------------------------------------------
out="$(blockers "$CLEAN
PROT_alpha=unprotected
PROT_beta=unprotected")"
[[ -z "$out" ]] || fail "3: convergence was blocked with no staged image anywhere: [$out]"

# ---------------------------------------------------------------------------
# 4. A service with NO state path under the protected tier is reported, not
#    blocked. traefik and uptime-kuma keep their durable state in volumes that
#    the recovery pack captures; a snapshot could never cover them, and refusing
#    would be refusing the wrong thing.
# ---------------------------------------------------------------------------
out="$(blockers "$STAGED
PROT_alpha=protected
PROT_beta=unknown" nobeta)"
grep -q '^NOSTATE beta$' <<< "$out" || fail "4: a service with no state path was not reported: [$out]"
grep -q '^BLOCKED beta' <<< "$out" && fail "4: a service with no state path was BLOCKED: [$out]"

# ...but a path that EXISTS whose protection cannot be determined IS blocked.
# `unknown` means the path is missing or btrfs is unavailable; with the path
# present it is the second, and "I cannot tell" must never mean "proceed".
out="$(blockers "$STAGED
PROT_alpha=protected
PROT_beta=unknown")"
grep -q '^BLOCKED beta unknown$' <<< "$out" \
  || fail "4: an undeterminable protection state was not blocked: [$out]"

# ---------------------------------------------------------------------------
# 5. A disabled service is not consulted at all.
# ---------------------------------------------------------------------------
out="$(blockers "$STAGED
ENABLE_BETA=0
PROT_alpha=protected
PROT_beta=unprotected")"
grep -q 'beta' <<< "$out" && fail "5: a disabled service was consulted: [$out]"

# ---------------------------------------------------------------------------
# 6. THE REFUSAL ITSELF, run rather than located.
#
# The first version of this test only checked that apply CALLED the blocker list
# and that the call came before `up -d`. Disabling the refusal (`if false; then`)
# survived: the list was still built, and nothing noticed that its result was
# ignored.
# ---------------------------------------------------------------------------
refuse() {  # $1 = extra stubs -> output, with RC=<n> appended
  cat > "$TMP_DIR/refuse.sh" <<PROBE
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$TMP_DIR/data"
need_root() { :; }
load_cfg() { :; }
load_report_lib() { :; }
$1
rc=0
( apply_assert_staged_images_recoverable ) || rc=\$?
printf 'RC=%s' "\$rc"
PROBE
  bash "$TMP_DIR/refuse.sh" 2>&1
}

# Blocked -> refuses, names the service, and explains why another snapshot is not enough.
out="$(refuse 'apply_staged_image_blockers() { printf "BLOCKED plex unprotected
"; }')"
grep -q 'RC=0' <<< "$out" && fail "6: a blocked service did not stop the apply: $out"
grep -q 'BLOCKED plex unprotected' <<< "$out" || fail "6: the blocked service was not named: $out"
grep -q "another service's snapshot does not count" <<< "$out" \
  || fail "6: the refusal does not say why another service's snapshot is not enough: $out"
grep -q 'storage migrate-subvolume' <<< "$out" || fail "6: no way forward was offered: $out"
grep -q 'updates apply' <<< "$out" || fail "6: the gated path was not named: $out"

# Nothing blocked -> proceeds silently.
out="$(refuse 'apply_staged_image_blockers() { printf ""; }')"
grep -q 'RC=0' <<< "$out" || fail "6: convergence was refused with nothing blocked: $out"

# NOSTATE alone -> reported, and proceeds.
out="$(refuse 'apply_staged_image_blockers() { printf "NOSTATE traefik
"; }')"
grep -q 'RC=0' <<< "$out" || fail "6: a service with no state under the tier was refused: $out"
grep -q 'NOT under' <<< "$out" || fail "6: the no-state case was not reported: $out"
grep -q 'STATE-CLASSIFICATION' <<< "$out" || fail "6: it does not say what covers them instead: $out"

# The override works -- and announces.
out="$(refuse 'APPLY_ALLOW_IMAGE_CHANGE=1
apply_staged_image_blockers() { printf "BLOCKED plex unprotected
"; }')"
grep -q 'RC=0' <<< "$out" || fail "6: the override did not allow it: $out"
grep -q 'WILL upgrade these unprotected services' <<< "$out" || fail "6: the override went quiet: $out"

# Mixed: one blocker among several no-state entries still refuses.
out="$(refuse 'apply_staged_image_blockers() { printf "NOSTATE traefik
BLOCKED plex unprotected
NOSTATE uptime-kuma
"; }')"
grep -q 'RC=0' <<< "$out" && fail "6: a blocker was lost among NOSTATE entries: $out"

# ---------------------------------------------------------------------------
# 6b. The call site: the refusal must run BEFORE `up -d`.
# ---------------------------------------------------------------------------
apply_block="$(awk '/^apply\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'apply_assert_staged_images_recoverable' <<< "$apply_block" \
  || fail "6b: apply does not call the refusal"
# The refusal must come BEFORE the fleet-wide up -d, or it refuses after deploying.
gate_line="$(grep -n 'apply_assert_staged_images_recoverable' <<< "$apply_block" | head -1 | cut -d: -f1)"
up_line="$(grep -n 'compose_cmd up -d --remove-orphans' <<< "$apply_block" | head -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$up_line" ]] || fail "6b: could not locate the gate and the up -d"
(( gate_line < up_line )) \
  || fail "6b: the gate is at line $gate_line and 'up -d' at $up_line -- it would refuse after deploying"
[[ "$gate_line" -lt "$up_line" ]] || true

# ---------------------------------------------------------------------------
# 7. The OTHER path's gate must stay service-specific and fail closed.
#    refresh_images snapshots the service being updated, by name, and hands an
#    empty result to snapshot_protection_unavailable -- which dies unless
#    SNAPSHOT_POLICY=WARN.
# ---------------------------------------------------------------------------
rf="$(awk '/^refresh_images\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'create_service_snapshot "\$logical_service" "pre-update"' <<< "$rf" \
  || fail "7: refresh_images no longer snapshots the service it is updating, by name"
grep -q 'snapshot_protection_unavailable' <<< "$rf" \
  || fail "7: refresh_images no longer gates on the snapshot it just tried to take"
grep -qE 'snapshot_create\b' <<< "$rf" \
  && fail "7: refresh_images uses the FLEET-WIDE snapshot_create; a gate must not be satisfiable by another service"
# And the policy default must be the strict one.
grep -q 'SNAPSHOT_POLICY:-REQUIRED' "$REPO_ROOT/bin/domum-media" \
  || fail "7: SNAPSHOT_POLICY no longer defaults to REQUIRED, so the gate warns instead of refusing"

echo "PASS: upgrade protection gate smoke test"
