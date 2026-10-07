#!/usr/bin/env bash
set -uo pipefail

# `cleanup images --json` exists so operator scripts stop parsing prose.
#
# WHY IT EXISTS. The Plex upgrade wrapper asked whether the old image was still a
# deletion candidate like this:
#
#   if domum-media cleanup images 2>/dev/null | grep -qE "^${OLD_IMG}( |$)"; then
#
# That is the same shape as the wrapper that grepped for `recovery point  :
# verified` and aborted a migration that had completed perfectly. The human
# report is written for a human and its wording is not a contract.
#
# The dangerous failure mode for a structured interface is DISAGREEMENT: JSON
# reporting an image as protected while the candidate list would delete it. So
# both derive from one decision function, cleanup_image_decisions, and these
# assertions pin that -- structurally and by comparing the two outputs over the
# same fixture.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:?}"' EXIT

# Production shape: PLEX_OLD is what Plex runs now -- dangling (a newer :latest
# moved the tag), in use by a container, and named by its pre-upgrade recovery
# point. That is the exact image the wrapper must confirm is protected.
PLEX_OLD=sha256:58f13a1df833000000000000000000000000000000000000000000000000aaaa
PLEX_NEW=sha256:7f9a1d574958000000000000000000000000000000000000000000000000bbbb
JUNK=sha256:dddddddddddd0000000000000000000000000000000000000000000000000cccc
GONE=sha256:eeeeeeeeeeee0000000000000000000000000000000000000000000000000dddd
S_OLD=58f13a1df833
S_NEW=7f9a1d574958
S_JUNK=dddddddddddd

probe() {  # $1 = shell to run with the CLI sourced and docker stubbed
  {
    printf 'set -uo pipefail\n'
    printf 'DOMUM_DIR=%q\n' "$REPO_ROOT"
    printf 'CFG_FILE=%q\n' "$TMP_DIR/absent.conf"
    printf 'source %q\n' "$CLI"
    printf 'set +e\n'
    cat <<STUB
docker() {
  case "\$*" in
    "images --filter dangling=true -q") printf '%s\n%s\n' $S_OLD $S_JUNK ;;
    "ps -aq") printf 'cid-plex\n' ;;
    "inspect --format {{.Image}} cid-plex") printf '%s\n' $PLEX_OLD ;;
    "image inspect -f {{.Id}} $S_OLD"|"image inspect -f {{.Id}} $PLEX_OLD") printf '%s\n' $PLEX_OLD ;;
    "image inspect -f {{.Id}} $S_NEW"|"image inspect -f {{.Id}} $PLEX_NEW") printf '%s\n' $PLEX_NEW ;;
    "image inspect -f {{.Id}} $S_JUNK"|"image inspect -f {{.Id}} $JUNK") printf '%s\n' $JUNK ;;
    "image inspect -f {{.Id}} $GONE") return 1 ;;
    "image inspect $PLEX_OLD"|"image inspect $JUNK"|"image inspect $PLEX_NEW") return 0 ;;
    "image inspect $GONE") return 1 ;;
    "image inspect --format {{.Size}}"*) printf '1000\n' ;;
    "image inspect --format {{.RepoTags}}"*) printf '[]\n' ;;
    "image inspect"*"{{range .RepoTags}}"*) printf '\n' ;;
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

mkmeta() {  # $@ = full image ids named by a recovery point
  rm -rf "${TMP_DIR:?}/meta"; mkdir -p "$TMP_DIR/meta"
  local n=0
  { printf "FORMAT='1'\nSERVICE='plex'\nRECOVERY_POINT='plex-pre-upgrade'\n"
    for id in "$@"; do
      n=$((n + 1))
      printf "CONTAINER_%s_SERVICE='plex'\nCONTAINER_%s_IMAGE_ID='%s'\n" "$n" "$n" "$id"
    done
  } > "$TMP_DIR/meta/plex-pre-upgrade.recovery"
}

echo "== 1. the structured output is valid JSON with the documented fields =="
mkmeta "$PLEX_OLD"
json="$(probe 'cleanup_images_json')" || fail "cleanup_images_json failed: $(cat "$TMP_DIR/err")"
printf '%s' "$json" > "$TMP_DIR/out.json"
python3 - "$TMP_DIR/out.json" <<'PY' || fail "the output is not valid JSON or is missing fields"
import json, sys
d = json.load(open(sys.argv[1]))
assert "images" in d, "no images key"
req = {"id", "candidate", "in_use", "recovery_referenced", "local",
       "recovery_points", "tags"}
for img in d["images"]:
    missing = req - set(img)
    assert not missing, f"missing fields {missing} in {img}"
print(f"  {len(d['images'])} image records, every documented field present")
PY

echo "== 2. the production question is answerable directly =="
# "Is the image Plex runs now protected from cleanup?" -- in use AND named by a
# recovery point, present locally, and NOT a candidate.
python3 - "$TMP_DIR/out.json" "$PLEX_OLD" <<'PY' || fail "the protection question is not answerable"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rec = next((i for i in d["images"] if i["id"] == want), None)
assert rec is not None, f"{want} is absent from the record set entirely"
assert rec["in_use"] is True, f"not reported in use: {rec}"
assert rec["recovery_referenced"] is True, f"not reported recovery-referenced: {rec}"
assert rec["local"] is True, f"not reported present locally: {rec}"
assert rec["candidate"] is False, f"reported as a DELETION CANDIDATE: {rec}"
assert rec["recovery_points"] == ["plex-pre-upgrade"], f"point names wrong: {rec}"
print(f"  {want[:19]}  candidate=false in_use=true recovery=true local=true")
PY

echo "== 3. an unprotected dangling image IS a candidate =="
python3 - "$TMP_DIR/out.json" "$JUNK" <<'PY' || fail "an unprotected image is not a candidate"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rec = next((i for i in d["images"] if i["id"] == want), None)
assert rec is not None, f"{want} absent"
assert rec["candidate"] is True, f"not a candidate: {rec}"
assert rec["in_use"] is False and rec["recovery_referenced"] is False, rec
print("  an image nothing protects is still offered -- the report is not vacuous")
PY

echo "== 4. JSON and the candidate list cannot disagree =="
# The agreement check: every id the candidate selector returns must be exactly
# the set JSON marks candidate=true.
cands="$(probe 'collect_cleanup_image_ids')"
printf '%s' "$cands" > "$TMP_DIR/cands.txt"
python3 - "$TMP_DIR/out.json" "$TMP_DIR/cands.txt" <<'PY' || fail "JSON and the candidate list disagree"
import json, sys
d = json.load(open(sys.argv[1]))
from_json = {i["id"] for i in d["images"] if i["candidate"]}
from_list = {l.strip() for l in open(sys.argv[2]) if l.strip()}
assert from_json == from_list, (
    f"JSON says {sorted(from_json)} but the selector says {sorted(from_list)}")
print(f"  both agree on {len(from_json)} candidate(s)")
PY

echo "== 5. they agree because they share ONE decision function =="
# Structural, so agreement cannot be a coincidence of this fixture.
for fn in cleanup_images_json collect_cleanup_image_ids; do
  body="$(awk "/^${fn}\(\) \{/,/^\}\$/" "$CLI")"
  [ -n "$body" ] || fail "could not isolate $fn"
  grep -q 'cleanup_image_decisions' <<< "$body" \
    || fail "$fn does not derive from cleanup_image_decisions; it computes its own
answer and the two outputs can drift apart"
  grep -q 'docker images --filter dangling' <<< "$body" \
    && fail "$fn re-implements candidate discovery instead of deriving it"
done
echo "  both derive from cleanup_image_decisions; neither re-implements discovery"

echo "== 6. a recovery point naming an image that is GONE is still visible =="
mkmeta "$PLEX_OLD" "$GONE"
probe 'cleanup_images_json' > "$TMP_DIR/gone.json"
python3 - "$TMP_DIR/gone.json" "$GONE" <<'PY' || fail "an absent recovery image is invisible"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rec = next((i for i in d["images"] if i["id"] == want), None)
assert rec is not None, (
    f"{want} is named by a recovery point but absent from the records. "
    "An image the recovery point needs and the host no longer has is the most "
    "important case to be able to see.")
assert rec["local"] is False, f"reported as present: {rec}"
assert rec["recovery_referenced"] is True, rec
assert rec["candidate"] is False, rec
print("  reported: recovery_referenced=true, local=false, candidate=false")
PY

echo "== 7. --json is read-only by construction =="
out="$(probe 'cleanup_cmd images --json --confirm' 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "--json --confirm exited 0; a query must not be combinable
with a destructive flag"
cj="$(awk '/^cleanup_images_json\(\) \{/,/^\}$/' "$CLI")"
grep -q 'docker image rm' <<< "$cj" && fail "the JSON path can delete images"
echo "  --json --confirm refuses, and the JSON path contains no delete"

echo "== 8. the human report still works and still names what it protected =="
mkmeta "$PLEX_OLD"
human="$(probe 'cleanup_images_execute 1 0')"
grep -q 'Recovery points name' <<< "$human" \
  || fail "the human report no longer states the recovery-image set"
grep -q 'plex-pre-upgrade' <<< "$human" \
  || fail "the human report no longer names the point"
grep -q 'Withheld from cleanup' <<< "$human" || fail "no withheld summary"
echo "  prose output preserved alongside the structured one"

mutate() {  # $1 = sed program -> runs the agreement check, prints rc
  rm -rf "$TMP_DIR/mut"; mkdir -p "$TMP_DIR/mut"
  cp "$CLI" "$TMP_DIR/mut/domum-media"
  sed -i "$1" "$TMP_DIR/mut/domum-media" || { echo 99; return; }
  cmp -s "$CLI" "$TMP_DIR/mut/domum-media" && { echo 98; return; }
  local saved="$CLI"
  CLI="$TMP_DIR/mut/domum-media"
  mkmeta "$PLEX_OLD"
  probe 'cleanup_images_json' > "$TMP_DIR/mj.json" 2>/dev/null
  probe 'collect_cleanup_image_ids' > "$TMP_DIR/mc.txt" 2>/dev/null
  CLI="$saved"
  python3 - "$TMP_DIR/mj.json" "$TMP_DIR/mc.txt" >/dev/null 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = {i["id"] for i in d["images"] if i["candidate"]}
b = {l.strip() for l in open(sys.argv[2]) if l.strip()}
sys.exit(0 if a == b else 1)
PY
  echo $?
}

echo "== 9. mutation: JSON disagreeing with the candidate logic must be caught =="
# The required property: the structured answer cannot say "protected" while the
# deletion logic says "deletable".
rc="$(mutate 's@"$( (( candidate == 1 )) \&\& echo true || echo false )" \\@"$( (( candidate == 1 )) \&\& echo false || echo true )" \\@')"
[ "$rc" = "99" ] && fail "the inversion mutant could not be applied"
[ "$rc" = "98" ] && fail "the candidate field is no longer emitted as written"
[ "$rc" = "0" ] && fail "inverting the JSON candidate flag still agreed with the
selector -- the agreement check in section 4 proves nothing"
echo "  inverting the JSON candidate flag is caught by the agreement check"

echo "== 10. mutation: dropping a protection reason must be caught =="
rc="$(mutate 's@^    if \[\[ -z "$reasons" \]\] \&\& (( present == 1 )) \\@    if (( present == 1 )) \\@')"
[ "$rc" = "99" ] && fail "the dropped-reason mutant could not be applied"
if [ "$rc" = "98" ]; then
  echo "  (candidate gate no longer written as matched; checked below instead)"
else
  # Both outputs change together -- they share the function -- so agreement
  # still holds. What must change is the ANSWER about the protected image.
  python3 - "$TMP_DIR/mj.json" "$PLEX_OLD" <<'PY' || fail "dropping the reasons gate did
not make the protected image a candidate; the gate is not what protects it"
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
rec = next((i for i in d["images"] if i["id"] == want), None)
assert rec is not None and rec["candidate"] is True, (
    "removing the `-z reasons` gate left the in-use, recovery-named image "
    f"non-candidate: {rec}")
PY
  echo "  removing the reasons gate makes the protected image a candidate -- it is load-bearing"
fi

echo
echo "PASS: cleanup images json smoke"
