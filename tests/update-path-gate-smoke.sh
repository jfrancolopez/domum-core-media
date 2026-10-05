#!/usr/bin/env bash
set -uo pipefail

# `domum-media update` is NOT a separate path: it is repo_update, which ends in
#   exec /usr/local/bin/domum-media apply
# so whatever gates `apply` gates `update`. That indirection is exactly why the
# hole was missed, so it is asserted here rather than remembered.
#
# The invariant under test:
#
#   Any path capable of deploying a different application image must establish
#   service-specific recoverability for every stateful service it may recreate,
#   or refuse before reconciliation.
#
# tests/upgrade-protection-gate-smoke.sh proves the gate's logic with abstract
# services (alpha/beta). This suite instead builds the REAL production shape --
# six services with the names, staged-image status and protection states measured
# on this host -- because the operator's question is about plex and calibre-web
# by name, and because a hyphenated name (`calibre-web`) is not a legal shell
# variable, which is the kind of detail an abstract fixture hides.
#
# Measured on the N100 (2026-10-05):
#
#   plex         staged   /srv/data/plex          unprotected
#   calibre-web  staged   /srv/data/calibre-web   unprotected
#   traefik      staged   no /srv/data path       (ACME store is a docker volume)
#   uptime-kuma  staged   no /srv/data path       (data is a docker volume)
#   jellyfin     clean    subvolume + snapshot    protected
#   kavita       clean    subvolume + snapshot    protected
#   navidrome    clean    subvolume + snapshot    protected

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Build a probe against the real CLI. $1 = staged-image stub, $2 = protection
# stub, $3 = extra lines. Services whose names appear in $NOSTATE get no state
# directory, modelling a docker-volume service.
probe() {
  local staged_stub="$1" prot_stub="$2" extra="${3:-}" cmd="${4:-apply_staged_image_blockers}"
  rm -rf "$TMP_DIR/data" "$TMP_DIR/snaps"
  mkdir -p "$TMP_DIR/snaps"
  local svc
  for svc in plex calibre-web jellyfin kavita navidrome; do
    case " ${NOSTATE:-} " in *" $svc "*) continue ;; esac
    mkdir -p "$TMP_DIR/data/$svc"
  done
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$REPO_ROOT/bin/domum-media"
    printf 'DOMUM_DATA_ROOT=%q\n' "$TMP_DIR/data"
    printf 'DOMUM_SNAPSHOT_ROOT=%q\n' "$TMP_DIR/snaps"
    printf 'need_root() { :; }\n'
    printf 'load_cfg() { :; }\n'
    printf 'load_report_lib() { :; }\n'
    # The seven production services, all enabled.
    printf 'ENABLE_PLEX=1 ENABLE_CALIBRE_WEB=1 ENABLE_TRAEFIK=1 ENABLE_UPTIME_KUMA=1\n'
    printf 'ENABLE_JELLYFIN=1 ENABLE_KAVITA=1 ENABLE_NAVIDROME=1\n'
    cat <<'SPECS'
service_lifecycle_specs() {
  printf 'plex|ENABLE_PLEX|B|21|plex|PLEX_IMAGE|\n'
  printf 'calibre-web|ENABLE_CALIBRE_WEB|B|21|calibre-web|CALIBRE_WEB_IMAGE|\n'
  printf 'traefik|ENABLE_TRAEFIK|B|21|traefik|TRAEFIK_IMAGE|\n'
  printf 'uptime-kuma|ENABLE_UPTIME_KUMA|B|21|uptime-kuma|UPTIME_KUMA_IMAGE|\n'
  printf 'jellyfin|ENABLE_JELLYFIN|B|21|jellyfin|JELLYFIN_IMAGE|\n'
  printf 'kavita|ENABLE_KAVITA|B|21|kavita|KAVITA_IMAGE|\n'
  printf 'navidrome|ENABLE_NAVIDROME|B|21|navidrome|NAVIDROME_IMAGE|\n'
}
service_data_path() { printf '%s' "$DOMUM_DATA_ROOT/$1"; }
service_compose_services() { printf '%s' "$1"; }
SPECS
    printf '%s\n' "$staged_stub"
    printf '%s\n' "$prot_stub"
    printf '%s\n' "$extra"
    printf '%s\n' "$cmd"
  } > "$TMP_DIR/probe.sh"
  bash "$TMP_DIR/probe.sh" 2>&1
}

# Production's real staged set: plex, calibre-web, traefik, uptime-kuma.
STAGED_REAL='service_staged_image_changes() {
  case "$1" in
    plex|calibre-web|traefik|uptime-kuma)
      printf "STAGED %s sha256:running sha256:staged\n" "$1" ;;
    *) printf "" ;;
  esac
}'
# Production's real protection: the three migrated services are protected.
PROT_REAL='report_snapshot_protection() {
  local st
  case "$1" in
    jellyfin|kavita|navidrome) st=protected ;;
    *) st=unprotected ;;
  esac
  printf "{\"service\":\"%s\",\"state\":\"%s\"}" "$1" "$st"
}'
NOSTATE="traefik uptime-kuma"

# ---------------------------------------------------------------------------
echo "== 1. the real production shape: plex and calibre-web must be BLOCKED =="
out="$(probe "$STAGED_REAL" "$PROT_REAL")"
grep -q '^BLOCKED plex unprotected$' <<< "$out" \
  || fail "plex (staged + unprotected) was not blocked. got:
$out"
grep -q '^BLOCKED calibre-web unprotected$' <<< "$out" \
  || fail "calibre-web (staged + unprotected) was not blocked. got:
$out"
echo "  plex        BLOCKED unprotected"
echo "  calibre-web BLOCKED unprotected"

# ---------------------------------------------------------------------------
echo "== 2. the three migrated services must NOT be blocked =="
# They are clean here, but the point is that their own recovery point is what
# clears them -- proven in case 3 by staging an image for them.
for svc in jellyfin kavita navidrome; do
  grep -q "^BLOCKED $svc" <<< "$out" && fail "$svc was blocked but is protected and clean"
done
echo "  jellyfin, kavita, navidrome not blocked"

# ---------------------------------------------------------------------------
echo "== 3. a protected service's OWN recovery point clears its OWN upgrade =="
STAGED_ALL='service_staged_image_changes() { printf "STAGED %s sha256:running sha256:staged\n" "$1"; }'
out3="$(probe "$STAGED_ALL" "$PROT_REAL")"
for svc in jellyfin kavita navidrome; do
  grep -q "^BLOCKED $svc" <<< "$out3" \
    && fail "$svc is protected and staged, so its own recovery point should clear it. got:
$out3"
done
grep -q '^BLOCKED plex unprotected$' <<< "$out3" || fail "plex must still be blocked with everything staged"
echo "  all three staged + protected -> cleared; plex still blocked"

# ---------------------------------------------------------------------------
echo "== 4. service A's protection must NEVER satisfy service B =="
# Only jellyfin protected. plex and calibre-web must still be blocked -- this is
# the `immich reset-db` defect class, where an unrelated snapshot cleared a gate.
PROT_ONLY_JELLYFIN='report_snapshot_protection() {
  local st; case "$1" in jellyfin) st=protected ;; *) st=unprotected ;; esac
  printf "{\"service\":\"%s\",\"state\":\"%s\"}" "$1" "$st"
}'
out4="$(probe "$STAGED_ALL" "$PROT_ONLY_JELLYFIN")"
grep -q '^BLOCKED plex ' <<< "$out4"        || fail "jellyfin's protection cleared plex"
grep -q '^BLOCKED calibre-web ' <<< "$out4" || fail "jellyfin's protection cleared calibre-web"
grep -q '^BLOCKED kavita '    <<< "$out4"   || fail "jellyfin's protection cleared kavita"
grep -q '^BLOCKED navidrome ' <<< "$out4"   || fail "jellyfin's protection cleared navidrome"
grep -q '^BLOCKED jellyfin '  <<< "$out4"   && fail "jellyfin is protected and must not be blocked"
echo "  one protected service clears only itself (4 others still blocked)"

# ---------------------------------------------------------------------------
echo "== 5. protection 'unknown' must FAIL CLOSED =="
for state in unknown degraded snapshottable "" garbage; do
  PROT_X="report_snapshot_protection() { printf '{\"service\":\"%s\",\"state\":\"%s\"}' \"\$1\" '$state'; }"
  outx="$(probe "$STAGED_REAL" "$PROT_X")"
  grep -q '^BLOCKED plex ' <<< "$outx" \
    || fail "protection state '$state' did not block plex -- the gate must fail closed. got:
$outx"
  printf '  state %-14s -> BLOCKED\n' "'${state:-<empty>}'"
done

# ---------------------------------------------------------------------------
echo "== 6. NO global snapshot count can satisfy the gate =="
# The defect class: a gate that counts snapshots anywhere instead of asking about
# THIS service. Fill the snapshot root with 50 snapshots for other services.
EXTRA_SNAPS='for i in $(seq 1 50); do mkdir -p "$DOMUM_SNAPSHOT_ROOT/jellyfin-2026010$((i%9+1))-00000$((i%9+1))-post-migration"; done'
out6="$(probe "$STAGED_REAL" "$PROT_REAL" "$EXTRA_SNAPS")"
grep -q '^BLOCKED plex unprotected$' <<< "$out6" \
  || fail "50 unrelated snapshots satisfied plex's gate. got:
$out6"
echo "  50 unrelated snapshots present -> plex still BLOCKED"

# ---------------------------------------------------------------------------
echo "== 7. docker-volume services are REPORTED, not blocked =="
grep -q '^NOSTATE traefik$'     <<< "$out" || fail "traefik should be NOSTATE (volume), got:
$out"
grep -q '^NOSTATE uptime-kuma$' <<< "$out" || fail "uptime-kuma should be NOSTATE (volume)"
grep -q '^BLOCKED traefik'      <<< "$out" && fail "traefik must not be BLOCKED: a snapshot cannot cover a docker volume"
echo "  traefik, uptime-kuma -> NOSTATE (a snapshot could never cover them)"

# ---------------------------------------------------------------------------
echo "== 8. the refusal itself REFUSES, with the real names in the message =="
out8="$(probe "$STAGED_REAL" "$PROT_REAL" "" "apply_assert_staged_images_recoverable")"; rc8=$?
[ "$rc8" -ne 0 ] || fail "apply_assert_staged_images_recoverable exited 0 with plex and calibre-web blocked:
$out8"
grep -q 'Refusing' <<< "$out8"    || fail "the refusal did not say it was refusing: $out8"
grep -q 'plex' <<< "$out8"        || fail "the refusal did not name plex: $out8"
grep -q 'calibre-web' <<< "$out8" || fail "the refusal did not name calibre-web: $out8"
echo "  rc=$rc8, names plex and calibre-web"

# ---------------------------------------------------------------------------
echo "== 9. it PASSES when nothing staged is unprotected =="
# Convergence must stay usable. Nothing staged -> no blocker at all.
CLEAN_ALL='service_staged_image_changes() { printf ""; }'
out9="$(probe "$CLEAN_ALL" "$PROT_REAL" "" "apply_assert_staged_images_recoverable")"; rc9=$?
[ "$rc9" -eq 0 ] || fail "apply refused with NO staged image anywhere; convergence must stay usable:
$out9"
echo "  nothing staged -> rc=0"

# And with everything staged but everything protected.
PROT_ALL='report_snapshot_protection() { printf "{\"service\":\"%s\",\"state\":\"protected\"}" "$1"; }'
out9b="$(probe "$STAGED_ALL" "$PROT_ALL" "" "apply_assert_staged_images_recoverable")"; rc9b=$?
[ "$rc9b" -eq 0 ] || fail "everything staged AND protected should pass:
$out9b"
echo "  everything staged but protected -> rc=0"

# ---------------------------------------------------------------------------
echo "== 10. the deliberate override is explicit and LOUD =="
out10="$(probe "$STAGED_REAL" "$PROT_REAL" 'APPLY_ALLOW_IMAGE_CHANGE=1' "apply_assert_staged_images_recoverable")"; rc10=$?
[ "$rc10" -eq 0 ] || fail "APPLY_ALLOW_IMAGE_CHANGE=1 should proceed deliberately, got rc=$rc10:
$out10"
grep -q 'APPLY_ALLOW_IMAGE_CHANGE=1' <<< "$out10" \
  || fail "the override proceeded SILENTLY. It must name itself and the services it is upgrading:
$out10"
grep -q 'plex' <<< "$out10" || fail "the override did not name the services it upgrades: $out10"
echo "  override proceeds but announces itself and names plex"
# It must be opt-in: absent or 0 must refuse.
for v in 0 "" no; do
  outv="$(probe "$STAGED_REAL" "$PROT_REAL" "APPLY_ALLOW_IMAGE_CHANGE='$v'" "apply_assert_staged_images_recoverable")"; rcv=$?
  [ "$rcv" -ne 0 ] || fail "APPLY_ALLOW_IMAGE_CHANGE='$v' must NOT enable the override (got rc=0)"
done
echo "  only the exact value 1 enables it"

# ---------------------------------------------------------------------------
echo "== 11. \`update\` reaches the gate: the chain, asserted not remembered =="
CLI="$REPO_ROOT/bin/domum-media"
# update -> repo_update
grep -qE '^\s*update\)\s*shift;\s*repo_update' "$CLI" \
  || fail "the dispatcher no longer routes \`update\` to repo_update; re-verify the whole chain"
# repo_update -> exec apply
ru="$(awk '/^repo_update\(\)/,/^}/' "$CLI")"
grep -q 'exec /usr/local/bin/domum-media apply' <<< "$ru" \
  || fail "repo_update no longer execs apply; \`update\` may now reach \`up -d\` by another route"
echo "  update -> repo_update -> exec apply"

# ---------------------------------------------------------------------------
echo "== 12. in \`apply\`, the gate precedes EVERY up -d =="
ap="$(awk '/^apply\(\)/,/^}/' "$CLI")"
gate_line="$(grep -n 'apply_assert_staged_images_recoverable' <<< "$ap" | head -1 | cut -d: -f1)"
[ -n "$gate_line" ] || fail "apply() no longer calls apply_assert_staged_images_recoverable"
upd_lines="$(grep -n 'compose_cmd up -d' <<< "$ap" | cut -d: -f1)"
[ -n "$upd_lines" ] || fail "apply() has no 'compose_cmd up -d'; the call-site assertion is now vacuous"
n=0
while read -r l; do
  [ -n "$l" ] || continue
  n=$((n+1))
  [ "$gate_line" -lt "$l" ] \
    || fail "apply() reconciles at relative line $l BEFORE the gate at $gate_line"
done <<< "$upd_lines"
echo "  gate at relative line $gate_line precedes all $n 'compose_cmd up -d' call(s)"

# ---------------------------------------------------------------------------
echo "== 13. no OTHER function reconciles without a classified gate =="
# A new `up -d` in an unclassified function is how this defect appeared. The
# reconcile-boundary audit owns that rule; assert it is still wired into CI so
# this suite cannot be the only thing standing between us and a repeat.
grep -q 'reconcile-boundary-audit.py' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "reconcile-boundary-audit.py is not in the CI workflow"
grep -q 'update-path-gate-smoke.sh' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "this suite is not in the CI workflow, so it proves nothing about main"
echo "  reconcile-boundary audit and this suite are both wired into CI"

echo "PASS: update-path gate smoke test"
