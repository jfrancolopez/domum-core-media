#!/usr/bin/env bash
set -uo pipefail

# Enters through the REAL dispatcher -- `main updates apply --service plex` --
# against a production-shaped fixture, and lets service_upgrade actually run.
#
# WHY IT EXISTS. service_upgrade shipped to production calling
# `assert_pre_upgrade_possible`, a helper from a reverted refactor that was never
# defined. `bash -n` passed, shellcheck passed, 41 suites passed, CI was green.
# Every existing test asserted on the TEXT of the function; not one executed it,
# so an undefined call was indistinguishable from a defined one. The upgrade
# would have died under `set -e` after stopping the container.
#
# A text assertion cannot catch that class. Only running the code can. So this
# suite drives `main` with docker and btrfs replaced by stubs on PATH, and
# asserts on OBSERVED behaviour: what the stub was asked to do, in what order,
# and what state existed afterwards.
#
# The fixture is current production: plex on 58f13a1df833 with 7f9a1d574958
# staged, four protected subvolumes, eleven containers, and staged images for
# calibre-web/traefik/uptime-kuma that this operation must NOT deploy.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

PLEX_OLD=sha256:58f13a1df8330000000000000000000000000000000000000000000000000001
PLEX_NEW=sha256:7f9a1d5749580000000000000000000000000000000000000000000000000002
CW_OLD=sha256:6cf7dab48a4a0000000000000000000000000000000000000000000000000003
CW_NEW=sha256:6cf7dab48a4a0000000000000000000000000000000000000000000000000013
JF_IMG=sha256:1111111111110000000000000000000000000000000000000000000000000004

CONTAINERS="traefik tailscale uptime-kuma jellyfin plex navidrome calibre-web kavita immich_server immich_postgres immich_redis"

# --------------------------------------------------------------------------
# The fixture. $ENV/img-<svc> is the image a container currently runs; the
# stub rewrites it only on `compose up -d`, which is what reconciling means.
# --------------------------------------------------------------------------
setup() {  # $1.. = options: no-subvol, no-staged, archive-fails, snapshot-fails
  rm -rf "${TMP_DIR:?}/f"
  ENV_DIR="$TMP_DIR/f"
  mkdir -p "$ENV_DIR"/{data,snapshots,state,log,media,bin,st}
  mkdir -p "$ENV_DIR"/data/{plex,jellyfin,kavita,navidrome,calibre-web}
  local opts=" $* "

  # Four migrated subvolumes; calibre-web deliberately an ordinary directory.
  [[ "$opts" == *" no-subvol "* ]] || for s in plex jellyfin kavita navidrome; do
    touch "$ENV_DIR/data/$s/.is-subvol"
  done
  # Plausible application state so quiescence has something to look at.
  printf 'db\n' > "$ENV_DIR/data/plex/com.plexapp.plugins.library.db"

  printf '%s\n' "$PLEX_OLD" > "$ENV_DIR/st/img-plex"
  printf '%s\n' "$CW_OLD"   > "$ENV_DIR/st/img-calibre-web"
  printf '%s\n' "$JF_IMG"   > "$ENV_DIR/st/img-jellyfin"
  for c in $CONTAINERS; do
    [[ -f "$ENV_DIR/st/img-$c" ]] || printf 'sha256:%064d\n' "$((RANDOM % 9 + 1))" > "$ENV_DIR/st/img-$c"
  done
  # What each tag resolves to -- i.e. what is STAGED locally.
  if [[ "$opts" == *" no-staged "* ]]; then
    printf '%s\n' "$PLEX_OLD" > "$ENV_DIR/st/tag-plex"
  else
    printf '%s\n' "$PLEX_NEW" > "$ENV_DIR/st/tag-plex"
  fi
  printf '%s\n' "$CW_NEW" > "$ENV_DIR/st/tag-calibre-web"
  printf '%s\n' "$JF_IMG" > "$ENV_DIR/st/tag-jellyfin"

  [[ "$opts" == *" archive-fails "* ]] && touch "$ENV_DIR/st/archive-fails"
  [[ "$opts" == *" snapshot-fails "* ]] && touch "$ENV_DIR/st/snapshot-fails"

  cat > "$ENV_DIR/cfg" <<EOF
DOMUM_DATA_ROOT=$ENV_DIR/data
DOMUM_MEDIA_ROOT=$ENV_DIR/media
DOMUM_SNAPSHOT_ROOT=$ENV_DIR/snapshots
DOMUM_STATE_ROOT=$ENV_DIR/state
DOMUM_LOG_DIR=$ENV_DIR/log
ENABLE_TRAEFIK=1
ENABLE_TAILSCALE=1
ENABLE_UPTIME_KUMA=1
ENABLE_JELLYFIN=1
ENABLE_PLEX=1
ENABLE_NAVIDROME=1
ENABLE_CALIBRE_WEB=1
ENABLE_KAVITA=1
BACKUP_POLICY=PERMISSIVE
PLEX_IMAGE=plex:latest
CALIBRE_WEB_IMAGE=calibre-web:latest
JELLYFIN_IMAGE=jellyfin:latest
EOF
  : > "$ENV_DIR/calls.log"

  # ---- the docker stub ----------------------------------------------------
  # compose_cmd injects `-f <file>` arguments, so the subcommand is NOT at a
  # fixed position. Normalise first: drop `compose` and every `-f`/`--env-file`
  # pair, then dispatch on what is left.
  cat > "$ENV_DIR/bin/docker" <<STUB
#!/usr/bin/env bash
ST=$ENV_DIR/st
LOG=$ENV_DIR/calls.log
echo "docker \$*" >> "\$LOG"
img_of() { cat "\$ST/img-\$1" 2>/dev/null; }

IS_COMPOSE=0
declare -a A=()
while (( \$# )); do
  case "\$1" in
    compose) IS_COMPOSE=1; shift ;;
    -f|--file|--env-file|-p|--project-name) shift 2 ;;
    *) A+=("\$1"); shift ;;
  esac
done
set -- "\${A[@]}"

if (( IS_COMPOSE )); then
  sub="\$1"; shift
  case "\$sub" in
    ps)
      # -qa <svc>
      svc=""
      for a in "\$@"; do [[ "\$a" == -* ]] || svc="\$a"; done
      [[ -n "\$svc" && -f "\$ST/img-\$svc" ]] && echo "cid-\$svc"
      exit 0 ;;
    stop)  echo "STOPPED \$*" >> "\$LOG"; exit 0 ;;
    start) echo "STARTED \$*" >> "\$LOG"; exit 0 ;;
    up)
      # RECONCILE: each named service moves to whatever its image reference
      # resolves to -- a PINNED <SVC>_IMAGE if compose was given one, else the tag.
      if [[ -f "\$ST/repoint" ]]; then
        echo "sha256:deadbeef00000000000000000000000000000000000000000000000000000099" > "\$ST/tag-plex"
      fi
      for a in "\$@"; do
        [[ "\$a" == -* ]] && continue
        # compose resolves the service's image from <SVC>_IMAGE when one is set.
        # Honouring that pin is what lets a rollback which selects by image ID be
        # told apart from one that resolves a mutable tag -- the task-24 defect.
        var="\$(printf '%s' "\$a" | tr 'a-z-' 'A-Z_')_IMAGE"
        pin="\${!var:-}"
        if [[ "\$pin" == sha256:* ]]; then
          printf '%s\n' "\$pin" > "\$ST/img-\$a"
          echo "PINNED \$a \$pin" >> "\$LOG"
        elif [[ -f "\$ST/tag-\$a" ]]; then
          cp "\$ST/tag-\$a" "\$ST/img-\$a"
        fi
        echo "RECREATED \$a" >> "\$LOG"
      done
      exit 0 ;;
    config) exit 0 ;;
    *) exit 0 ;;
  esac
fi

case "\$*" in
  "ps -a --format {{.Names}}") for c in $CONTAINERS; do echo "\$c"; done; exit 0 ;;
  "ps -aq") for c in $CONTAINERS; do echo "cid-\$c"; done; exit 0 ;;
  "images --filter dangling=true -q") printf '%s
' "\$(img_of plex | cut -c8-19)"; exit 0 ;;
esac

# docker inspect [-f|--format] <fmt> <ref>
if [[ "\$1" == "inspect" ]]; then
  fmt=""; ref=""
  shift
  while (( \$# )); do
    case "\$1" in
      -f|--format) fmt="\$2"; shift 2 ;;
      *) ref="\$1"; shift ;;
    esac
  done
  n="\${ref#cid-}"
  case "\$fmt" in
    "{{.Image}}")        img_of "\$n"; exit 0 ;;
    "{{.Config.Image}}") echo "\$n:latest"; exit 0 ;;
    "{{.State.Status}}")
      # The fixture is production: every container is RUNNING unless the test
      # says otherwise. Without this the service looks stopped and the upgrade
      # silently skips the stop, so quiescence is never proven.
      if [[ -f "\$ST/stopped-\$n" ]]; then echo exited; else echo running; fi
      exit 0 ;;
    *"config-hash"*) echo "fixture-hash"; exit 0 ;;
    "{{.State.Health.Status}}") echo healthy; exit 0 ;;
    "{{.Id}}")
      # A TAG reference: what is staged locally for it.
      t="\${ref%%:*}"
      if [[ -f "\$ST/tag-\$t" ]]; then cat "\$ST/tag-\$t"; exit 0; fi
      echo "cid-\$n"; exit 0 ;;
    *) echo "cid-\$n"; exit 0 ;;
  esac
fi

if [[ "\$1" == "image" ]]; then
  shift
  case "\$1" in
    inspect)
      shift
      fmt=""; ref=""
      while (( \$# )); do
        case "\$1" in
          -f|--format) fmt="\$2"; shift 2 ;;
          *) ref="\$1"; shift ;;
        esac
      done
      case "\$fmt" in
        "{{.Size}}") echo 100000000; exit 0 ;;
        "{{.RepoTags}}") echo "[]"; exit 0 ;;
        *"range .RepoTags"*) echo ""; exit 0 ;;
      esac
      # Canonicalise a reference to a full id, or fail if unknown.
      case "\$ref" in
        sha256:*)
          # A PRUNED image is gone. This is what forces a rollback to go through
          # the archive rather than finding a convenient local object.
          [[ -f "\$ST/pruned-\${ref#sha256:}" ]] && exit 1
          echo "\$ref"; exit 0 ;;
      esac
      for c in $CONTAINERS; do
        i="\$(img_of "\$c")"
        [[ -n "\$i" && "\${i:7:12}" == "\$ref" ]] && { echo "\$i"; exit 0; }
      done
      t="\${ref%%:*}"
      [[ -f "\$ST/tag-\$t" ]] && { cat "\$ST/tag-\$t"; exit 0; }
      exit 1 ;;
    save)
      [[ -f "\$ST/archive-fails" ]] && exit 1
      out=""; prev=""; ref=""
      for a in "\$@"; do
        [[ "\$prev" == "-o" ]] && out="\$a"
        [[ "\$a" == sha256:* ]] && ref="\$a"
        prev="\$a"
      done
      [[ -n "\$out" ]] && printf 'FAKE-IMAGE-ARCHIVE\nARCHIVED_ID=%s\n' "\$ref" > "\$out"
      echo "SAVED \$out" >> "\$LOG"; exit 0 ;;
    load)
      # Report what the ARCHIVE holds. A stub echoing the running image would
      # make the identity comparison in rollback_upgrade vacuous.
      f=""; prev=""
      for a in "\$@"; do [[ "\$prev" == "-i" ]] && f="\$a"; prev="\$a"; done
      [[ -n "\$f" && -r "\$f" ]] \\
        && echo "Loaded image ID: \$(sed -n 's/^ARCHIVED_ID=//p' "\$f" | head -1)"
      exit 0 ;;
    rm) echo "DELETED \$*" >> "\$LOG"; exit 0 ;;
  esac
fi

case "\$1" in
  save)
    [[ -f "\$ST/archive-fails" ]] && exit 1
    out=""; prev=""; ref=""
    for a in "\$@"; do
      [[ "\$prev" == "-o" ]] && out="\$a"
      [[ "\$a" == sha256:* ]] && ref="\$a"
      prev="\$a"
    done
    [[ -n "\$out" ]] && printf 'FAKE-IMAGE-ARCHIVE\nARCHIVED_ID=%s\n' "\$ref" > "\$out"
    echo "SAVED \$out" >> "\$LOG"; exit 0 ;;
  load)
    # Report what the ARCHIVE holds. A stub echoing the running image would
    # make the identity comparison in rollback_upgrade vacuous.
    f=""; prev=""
    for a in "\$@"; do [[ "\$prev" == "-i" ]] && f="\$a"; prev="\$a"; done
    [[ -n "\$f" && -r "\$f" ]] \\
      && echo "Loaded image ID: \$(sed -n 's/^ARCHIVED_ID=//p' "\$f" | head -1)"
    exit 0 ;;
esac
exit 0
STUB

  # ---- the btrfs stub -----------------------------------------------------
  cat > "$ENV_DIR/bin/btrfs" <<STUB
#!/usr/bin/env bash
LOG=$ENV_DIR/calls.log
echo "btrfs \$*" >> "\$LOG"
case "\$1 \$2" in
  "subvolume show") [[ -f "\$3/.is-subvol" ]] && exit 0; exit 1 ;;
  "subvolume snapshot")
    [[ -f $ENV_DIR/st/snapshot-fails ]] && exit 1
    src="\${@: -2:1}"; dst="\${@: -1}"
    mkdir -p "\$dst" && cp -a "\$src/." "\$dst/" 2>/dev/null
    touch "\$dst/.is-subvol" "\$dst/.ro"
    echo "SNAPSHOT \$dst" >> "\$LOG"; exit 0 ;;
  "subvolume delete") rm -rf "\${@: -1}"; exit 0 ;;
  "property get") echo "ro=true"; exit 0 ;;
  "property set") exit 0 ;;
  "filesystem usage") echo "Free (estimated): 500.00GiB"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$ENV_DIR/bin/docker" "$ENV_DIR/bin/btrfs"
}

# Run the REAL dispatcher. Only need_root and the host tools are replaced.
run_cli() {  # $@ = argv for domum-media
  local argv=("$@")
  {
    printf 'set -uo pipefail\n'
    printf 'export PATH=%q:"$PATH"\n' "$ENV_DIR/bin"
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$ENV_DIR/cfg"
    printf 'source %q\n' "$CLI"
    # sudo cannot be supplied in a test; nothing else about root is simulated.
    printf 'need_root() { :; }\n'
    # domum_is_subvolume consults btrfs only when uid is 0; otherwise it
    # falls back to stat on a REAL btrfs filesystem, which a tmpdir is not.
    # The fixture marks subvolumes with a file, as the btrfs stub does.
    printf 'domum_is_subvolume() { [[ -n "${1:-}" && -f "$1/.is-subvol" ]]; }\n'
    # Health and application probes would need a live service.
    printf 'wait_for_service_health() { return 0; }\n'
    printf 'service_health_state() { printf healthy; }\n'
    printf 'service_ready_probe() { return 1; }\n'
    printf 'verify_backup_freshness() { return 0; }\n'
    printf 'domum_sqlite_check() { printf "ok"; }\n'
    printf 'main'
    printf ' %q' "${argv[@]}"
    printf '\n'
  } > "$ENV_DIR/drv.sh"
  bash "$ENV_DIR/drv.sh" >"$ENV_DIR/out" 2>"$ENV_DIR/err"
  echo $?
}

img()   { cat "$ENV_DIR/st/img-$1"; }
calls() { cat "$ENV_DIR/calls.log"; }
out()   { cat "$ENV_DIR/out" "$ENV_DIR/err"; }

echo "== 1. the real dispatcher reaches service_upgrade and it RUNS =="
# The assertion the old suite could not make. An undefined helper, a typo in a
# function name, or a `set -e` abort all show up here and nowhere else.
setup
rc="$(run_cli updates apply --service plex)"
if [ "$rc" != "0" ]; then
  echo "--- stdout/stderr ---"; out() { :; }; cat "$ENV_DIR/out" "$ENV_DIR/err"
  fail "the upgrade failed (rc=$rc) on a fixture where it should succeed"
fi
grep -q 'command not found' "$ENV_DIR/err" \
  && fail "an undefined function was called: $(grep 'command not found' "$ENV_DIR/err")"
grep -q 'phase 1/4' "$ENV_DIR/out" || fail "phase 1 never ran: $(out)"
grep -q 'phase 4/4' "$ENV_DIR/out" || fail "phase 4 never ran: $(out)"
echo "  all four phases ran through main; no unresolved commands"

echo "== 2. the full orchestration happened IN ORDER =="
# stop -> quiesce -> snapshot -> archive -> deploy. Proven from the call log,
# not from reading the source.
log="$(calls)"
n_stop="$(grep -n '^STOPPED' <<< "$log" | head -1 | cut -d: -f1)"
n_snap="$(grep -n '^SNAPSHOT' <<< "$log" | head -1 | cut -d: -f1)"
n_save="$(grep -n '^docker image save\|^docker save' <<< "$log" | head -1 | cut -d: -f1)"
n_up="$(grep -n '^RECREATED plex' <<< "$log" | head -1 | cut -d: -f1)"
[ -n "$n_stop" ] || fail "plex was never stopped before snapshotting"
[ -n "$n_snap" ] || fail "no snapshot was taken"
[ -n "$n_save" ] || fail "the old image was never archived"
[ -n "$n_up" ] || fail "the staged image was never deployed"
[ "$n_stop" -lt "$n_snap" ] || fail "snapshot ($n_snap) preceded the stop ($n_stop): it would
be crash-consistent, which is the defect the update path has"
[ "$n_snap" -lt "$n_up" ] || fail "deployed ($n_up) before snapshotting ($n_snap)"
[ "$n_save" -lt "$n_up" ] || fail "deployed ($n_up) before archiving the old image ($n_save)"
echo "  stop($n_stop) < snapshot($n_snap) < archive($n_save) < deploy($n_up)"

echo "== 3. ONLY plex was deployed; the other ten are untouched =="
recreated="$(grep '^RECREATED ' <<< "$log" | awk '{print $2}' | sort -u)"
[ "$recreated" = "plex" ] || fail "recreated more than plex: $recreated"
[ "$(img plex)" = "$PLEX_NEW" ] || fail "plex is on $(img plex), not the staged $PLEX_NEW"
# calibre-web has a staged image too and must NOT have moved to it.
[ "$(img calibre-web)" = "$CW_OLD" ] \
  || fail "calibre-web moved to its staged image. A service-scoped upgrade became a
fleet deployment -- the immich reset-db defect class."
[ "$(img jellyfin)" = "$JF_IMG" ] || fail "jellyfin's image changed"
grep -q 'scope           : all' "$ENV_DIR/out" || fail "no scope proof was reported: $(out)"
echo "  plex -> staged; calibre-web still $CW_OLD; scope proof reported"

echo "== 4. a recovery point, archive and metadata all exist afterwards =="
point="$(find "$ENV_DIR/snapshots" -maxdepth 1 -name 'plex-*pre-upgrade*' -printf '%f\n' | head -1)"
[ -n "$point" ] || fail "no pre-upgrade snapshot: $(ls "$ENV_DIR/snapshots")"
meta="$(find "$ENV_DIR/state" "$ENV_DIR/snapshots" -name "$point.recovery" | head -1)"
[ -n "$meta" ] || fail "no recovery metadata for $point"
grep -q "CONTAINER_._IMAGE_ID='$PLEX_OLD'" "$meta" \
  || fail "the recovery metadata does not record the OLD image id. Without it a
rollback has no way to pair the snapshot with the application that wrote it:
$(cat "$meta")"
archive="$(find "$ENV_DIR/data/backups/images" -type f ! -name '*.sha256' 2>/dev/null | head -1)"
[ -n "$archive" ] || fail "no image archive under data/backups/images"
[ -r "$archive.sha256" ] || fail "the archive has no checksum beside it"
echo "  point=$point  metadata records $PLEX_OLD  archive + sha256 present"

echo "== 5. the archived old image is excluded from structured cleanup =="
# The wrapper's real question, asked the machine-readable way.
rc="$(run_cli cleanup images --json)"
[ "$rc" = "0" ] || fail "cleanup images --json failed: $(out)"
python3 - "$ENV_DIR/out" "$PLEX_OLD" <<'PY' || fail "the old image is not protected after the upgrade"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rec = next((i for i in d["images"] if i["id"] == want), None)
assert rec is not None, f"{want} is absent from the cleanup records entirely"
assert rec["recovery_referenced"] is True, f"not recovery-referenced: {rec}"
assert rec["candidate"] is False, (
    f"the image the pre-upgrade point pairs with is a DELETION CANDIDATE: {rec}")
print(f"  {want[:19]} recovery_referenced=true candidate=false")
PY

echo "== 6. an unknown service dies, and NOTHING is touched =="
setup
rc="$(run_cli updates apply --service plexx)"
[ "$rc" != "0" ] || fail "a typo'd service name exited 0"
grep -q 'not an upgradable service' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
[ -z "$(grep -c '^RECREATED' <<< "$(calls)" | grep -v '^0$')" ] \
  || fail "a typo recreated containers: $(calls)"
grep -q '^STOPPED' <<< "$(calls)" && fail "a typo stopped a container"
[ "$(img plex)" = "$PLEX_OLD" ] || fail "plex's image changed on a typo"
# A typo must not widen to the fleet.
grep -q 'Known:' "$ENV_DIR/err" || fail "the refusal does not list the known services"
echo "  refused, nothing stopped, nothing recreated, scope never widened"

echo "== 7. unprotected state refuses BEFORE the stop =="
# calibre-web is an ordinary directory in the fixture, as in production.
setup
rc="$(run_cli updates apply --service calibre-web)"
[ "$rc" != "0" ] || fail "upgrading a service with unprotected state exited 0"
grep -q 'not a Btrfs subvolume' "$ENV_DIR/err" \
  || fail "wrong refusal for unprotected state: $(out)"
grep -q '^STOPPED' <<< "$(calls)" \
  && fail "calibre-web was STOPPED before the refusal. The whole point of asking
first is that an unsnapshottable service stays up."
grep -q '^RECREATED' <<< "$(calls)" && fail "calibre-web was recreated"
[ "$(img calibre-web)" = "$CW_OLD" ] || fail "calibre-web's image changed"
echo "  refused while still running; never stopped, never recreated"

echo "== 8. no staged image fails closed and deploys nothing =="
setup no-staged
rc="$(run_cli updates apply --service plex)"
grep -q '^RECREATED' <<< "$(calls)" && fail "deployed something with nothing staged"
[ "$(img plex)" = "$PLEX_OLD" ] || fail "plex's image changed with nothing staged"
grep -q 'no staged image' "$ENV_DIR/out" || fail "it did not say there was nothing to do: $(out)"
echo "  reported and stopped; no snapshot, no deployment"

echo "== 9. a failed snapshot prevents deployment =="
setup snapshot-fails
rc="$(run_cli updates apply --service plex)"
[ "$rc" != "0" ] || fail "a failed pre-upgrade snapshot exited 0"
grep -q '^RECREATED plex' <<< "$(calls)" \
  && fail "plex was DEPLOYED although its pre-upgrade snapshot failed. The staged
image would be running with no rollback point."
[ "$(img plex)" = "$PLEX_OLD" ] || fail "plex's image changed despite a failed snapshot"
grep -q '^STARTED' <<< "$(calls)" \
  || fail "plex was left stopped after the failure; the failure path must bring it back"
echo "  refused, not deployed, and plex was restarted on its ORIGINAL image"

echo "== 10. a failed archive prevents deployment =="
setup archive-fails
rc="$(run_cli updates apply --service plex)"
[ "$rc" != "0" ] || fail "a failed image archive exited 0"
grep -q '^RECREATED plex' <<< "$(calls)" \
  && fail "plex was DEPLOYED although the old image could not be archived. The
recovery point's application half would not exist."
[ "$(img plex)" = "$PLEX_OLD" ] || fail "plex's image changed despite a failed archive"
echo "  refused, not deployed"

echo "== 11. the deployed image must be the INTENDED one =="
# If a pull re-points the tag between the staged-image read and `up -d`, plex
# comes up on something other than what was reviewed. That is a failure, not a
# success with a warning -- the operation lock does not cover other tools.
setup
touch "$ENV_DIR/st/repoint"
rc="$(run_cli updates apply --service plex)"
[ "$rc" != "0" ] \
  || fail "the upgrade reported SUCCESS while plex came up on an image other than
the intended staged one"
grep -q 'NOT running the intended image' "$ENV_DIR/err" \
  || fail "the mismatch was not reported: $(out)"
echo "  a mismatch between intended and actual is a failure, and is named"

echo "== 12. --dry-run deploys nothing =="
setup
rc="$(run_cli updates apply --service plex --dry-run)"
grep -q '^RECREATED' <<< "$(calls)" && fail "--dry-run recreated a container"
[ "$(img plex)" = "$PLEX_OLD" ] || fail "--dry-run changed plex's image"
echo "  nothing deployed"

echo "== 13. the fleet path still cannot target one service =="
setup
rc="$(run_cli refresh-images plex)"
[ "$rc" != "0" ] || fail "refresh_images accepted a positional service argument;
`updates apply --service` and the fleet path would no longer be distinct operations"
echo "  refresh_images still refuses a positional argument"

# ===========================================================================
# ROLLBACK (task-24), proven in integration rather than from helper tests.
#
# The defect being guarded: the OLD auto-rollback restored the snapshot and then
# used `compose start` -- on the container the upgrade had just created, i.e. the
# NEW image. Old data under a newer application: the exact pairing failure.
# Restoring data is the easy half; restoring the application it pairs with is
# the half that was missing.
# ===========================================================================

upgrade_then_find_point() {  # leaves plex upgraded; echoes the recovery point
  setup
  run_cli updates apply --service plex >/dev/null
  find "$ENV_DIR/snapshots" -maxdepth 1 -name 'plex-*pre-upgrade' -printf '%f\n' | head -1
}

echo "== 14. rollback restores BOTH halves: data AND the recorded image =="
point="$(upgrade_then_find_point)"
[ -n "$point" ] || fail "no recovery point to roll back to"
[ "$(img plex)" = "$PLEX_NEW" ] || fail "precondition: plex should be on the new image"
# Mark something in the restored tree so the data restore is observable.
echo "UPGRADED" > "$ENV_DIR/data/plex/marker"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" = "0" ] || fail "rollback failed: $(out)"
[ "$(img plex)" = "$PLEX_OLD" ] \
  || fail "after rollback plex runs $(img plex), not the recorded old image $PLEX_OLD.
Restoring the data under a newer application is the task-24 pairing failure."
[ -f "$ENV_DIR/data/plex/com.plexapp.plugins.library.db" ] \
  || fail "the restored tree is missing the database that was snapshotted"
[ -f "$ENV_DIR/data/plex/marker" ] \
  && fail "the live tree was not replaced by the snapshot; post-upgrade state survived"
echo "  plex back on $PLEX_OLD, data restored from the snapshot"

echo "== 15. the failed state is PRESERVED, never deleted =="
failed="$(find "$ENV_DIR/data" -maxdepth 1 -name 'plex.failed-*' | head -1)"
[ -n "$failed" ] || fail "the post-upgrade state was not preserved as plex.failed-*"
grep -qx UPGRADED "$failed/marker" \
  || fail "the preserved directory is not the state that was running: $(ls "$failed")"
echo "  preserved at $(basename "$failed"), with its contents intact"

echo "== 16. a MUTABLE TAG does not decide the rollback =="
# tag-plex still resolves to the NEW image. If the rollback had recreated without
# pinning, plex would have come straight back up on it.
[ "$(cat "$ENV_DIR/st/tag-plex")" = "$PLEX_NEW" ] \
  || fail "precondition: the tag should still point at the new image"
grep -q "^PINNED plex $PLEX_OLD$" <<< "$(calls)" \
  || fail "the rollback did not pin the image by ID. The tag still resolves to
$PLEX_NEW, so anything that merely recreated would be running the NEW build:
$(grep -E 'PINNED|RECREATED' <<< "$(calls)")"
echo "  pinned by image ID while the tag still points at $PLEX_NEW"

echo "== 17. the image comes from the ARCHIVE when the local object is gone =="
# Plex's pairing is identity,local -- the local object is the only copy, and the
# moment plex is upgraded that object becomes prunable.
point="$(upgrade_then_find_point)"
touch "$ENV_DIR/st/pruned-${PLEX_OLD#sha256:}"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" = "0" ] || fail "rollback failed with the old image pruned: $(out)"
grep -q 'loading .* from ' "$ENV_DIR/out" || fail "it did not load from the archive: $(out)"
grep -q 'identity CONFIRMED equal to the record' "$ENV_DIR/out" \
  || fail "the loaded image's identity was not confirmed against the record: $(out)"
echo "  loaded from the archive and its identity confirmed against the record"

echo "== 18. rollback REFUSES when the archive holds a different image =="
point="$(upgrade_then_find_point)"
touch "$ENV_DIR/st/pruned-${PLEX_OLD#sha256:}"
arch="$(find "$ENV_DIR/data/backups/images" -type f ! -name '*.sha256' | head -1)"
[ -n "$arch" ] || fail "no archive to tamper with"
# Same FILE (checksum still matches), different IMAGE inside. Only the identity
# comparison can catch this -- the checksum cannot.
sed -i 's/^ARCHIVED_ID=.*/ARCHIVED_ID=sha256:0bad0bad0bad0000000000000000000000000000000000000000000000000bad/' "$arch"
sha256sum "$arch" | awk '{print $1}' > "$arch.sha256.new"
meta="$ENV_DIR/state/snapshots/$point.recovery"
newsha="$(cat "$arch.sha256.new")"
sed -i "s/^IMAGE_ARCHIVE_SHA256='.*'/IMAGE_ARCHIVE_SHA256='$newsha'/" "$meta"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" != "0" ] \
  || fail "the rollback accepted an archive containing a DIFFERENT image than the
recovery point records. The checksum matched; only the identity check could
catch it, and it did not."
grep -q 'restored a DIFFERENT image' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
grep -q '^PINNED' <<< "$(calls)" && fail "it pinned something despite refusing"
echo "  refused on identity although the file checksum matched"

echo "== 19. rollback REFUSES on a corrupted archive file =="
point="$(upgrade_then_find_point)"
touch "$ENV_DIR/st/pruned-${PLEX_OLD#sha256:}"
arch="$(find "$ENV_DIR/data/backups/images" -type f ! -name '*.sha256' | head -1)"
printf 'CORRUPTED\n' >> "$arch"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" != "0" ] || fail "the rollback loaded an archive whose checksum did not match"
grep -q 'does not match its recorded sha256' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
echo "  refused before loading, and said which checksum disagreed"

echo "== 20. rollback REFUSES when the recovery metadata is incomplete =="
point="$(upgrade_then_find_point)"
meta="$ENV_DIR/state/snapshots/$point.recovery"
sed -i "/^CONTAINER_1_IMAGE_ID=/d" "$meta"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" != "0" ] \
  || fail "the rollback proceeded with no recorded image identity. It would have
restored the data under whatever is running now -- the pairing failure."
grep -q 'records no image identity' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
[ "$(img plex)" = "$PLEX_NEW" ] || fail "it changed the running image before refusing"
find "$ENV_DIR/data" -maxdepth 1 -name 'plex.failed-*' | grep -q . \
  && fail "it moved the live data aside before refusing"
echo "  refused, and nothing was moved or restarted"

echo "== 21. rollback REFUSES when the snapshot itself is missing =="
point="$(upgrade_then_find_point)"
rm -rf "$ENV_DIR/snapshots/$point"
rc="$(run_cli rollback-upgrade plex "$point")"
[ "$rc" != "0" ] || fail "the rollback proceeded with no snapshot to restore from"
grep -q 'is missing; this point cannot be restored' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
echo "  refused"

echo "== 22. an unknown service and an unknown point both refuse =="
point="$(upgrade_then_find_point)"
rc="$(run_cli rollback-upgrade plexx "$point")"
[ "$rc" != "0" ] || fail "an unknown service exited 0"
rc="$(run_cli rollback-upgrade plex no-such-point)"
[ "$rc" != "0" ] || fail "an unknown recovery point exited 0"
grep -q 'No recovery evidence' "$ENV_DIR/err" || fail "wrong refusal: $(out)"
[ "$(img plex)" = "$PLEX_NEW" ] || fail "the running image changed on a refusal"
echo "  both refused; nothing touched"

echo
echo "PASS: service upgrade integration smoke"
