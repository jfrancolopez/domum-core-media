#!/usr/bin/env bash
set -uo pipefail

# `cleanup images --confirm` runs `docker image rm` on everything the selector
# returns. Two defects made that unsafe.
#
# 1. THE IN-USE EXCLUSION NEVER MATCHED. `docker images -q` yields SHORT ids
#    (`58f13a1df833`) while `{{.Image}}` yields `sha256:<64 hex>`, and the
#    exclusion compared them with `grep -Fxq`. Measured on the N100: FOUR images
#    belonging to RUNNING containers were offered as deletion candidates --
#    plex 58f13a1df833, calibre-web 6cf7dab48a4a, traefik 9c3b91d5fb77,
#    uptime-kuma a8610b3b4c38 -- because each is dangling, a newer `:latest`
#    having moved the tag off it. Docker refuses to remove an image a container
#    uses, but the whole batch goes to one `docker image rm`, and the moment such
#    a service is upgraded its old image stops being in use.
#
# 2. RECOVERY-POINT IMAGES HAD NO PROTECTION AT ALL. The selector consulted no
#    recovery metadata. Deleting one leaves the snapshot restorable and the
#    application that wrote it unobtainable -- and plex's pairing is
#    `identity,local`, RepoTags and RepoDigests both empty, so the local object is
#    the only copy. Upgrading plex is precisely what makes it deletable.
#
# Both rules are pinned here, in both id formats, because the first defect was a
# format mismatch that no test would have caught by reading.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

FULL_A=sha256:aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111
FULL_B=sha256:bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222
FULL_C=sha256:cccccccccccc3333333333333333333333333333333333333333333333333333
SHORT_A=aaaaaaaaaaaa
SHORT_B=bbbbbbbbbbbb
SHORT_C=cccccccccccc

# A docker stub. Candidates come back SHORT, as the real `docker images -q` does;
# container images come back FULL, as `{{.Image}}` does. That asymmetry IS the bug.
probe() {  # $1 = extra shell
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    cat <<STUB
docker() {
  case "\$*" in
    "images --filter dangling=true -q") printf '%s\n%s\n%s\n' $SHORT_A $SHORT_B $SHORT_C ;;
    "ps -aq") printf 'cid-a\n' ;;
    "inspect --format {{.Image}} cid-a") printf '%s\n' $FULL_A ;;
    "image inspect -f {{.Id}} $SHORT_A"|"image inspect -f {{.Id}} $FULL_A") printf '%s\n' $FULL_A ;;
    "image inspect -f {{.Id}} $SHORT_B"|"image inspect -f {{.Id}} $FULL_B") printf '%s\n' $FULL_B ;;
    "image inspect -f {{.Id}} $SHORT_C"|"image inspect -f {{.Id}} $FULL_C") printf '%s\n' $FULL_C ;;
    *) return 1 ;;
  esac
}
rollback_entries() { :; }
snapshot_metadata_dir() { printf '%s' "$TMP_DIR/meta"; }
STUB
    printf '%s\n' "$1"
  } > "$TMP_DIR/probe.sh"
  bash "$TMP_DIR/probe.sh" 2>"$TMP_DIR/err"
}

mkmeta() {  # $1 = full image id to name in a recovery file, or empty for none
  rm -rf "${TMP_DIR:?}/meta"; mkdir -p "$TMP_DIR/meta"
  [ -n "${1:-}" ] || return 0
  cat > "$TMP_DIR/meta/point.recovery" <<EOF
FORMAT='1'
SERVICE='plex'
RECOVERY_POINT='point'
CONTAINER_1_SERVICE='plex'
CONTAINER_1_IMAGE_ID='$1'
EOF
}

echo "== 1. an image a container uses is NOT a candidate, across id formats =="
mkmeta ""
out="$(probe 'collect_cleanup_image_ids')"
grep -qx "$FULL_A" <<< "$out" \
  && fail "the image of a running container is a deletion candidate. The in-use
exclusion compares short ids against sha256:-prefixed ones and never matches:
$out"
grep -q "SKIP $FULL_A in-use" "$TMP_DIR/err" \
  || fail "it was not reported as protected: $(cat "$TMP_DIR/err")"
echo "  in-use image protected and reported"

echo "== 2. genuinely unreferenced images ARE candidates =="
for f in "$FULL_B" "$FULL_C"; do
  grep -qx "$f" <<< "$out" || fail "an unreferenced dangling image must still be prunable: $out"
done
[ "$(grep -c . <<< "$out")" = 2 ] || fail "expected exactly 2 candidates, got: $out"
echo "  2 candidates, both unreferenced"

echo "== 3. candidates are emitted as FULL ids, not short =="
grep -qE '^[0-9a-f]{12}$' <<< "$out" \
  && fail "a short id reached the output; docker image rm would be given an
ambiguous reference and comparisons downstream would break again: $out"
echo "  all candidates are sha256:-prefixed"

echo "== 4. an image named by a RECOVERY POINT is protected =="
# This is the post-upgrade state: no container uses it any more, and it is
# dangling, so nothing else would hold it back.
mkmeta "$FULL_B"
out="$(probe 'collect_cleanup_image_ids')"
grep -qx "$FULL_B" <<< "$out" \
  && fail "an image a recovery point pairs with is a deletion candidate. Deleting it
leaves the snapshot restorable and the application unobtainable:
$out"
grep -q "SKIP $FULL_B recovery-point" "$TMP_DIR/err" \
  || fail "it was not reported as recovery-protected: $(cat "$TMP_DIR/err")"
grep -qx "$FULL_C" <<< "$out" || fail "an unrelated image should still be prunable: $out"
echo "  recovery-point image protected; unrelated image still prunable"

echo "== 5. recovery_point_image_ids reads every .recovery file =="
mkmeta "$FULL_B"
cat > "$TMP_DIR/meta/second.recovery" <<EOF
CONTAINER_1_SERVICE='kavita'
CONTAINER_1_IMAGE_ID='$FULL_C'
CONTAINER_2_SERVICE='kavita-sidecar'
CONTAINER_2_IMAGE_ID='$FULL_A'
EOF
out="$(probe 'recovery_point_image_ids')"
for f in "$FULL_A" "$FULL_B" "$FULL_C"; do
  grep -qx "$f" <<< "$out" || fail "recovery_point_image_ids missed $f (multi-file, multi-container): $out"
done
echo "  3 ids across 2 files and CONTAINER_1/CONTAINER_2"

echo "== 6. no recovery metadata at all is not an error =="
mkmeta ""
out="$(probe 'recovery_point_image_ids; echo RC=$?')"
grep -q 'RC=0' <<< "$out" || fail "an empty metadata directory must not fail: $out"
rm -rf "${TMP_DIR:?}/meta"
out="$(probe 'recovery_point_image_ids; echo RC=$?')"
grep -q 'RC=0' <<< "$out" || fail "a MISSING metadata directory must not fail: $out"
echo "  empty and missing both return 0"

echo "== 7. the operator is told what was protected =="
mkmeta "$FULL_B"
out="$(probe 'cleanup_images_execute 1 0')"
grep -q 'Protected from cleanup' <<< "$out" \
  || fail "the dry run does not say what it protected. A deletion tool that silently
omits things gives no way to notice the protection stopped working: $out"
grep -q 'recovery point pairs with it' <<< "$out" \
  || fail "the recovery-point protection is not explained: $out"
echo "  reported: $(grep -o 'Protected from cleanup.*' <<< "$out" | cut -c1-62)"

echo "== 8. --confirm is still required =="
mkmeta ""
grep -q 'Refusing destructive cleanup without --confirm' "$CLI" \
  || fail "the --confirm guard is gone"
fn="$(awk '/^cleanup_images_execute\(\) \{/,/^\}/' "$CLI")"
c_line="$(grep -n 'Refusing destructive cleanup' <<< "$fn" | head -1 | cut -d: -f1)"
r_line="$(grep -n 'docker image rm' <<< "$fn" | head -1 | cut -d: -f1)"
[ -n "$c_line" ] && [ -n "$r_line" ] || fail "could not locate the guard and the removal"
[ "$c_line" -lt "$r_line" ] \
  || fail "the --confirm guard (line $c_line) comes AFTER docker image rm (line $r_line)"
echo "  guard at relative line $c_line precedes the removal at $r_line"

echo "== 9. cleanup images is not on any timer =="
# It deletes. It must stay operator-initiated.
for t in "$REPO_ROOT"/systemd/*.service; do
  grep -q 'cleanup' "$t" 2>/dev/null \
    && fail "$(basename "$t") invokes cleanup; a deleting path must not be scheduled"
done
echo "  no unit invokes cleanup"

echo "PASS: cleanup image protection smoke test"
