#!/usr/bin/env bash
set -uo pipefail

# "No /srv/data/<service>" is NOT "stateless", and the upgrade gate used to
# treat them as the same thing.
#
# WHY IT EXISTS. apply_staged_image_blockers asked one question -- does
# /srv/data/<service> exist? -- and emitted NOSTATE when it did not. NOSTATE was
# reported and then ALLOWED. Measured on this host 2026-10-08:
#
#   traefik      volume domum-media_traefik-letsencrypt -> /letsencrypt
#                acme.json 116,015 bytes mode 0600: the Let's Encrypt ACCOUNT
#                KEY and every issued certificate
#   uptime-kuma  volume domum-media_uptime-kuma-data -> /app/data
#                kuma.db 286,720 bytes with a NON-EMPTY -wal: a live SQLite
#                database the application forward-migrates on startup
#
# Both had a staged image waiting (traefik v3.7.10 -> v3.7.12, uptime-kuma
# a8610b3b4c38 -> 3e24e96c89ef) and neither was blocked.
#
# The recovery pack does capture both, so this was never "no coverage" -- it is
# the wrong KIND. A recovery pack is periodic, operator-driven, and records no
# image identity, so it cannot pair state with the application that wrote it.
#
# These assertions pin the classification, the gate's treatment of each class,
# and -- the part that matters most -- that it fails CLOSED when the declaration
# and the live mounts disagree.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

# A probe with docker stubbed, so mounts are whatever the case under test needs.
probe() {  # $1 = docker stub body, $2 = shell to run
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    printf 'DOMUM_DATA_ROOT=%q\n' "$TMP_DIR/data"
    printf '%s\n' "$1"
    printf '%s\n' "$2"
  } > "$TMP_DIR/probe.sh"
  bash "$TMP_DIR/probe.sh" 2>"$TMP_DIR/err"
}

# Mount shapes, by destination/source, keyed on the container name.
STUB_VOLUME='docker() {
  case "$*" in
    *"eq .Type \"volume\""*)
      case "$*" in
        *traefik*)     printf "/letsencrypt\n" ;;
        *uptime-kuma*) printf "/app/data\n" ;;
        *immich*)      printf "/cache\n/data\n" ;;
      esac ;;
    *"eq .Type \"bind\""*) : ;;
  esac
  return 0
}'

echo "== 1. the three classes are distinguished on the REAL declarations =="
out="$(probe "$STUB_VOLUME" 'for s in traefik uptime-kuma plex tailscale immich; do printf "%s=%s\n" "$s" "$(service_state_model "$s")"; done')"
grep -q '^traefik=docker-volume' <<< "$out" || fail "traefik is not docker-volume: $out"
grep -q '^uptime-kuma=docker-volume' <<< "$out" || fail "uptime-kuma is not docker-volume: $out"
grep -q '^plex=protected-tier' <<< "$out" || fail "plex is not protected-tier: $out"
grep -q '^tailscale=stateless' <<< "$out" || fail "tailscale is not stateless: $out"
# immich's /cache and /data are DECLARED benign, so they must not make it unknown.
grep -q '^immich=protected-tier' <<< "$out" || fail "immich is not protected-tier: $out"
echo "  docker-volume x2, protected-tier x2, stateless x1"

echo "== 2. the reason NAMES the volume, so the finding is actionable =="
grep -q 'traefik=docker-volume.*letsencrypt' <<< "$out" \
  || fail "the traefik reason does not name /letsencrypt: $out"
grep -q 'uptime-kuma=docker-volume.*/app/data' <<< "$out" \
  || fail "the uptime-kuma reason does not name /app/data: $out"
echo "  /letsencrypt and /app/data named"

echo "== 3. an UNDECLARED service is unknown, not permissive =="
out="$(probe "$STUB_VOLUME" 'service_state_model no-such-service')"
grep -q '^unknown' <<< "$out" || fail "an undeclared service was not 'unknown': $out"
echo "  unknown"

echo "== 4. a declaration contradicted by the live mounts fails CLOSED =="
# (a) declared stateless, but mounts an undeclared rw volume.
STUB_SNEAKY='docker() {
  case "$*" in
    *"eq .Type \"volume\""*) printf "/var/lib/sneaky\n" ;;
    *"eq .Type \"bind\""*) : ;;
  esac
  return 0
}'
out="$(probe "$STUB_SNEAKY" 'service_state_model tailscale')"
grep -q '^unknown' <<< "$out" \
  || fail "a service declared stateless that mounts an undeclared rw volume was NOT
flagged. A volume added later would inherit the permissive classification: $out"
grep -q 'sneaky' <<< "$out" || fail "the offending volume was not named: $out"
# (b) declared stateless, but writes under the protected data root via a bind.
STUB_BIND='docker() {
  case "$*" in
    *"eq .Type \"volume\""*) : ;;
    *"eq .Type \"bind\""*) printf "%s/tailscale\n" "'"$TMP_DIR"'/data" ;;
  esac
  return 0
}'
out="$(probe "$STUB_BIND" 'service_state_model tailscale')"
grep -q '^unknown' <<< "$out" \
  || fail "a service declared stateless that WRITES under the data root via a bind
mount was not flagged: $out"
# (c) declared protected-tier, but mounts an undeclared rw volume.
out="$(probe "$STUB_SNEAKY" 'service_state_model plex')"
grep -q '^unknown' <<< "$out" \
  || fail "a protected-tier service with an undeclared rw volume was not flagged: $out"
echo "  undeclared volume, undeclared bind, and protected-tier contradiction all -> unknown"

echo "== 5. the GATE blocks docker-volume and unknown, and allows only stateless =="
# Drive apply_staged_image_blockers itself: every service reports STAGED, so the
# classification is the only thing deciding the outcome.
GATE_SCAFFOLD='
service_staged_image_changes() { printf "STAGED %s old new\n" "$1"; }
report_snapshot_protection() { printf "{\"state\":\"protected\"}"; }
ENABLE_TRAEFIK=1; ENABLE_TAILSCALE=1; ENABLE_UPTIME_KUMA=1; ENABLE_PLEX=1
ENABLE_JELLYFIN=0; ENABLE_NAVIDROME=0; ENABLE_CALIBRE_WEB=0; ENABLE_KAVITA=0
ENABLE_IMMICH=0; ENABLE_RESTIC_REST_SERVER=0
load_report_lib() { :; }'
GATE_STUB="$STUB_VOLUME$GATE_SCAFFOLD"
GATE_STUB_SNEAKY="$STUB_SNEAKY$GATE_SCAFFOLD"
mkdir -p "$TMP_DIR/data/plex"
out="$(probe "$GATE_STUB" 'apply_staged_image_blockers')"
grep -q '^BLOCKED traefik docker-volume' <<< "$out" \
  || fail "traefik was NOT blocked. A staged image would deploy over the Let's Encrypt
account key with no recovery point: $out"
grep -q '^BLOCKED uptime-kuma docker-volume' <<< "$out" \
  || fail "uptime-kuma was NOT blocked. A staged image would forward-migrate kuma.db
with no recovery point: $out"
grep -q '^STATELESS tailscale' <<< "$out" || fail "tailscale was not reported stateless: $out"
grep -q '^BLOCKED tailscale' <<< "$out" && fail "a stateless service was blocked"
grep -q 'traefik\|uptime-kuma' <<< "$(grep '^STATELESS' <<< "$out")" \
  && fail "a docker-volume service was reported STATELESS"
echo "  docker-volume blocked, stateless reported, nothing mis-sorted"

echo "== 6. a protected-tier service whose path is MISSING is blocked =="
# Not "nothing to protect": either the mount is gone or the declaration is wrong,
# and upgrading on top of that creates a fresh install.
out="$(probe "$GATE_STUB" 'DOMUM_DATA_ROOT='"$TMP_DIR"'/empty; apply_staged_image_blockers')"
grep -q '^BLOCKED plex missing-state-path' <<< "$out" \
  || fail "a protected-tier service with no state path was not blocked: $out"
echo "  blocked, and named as a missing state path"

echo "== 7. the refusal reaches the OPERATOR, not just the log =="
out="$(probe "$GATE_STUB" 'apply_assert_staged_images_recoverable' 2>&1; cat "$TMP_DIR/err")"
grep -q 'Refusing' <<< "$out" || fail "the gate did not refuse: $out"
grep -q 'traefik' <<< "$out" || fail "the refusal does not name traefik: $out"
echo "  refuses and names the services"

echo "== 8. the per-service upgrade path explains the volume case accurately =="
# It used to fall through to "/srv/data/traefik does not exist", which invites
# the operator to create the directory -- which would protect nothing.
body="$(awk '/^assert_pre_upgrade_possible\(\) \{/,/^\}$/' "$CLI")"
[ -n "$body" ] || fail "could not isolate assert_pre_upgrade_possible"
grep -q 'service_state_model' <<< "$body" \
  || fail "it does not consult the state model"
grep -q 'DOCKER VOLUME' <<< "$body" || fail "it does not explain the volume case"
grep -q 'would protect nothing' <<< "$body" \
  || fail "it does not warn that creating the directory protects nothing"
grep -q 'Failing closed' <<< "$body" || fail "it does not fail closed on an unknown model"
echo "  names the volume case, warns against the wrong fix, fails closed on unknown"

echo "== 9. NOSTATE is gone from the code, not merely renamed =="
grep -n 'NOSTATE' "$CLI" | grep -v '^\s*[0-9]*:#' | grep -v 'classified NOSTATE' \
  && fail "NOSTATE still appears outside the historical comment"
echo "  only the historical comment remains"

mutate() {  # $1 = sed program -> prints the gate output under mutation
  rm -rf "$TMP_DIR/m"; mkdir -p "$TMP_DIR/m"
  cp "$CLI" "$TMP_DIR/m/domum-media"
  sed -i "$1" "$TMP_DIR/m/domum-media" || { echo "SEDFAIL"; return; }
  cmp -s "$CLI" "$TMP_DIR/m/domum-media" && { echo "NOCHANGE"; return; }
  local saved="$CLI"; CLI="$TMP_DIR/m/domum-media"
  probe "$GATE_STUB" 'apply_staged_image_blockers'
  CLI="$saved"
}

echo "== 10. mutation: every arm of the gate is load-bearing =="
# (a) docker-volume downgraded from BLOCKED back to a report.
out="$(mutate "s|printf 'BLOCKED %s docker-volume %s\\\\n' \"\$svc\" \"\$reason\"|printf 'STATELESS %s %s\\\\n' \"\$svc\" \"\$reason\"|")"
[ "$out" = "SEDFAIL" ] && fail "the docker-volume mutation could not be applied"
[ "$out" = "NOCHANGE" ] && fail "the docker-volume block is no longer written as matched"
grep -q '^BLOCKED traefik' <<< "$out" \
  && fail "downgrading the docker-volume arm changed nothing; it is not what blocks traefik"
echo "  (a) the docker-volume arm is what blocks traefik"
# (b) unknown made permissive. Needs a service that actually CLASSIFIES as
#     unknown, otherwise the arm is never reached and the mutation proves
#     nothing. STUB_SNEAKY gives tailscale an undeclared rw volume.
out="$(probe "$GATE_STUB_SNEAKY" 'apply_staged_image_blockers')"
grep -q '^BLOCKED tailscale unknown' <<< "$out" \
  || fail "a service whose declaration is contradicted was not blocked by the gate: $out"
rm -rf "$TMP_DIR/m3"; mkdir -p "$TMP_DIR/m3"
cp "$CLI" "$TMP_DIR/m3/domum-media"
sed -i "s|printf 'BLOCKED %s unknown %s\\\\n' \"\$svc\" \"\$reason\"|printf 'STATELESS %s %s\\\\n' \"\$svc\" \"\$reason\"|" "$TMP_DIR/m3/domum-media"
cmp -s "$CLI" "$TMP_DIR/m3/domum-media" && fail "the unknown arm is no longer written as matched"
saved="$CLI"; CLI="$TMP_DIR/m3/domum-media"
out="$(probe "$GATE_STUB_SNEAKY" 'apply_staged_image_blockers')"
CLI="$saved"
grep -q '^BLOCKED tailscale' <<< "$out" \
  && fail "downgrading the unknown arm changed nothing; an unclassifiable service
would still be blocked by something else, so this arm is not what fails closed"
echo "  (b) the unknown arm is what blocks an unclassifiable service"
# (c) the contradiction check removed: a sneaky volume must stop being detected.
rm -rf "$TMP_DIR/m2"; mkdir -p "$TMP_DIR/m2"
cp "$CLI" "$TMP_DIR/m2/domum-media"
sed -i 's|\[\[ " \$benign " == \*" \$dest "\* \]\] && continue|continue|' "$TMP_DIR/m2/domum-media"
cmp -s "$CLI" "$TMP_DIR/m2/domum-media" && fail "the benign-list check is no longer written as matched"
saved="$CLI"; CLI="$TMP_DIR/m2/domum-media"
out="$(probe "$STUB_SNEAKY" 'service_state_model tailscale')"
CLI="$saved"
grep -q '^unknown' <<< "$out" \
  && fail "treating EVERY volume as benign still flagged the sneaky one, so the
contradiction check is not what catches it"
echo "  (c) the benign-list comparison is what catches an undeclared volume"

echo "== 11. storage protection reports the model, and exits 0 ONLY when protected =="
# An operator wrapper tests the exit status, so `stateless` must never read as
# `protected`. Before this, a docker-volume service answered
# "unknown -- state path is missing", which reads as a measurement failure
# rather than as "a snapshot cannot reach this state at all".
PROT_STUB="$STUB_VOLUME"'
report_snapshot_protection() { printf "{\"state\":\"protected\"}"; }
load_report_lib() { :; }'
mkdir -p "$TMP_DIR/data/plex"
for pair in "plex:protected:0" "traefik:docker-volume:1" \
            "uptime-kuma:docker-volume:1" "tailscale:stateless:1"; do
  svc="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; wantrc="${rest##*:}"
  got="$(probe "$PROT_STUB" 'storage_protection '"$svc"'; echo "rc=$?"')"
  word="$(head -1 <<< "$got")"
  rc="$(sed -n 's/^rc=//p' <<< "$got" | tail -1)"
  [ "$word" = "$want" ] || fail "storage protection $svc said '$word', expected '$want'"
  [ "$rc" = "$wantrc" ] \
    || fail "storage protection $svc exited $rc, expected $wantrc. An operator
wrapper tests this status: a non-protected state must not exit 0."
done
echo "  protected=0; docker-volume, stateless and unprotected all non-zero"

echo
echo "PASS: state model smoke"
