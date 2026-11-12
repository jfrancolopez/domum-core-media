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
# Every mutation below operates on a COPY of the CLI, never on the tracked
# file. A suite that mutates a tracked file is a suite that can be stopped
# mid-run and leave the file mutated -- which happened twice, and the second
# time the mutant hid inside a legitimately modified file, where git status
# could not tell it from the intended change. F6 compares the tracked file
# against this pristine copy to prove no section touched it.
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"
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
# ---------------------------------------------------------------------------
#  Phase 4 was NOT model-aware, so a successful volume upgrade reported failure.
#
#  Two of its assertions were unconditional:
#
#      domum_is_subvolume "$(service_data_path "$service")"   || rc=1
#      btrfs property get -ts "$SNAPSHOT_ROOT/$point"         || rc=1
#
#  For traefik and uptime-kuma both are false BY CONSTRUCTION -- there is no
#  /srv/data/<service>, and a volume pre-upgrade point is a dump set rather
#  than a read-only Btrfs snapshot. So the verification set rc=1 twice on a
#  completely successful upgrade. Phases 1-3 were made model-aware when the
#  dispatch was added and phase 4 was left behind: the same defect as
#  assert_pre_upgrade_possible dying on docker-volume, which this project has
#  already fixed once in this very function.
#
#  Driven in its own subshell with the REAL load_cfg, as the gate section is:
#  the `drive` helper stubs load_cfg, which leaves DOMUM_LOG_DIR unbound and
#  `set -u` kills the shell -- this suite already carries a comment about that
#  and I walked into it anyway.
# ---------------------------------------------------------------------------
phase4() {  # $1 = service, $2 = model, $3 = extra stubs
  (
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state"
    export CFG_FILE="$TMP/domum-media.conf" VOLUME_UPGRADE_ENABLED=1
    # 0 means "look once, do not sleep". uptime-kuma DECLARES a readiness
    # pattern, so without this every section reaching phase 4 pays the full
    # 60-second default. Three drivers in this file lacked it, the suite took
    # 222s, that exceeded a command timeout, the run was interrupted -- and an
    # interrupted run is what once left a neutralised guard in the working
    # tree. No assertion reads the wait value, so 0 costs nothing.
    export UPGRADE_READY_LOG_WAIT=0
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    need_root() { :; }
    export_env_for_compose() { :; }
    warn() { echo "WARN: $*"; }
    # Everything heavy succeeds, so the ONLY thing that can fail the
    # verification is an assertion that does not apply to this model.
    service_state_model() { printf '%s vol\n' "$2"; }
    is_managed_service() { return 0; }
    managed_image_specs() { printf '%s|img\n' "$1"; }
    service_compose_services() { printf '%s' "$1"; }
    domum_acquire_lock() { return 0; }
    verify_backup_freshness() { :; }
    assert_pre_upgrade_possible() { :; }
    service_running_images() { printf '%s sha256:new\n' "$1"; }
    other_container_identities() { printf 'traefik id1 img1\n'; }
    service_staged_image_changes() { printf 'STAGED %s old sha256:new\n' "$1"; }
    create_upgrade_rollback_point() {
      PRE_UPGRADE_POINT=pt; PRE_UPGRADE_META=mt; PRE_UPGRADE_ARCHIVE=ar; return 0; }
    verify_upgrade_rollback_point() { return 0; }
    compose_cmd() { return 0; }
    wait_for_service_health() { return 0; }
    service_health_state() { printf 'healthy'; }
    service_ready_probe() { return 1; }
    cleanup_images_execute() { return 0; }
    collect_cleanup_image_ids() { printf 'sha256:unrelated\n'; }
    record_upgrade_history() { :; }
    # Tripwires. These two must be UNREACHABLE for a docker-volume service.
    domum_is_subvolume() { echo "SUBVOL-ASKED" >&2; return 1; }
    btrfs() { echo "BTRFS-ASKED" >&2; return 1; }
    eval "$3"
    set +e
    model_override="$2"
    service_state_model() { printf '%s vol\n' "$model_override"; }
    service_upgrade "$1" 2>&1
    echo "RC=$?"
  ) 2>&1
}

sect "phase 4 asks a docker-volume service nothing it cannot answer"
out="$(phase4 uptime-kuma docker-volume '')"
grep -q 'SUBVOL-ASKED' <<< "$out" \
  && fail "phase 4 still asserts subvolume-ness for a docker-volume service: $out"
grep -q 'BTRFS-ASKED' <<< "$out" \
  && fail "phase 4 still asks btrfs about a volume pre-upgrade point: $out"
grep -qi 'docker-volume -- the dumps are checked' <<< "$out" \
  || fail "phase 4 says nothing about how the volume point WAS verified: $out"
grep -qi 'Upgrade INCOMPLETE' <<< "$out" \
  && fail "a successful volume upgrade still reports INCOMPLETE -- the defect: $out"
echo "  no subvolume or btrfs assertion, and the run is not INCOMPLETE"

sect "a protected-tier service still gets BOTH storage assertions"
# The guard must not become a blanket skip: for the snapshot tier those two
# assertions are what prove the recovery point survived the upgrade.
out="$(phase4 plex protected-tier '')"
grep -q 'SUBVOL-ASKED' <<< "$out" \
  || fail "the protected tier lost its subvolume assertion -- the guard became a
blanket skip, so nothing would prove the recovery point survived: $out"
echo "  protected-tier still asserted"

sect "readiness is UNPROVEN for a service that can answer NOTHING"
# The UNPROVEN sentence is BUILT from what is actually absent, and the branch
# where NOTHING is declared had never been driven. Every existing assertion on it
# uses a service that DECLARES a log pattern and stayed silent
# (service-upgrade-integration-smoke, section N+3), so the all-absent wording --
# the one the message was written for -- was unasserted.
#
# traefik is exactly that service, and it is a docker-volume one: measured, it has
# no container healthcheck, logs no definitive readiness line, and
# service_ready_log_pattern deliberately leaves it undeclared, because declaring
# one of the `Starting provider` lines would assert readiness from evidence that
# only shows a provider beginning to start.
READY_STUBS='
  service_health_state() { printf none; }
  service_ready_probe() { return 1; }
  service_ready_log_pattern() { return 1; }
'
out="$(phase4 traefik docker-volume "$READY_STUBS")"
grep -q 'readiness       : UNPROVEN' <<< "$out" \
  || fail "a service with no healthcheck, no probe and no declared pattern was not reported UNPROVEN -- a started container read as a working one: $out"
grep -q 'no container healthcheck, no readiness probe and no declared log pattern' <<< "$out" \
  || fail "the UNPROVEN message does not name what is actually absent: $out"
# The two wordings that would be FALSE here. Each belongs to a different absent
# thing, so printing either describes a service this is not.
grep -q 'a readiness probe that did not answer' <<< "$out" \
  && fail "it claims a probe did not answer, for a service that declares none: $out"
grep -q 'a declared log pattern that did not appear' <<< "$out" \
  && fail "it claims a declared pattern was silent, for a service that declares none: $out"
grep -q 'RUNNING is the whole claim' <<< "$out" \
  || fail "UNPROVEN does not say RUNNING is the whole claim: $out"
grep -qi 'Upgrade INCOMPLETE' <<< "$out" \
  && fail "unproven readiness must be REPORTED, never a failure: $out"
echo "  UNPROVEN names all three absences, claims neither false one, and does not fail"

sect "MUTATION: a fixed 'pattern did not appear' must become false here"
# The recorded defect is that a FIXED sentence is false for one of the two cases.
# This mutation makes the silent-pattern wording unconditional: correct for a
# service that declares a pattern, wrong for traefik.
MUT="$TMP/cli-readiness-mutant"
cp "$CLI" "$MUT"
cat > "$TMP/mut-readiness.py" <<'PYMUT'
import io, sys

p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '    case "$ready_log_state" in\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
i = s.index(old)
j = s.index("    esac\n", i) + len("    esac\n")
new = '    ready_missing="$ready_missing, and a declared log pattern that did not appear"\n'
io.open(p, "w", encoding="utf-8").write(s[:i] + new + s[j:])
PYMUT
python3 -I "$TMP/mut-readiness.py" "$MUT" || fail "the readiness mutation did not apply"
grep -q 'ready_log_state" in' "$MUT" \
  && fail "the mutation did not remove the case -- it changed nothing"
mout="$(CLI="$MUT" phase4 traefik docker-volume "$READY_STUBS")"
grep -q 'a declared log pattern that did not appear' <<< "$mout" \
  || fail "the mutant did not produce the false wording -- the mutation changed no ANSWER: $mout"
echo "  the mutant describes a declared pattern traefik does not have"

sect "MUTATION: removing the model guard breaks the volume upgrade again"
MUTP4="$TMP/cli-p4-mutant"
cp "$CLI" "$MUTP4"
cat > "$TMP/mutate-p4.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  if [[ "$model" == "protected-tier" ]]; then\n    domum_is_subvolume'
new = '  if [[ "$model" == "$model" ]]; then\n    domum_is_subvolume'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
python3 -I "$TMP/mutate-p4.py" "$MUTP4" \
  || fail "the phase-4 mutation did not apply"
mout="$(CLI="$MUTP4" phase4 uptime-kuma docker-volume '')"
grep -q 'SUBVOL-ASKED' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the guard a volume service
must be asked whether its absent data path is a subvolume: $mout"
echo "  killed: an always-true guard asks a volume service about subvolumes again"

sect "the production gate is CLOSED by default and refuses BEFORE the lock"
# The whole point of the gate: the path is implemented and tested, and has never
# run against a real service. The refusal must happen before the lock is taken
# and before any container is stopped, or a closed gate still causes downtime.
gate_out="$(
  export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CALLS="$TMP/g.log"
  : > "$CALLS"
  export CFG_FILE="$TMP/domum-media.conf" UPGRADE_READY_LOG_WAIT=0
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
  export CFG_FILE="$TMP/domum-media.conf" UPGRADE_READY_LOG_WAIT=0
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

# ===========================================================================
#  FAILURE INJECTION on the volume upgrade's three pre-deploy gates.
#
#  service_upgrade must not reach `compose up -d` unless the pre-upgrade point
#  was created, is complete, and verified. Those are three separate `die`s, and
#  the dispatch sections above test the VERIFIERS in isolation -- none of them
#  drove service_upgrade with a gate failing and asked whether the deploy
#  happened anyway. That is the question that matters: a volume service whose
#  recovery point failed and which got upgraded regardless has had its state
#  put under a new application with nothing to roll back to.
#
#  The POSITIVE control is section F4 and it is what makes F1-F3 mean anything:
#  "no up -d" passes trivially against a function that never deploys at all.
# ===========================================================================

# $1 = extra stubs appended last, so a section can override anything above it.
vol_upgrade() {
  (
    export DOMUM_DATA_ROOT="$TMP/data" DOMUM_STATE_ROOT="$TMP/state" CALLS="$TMP/f.log"
    export CFG_FILE="$TMP/domum-media.conf"
    export VOLUME_UPGRADE_ENABLED=1
    # 0 means "look once, do not sleep". The default is 60s in 5s steps, and
    # without this every section that reaches phase 4 costs a real minute --
    # which is exactly what it cost before this line was added. CLAUDE.md says
    # the fixture sets it to 0; this one did not.
    export UPGRADE_READY_LOG_WAIT=0
    : > "$CALLS"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    need_root() { :; }
    export_env_for_compose() { :; }
    die() { echo "DIE: $*"; exit 1; }
    warn() { echo "WARN: $*"; }
    service_state_model() { printf 'docker-volume domum-media_uptime-kuma-data\n'; }
    is_managed_service() { return 0; }
    service_compose_services() { printf 'uptime-kuma\n'; }
    service_running_images() { printf 'uptime-kuma sha256:aaa\n'; }
    # service_upgrade reads the staged image from service_staged_image_changes
    # and takes field 4 of the first `STAGED ` line. Stubbing staged_image_for
    # instead did nothing -- the function is not on this path -- so every
    # section below fell into the graceful "nothing to upgrade" branch and F1
    # failed with a message that named the real cause. A stub of a function
    # nobody calls is not a stub.
    service_staged_image_changes() { printf 'STAGED uptime-kuma sha256:aaa sha256:bbb\n'; }
    other_container_identities() { printf '' ; }
    domum_acquire_lock() { echo "LOCK" >> "$CALLS"; return 0; }
    verify_backup_freshness() { return 0; }
    service_is_healthy() { return 0; }
    service_ready_probe() { return 1; }
    service_logged_ready_since() { return 1; }
    compose_cmd() { echo "COMPOSE $*" >> "$CALLS"; return 0; }
    # All three gates PASS by default; each section below breaks exactly one.
    #
    # The completeness check reads three GLOBALS that the real
    # create_upgrade_rollback_point sets -- PRE_UPGRADE_POINT, _META and
    # _ARCHIVE -- so the stub must set them. Without that, `set -u` killed the
    # function at the completeness line and F2 "passed" on an unbound-variable
    # abort rather than on the check it names. STUB_* use `-` and not `:-`, so
    # a section can set one to EMPTY and break completeness the way production
    # can.
    create_upgrade_rollback_point() {
      echo "POINT" >> "$CALLS"
      PRE_UPGRADE_POINT="${STUB_POINT-pt}"
      PRE_UPGRADE_META="${STUB_META-pt.recovery}"
      PRE_UPGRADE_ARCHIVE="${STUB_ARCHIVE-pt.tar}"
      printf '%s\n' "$PRE_UPGRADE_POINT"
      return 0
    }
    verify_upgrade_rollback_point() { echo "VERIFY" >> "$CALLS"; return 0; }
    eval "${1:-}"
    set +e
    service_upgrade uptime-kuma 2>&1
    echo "RC=$?"
    echo "--- calls ---"; cat "$CALLS"
  ) 2>&1
}

sect "F1. the pre-upgrade point FAILS -- no up -d, and it says so"
out="$(vol_upgrade 'create_upgrade_rollback_point() { echo "POINT-TRIED" >> "$CALLS"; return 1; }')"
grep -q '^RC=0$' <<< "$out" && fail "F1: a failed pre-upgrade point still returned success: $out"
grep -q 'COMPOSE up -d' <<< "$out" \
  && fail "F1: it DEPLOYED after the pre-upgrade point failed -- the state is now
under a new application with nothing to roll back to: $out"
grep -qi 'NOT deployed' <<< "$out" \
  || fail "F1: the refusal does not state that the staged image was not deployed: $out"
echo "  refused, nothing deployed, and the message says which"

sect "F2. the point is created but INCOMPLETE -- no up -d"
# A point without its metadata and archive is half a recovery point: the data
# could be restored and the application that wrote it could not be identified.
# Broken the way production can break: the point is created and one of its
# three artefacts is missing. The first version of this section stubbed an
# INVENTED `upgrade_rollback_point_complete`, which does not exist -- so the
# stub did nothing and the section passed on an unbound-variable abort instead
# of on the completeness check. Stubbing a function nobody defines is not a
# stub, and here it hid a vacuous pass.
out="$(STUB_ARCHIVE='' vol_upgrade '')"
grep -q '^RC=0$' <<< "$out" && fail "F2: an incomplete point still returned success: $out"
grep -q 'COMPOSE up -d' <<< "$out" \
  && fail "F2: it deployed on an incomplete recovery point: $out"
echo "  refused, nothing deployed"

sect "F3. VERIFICATION of the point fails -- no up -d"
out="$(vol_upgrade 'verify_upgrade_rollback_point() { echo "VERIFY-TRIED" >> "$CALLS"; return 1; }')"
grep -q '^RC=0$' <<< "$out" && fail "F3: a point that did not verify still returned success: $out"
grep -q 'COMPOSE up -d' <<< "$out" \
  && fail "F3: it deployed on a point that did not verify: $out"
grep -qi 'did not verify\|NOT deployed' <<< "$out" \
  || fail "F3: the refusal does not name the cause: $out"
echo "  refused, nothing deployed"

sect "F4. POSITIVE CONTROL: with all three gates passing, up -d IS reached"
# Without this, F1-F3 would pass against a service_upgrade that never deploys
# under any circumstances, and the three sections above would be measuring
# nothing.
out="$(vol_upgrade '')"
grep -q 'COMPOSE up -d' <<< "$out" \
  || fail "F4: the deploy is never reached even when every gate passes, so F1-F3
prove nothing: $out"
# And the order is the safety property, not an incidental: the point and its
# verification must both precede the deploy.
calls="$(sed -n '/--- calls ---/,$p' <<< "$out")"
p_line="$(grep -n '^POINT$'  <<< "$calls" | head -1 | cut -d: -f1)"
v_line="$(grep -n '^VERIFY$' <<< "$calls" | head -1 | cut -d: -f1)"
d_line="$(grep -n '^COMPOSE up -d' <<< "$calls" | head -1 | cut -d: -f1)"
[[ -n "$p_line" && -n "$v_line" && -n "$d_line" ]] \
  || fail "F4: expected POINT, VERIFY and the deploy to all be recorded: $calls"
(( p_line < d_line )) || fail "F4: the deploy happened before the point was created"
(( v_line < d_line )) || fail "F4: the deploy happened before the point was verified"
echo "  deploy reached, and it follows both the point and its verification"

sect "F5. the two gates are DEFENCE IN DEPTH, not one check written twice"
# Worth asserting because it is what the first version of this section got
# wrong. Tolerating gate 1 (the point-creation failure) is NOT sufficient to
# deploy: gate 2 reads PRE_UPGRADE_POINT/_META/_ARCHIVE, and a creation that
# failed before setting them is caught there. Mutating gate 1 away therefore
# still refuses -- for a different reason -- which is a property of the code,
# not a defect in the test.
MUTG1="$TMP/cli-g1-mutant"
cp "$CLI" "$MUTG1"
cat > "$TMP/mutate-g1.py" <<'PYG1'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Tolerate gate 1: keep the CALL (so the globals are set exactly as production
# would set them) and turn its fatal refusal into a warning. `if false` would
# skip the call entirely and prove nothing -- that is what the first version
# did, and gate 2 then stopped the mutant on unset globals.
old = '    die "Pre-upgrade protection failed. The staged image was NOT deployed and'
new = '    warn "TOLERATED gate 1"; : "Pre-upgrade protection failed and'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYG1
python3 -I "$TMP/mutate-g1.py" "$MUTG1" \
  || fail "F5: the gate-1 mutation did not apply"
# The stub FAILS but still leaves the three artefacts, which a creation that
# failed late would do. Gate 2 therefore passes and gate 1 is the only thing
# between this and a deploy.
mout="$(CLI="$MUTG1" vol_upgrade 'create_upgrade_rollback_point() {
  echo "POINT" >> "$CALLS"
  PRE_UPGRADE_POINT=pt; PRE_UPGRADE_META=pt.recovery; PRE_UPGRADE_ARCHIVE=pt.tar
  printf "pt\\n"; return 1
}')"
grep -q 'COMPOSE up -d' <<< "$mout" \
  || fail "F5: the mutation changed no ANSWER -- with gate 1 tolerated and the
artefacts present, the deploy must happen: $mout"
echo "  killed: gate 1 tolerated with artefacts present -> it deploys"

sect "F5b. and with the artefacts ABSENT, gate 2 catches it anyway"
# The other half of defence in depth, and the reason F5 had to be made
# faithful: tolerate gate 1 AND leave the artefacts unset, and the refusal
# still happens -- at gate 2.
# Already mutated above and deliberately not re-applied: it is a COPY, so it
# stays mutated, and re-running the edit would fail its own single-match
# assertion.
mout="$(CLI="$MUTG1" vol_upgrade 'create_upgrade_rollback_point() {
  echo "POINT" >> "$CALLS"; printf "pt\\n"; return 1
}')"
grep -q 'COMPOSE up -d' <<< "$mout" \
  && fail "F5b: with gate 1 tolerated AND no artefacts it still deployed -- gate 2
is not catching the case it exists for: $mout"
echo "  gate 2 refuses independently of gate 1"

sect "F6. the tracked CLI was never mutated at all"
# Stronger than restoring it: every mutation above ran against a copy, so an
# interrupted run cannot leave the tracked file changed. This compares it
# against the pristine copy taken before the first section.
cmp -s "$CLI" "$PRISTINE" \
  || { f6diff="$(diff "$PRISTINE" "$CLI" || true)"
       fail "F6: the tracked CLI differs from the pristine copy -- a section
mutated it in place, so stopping this suite part-way would leave a neutralised
guard in the working tree:
$(sed -n '1,10p' <<< "$f6diff")"; }
grep -q 'if ! create_upgrade_rollback_point "\$service"; then' "$CLI" \
  || fail "F6: the point-creation gate is missing from the CLI"
echo "  the tracked CLI is byte-identical to the pristine copy"
