#!/usr/bin/env bash
# A configuration-only compose recreate must not deploy an image.
#
# Why this suite exists. 2026-11-25, repairing stale container DNS, ten
# containers were recreated with `domum-media compose up -d --force-recreate`.
# Nine kept their image because nothing was staged for them; uptime-kuma did
# not -- it went a8610b3b4c38 -> 3e24e96c89ef, became 2.5.3 and
# forward-migrated kuma.db, so rolling back is no longer a clean recovery
# point. The operator block had exported UPTIME_KUMA_IMAGE=<running id> first,
# which was believed to pin it.
#
# It could never have pinned anything. `compose_passthrough` runs
#
#     need_root; load_cfg; export_env_for_compose; compose_cmd "$@"
#
# and load_cfg does `source "$CFG_FILE"`, where the production config assigns
# UPTIME_KUMA_IMAGE=louislam/uptime-kuma:2 explicitly. So the exported pin was
# OVERWRITTEN by the source, and export_env_for_compose's
# ${UPTIME_KUMA_IMAGE:-default} then saw a non-empty tag and kept it. Measured:
#
#     export UPTIME_KUMA_IMAGE=sha256:a8610b3b4c38   -> sha256:a8610b3b4c38
#     source conf (UPTIME_KUMA_IMAGE=louislam/...:2) -> louislam/uptime-kuma:2
#     ${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:2}   -> louislam/uptime-kuma:2
#
# This is the recorded shape "a fix in a default is not in force wherever the
# configuration overrides that default", applied to an image reference. I had
# reasoned from export_env_for_compose's `:-` alone and missed the `source` one
# line above it.
#
# Two things close it, and neither alone is enough: DOMUM_PIN_RUNNING_IMAGES
# gives a channel the config cannot clobber (it is read from the environment,
# which load_cfg never assigns, and applied AFTER the source), and the gate
# makes forgetting it a refusal rather than a silent upgrade.
#
# Everything below is DRIVEN. A test that reads a function's text does not
# prove the function runs.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# What the drivers LOAD. A mutation repoints this at a mutated COPY, so bin/ is
# never written: an interrupted run leaves nothing behind and a concurrent run
# cannot read a half-mutated file.
MUTCLI="$CLI"
PRISTINE="$TMP/cli.pristine"; cp "$CLI" "$PRISTINE"

# ---------------------------------------------------------------------------
#  The driver. Only the functions under test are sourced.
#
#  die/warn/cmd_exists are SINGLE-LINE definitions, so an awk range from
#  /^name() {/ to /^}/ would swallow the rest of the file -- the recorded
#  single-line-definition trap. They are picked out by their own line instead,
#  so the real implementations are used rather than stand-ins.
# ---------------------------------------------------------------------------
cat > "$TMP/drive.sh" <<'DRIVER'
set -uo pipefail
source <(sed -n '/^die()  {/p;/^warn() {/p;/^cmd_exists() {/p' "$CLI_PATH")
source <(awk '/^uppercase_token\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^compose_running_image_pins\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^compose_image_change_plan\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^compose_assert_no_unpinned_image_change\(\) \{/,/^\}/' "$CLI_PATH")
eval "$DRIVE"
DRIVER

# A docker stub built from a table of "service<TAB>running_id<TAB>created_ref".
# IMAGES holds "<ref> <id>" lines: a ref absent from it resolves to nothing,
# which is how "the tag is not present locally" is driven.
make_docker() {  # $1 = containers table file, $2 = images table file
  cat > "$TMP/bin/docker" <<STUB
#!/usr/bin/env bash
CT="$1"; IMG="$2"
STUB
  cat >> "$TMP/bin/docker" <<'STUB'
case "$1 $2" in
  "ps -q")
    n=0
    while IFS=$'\t' read -r svc run ref; do
      [ -n "$svc" ] || continue
      n=$((n+1)); printf 'cid%d\n' "$n"
    done < "$CT"
    exit 0 ;;
esac
if [ "$1" = "inspect" ]; then
  fmt=""; target=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --format) fmt="$2"; shift 2 ;; *) target="$1"; shift ;; esac
  done
  idx="${target#cid}"
  line="$(sed -n "${idx}p" "$CT")"
  svc="$(printf '%s' "$line" | cut -f1)"
  run="$(printf '%s' "$line" | cut -f2)"
  ref="$(printf '%s' "$line" | cut -f3)"
  case "$fmt" in
    *compose.service*) printf '%s\n' "$svc" ;;
    '{{.Image}}')      printf '%s\n' "$run" ;;
    '{{.Config.Image}}') printf '%s\n' "$ref" ;;
  esac
  exit 0
fi
if [ "$1 $2" = "image inspect" ]; then
  fmt=""; target=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --format) fmt="$2"; shift 2 ;; *) target="$1"; shift ;; esac
  done
  while read -r r i; do
    [ "$r" = "$target" ] && { printf '%s\n' "$i"; exit 0; }
  done < "$IMG"
  exit 1
fi
exit 0
STUB
  chmod +x "$TMP/bin/docker"
}

probe() {  # $1 = DRIVE snippet; env: extra exports via EXTRA
  ( export CLI_PATH="$MUTCLI" DRIVE="$1" PATH="$TMP/bin:$PATH"
    eval "${EXTRA:-}"
    bash "$TMP/drive.sh" 2>&1 )
}

mkdir -p "$TMP/bin"

# Two running containers: uptime-kuma whose tag has MOVED, and a four-word
# compose service name, which is what proves the variable is DERIVED rather
# than read from managed_image_specs (immich is deliberately absent from it).
cat > "$TMP/ct" <<EOF
uptime-kuma$(printf '\t')sha256:aaaa$(printf '\t')louislam/uptime-kuma:2
immich_machine_learning$(printf '\t')sha256:bbbb$(printf '\t')ghcr.io/immich-app/immich-machine-learning:release
EOF
# An image ID is itself a valid reference and docker resolves it to itself, so
# the table carries the id self-mappings. Without them a PINNED service reads as
# "reference not present locally" and the pin looks broken when it is not.
cat > "$TMP/img" <<'EOF'
louislam/uptime-kuma:2 sha256:cccc
ghcr.io/immich-app/immich-machine-learning:release sha256:bbbb
sha256:aaaa sha256:aaaa
sha256:bbbb sha256:bbbb
sha256:cccc sha256:cccc
EOF
make_docker "$TMP/ct" "$TMP/img"

# ---------------------------------------------------------------------------
sect "1. the pin derives the variable name the compose files actually use"
out="$(probe 'compose_running_image_pins')"
grep -qxF 'UPTIME_KUMA_IMAGE=sha256:aaaa' <<< "$out" \
  || fail "1: no UPTIME_KUMA_IMAGE pin; got: $out"
grep -qxF 'IMMICH_MACHINE_LEARNING_IMAGE=sha256:bbbb' <<< "$out" \
  || fail "1: immich_machine_learning did not derive IMMICH_MACHINE_LEARNING_IMAGE; got: $out"
[ "$(grep -c '_IMAGE=' <<< "$out")" = 2 ] || fail "1: expected 2 pins, got: $out"

sect "2. no docker -> no pins, and not a failure"
out="$(probe 'cmd_exists() { [ "$1" != docker ]; }; compose_running_image_pins; echo "RC=$?"')"
grep -qxF 'RC=0' <<< "$out" || fail "2: expected rc 0, got: $out"
grep -q '_IMAGE=' <<< "$out" && fail "2: pinned something with no docker: $out"

# ---------------------------------------------------------------------------
sect "3. the plan reports a moved tag as CHANGE, and names both ids"
out="$(probe 'compose_image_change_plan')"
grep -qxF 'CHANGE uptime-kuma sha256:aaaa sha256:cccc' <<< "$out" \
  || fail "3: uptime-kuma not reported as CHANGE; got: $out"

sect "4. a service whose tag still resolves to its running image is NOT reported"
grep -q 'immich_machine_learning' <<< "$out" \
  && fail "4: a service with nothing staged was reported: $out"

sect "5. a reference absent locally is UNKNOWN, never silently clean"
cat > "$TMP/img2" <<'EOF'
ghcr.io/immich-app/immich-machine-learning:release sha256:bbbb
sha256:aaaa sha256:aaaa
sha256:bbbb sha256:bbbb
EOF
make_docker "$TMP/ct" "$TMP/img2"
out="$(probe 'compose_image_change_plan')"
grep -qE '^UNKNOWN uptime-kuma sha256:aaaa louislam/uptime-kuma:2$' <<< "$out" \
  || fail "5: an absent reference was not UNKNOWN; got: $out"
make_docker "$TMP/ct" "$TMP/img"

sect "6. THE REGRESSION: an exported pin is what the plan compares against"
out="$(EXTRA='export UPTIME_KUMA_IMAGE=sha256:aaaa' probe 'compose_image_change_plan; echo "END"')"
grep -q 'uptime-kuma' <<< "$out" \
  && fail "6: a pinned service was still reported as changing: $out"
grep -qxF 'END' <<< "$out" || fail "6: the plan did not complete: $out"

# ---------------------------------------------------------------------------
sect "7. the gate REFUSES an up that would move a running container's image"
out="$(probe 'compose_assert_no_unpinned_image_change up -d --force-recreate; echo "REACHED"')"
grep -qxF 'REACHED' <<< "$out" && fail "7: the gate allowed an image change: $out"
grep -q 'uptime-kuma: aaaa -> cccc' <<< "$out" || fail "7: the refusal did not name the change: $out"
grep -q 'DOMUM_PIN_RUNNING_IMAGES=1' <<< "$out" || fail "7: the refusal offered no pin remedy: $out"

sect "8. a NON-reconciling command is not gated"
for verb in ps logs stop restart config; do
  out="$(probe "compose_assert_no_unpinned_image_change $verb; echo REACHED")"
  grep -qxF 'REACHED' <<< "$out" || fail "8: '$verb' was gated but does not reconcile: $out"
done

sect "9. the gate passes once the images are pinned (positive control)"
out="$(EXTRA='export UPTIME_KUMA_IMAGE=sha256:aaaa' probe 'compose_assert_no_unpinned_image_change up -d; echo REACHED')"
grep -qxF 'REACHED' <<< "$out" || fail "9: a fully pinned up was refused: $out"

sect "10. an explicit override is honoured, and only when explicit"
out="$(EXTRA='export DOMUM_ALLOW_IMAGE_CHANGE=1' probe 'compose_assert_no_unpinned_image_change up -d; echo REACHED')"
grep -qxF 'REACHED' <<< "$out" || fail "10: DOMUM_ALLOW_IMAGE_CHANGE=1 did not allow it: $out"
out="$(EXTRA='export DOMUM_ALLOW_IMAGE_CHANGE=0' probe 'compose_assert_no_unpinned_image_change up -d; echo REACHED')"
grep -qxF 'REACHED' <<< "$out" && fail "10: =0 allowed the change: $out"

sect "11. the config CLOBBERS an exported pin -- the premise the fix rests on"
# If this ever stops holding, DOMUM_PIN_RUNNING_IMAGES is unnecessary and the
# comment in export_env_for_compose is wrong. Asserted so the premise cannot
# rot silently underneath the mechanism built for it.
printf 'UPTIME_KUMA_IMAGE=louislam/uptime-kuma:2\n' > "$TMP/conf"
got="$( export UPTIME_KUMA_IMAGE=sha256:aaaa
        # shellcheck disable=SC1090
        source "$TMP/conf"
        printf '%s' "${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:2}" )"
[ "$got" = 'louislam/uptime-kuma:2' ] \
  || fail "11: expected the config to win, got '$got'"

sect "12. the pin is applied AFTER the config is sourced, not before"
# Position, not prose: the whole defect was ordering.
src="$(cat "$MUTCLI")"
pin_at="$(grep -n 'DOMUM_PIN_RUNNING_IMAGES:-0' <<< "$src" | head -1 | cut -d: -f1)"
fn_at="$(grep -n '^export_env_for_compose() {' <<< "$src" | head -1 | cut -d: -f1)"
pass_at="$(grep -n '^compose_passthrough() {' <<< "$src" | head -1 | cut -d: -f1)"
[ -n "$pin_at" ] && [ -n "$fn_at" ] && [ -n "$pass_at" ] \
  || fail "12: could not locate the pin, export_env_for_compose or compose_passthrough"
(( pin_at > fn_at )) || fail "12: the pin is not inside export_env_for_compose"
# compose_passthrough must call load_cfg BEFORE export_env_for_compose, which is
# what makes "after the source" true at run time.
body="$(awk '/^compose_passthrough\(\) \{/,/^\}/' <<< "$src")"
lc="$(grep -n 'load_cfg' <<< "$body" | head -1 | cut -d: -f1)"
ee="$(grep -n 'export_env_for_compose' <<< "$body" | head -1 | cut -d: -f1)"
ga="$(grep -n 'compose_assert_no_unpinned_image_change' <<< "$body" | head -1 | cut -d: -f1)"
cc="$(grep -n 'compose_cmd "\$@"' <<< "$body" | head -1 | cut -d: -f1)"
[ -n "$lc" ] && [ -n "$ee" ] && [ -n "$ga" ] && [ -n "$cc" ] \
  || fail "12: compose_passthrough is missing one of load_cfg/export/gate/compose_cmd"
(( lc < ee )) || fail "12: export_env_for_compose runs before load_cfg"
(( ga < cc )) || fail "12: the gate runs after compose -- a gate that recreates is not a gate"

# ---------------------------------------------------------------------------
sect "13. END TO END through the real export_env_for_compose"
# The whole function is driven, with the config value already assigned exactly
# as load_cfg's `source "$CFG_FILE"` leaves it. This is the incident reproduced:
# with the pin off the config tag survives and `up -d` would deploy whatever it
# now resolves to; with the pin on the running image id wins.
mkdir -p "$TMP/e2e/bin"
cat > "$TMP/e2e/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "ps -q") echo cid1; exit 0 ;;
esac
if [ "$1" = inspect ]; then
  for a in "$@"; do
    case "$a" in
      *compose.service*) echo uptime-kuma; exit 0 ;;
      '{{.Image}}')      echo sha256:aaaa;  exit 0 ;;
    esac
  done
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/e2e/bin/docker"
cat > "$TMP/e2e/drive.sh" <<'E2E'
set -uo pipefail
SECRETS_DIR="$E/secrets"; MEDIA_ROOT_DEFAULT="$E/media"
DOMUM_DIR="$E"; DOMUM_STATE_ROOT="$E/state"; DOMUM_DATA_ROOT="$E/data"
mkdir -p "$SECRETS_DIR" "$MEDIA_ROOT_DEFAULT" "$DOMUM_STATE_ROOT" "$DOMUM_DATA_ROOT"
load_runtime_secrets() { :; }
source <(sed -n '/^die()  {/p;/^warn() {/p;/^cmd_exists() {/p' "$CLI_PATH")
source <(awk '/^uppercase_token\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^compose_running_image_pins\(\) \{/,/^\}/' "$CLI_PATH")
source <(awk '/^export_env_for_compose\(\) \{/,/^\}/' "$CLI_PATH")
UPTIME_KUMA_IMAGE='louislam/uptime-kuma:2'
export_env_for_compose >/dev/null 2>&1
echo "RESULT=$UPTIME_KUMA_IMAGE"
E2E

e2e() {  # $1 = CLI to load; env: DOMUM_PIN_RUNNING_IMAGES
  ( export E="$TMP/e2e" CLI_PATH="$1" PATH="$TMP/e2e/bin:$PATH"
    out="$(bash "$TMP/e2e/drive.sh" 2>&1)"
    sed -n '/^RESULT=/p' <<< "$out" )
}

got="$(DOMUM_PIN_RUNNING_IMAGES=1 e2e "$CLI")"
[ "$got" = 'RESULT=sha256:aaaa' ] \
  || fail "13: with the pin on, the running image did not win; got '$got'"
got="$(e2e "$CLI")"
[ "$got" = 'RESULT=louislam/uptime-kuma:2' ] \
  || fail "13: without the pin the config tag should survive (that IS the bug); got '$got'"

sect "13b. MUTATION: neutralise the pin channel -> the config tag wins even with it on"
mut="$TMP/cli.nopin"
python3 - "$PRISTINE" "$mut" <<'MUTPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '  if [[ "${DOMUM_PIN_RUNNING_IMAGES:-0}" == "1" ]]; then\n'
assert s.count(old) == 1, "mutation anchor matched %d times" % s.count(old)
s = s.replace(old, '  if [[ "${DOMUM_PIN_RUNNING_IMAGES:-0}" != "${DOMUM_PIN_RUNNING_IMAGES:-0}" ]]; then\n', 1)
open(dst, "w").write(s)
MUTPY
[ -s "$mut" ] || fail "13b: the mutation did not apply"
got="$(DOMUM_PIN_RUNNING_IMAGES=1 e2e "$mut")"
[ "$got" = 'RESULT=louislam/uptime-kuma:2' ] \
  || fail "13b: the mutant still pinned -- the mutation proves nothing; got '$got'"

sect "14. MUTATION: without the gate, an up that moves an image is allowed"
mut2="$TMP/cli.nogate"
python3 - "$PRISTINE" "$mut2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = '  (( reconciles == 1 )) || return 0\n'
assert s.count(old) == 1, "mutation anchor matched %d times" % s.count(old)
s = s.replace(old, '  (( reconciles == 1 )) || return 0\n  return 0\n', 1)
open(dst, "w").write(s)
PY
[ $? -eq 0 ] || fail "14: the mutation did not apply"
MUTCLI="$mut2"
out="$(probe 'compose_assert_no_unpinned_image_change up -d; echo REACHED')"
grep -qxF 'REACHED' <<< "$out" || fail "14: the mutant still refused -- the mutation proves nothing"
MUTCLI="$CLI"
out="$(probe 'compose_assert_no_unpinned_image_change up -d; echo REACHED')"
grep -qxF 'REACHED' <<< "$out" && fail "14: the real gate stopped refusing"

sect "15. bin/ was never written"
cmp -s "$CLI" "$PRISTINE" || fail "15: $CLI differs from the pristine copy taken at start"

echo "OK: compose image pin and gate"
