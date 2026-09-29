#!/usr/bin/env bash
set -uo pipefail

# A storage migration must not change which application is running, and must
# record which one wrote the state it snapshotted.
#
# The Kavita migration recreated its container on a newer staged image, and
# Kavita forward-migrated its database on startup. The proof snapshot holds a
# 0.9.0.2 database; the service now runs 0.9.1.0. Nothing was lost, but the
# recovery point stopped being a rollback point.
#
# Two invariants come out of that:
#
#   1. RUNTIME STATE IS PRESERVED. Running before -> running after. Stopped
#      before -> stopped after. Absent before -> absent after. A migration is not
#      an occasion to start something the operator stopped, and "stopped" must not
#      become a loophole where the image is resolved with no identity captured.
#
#   2. THE IMAGE IS PRESERVED, structurally. `compose start` restarts the same
#      container object, so no image resolution happens and the mutable-tag race
#      has nowhere to occur. `up -d` reconciles and is the defect.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# $1 = scenario, $2 = stubs
run_migration() {
  local dir="$TMP_DIR/$1" stubs="${2:-}"
  rm -rf "$dir"; mkdir -p "$dir/data/kavita/config" "$dir/snapshots" "$dir/state"
  printf 'the-original\n' > "$dir/data/kavita/config/app.conf"

  cat > "$dir/harness.sh" <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$dir/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$dir/data"
DOMUM_MEDIA_ROOT="$dir/media"
DOMUM_SNAPSHOT_ROOT="$dir/snapshots"
DOMUM_STATE_ROOT="$dir/state"
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
service_data_path() { printf '%s' "$dir/data"/"\$1"; }
service_compose_services() { printf 'kavita'; }
migrate_assert_same_btrfs() { :; }
wait_for_service_health() { return 0; }
SUBVOL_REG="$dir/.subvols"
path_is_subvolume() { grep -qxF "\$1" "\$SUBVOL_REG" 2>/dev/null; }
btrfs() {
  case "\$1" in
    subvolume) mkdir -p "\${!#}" && printf '%s\\n' "\${!#}" >> "\$SUBVOL_REG" ;;
    property)  printf 'ro=true\\n' ;;
  esac
}
mv() {
  local src="\${@: -2:1}" dst="\${@: -1}"
  command mv "\$@" || return 1
  grep -qxF "\$src" "\$SUBVOL_REG" 2>/dev/null && printf '%s\\n' "\$dst" >> "\$SUBVOL_REG"
  true
}
cp() { command cp -a "\${@: -2:1}" "\${@: -1}"; }
create_service_snapshot() {
  local name="kavita-20260101-000000-post-migration"
  command cp -a "$dir/data/kavita" "$dir/snapshots/\$name" 2>/dev/null || return 1
  printf '%s\\n' "$dir/snapshots/\$name" >> "\$SUBVOL_REG"
  printf '%s' "\$name"
}
# Records every compose verb, so the test can assert start-vs-up rather than
# inferring it from side effects.
COMPOSE_LOG="$dir/compose.log"
: > "\$COMPOSE_LOG"
compose_cmd() { printf '%s\\n' "\$*" >> "\$COMPOSE_LOG"; return 0; }
$stubs
storage_migrate_subvolume kavita
EOF
  bash "$dir/harness.sh" > "$dir/out.txt" 2>&1
  printf '%s' "$?" > "$dir/rc"
  printf '%s' "$dir"
}

# A docker/compose stub pair describing one container in a chosen state.
# $1 = docker state (running|exited), $2 = whether `ps -qa` yields an id
stub_state() {
  local state="$1" has_container="$2"
  cat <<EOF
tracked_service_container_id()     { $( [[ "$state" == running && "$has_container" == yes ]] && echo 'printf "cid-kavita"' || echo 'printf ""' ); }
tracked_service_container_id_any() { $( [[ "$has_container" == yes ]] && echo 'printf "cid-kavita"' || echo 'printf ""' ); }
docker() {
  case "\$*" in
    *"{{.State.Status}}"*) printf '%s\n' "$state" ;;
    *"{{.Image}}"*)        printf 'sha256:pinned\n' ;;
    *"{{.Config.Image}}"*) printf 'example/kavita:latest\n' ;;
    *"{{.Id}}"*)           printf 'sha256:pinned\n' ;;
    *RepoDigests*)         printf 'example/kavita@sha256:pinned\n' ;;
    *config-hash*)         printf 'confighash123\n' ;;
    *"image.version"*)     printf '0.9.0.2\n' ;;
    *"image.revision"*)    printf 'abcdef123456\n' ;;
    *"{{.Created}}"*)      printf '2026-08-28T15:53:14Z\n' ;;
    *) : ;;
  esac
}
EOF
}

# ---------------------------------------------------------------------------
# 1. RUNNING -> stopped and started again, via `start`, NOT `up -d`.
# ---------------------------------------------------------------------------
d="$(run_migration running "$(stub_state running yes)")"
[ "$(cat "$d/rc")" = "0" ] || fail "1: the migration failed: $(cat "$d/out.txt")"
grep -q '^stop kavita$'  "$d/compose.log" || fail "1: the service was never stopped: $(cat "$d/compose.log")"
grep -q '^start kavita$' "$d/compose.log" || fail "1: the service was not restarted with 'start': $(cat "$d/compose.log")"
grep -q '^up -d'         "$d/compose.log" && fail "1: 'up -d' was used, which reconciles and can deploy a staged image: $(cat "$d/compose.log")"
grep -q 'runtime state before: running' "$d/out.txt" || fail "1: the runtime state was not captured: $(cat "$d/out.txt")"
grep -q 'runtime state preserved: running' "$d/out.txt" || fail "1: preservation was not confirmed: $(cat "$d/out.txt")"

# ---------------------------------------------------------------------------
# 2. STOPPED stays stopped. This is the loophole: a migration must not turn a
#    service the operator stopped into a running one, and must not resolve an
#    image tag to do it.
# ---------------------------------------------------------------------------
d="$(run_migration stopped "$(stub_state exited yes)")"
[ "$(cat "$d/rc")" = "0" ] || fail "2: a stopped service could not be migrated: $(cat "$d/out.txt")"
grep -q 'runtime state before: stopped' "$d/out.txt" || fail "2: not detected as stopped: $(cat "$d/out.txt")"
grep -q 'will be left stopped' "$d/out.txt" || fail "2: the decision was not stated: $(cat "$d/out.txt")"
grep -qE '^(start|up) ' "$d/compose.log" \
  && fail "2: a STOPPED service was started by the migration: $(cat "$d/compose.log")"
grep -q '^stop ' "$d/compose.log" \
  && fail "2: a stopped service was stopped again: $(cat "$d/compose.log")"
# ...and the data really did migrate.
grep -qxF "$d/data/kavita" "$d/.subvols" || fail "2: the data was not migrated"
[ -d "$d/data/kavita.premigration" ] || fail "2: the original was not preserved"

# ---------------------------------------------------------------------------
# 3. ABSENT stays absent, and its image identity is recorded as UNKNOWN rather
#    than guessed from a mutable tag.
# ---------------------------------------------------------------------------
d="$(run_migration absent "$(stub_state exited no)")"
[ "$(cat "$d/rc")" = "0" ] || fail "3: a service with no container could not be migrated: $(cat "$d/out.txt")"
grep -q 'runtime state before: absent' "$d/out.txt" || fail "3: not detected as absent: $(cat "$d/out.txt")"
grep -qE '^(start|up) ' "$d/compose.log" \
  && fail "3: a container was created for a service that had none: $(cat "$d/compose.log")"
meta="$(ls "$d"/state/snapshots/*.recovery 2>/dev/null | head -1)"
[ -n "$meta" ] || fail "3: no recovery evidence was written: $(ls -R "$d/state" 2>&1)"
grep -q "CONTAINER_1_IMAGE_IDENTITY='unknown'" "$meta" \
  || fail "3: an absent container was not recorded as unknown: $(cat "$meta")"

# ---------------------------------------------------------------------------
# 4. The recovery evidence answers "what wrote this?" -- and carries no secrets.
# ---------------------------------------------------------------------------
d="$(run_migration evidence "$(stub_state running yes)")"
meta="$(ls "$d"/state/snapshots/*.recovery 2>/dev/null | head -1)"
[ -n "$meta" ] || fail "4: no recovery evidence: $(ls -R "$d/state" 2>&1)"
for k in FORMAT SERVICE RECOVERY_POINT CAPTURED_AT DATA_PATH RUNTIME_STATE_BEFORE \
         CONTAINER_1_SERVICE CONTAINER_1_IMAGE_ID CONTAINER_1_IMAGE_REF \
         CONTAINER_1_IMAGE_REPO_DIGESTS CONTAINER_1_IMAGE_LABEL_VERSION \
         CONTAINER_1_COMPOSE_CONFIG_HASH; do
  grep -q "^$k=" "$meta" || fail "4: recovery evidence is missing $k: $(cat "$meta")"
done
grep -q "CONTAINER_1_IMAGE_IDENTITY='known'" "$meta" || fail "4: identity not marked known: $(cat "$meta")"
grep -q "CONTAINER_1_IMAGE_ID='sha256:pinned'" "$meta" || fail "4: the image id was not recorded: $(cat "$meta")"
grep -q "RUNTIME_STATE_BEFORE='running'" "$meta" || fail "4: runtime state not recorded: $(cat "$meta")"
# It must be sourceable, because that is the documented way to read it later.
( set -u; # shellcheck disable=SC1090
  . "$meta"; [ "$SERVICE" = kavita ] ) || fail "4: the evidence file cannot be sourced: $(cat "$meta")"
# Compose files identified by digest, never rendered -- rendering interpolates
# secrets, and this file is read months later by a human.
grep -q "^COMPOSE_FILE_1_SHA256=" "$meta" || fail "4: compose configuration is not identified: $(cat "$meta")"
# Over the VALUES only: the header comment explains that secrets are excluded,
# and a scan that reads its own explanation as a finding is not a scan.
meta_values="$(grep -v '^#' "$meta")"
grep -qiE "password|secret|token|api[_-]?key|PRIVATE KEY" <<< "$meta_values" \
  && { grep -niE "password|secret|token|api[_-]?key|PRIVATE KEY" <<< "$meta_values" >&2
       fail "4: the recovery evidence contains something secret-shaped"; }
# 0600: it names container and image ids, and lives under the state root.
[ "$(stat -c %a "$meta")" = "600" ] || fail "4: recovery evidence is mode $(stat -c %a "$meta"), expected 600"

# ---------------------------------------------------------------------------
# 5. If `start` fails the service must still come back -- and the fact that
#    recreation resolves the tag must be said out loud, not discovered later.
# ---------------------------------------------------------------------------
d="$(run_migration start_fails "$(stub_state running yes)
compose_cmd() {
  printf '%s\n' \"\$*\" >> \"\$COMPOSE_LOG\"
  [[ \"\${1:-}\" == start ]] && return 1
  return 0
}")"
grep -q '^start kavita$' "$d/compose.log" || fail "5: 'start' was not attempted first: $(cat "$d/compose.log")"
grep -q '^up -d kavita$' "$d/compose.log" || fail "5: the service was not brought back at all: $(cat "$d/compose.log")"
grep -q 'Recreation resolves the image tag' "$d/out.txt" \
  || fail "5: recreation happened silently: $(cat "$d/out.txt")"

# ---------------------------------------------------------------------------
# 6. service_runtime_state, directly -- including a multi-container service.
#    Immich has four containers; one still stopped means the service is not
#    simply "running", and one staged image among four must not be averaged away.
# ---------------------------------------------------------------------------
runtime_state() {  # $1 = compose services, $2 = per-service state assignments
  bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
need_root() { :; }
load_cfg() { :; }
compose_cmd() { :; }
service_compose_services() { printf '%s' '$1'; }
tracked_service_container_id_any() { eval \"printf '%s' \\\"\\\$CID_\${1//-/_}\\\"\"; }
docker() {
  local cid=\"\${4:-}\"
  case \"\$*\" in
    *'{{.State.Status}}'*) eval \"printf '%s' \\\"\\\$ST_\${cid#cid-}\\\"\" ;;
    *) : ;;
  esac
}
$2
service_runtime_state svc" 2>/dev/null
}

[[ "$(runtime_state a 'CID_a=cid-a; ST_a=running')" == running ]] || fail "6: one running container is not 'running'"
[[ "$(runtime_state a 'CID_a=cid-a; ST_a=exited')"  == stopped ]] || fail "6: one exited container is not 'stopped'"
[[ "$(runtime_state a 'CID_a=')"                    == absent  ]] || fail "6: no container is not 'absent'"
[[ "$(runtime_state 'a b c d' 'CID_a=cid-a; CID_b=cid-b; CID_c=cid-c; CID_d=cid-d
ST_a=running; ST_b=running; ST_c=running; ST_d=running')" == running ]] \
  || fail "6: four running containers is not 'running'"
[[ "$(runtime_state 'a b c d' 'CID_a=cid-a; CID_b=cid-b; CID_c=cid-c; CID_d=cid-d
ST_a=running; ST_b=exited; ST_c=running; ST_d=running')" == running ]] \
  || fail "6: a partly-up multi-container service must report running, so the set is restored"
[[ "$(runtime_state 'a b c d' 'CID_a=cid-a; CID_b=cid-b; CID_c=cid-c; CID_d=cid-d
ST_a=exited; ST_b=exited; ST_c=exited; ST_d=exited')" == stopped ]] \
  || fail "6: four stopped containers is not 'stopped'"
[[ "$(runtime_state 'a b c d' 'CID_a=; CID_b=; CID_c=; CID_d=')" == absent ]] \
  || fail "6: four absent containers is not 'absent'"

# ---------------------------------------------------------------------------
# 7. A staged image must be detected on a STOPPED container too. `compose ps -q`
#    lists running containers only, so the detector used to report a stopped
#    service as having nothing staged -- the same fail-open shape in a new place.
# ---------------------------------------------------------------------------
# Written to a FILE rather than nested inside `bash -c "..."`: the stub needs
# literal `$*` and `{{.Image}}`, and three levels of quoting turned them into
# something that matched no branch -- so the probe reported UNKNOWN and the test
# passed against a stub that was simply broken.
cat > "$TMP_DIR/stopped-staged.sh" <<PROBE
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
need_root() { :; }
load_cfg() { :; }
compose_cmd() { :; }
service_compose_services() { printf 'kavita'; }
tracked_service_container_id()     { printf ''; }           # not running
tracked_service_container_id_any() { printf 'cid-kavita'; } # but it exists
docker() {
  case "\$*" in
    *'{{.Image}}'*)        printf 'sha256:running\n' ;;
    *'{{.Config.Image}}'*) printf 'example/kavita:latest\n' ;;
    *'{{.Id}}'*)           printf 'sha256:staged\n' ;;
    *) : ;;
  esac
}
service_staged_image_changes kavita
PROBE
staged_on_stopped="$(bash "$TMP_DIR/stopped-staged.sh" 2>/dev/null)"
grep -q '^STAGED kavita ' <<< "$staged_on_stopped" \
  || fail "7: a staged image on a STOPPED container was missed: [$staged_on_stopped]"

# ---------------------------------------------------------------------------
# 8. The rollback path must preserve the image too. Restoring an older
#    application's data while upgrading the application is the pairing failure.
# ---------------------------------------------------------------------------
restore_block="$(awk '/^restore_snapshot_for_service\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media")"
grep -q 'compose_cmd start' <<< "$restore_block" \
  || fail "8: the rollback still brings the service back with 'up -d', which can deploy a staged image"
awk '/compose_cmd up -d/ {found=1} END {exit found ? 0 : 1}' <<< "$restore_block" \
  || fail "8: the rollback has no recreate fallback, so a removed container would leave it down"

echo "PASS: image identity preservation smoke test"
