#!/usr/bin/env bash
set -uo pipefail

# Proves `verify-sample` makes a real, falsifiable claim:
#
#   * selection is deterministic and diverse across media types;
#   * files above the per-file cap and the total cap are excluded;
#   * a byte difference between source and restored content FAILS;
#   * the manifest records the evidence a reader needs to re-check the claim.
#
# Hermetic: no restic, no network, no production paths.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

LIB="$TMP_DIR/library"
mkdir -p "$LIB/a" "$LIB/b"
# Diverse types and sizes, plus one file deliberately over the per-file cap.
mk() { head -c "$2" /dev/urandom > "$LIB/$1"; }
mk a/one.heic   1000
mk a/two.heic   2000
mk a/three.heic 3000
mk a/clip.mov   9000
mk b/pic.jpeg   1500
mk b/raw.dng    7000
mk b/shot.png    120
mk b/noext       500     # no extension at all
mk b/huge.mp4  40000     # over the per-file cap below

# The stubs live in a file so the test never has to nest quoting levels.
cat > "$TMP_DIR/stubs.sh" <<'STUBS'
backup_target_enabled() { return 0; }
log() { :; }
restic_for_target() {
  shift
  case "$1" in
    snapshots) printf '%s' '[{"short_id":"deadbeef"}]' ;;
    restore)
      local tgt=""
      shift
      while (( $# )); do
        case "$1" in
          --target)  tgt="$2"; shift 2 ;;
          --include) mkdir -p "$tgt$(dirname "$2")"; cp -- "$2" "$tgt$2"; shift 2 ;;
          *)         shift ;;
        esac
      done
      if [[ -n "${RESTORE_CORRUPT:-}" ]]; then
        # Append a byte to one restored file: the restore "succeeded" but the
        # bytes differ. Verification must catch exactly this.
        local victim
        victim="$(find "$tgt" -type f | sort | head -1)"
        [[ -n "$victim" ]] && printf 'X' >> "$victim"
      fi
      ;;
  esac
}
STUBS

harness() {
  # $1 = shell code evaluated after the real script and the stubs are loaded
  bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_MEDIA_ROOT='$TMP_DIR/mediaroot'
IMMICH_LIBRARY_DIR='$LIB'
SAMPLE_MAX_FILE_BYTES=10000
SAMPLE_MAX_TOTAL_BYTES=1000000
source '$REPO_ROOT/bin/domum-media-backup'
source '$TMP_DIR/stubs.sh'
$1
"
}

# ---------------------------------------------------------------------------
# 1. Selection is deterministic and diverse, and honours the per-file cap.
# ---------------------------------------------------------------------------
sel1="$(harness 'sample_select_paths "$IMMICH_LIBRARY_DIR" 7')" \
  || fail "sample_select_paths failed"
sel2="$(harness 'sample_select_paths "$IMMICH_LIBRARY_DIR" 7')"
[[ "$sel1" == "$sel2" ]] || fail "selection is not deterministic"

grep -q 'huge.mp4' <<< "$sel1" && fail "a file above the per-file cap was selected: $sel1"

for ext in heic mov jpeg dng png; do
  grep -q "\.$ext\$" <<< "$sel1" \
    || fail "media type '$ext' is absent from a 7-file sample of 6 types: $sel1"
done

# ---------------------------------------------------------------------------
# 2. A faithful restore verifies, and the manifest carries the evidence.
# ---------------------------------------------------------------------------
out="$(harness 'do_verify_sample cloud 7' 2>&1)" \
  || fail "verify-sample failed on an identical restore: $out"

MANIFEST="$TMP_DIR/state/restore-verification/cloud-sample.jsonl"
[[ -f "$MANIFEST" ]] || fail "no manifest was written"
[[ "$(stat -c '%a' "$MANIFEST")" == 600 ]] || fail "manifest must be mode 0600"

n="$(wc -l < "$MANIFEST")"
(( n == 7 )) || fail "expected 7 manifest rows, got $n"

while read -r row; do
  jq -e '
    .snapshot_id == "deadbeef"
    and (.path | startswith("/"))
    and (.media_type | test("^[a-z0-9]+$"))
    and (.size_bytes > 0)
    and (.source_sha256 | length == 64)
    and (.restored_sha256 == .source_sha256)
    and .result == "match"
    and (.verified_at | length > 0)
  ' <<< "$row" >/dev/null || fail "manifest row is missing required evidence: $row"
done < "$MANIFEST"

# Every recorded type must be one of the real types, and at least 5 distinct.
types="$(jq -r '.media_type' "$MANIFEST" | sort -u | tr '\n' ' ')"
(( $(wc -w <<< "$types") >= 5 )) || fail "sample is not diverse: $types"

# An extensionless file must be typed "none" -- never its own path, which would
# both leak the tree into the type column and fake extra diversity.
grep -q '"media_type":"none"' "$MANIFEST" \
  || fail "the extensionless file was not typed as 'none': $types"
jq -e 'select(.media_type | test("/"))' "$MANIFEST" >/dev/null \
  && fail "a media type contains a path separator: $types"

# ---------------------------------------------------------------------------
# 3. Corruption in the restored bytes MUST fail. If this passes, the whole
#    command is decorative.
# ---------------------------------------------------------------------------
out="$(harness 'RESTORE_CORRUPT=1; do_verify_sample cloud 7' 2>&1)"
rc=$?
(( rc != 0 )) || fail "a corrupted restore was reported as verified: $out"
grep -qi 'mismatch' <<< "$out" || fail "failure did not name the mismatch: $out"
grep -q 'MISMATCH' "$MANIFEST" || fail "the mismatch was not recorded in the manifest"

# ---------------------------------------------------------------------------
# 4. The total-byte cap is enforced, not just the per-file cap.
# ---------------------------------------------------------------------------
out="$(harness 'SAMPLE_MAX_TOTAL_BYTES=2600; do_verify_sample cloud 7' 2>&1)" \
  || fail "verify-sample failed under a tight total cap: $out"
total="$(jq -s 'map(.size_bytes) | add' "$MANIFEST")"
(( total <= 2600 )) || fail "the total-byte cap was exceeded: $total"

# ---------------------------------------------------------------------------
# 5. Scratch space may never live inside a live data root.
# ---------------------------------------------------------------------------
out="$(harness 'DOMUM_STATE_ROOT="$DOMUM_DATA_ROOT/state"; do_verify_sample cloud 2' 2>&1)"
rc=$?
(( rc != 0 )) || fail "scratch inside the data root was permitted"
grep -qi 'live data root' <<< "$out" || fail "refusal did not explain itself: $out"

echo "PASS: sample-verification-smoke"
