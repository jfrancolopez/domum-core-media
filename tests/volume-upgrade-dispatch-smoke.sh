#!/usr/bin/env bash
# The docker-volume upgrade path: dispatch, gate, verification and rollback.
#
# WHY IT EXISTS. The volume primitives -- storage_volume_pre_upgrade_point,
# storage_verify_volume_dumps, rollback_volume_upgrade -- all existed and
# NOTHING REACHED THEM. `create_upgrade_rollback_point` called
# storage_pre_upgrade_point unconditionally, so a docker-volume service could
# only ever be refused, by assert_pre_upgrade_possible, for the generic reason
# that its path is not a subvolume. Three tested functions, zero call sites.
#
# What this suite pins is the part that was missing: choosing the right
# machinery for the declared state model, refusing when the model is unknown
# rather than guessing, and verifying a volume point with the verifier that can
# actually see what it contains.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/data" "$TMP/snapshots" "$TMP/media" "$TMP/secrets" "$TMP/log"

# A minimal REAL config. The gate section below runs the real load_cfg, because
# stubbing it left DOMUM_LOG_DIR unbound and `set -u` killed the shell before
# the refusal could be printed -- the same shape as the production checkup that
# printed nothing at all.
cat > "$TMP/domum-media.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
DOMUM_LOG_DIR=$TMP/log
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS=cloud
ENABLE_UPTIME_KUMA=1
CFG

# Drive a real function with the declaration functions replaced. Everything
# else -- the dispatch, the gate, the verifier selection -- is the shipped code.
drive() {  # $1 = stubs, $2 = call
  (
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export CALLS="$TMP/calls.log"
    : > "$CALLS"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    need_root() { :; }
    load_cfg()  { :; }
    warn() { echo "WARN: $*"; }
    die()  { echo "DIE: $*"; exit 1; }
    # Record which machinery was chosen, without running any of it.
    storage_pre_upgrade_point()        { echo "CHOSE protected-tier $*" >> "$CALLS"; return 0; }
    storage_volume_pre_upgrade_point() { echo "CHOSE docker-volume $*"  >> "$CALLS"; return 0; }
    rollback_upgrade()                 { echo "ROLLBACK protected-tier $*" >> "$CALLS"; return 0; }
    rollback_volume_upgrade()          { echo "ROLLBACK docker-volume $*"  >> "$CALLS"; return 0; }
    storage_verify_archive()           { echo "VERIFY archive $*" >> "$CALLS"; return "${ARCHIVE_RC:-0}"; }
    storage_verify_volume_dumps()      { echo "VERIFY dumps $*"   >> "$CALLS"; return "${DUMPS_RC:-0}"; }
    eval "$1"
    set +e
    eval "$2"
    echo "RC=$?"
    echo "--- calls ---"
    cat "$CALLS"
  ) 2>&1
}

MODEL_TIER='service_state_model() { printf "protected-tier ok\n"; }'
MODEL_VOL='service_state_model()  { printf "docker-volume domum-media_uptime-kuma-data\n"; }'
MODEL_UNK='service_state_model()  { printf "unknown missing-state-path\n"; }'
MODEL_NONE='service_state_model() { printf "stateless no rw mounts\n"; }'

# ---------------------------------------------------------------------------
sect "a protected-tier service still takes the SNAPSHOT path"
out="$(drive "$MODEL_TIER" 'create_upgrade_rollback_point plex')"
grep -q 'CHOSE protected-tier plex --archive-image' <<< "$out" \
  || fail "the protected-tier path regressed: $out"
grep -q 'CHOSE docker-volume' <<< "$out" && fail "it also took the volume path: $out"
echo "  snapshot path, with --archive-image"

sect "a docker-volume service takes the VOLUME path -- the call site that did not exist"
out="$(drive "$MODEL_VOL" 'create_upgrade_rollback_point uptime-kuma')"
grep -q 'CHOSE docker-volume uptime-kuma --archive-image' <<< "$out" \
  || fail "a docker-volume service did not reach the volume primitive: $out"
grep -q 'CHOSE protected-tier' <<< "$out" && fail "it took the snapshot path too: $out"
echo "  volume path, with --archive-image"

sect "an UNKNOWN model is refused, not guessed"
# service_state_model fails closed: an undeclared service, an undeclared rw
# volume, or a protected-tier service whose path is absent all read as unknown.
# Guessing either way would build a point that cannot restore the state.
for m in "$MODEL_UNK" "$MODEL_NONE"; do
  out="$(drive "$m" 'create_upgrade_rollback_point whatever')"
  grep -q '^RC=0$' <<< "$out" && fail "an unusable model was accepted: $out"
  grep -qE 'CHOSE' <<< "$out" && fail "it chose machinery for an unusable model: $out"
  grep -qi 'protected-tier' <<< "$out" || fail "the refusal does not say what IS supported: $out"
  grep -qi 'service_state_models' <<< "$out" || fail "the refusal does not say where to fix it: $out"
done
echo "  refused, naming both supported models and where the declaration lives"

# ---------------------------------------------------------------------------
sect "a volume point is verified by BOTH the archive and the dumps"
# Using storage_verify_archive alone would report a volume point as verified
# having checked nothing it actually contains -- the dumps ARE the state.
out="$(drive "$MODEL_VOL" 'verify_upgrade_rollback_point point-1 docker-volume')"
grep -q 'VERIFY archive point-1' <<< "$out" || fail "the archive was not verified: $out"
grep -q 'VERIFY dumps point-1'   <<< "$out" || fail "the volume dumps were not verified: $out"
grep -q '^RC=0$' <<< "$out" || fail "both verifiers passed but the result was not 0: $out"
echo "  archive and dumps, both"

sect "a protected-tier point is NOT handed to the volume verifier"
out="$(drive "$MODEL_TIER" 'verify_upgrade_rollback_point point-2 protected-tier')"
grep -q 'VERIFY archive point-2' <<< "$out" || fail "the archive was not verified: $out"
grep -q 'VERIFY dumps' <<< "$out" \
  && fail "a snapshot point was checked for volume dumps it cannot have: $out"
echo "  archive only"

sect "either verifier failing fails the whole point"
# A point that half-verifies must never read as verified: the upgrade is gated
# on this, and a passing verdict here is what lets `up -d` run.
out="$(DUMPS_RC=1 drive "$MODEL_VOL" 'ARCHIVE_RC=0 DUMPS_RC=1 verify_upgrade_rollback_point p docker-volume')"
grep -q '^RC=0$' <<< "$out" && fail "a failed dump verification still passed: $out"
out="$(drive "$MODEL_VOL" 'ARCHIVE_RC=1 verify_upgrade_rollback_point p docker-volume')"
grep -q '^RC=0$' <<< "$out" && fail "a failed archive verification still passed: $out"
grep -q 'VERIFY dumps' <<< "$out" \
  && fail "it went on to the dumps after the archive failed; the point is already unusable: $out"
echo "  either failure fails it, and the archive short-circuits"

# ---------------------------------------------------------------------------
sect "rollback is dispatched on the model too"
out="$(drive "$MODEL_VOL" 'rollback_dispatch uptime-kuma point-9')"
grep -q 'ROLLBACK docker-volume uptime-kuma point-9' <<< "$out" \
  || fail "a volume rollback did not reach rollback_volume_upgrade: $out"
grep -q 'ROLLBACK protected-tier' <<< "$out" && fail "it also ran the snapshot rollback: $out"
out="$(drive "$MODEL_TIER" 'rollback_dispatch plex point-8')"
grep -q 'ROLLBACK protected-tier plex point-8' <<< "$out" \
  || fail "a snapshot rollback regressed: $out"
echo "  each model reaches its own rollback"

sect "a rollback with an unusable model is REFUSED, not attempted"
# Restoring a subvolume snapshot over a Docker volume, or vice versa, would
# report success having restored nothing -- the worst possible outcome for a
# rollback, because the operator stops looking.
out="$(drive "$MODEL_UNK" 'rollback_dispatch mystery point-7')"
grep -q '^RC=0$' <<< "$out" && fail "an unusable model was rolled back anyway: $out"
grep -q 'ROLLBACK' <<< "$out" && fail "it ran rollback machinery for an unknown model: $out"
grep -qi 'restored nothing' <<< "$out" || fail "the refusal does not say what the risk is: $out"
echo "  refused, and it says why guessing is worse than stopping"

sect "rollback with no service named is refused before anything is read"
out="$(drive "$MODEL_VOL" 'rollback_dispatch "" ""')"
grep -q '^RC=0$' <<< "$out" && fail "an empty service name was accepted: $out"
grep -qi 'usage' <<< "$out" || fail "no usage shown: $out"
echo "  usage, not a crash"

# ---------------------------------------------------------------------------
sect "the production gate is CLOSED by default and refuses BEFORE the lock"
# The whole point of the gate: the path is implemented and tested, and has never
# run against a real service. The refusal must happen before the lock is taken
# and before any container is stopped, or a closed gate still causes downtime.
gate_out="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CALLS="$TMP/g.log"
  : > "$CALLS"
  export CFG_FILE="$TMP/domum-media.conf"
  # shellcheck disable=SC1090
  source "$CLI" >/dev/null 2>&1
  need_root() { :; }
  export_env_for_compose() { :; }
  die() { echo "DIE: $*"; exit 1; }
  service_state_model() { printf 'docker-volume domum-media_uptime-kuma-data\n'; }
  is_managed_service() { return 0; }
  service_compose_services() { printf 'uptime-kuma\n'; }
  service_running_images() { printf 'uptime-kuma sha256:aaa\n'; }
  staged_image_for() { printf 'sha256:bbb\n'; }
  domum_acquire_lock() { echo "LOCK TAKEN" >> "$CALLS"; return 0; }
  compose_cmd() { echo "COMPOSE $*" >> "$CALLS"; return 0; }
  verify_backup_freshness() { echo "BACKUP CHECK" >> "$CALLS"; return 0; }
  set +e
  service_upgrade uptime-kuma 2>&1
  echo "RC=$?"
  echo "--- calls ---"; cat "$CALLS"
)"
grep -q '^RC=0$' <<< "$gate_out" && fail "the gate let a volume upgrade through by default: $gate_out"
grep -qi 'VOLUME_UPGRADE_ENABLED' <<< "$gate_out" || fail "the refusal does not name the flag: $gate_out"
grep -q 'LOCK TAKEN' <<< "$gate_out" && fail "it took the lock before refusing: $gate_out"
grep -q 'COMPOSE' <<< "$gate_out" && fail "it touched compose before refusing: $gate_out"
grep -qi 'original image' <<< "$gate_out" || fail "it does not state that nothing was deployed: $gate_out"
echo "  refused by default, before the lock and before compose"

sect "mutation: defaulting the gate OPEN lets a volume upgrade proceed unreviewed"
MUT="$TMP/mut-gate"
cp "$CLI" "$MUT"
python3 - "$CLI" "$MUT" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
old = '"${VOLUME_UPGRADE_ENABLED:-0}" != "1"'
assert s.count(old) == 1, "gate target not unique: %d" % s.count(old)
# Mutate the COMPARISON into one that cannot hold. `&& false` inside [[ ]] would
# be a non-empty STRING, not the command, and would change nothing.
s = s.replace(old, '"${VOLUME_UPGRADE_ENABLED:-0}" != "${VOLUME_UPGRADE_ENABLED:-0}"', 1)
io.open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
grep -q 'VOLUME_UPGRADE_ENABLED:-0}" != "${VOLUME_UPGRADE_ENABLED' "$MUT" \
  || fail "the gate mutation was not applied; it proves nothing"
mout="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CALLS="$TMP/m.log"
  : > "$CALLS"
  # shellcheck disable=SC1090
  export CFG_FILE="$TMP/domum-media.conf"
  # shellcheck disable=SC1090
  source "$MUT" >/dev/null 2>&1
  need_root() { :; }
  export_env_for_compose() { :; }
  die() { echo "DIE: $*"; exit 1; }
  service_state_model() { printf 'docker-volume x\n'; }
  is_managed_service() { return 0; }
  service_compose_services() { printf 'uptime-kuma\n'; }
  service_running_images() { printf 'uptime-kuma sha256:aaa\n'; }
  staged_image_for() { printf 'sha256:bbb\n'; }
  domum_acquire_lock() { echo "LOCK TAKEN" >> "$CALLS"; return 0; }
  verify_backup_freshness() { return 0; }
  create_upgrade_rollback_point() { echo "POINT BUILT" >> "$CALLS"; return 1; }
  set +e
  service_upgrade uptime-kuma 2>&1
)"
# Name the observable the mutation ACTUALLY changes. "It reaches the lock" is
# not that: with the gate neutralised the function runs on into
# other_container_identities and the staged-image resolution, which this fixture
# does not stub, so it dies there for an unrelated reason and the lock assertion
# fails against a mutant that genuinely got past the gate. What the mutation
# changes is whether the REFUSAL happens at all.
grep -qi 'VOLUME_UPGRADE_ENABLED is not 1' <<< "$mout" \
  && fail "the mutant still refused, so the comparison is not what gates it: $mout"
grep -qi 'VOLUME_UPGRADE_ENABLED is not 1' <<< "$gate_out" \
  || fail "the UNMUTATED run did not refuse, so this comparison proves nothing: $gate_out"
echo "  killed: the unmutated run refuses and the mutant does not"

echo "PASS: volume upgrade dispatch smoke test"
