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

# The command prints each candidate as "<full-id> [tags]"; the selector prints a
# bare id. `grep -qx "<id>"` against COMMAND output can never match, so an
# absence assertion written that way is vacuously true -- three of the cases
# below were, until this helper replaced them.
cmd_lists_candidate() {  # $1 = full image id, $2 = command output
  grep -qE "^$1( |\$)" <<< "$2"
}

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
    "image inspect $FULL_A"|"image inspect $FULL_B"|"image inspect $FULL_C") return 0 ;;
    "image inspect --format {{.Size}}"*) printf '1000\n' ;;
    "image inspect --format {{.RepoTags}}"*) printf '[]\n' ;;
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

echo "== 7. the dry run reports the recovery SET and what it withheld =="
mkmeta "$FULL_B"
out="$(probe 'cleanup_images_execute 1 0')"
# Structured facts, not prose: the set size, the named id, and the per-reason
# tally. Asserting on a summary sentence is how a reworded line aborted a correct
# migration in this project, and it is what broke this very case when the wording
# changed one commit ago.
grep -qE 'name[s]? 1 image\(s\)' <<< "$out" \
  || fail "the recovery-image SET SIZE is not reported: $out"
grep -q "${FULL_B:0:19}" <<< "$out" || fail "the named image id is not shown: $out"
grep -qE 'named by a recovery point' <<< "$out" \
  || fail "the per-reason tally does not mention the recovery rule: $out"
cmd_lists_candidate "$FULL_B" "$out" && fail "the withheld image appears as a candidate: $out"
echo "  set size, id and per-reason tally all present"

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

# ---------------------------------------------------------------------------
# Everything above tests the SELECTOR. The production dry run disagreed with a
# selector-level probe, so from here the tests drive the COMMAND.
#
# What happened: the probe stubbed snapshot_metadata_dir to a fixture directory
# and reported "protected" as production evidence. The real `cleanup images` then
# printed "0 named by a recovery point", because that line counted candidates
# BLOCKED by that reason -- genuinely 0, since the only recovery-named image that
# is also a candidate is plex's, and `in-use` was checked first and won. The line
# could not distinguish "no recovery metadata exists" from "nothing reached this
# branch", so neither reading could be ruled out. A safety report that cannot be
# falsified is not a safety report.
cmd_probe() {  # $1 = extra shell; drives cleanup_cmd, i.e. the real dispatch
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    cat <<STUB
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
ensure_state_dirs() { :; }
docker() {
  case "\$*" in
    "images --filter dangling=true -q") printf '%s\n%s\n%s\n' $SHORT_A $SHORT_B $SHORT_C ;;
    "ps -aq") printf 'cid-a\n' ;;
    "inspect --format {{.Image}} cid-a") printf '%s\n' $FULL_A ;;
    "image inspect -f {{.Id}} $SHORT_A"|"image inspect -f {{.Id}} $FULL_A") printf '%s\n' $FULL_A ;;
    "image inspect -f {{.Id}} $SHORT_B"|"image inspect -f {{.Id}} $FULL_B") printf '%s\n' $FULL_B ;;
    "image inspect -f {{.Id}} $SHORT_C"|"image inspect -f {{.Id}} $FULL_C") printf '%s\n' $FULL_C ;;
    "image inspect $FULL_A"|"image inspect $FULL_B"|"image inspect $FULL_C") return 0 ;;
    "image inspect --format {{.Size}}"*) printf '1000\n' ;;
    "image inspect --format {{.RepoTags}}"*) printf '[]\n' ;;
    *) return 1 ;;
  esac
}
rollback_entries() { :; }
snapshot_metadata_dir() { printf '%s' "$TMP_DIR/meta"; }
STUB
    printf '%s\n' "$1"
  } > "$TMP_DIR/cmd.sh"
  bash "$TMP_DIR/cmd.sh" 2>/dev/null
}

echo "== 10. COMMAND LEVEL: the dry run distinguishes the two cases =="
# No metadata at all.
mkmeta ""
out="$(cmd_probe 'cleanup_cmd images')"
grep -q 'No recovery point names any image' <<< "$out" \
  || fail "with no metadata the command must say so explicitly, not print a bare 0: $out"
# Metadata naming an image that is NOT in use -- the post-upgrade state.
mkmeta "$FULL_B"
out="$(cmd_probe 'cleanup_cmd images')"
grep -qE 'Recovery points name 1 image\(s\); 1 present' <<< "$out" \
  || fail "the recovery SET is not reported independently of what it blocked: $out"
grep -q "names ${FULL_B:0:19}" <<< "$out" || fail "the named image is not listed: $out"
grep -qE 'named by a recovery point \(0 by both\)' <<< "$out" \
  || fail "an image protected ONLY by metadata was not attributed to that rule: $out"
cmd_lists_candidate "$FULL_B" "$out" && fail "the protected image still appears as a candidate: $out"
echo "  no-metadata and metadata cases give different, unambiguous output"

echo "== 11. an image protected by BOTH rules is counted in both =="
# This is the plex case, and first-match-wins is what hid it in production.
mkmeta "$FULL_A"
out="$(cmd_probe 'cleanup_cmd images')"
grep -qE 'in use by a container, 1 named by a recovery point \(1 by both\)' <<< "$out" \
  || fail "an image that is BOTH in use and recovery-named must be counted in both,
or the report cannot show that the recovery rule is working: $out"
echo "  reported as in-use AND recovery-point (1 by both)"

echo "== 12. several points naming the same image, and several images =="
mkmeta "$FULL_B"
cat > "$TMP_DIR/meta/second.recovery" <<EOF
CONTAINER_1_SERVICE='plex'
CONTAINER_1_IMAGE_ID='$FULL_B'
EOF
cat > "$TMP_DIR/meta/third.recovery" <<EOF
CONTAINER_1_SERVICE='kavita'
CONTAINER_1_IMAGE_ID='$FULL_C'
EOF
out="$(cmd_probe 'cleanup_cmd images')"
grep -qE 'Recovery points name 3 image\(s\)' <<< "$out" \
  || fail "two points naming one image plus one naming another should report 3 pairs: $out"
for f in "$FULL_B" "$FULL_C"; do
  cmd_lists_candidate "$f" "$out" && fail "$f is recovery-named and must not be a candidate: $out"
done
echo "  3 pairs, both images withheld"

echo "== 13. a recorded image that is GONE is reported honestly =="
mkmeta "sha256:dddddddddddd4444444444444444444444444444444444444444444444444444"
out="$(cmd_probe 'cleanup_cmd images')"
grep -qE 'name 1 image\(s\); 0 present' <<< "$out" \
  || fail "an image the host no longer has must be counted as not present: $out"
grep -q 'NOT present locally' <<< "$out" \
  || fail "it must be flagged, not silently counted as protected: $out"
echo "  reported as named but NOT present locally"

echo "== 14. metadata with no image identity invents no protection =="
# jellyfin and kavita were migrated before recovery metadata existed; a point
# without an image id must not protect anything.
rm -rf "${TMP_DIR:?}/meta"; mkdir -p "$TMP_DIR/meta"
cat > "$TMP_DIR/meta/historical.recovery" <<EOF
FORMAT='1'
SERVICE='jellyfin'
RECOVERY_POINT='historical'
CONTAINER_1_SERVICE='jellyfin'
CONTAINER_1_IMAGE_IDENTITY='unknown'
EOF
out="$(cmd_probe 'cleanup_cmd images')"
grep -q 'No recovery point names any image' <<< "$out" \
  || fail "a point with no CONTAINER_n_IMAGE_ID must name nothing: $out"
echo "  historical point without an image id protects nothing"

echo "== 15. SHA-looking text in the wrong key protects nothing =="
rm -rf "${TMP_DIR:?}/meta"; mkdir -p "$TMP_DIR/meta"
cat > "$TMP_DIR/meta/bogus.recovery" <<EOF
SERVICE='plex'
NOTE='$FULL_B was running at the time'
CONTAINER_1_CONFIG_DIGEST='$FULL_C'
EOF
out="$(cmd_probe 'cleanup_cmd images')"
grep -q 'No recovery point names any image' <<< "$out" \
  || fail "only CONTAINER_n_IMAGE_ID may confer protection: $out"
cmd_lists_candidate "$FULL_B" "$out" || fail "$FULL_B should still be a candidate: $out"
echo "  only CONTAINER_n_IMAGE_ID confers protection"

echo "== 16. malformed metadata fails safe, not open =="
rm -rf "${TMP_DIR:?}/meta"; mkdir -p "$TMP_DIR/meta"
printf 'CONTAINER_1_IMAGE_ID=%s\n' "$FULL_B" > "$TMP_DIR/meta/unquoted.recovery"   # no quotes
printf '\x00\x01binary garbage\n' > "$TMP_DIR/meta/garbage.recovery"
out="$(cmd_probe 'cleanup_cmd images; echo RC=$?')"
grep -q 'RC=0' <<< "$out" || fail "malformed metadata must not crash the command: $out"
# An unquoted value does not match the writer's format, so it must NOT protect --
# failing safe here means "not protected", which is visible, rather than silently
# treating arbitrary text as an image id.
cmd_lists_candidate "$FULL_B" "$out" \
  || fail "an unquoted value matched the parser; only the writer's exact format
may confer protection, or arbitrary text could suppress cleanup: $out"
echo "  survives garbage; non-conforming values confer nothing"

echo "PASS: cleanup image protection smoke test"
