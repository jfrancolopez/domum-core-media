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

# Make the host unreachable. Any code path that tries to read the real Immich
# database must FAIL here rather than quietly succeed: an earlier revision of
# this suite reached production and reported its 23,033 assets from inside a
# fixture library.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<'NODOCKER'
#!/usr/bin/env bash
echo "docker is deliberately unavailable in this test" >&2
exit 127
NODOCKER
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

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
# Stands in for the Immich asset table. It lists the fixture's media files and
# deliberately does NOT list the .immich marker, because the asset table does
# not list markers -- which is exactly why the marker can no longer be sampled.
immich_db_original_paths() {
  find "$IMMICH_LIBRARY_DIR" -type f ! -name '.immich' 2>/dev/null | sort
}
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

# Selection skips already-proven originals, so any section that wants a fresh
# selection must clear the durable history first. Sections testing accumulation
# deliberately do not.
reset_sample_history() {
  rm -f "$TMP_DIR/state/restore-verification/cloud-sample-verified.jsonl"
}

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
# Selection and coverage are pure functions of an INVENTORY file. Production
# builds it from the Immich asset table; tests build it by walking, which is
# what inventory_from_dir exists for.
_inv() { local f; f=\"\$(mktemp)\"; inventory_from_dir \"\$1\" \"\$f\"; printf '%s' \"\$f\"; }
$1
"
}

# ---------------------------------------------------------------------------
# 1. Selection is deterministic and diverse, and honours the per-file cap.
# ---------------------------------------------------------------------------
sel1="$(harness 'sample_select_paths "$(_inv "$IMMICH_LIBRARY_DIR")" 7')" \
  || fail "sample_select_paths failed"
sel2="$(harness 'sample_select_paths "$(_inv "$IMMICH_LIBRARY_DIR")" 7')"
[[ "$sel1" == "$sel2" ]] || fail "selection is not deterministic"

grep -q 'huge.mp4' <<< "$sel1" && fail "a file above the per-file cap was selected: $sel1"

for ext in heic mov jpeg dng png; do
  grep -q "\.$ext\$" <<< "$sel1" \
    || fail "media type '$ext' is absent from a 7-file sample of 6 types: $sel1"
done

# ---------------------------------------------------------------------------
# 2. A faithful restore verifies, and the manifest carries the evidence.
# ---------------------------------------------------------------------------
reset_sample_history
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
reset_sample_history
out="$(harness 'RESTORE_CORRUPT=1; do_verify_sample cloud 7' 2>&1)"
rc=$?
(( rc != 0 )) || fail "a corrupted restore was reported as verified: $out"
grep -qi 'mismatch' <<< "$out" || fail "failure did not name the mismatch: $out"
grep -q 'MISMATCH' "$MANIFEST" || fail "the mismatch was not recorded in the manifest"

# ---------------------------------------------------------------------------
# 4. The total-byte cap is enforced, not just the per-file cap.
# ---------------------------------------------------------------------------
reset_sample_history
out="$(harness 'SAMPLE_MAX_TOTAL_BYTES=2600; do_verify_sample cloud 7' 2>&1)" \
  || fail "verify-sample failed under a tight total cap: $out"
total="$(jq -s 'map(.size_bytes) | add' "$MANIFEST")"
(( total <= 2600 )) || fail "the total-byte cap was exceeded: $total"

# ---------------------------------------------------------------------------
# 5. Scratch space may never live inside a live data root.
# ---------------------------------------------------------------------------
reset_sample_history
out="$(harness 'DOMUM_STATE_ROOT="$DOMUM_DATA_ROOT/state"; do_verify_sample cloud 2' 2>&1)"
rc=$?
(( rc != 0 )) || fail "scratch inside the data root was permitted"
grep -qi 'live data root' <<< "$out" || fail "refusal did not explain itself: $out"

# ---------------------------------------------------------------------------
# 6. Sampling must cover ORIGINALS, not derived files.
#
# The Immich library root is not a directory of originals. It holds upload/ (the
# originals), thumbs/ (32,295 generated previews), encoded-video/ (9,029
# transcodes), and backups/ (database dumps). Sampling the whole tree meant
# "a deterministic sample of real Immich originals" was mostly thumbnails,
# transcodes and a .sql.gz -- derived data Immich regenerates, spending the
# sample budget on files whose loss costs nothing.
# ---------------------------------------------------------------------------
LIB2="$TMP_DIR/library2"
mkdir -p "$LIB2/upload/aa" "$LIB2/thumbs/bb" "$LIB2/encoded-video/cc" "$LIB2/backups"
for i in 1 2 3 4 5 6; do head -c 900 /dev/urandom > "$LIB2/upload/aa/orig$i.heic"; done
head -c 900 /dev/urandom > "$LIB2/upload/aa/orig.mov"
for i in 1 2 3 4 5 6 7 8; do head -c 900 /dev/urandom > "$LIB2/thumbs/bb/thumb$i.jpeg"; done
head -c 900 /dev/urandom > "$LIB2/encoded-video/cc/transcode.mp4"
head -c 900 /dev/urandom > "$LIB2/backups/dump.sql.gz"

# The asset table decides what is an original -- not the directory a file
# sits in. That is the whole point: a motion-photo original lives UNDER
# encoded-video/ and must be sampleable, while a transcode sitting beside it
# must never be. A walk of upload/ got both of those wrong at once.
LIB2_MP="$LIB2/encoded-video/aa/bb/676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4"
mkdir -p "$(dirname "$LIB2_MP")"
head -c 700 /dev/urandom > "$LIB2_MP"

cat > "$TMP_DIR/dbstub.sh" <<STUB
# Stands in for the asset table: upload/ originals plus one motion-photo
# original under encoded-video/. Nothing generated is listed, because the
# asset table does not list generated files.
immich_db_original_paths() {
  printf '%s\n' \\
    '$LIB2/upload/a/one.heic' \\
    '$LIB2/upload/a/two.mov' \\
    '$LIB2_MP'
}
STUB

run2() {
  bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_MEDIA_ROOT='$TMP_DIR/mediaroot'
IMMICH_LIBRARY_DIR='$LIB2'
SAMPLE_MAX_FILE_BYTES=100000
SAMPLE_MAX_TOTAL_BYTES=10000000
source '$REPO_ROOT/bin/domum-media-backup'
source '$TMP_DIR/dbstub.sh'
$1
"
}

mkdir -p "$LIB2/upload/a"
head -c 500 /dev/urandom > "$LIB2/upload/a/one.heic"
head -c 600 /dev/urandom > "$LIB2/upload/a/two.mov"

inv_counts="$(run2 'inv=$(mktemp); immich_original_inventory "$inv"; cat "$inv"')" \
  || fail "building the inventory from the asset table failed"
[[ "$(head -1 <<< "$inv_counts")" == "3 0" ]] \
  || fail "expected 3 originals and 0 missing, got: $(head -1 <<< "$inv_counts")"

sel="$(run2 'inv=$(mktemp); immich_original_inventory "$inv" >/dev/null; sample_select_paths "$inv" 8')"
[[ -n "$sel" ]] || fail "nothing was selected from the asset table"
grep -q '/upload/' <<< "$sel" || fail "the sample did not include upload/ originals: $sel"
grep -q -- '-MP.mp4' <<< "$sel" \
  || fail "the motion-photo ORIGINAL under encoded-video/ was not sampleable: $sel"
grep -q '/thumbs/' <<< "$sel" && fail "a generated thumbnail was sampled as an original: $sel"
grep -q '/backups/' <<< "$sel" && fail "a database dump was sampled as an original: $sel"
grep -qE '/encoded-video/.*[0-9a-f]\.mp4' <<< "$sel" \
  && fail "a transcode was sampled as an original: $sel"
grep -q '\.immich' <<< "$sel" && fail "an .immich marker was sampled as an original: $sel"

# A path the asset table names but that is NOT on disk must be counted as
# missing, not silently dropped: it is an original with no backup.
cat > "$TMP_DIR/dbstub.sh" <<STUB
immich_db_original_paths() {
  printf '%s\n' '$LIB2/upload/a/one.heic' '$LIB2/upload/a/GONE.heic'
}
STUB
miss="$(run2 'inv=$(mktemp); immich_original_inventory "$inv"')"
[[ "$miss" == "2 1" ]] || fail "a missing original was not counted: got '$miss'"

# And with no asset table at all it must REFUSE, not fall back to a walk.
cat > "$TMP_DIR/dbstub.sh" <<'STUB'
immich_db_original_paths() { return 1; }
STUB
out="$(run2 'do_sample_plan 4' 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] || fail "with no asset table the plan must refuse, it exited 0: $out"
grep -q 'asset table could not be read' <<< "$out" \
  || fail "the refusal does not name the cause: $out"
grep -q 'marker' <<< "$out" \
  || fail "the refusal does not say why a walk is not an acceptable substitute: $out"

# The plan command itself must sample originals, and must say plainly that it
# is a plan. Exercising only sample_select_paths left do_sample_plan free to
# pass the whole library root -- a mutation doing exactly that survived until
# this was added.
# Clear any manifest an earlier assertion left behind, or "a plan records
# nothing" would be checking someone else's file.
rm -f "$TMP_DIR/state/restore-verification/cloud-sample.jsonl"
# Restore the LIB2 asset-table stub: the section above deliberately broke it to
# prove the plan REFUSES without one.
cat > "$TMP_DIR/dbstub.sh" <<STUB
immich_db_original_paths() {
  printf '%s\n' \\
    '$LIB2/upload/a/one.heic' \\
    '$LIB2/upload/a/two.mov' \\
    '$LIB2_MP'
}
STUB
plan_out="$(run2 'do_sample_plan 8' 2>&1)" || fail "sample-plan failed: $plan_out"

# The plan states its population AND where those originals live, so a reader
# can see that encoded-video/ contributes originals rather than assuming every
# original sits under upload/.
grep -q 'Sample plan over 3 original(s)' <<< "$plan_out" \
  || fail "sample-plan did not state its population: $plan_out"
grep -qE '2 under upload/' <<< "$plan_out" \
  || fail "sample-plan did not break the population down by location: $plan_out"
grep -qE '1 under encoded-video/' <<< "$plan_out" \
  || fail "sample-plan hid the encoded-video original: $plan_out"
grep -q 'from the Immich asset table' <<< "$plan_out" \
  || fail "sample-plan does not say where its population came from: $plan_out"
# Generated files are absent because the asset table never named them.
grep -q 'thumbs/' <<< "$plan_out" && fail "sample-plan listed a generated thumbnail: $plan_out"
grep -q 'backups/' <<< "$plan_out" && fail "sample-plan listed a database dump: $plan_out"
grep -qE '/encoded-video/.*[0-9a-f]\.mp4' <<< "$plan_out" \
  && fail "sample-plan listed a transcode: $plan_out"

# A plan is not evidence and must never read as one.
grep -qi 'This is a PLAN' <<< "$plan_out" || fail "sample-plan did not say it is a plan: $plan_out"
grep -qi 'Nothing was restored' <<< "$plan_out" || fail "sample-plan did not say it restored nothing"
[[ ! -f "$TMP_DIR/state/restore-verification/cloud-sample.jsonl" ]] \
  || fail "sample-plan wrote a manifest; a plan must record no evidence"

# ---------------------------------------------------------------------------
# COVERAGE: what the sample provably does NOT reach.
#
# The cap is not a detail. Measured on this host, SAMPLE_MAX_FILE_BYTES=256 MiB
# leaves 17 of 22,976 Immich originals outside the sample -- 7.9 GiB, and they
# are the largest videos, exactly what a sample of small photos least
# represents. Before this, the plan and the verification printed the caps but
# never said how many files fell outside, and the recorded evidence carried no
# population at all: "12 sampled, 12 matched" was a coverage claim that could
# not be falsified.
# ---------------------------------------------------------------------------
echo "== coverage: the population and the never-sampled set are counted =="
# The fixture has 9 files; huge.mp4 (40000 b) is the only one over the 10000 cap.
cov="$(harness 'sample_coverage_stats "$(_inv "$IMMICH_LIBRARY_DIR")"')" \
  || fail "sample_coverage_stats failed"
read -r c_tf c_tb c_of c_ob <<< "$cov"
[ "$c_tf" = "9" ] || fail "population is $c_tf file(s), expected 9: [$cov]"
[ "$c_of" = "1" ] || fail "oversize is $c_of file(s), expected 1 (huge.mp4): [$cov]"
[ "$c_ob" = "40000" ] || fail "oversize bytes is $c_ob, expected 40000: [$cov]"
exp_tb=$(( 1000+2000+3000+9000+1500+7000+120+500+40000 ))
[ "$c_tb" = "$exp_tb" ] || fail "population bytes is $c_tb, expected $exp_tb"
echo "  9 file(s) / $exp_tb b; 1 oversize / 40000 b"

echo "== coverage: the oversize file is really unreachable by selection =="
# Not merely counted as excluded -- it must never appear in a selection, even
# when the quota exceeds the number of eligible files.
sel="$(harness 'sample_select_paths "$(_inv "$IMMICH_LIBRARY_DIR")" 99')"
grep -q 'huge.mp4' <<< "$sel" \
  && fail "the oversize file was selected despite the per-file cap"
[ "$(grep -c . <<< "$sel")" = "8" ] \
  || fail "expected all 8 eligible files when the quota exceeds them, got $(grep -c . <<< "$sel")"
echo "  selection returns 8 of 9; huge.mp4 is never reachable"

echo "== coverage: the report block NAMES the gap, and says so in bytes =="
out="$(harness 'sample_report_coverage "$(_inv "$IMMICH_LIBRARY_DIR")" "$IMMICH_LIBRARY_DIR" 0' 2>&1)" \
  || fail "sample_report_coverage failed: $out"
grep -q 'originals    : 9 asset(s)' <<< "$out" || fail "no population line: $out"
grep -q 'from the Immich asset table' <<< "$out" \
  || fail "the population does not state its provenance: $out"
grep -q 'NEVER sampled: 1 file(s)' <<< "$out" || fail "the gap is not stated: $out"
grep -q 'exceed the per-file' <<< "$out" || fail "the reason is not stated: $out"
grep -q 'verify-large' <<< "$out" \
  || fail "it does not say how to close the gap: $out"
echo "  population, never-sampled count, bytes and the remedy all stated"

echo "== coverage: 'none by size' when every file fits =="
# The reassuring answer must be reachable too, or the line is just noise.
out="$(harness 'SAMPLE_MAX_FILE_BYTES=100000; sample_report_coverage "$(_inv "$IMMICH_LIBRARY_DIR")" "$IMMICH_LIBRARY_DIR" 0' 2>&1)"
grep -q 'NEVER sampled: none by size' <<< "$out" \
  || fail "with a cap above every file it did not say the gap is empty: $out"
grep -q 'NEVER sampled: 1 file' <<< "$out" \
  && fail "it still reported an oversize file with a cap above every file"
echo "  states explicitly that nothing is excluded by size"

echo "== coverage: verify-sample RECORDS the population beside the manifest =="
# Earlier sections have already proven files, and selection now SKIPS those, so
# clear the history first: this section is about the coverage artefact's
# contents, not about accumulation.
reset_sample_history
out="$(harness 'do_verify_sample cloud 4' 2>&1)" || fail "verify-sample failed: $out"
cf="$TMP_DIR/state/restore-verification/cloud-coverage.json"
[ -r "$cf" ] || fail "no coverage artefact was written at $cf"
[ "$(stat -c %a "$cf")" = "600" ] || fail "the coverage artefact is mode $(stat -c %a "$cf"), not 600"
jq -e '.population_files == 9 and .oversize_files == 1 and .oversize_bytes == 40000
       and .per_file_cap_bytes == 10000 and .sampled_files == 4' "$cf" >/dev/null \
  || fail "the recorded coverage is wrong: $(cat "$cf")"
grep -q 'coverage : ' <<< "$out" || fail "verify-sample did not name the coverage artefact"
grep -q 'NEVER sampled: 1 file(s)' <<< "$out" \
  || fail "verify-sample did not state the gap: $out"
echo "  recorded 9/1/40000 at mode 600, and named in the output"

echo "== coverage: the report turns it into an unmissable statement =="
# The report must not be able to say "sampled, all matched" without also saying
# what was out of reach.
rep="$(jq -s --argjson coverage "$(jq -c '{population_files,population_bytes,oversize_files,oversize_bytes,per_file_cap_bytes,recorded_at}' "$cf")" \
  '(map(select(.result == "match")) | length) as $ok
   | {sampled_files: length, matched: $ok, coverage: $coverage,
      unsampled_files: ($coverage.population_files - length),
      oversize_files: $coverage.oversize_files,
      reason: (if ($coverage.oversize_files // 0) > 0
               then ($coverage.oversize_files|tostring) + " original(s) exceed the per-file sampling cap and have never been restore-tested"
               else null end)}' \
  "$TMP_DIR/state/restore-verification/cloud-sample.jsonl")"
jq -e '.unsampled_files == 5 and .oversize_files == 1' <<< "$rep" >/dev/null \
  || fail "the report arithmetic is wrong: $rep"
jq -e '.reason | test("never been restore-tested")' <<< "$rep" >/dev/null \
  || fail "the report does not state that the oversize originals are untested: $rep"
echo "  4 sampled of 9; 5 unsampled; 1 never restore-testable -- all stated"

echo "== accumulation: a second run picks DIFFERENT originals =="
# Selection is deterministic by design, which is what makes a run reproducible.
# Measured consequence in production: the 2026-10-09 and 2026-10-11 runs sampled
# the SAME 12 files, so coverage of the main library was capped at 12 of 23,033
# however often the command ran. Already-proven files are now skipped.
reset_sample_history
rm -f "$TMP_DIR/state/restore-verification/cloud-sample.jsonl"
r1="$(harness 'do_verify_sample cloud 3' 2>&1)" || fail "run 1 failed: $r1"
r2="$(harness 'do_verify_sample cloud 3' 2>&1)" || fail "run 2 failed: $r2"
p1="$(grep -oE '[a-z0-9/_.-]+\.(heic|jpeg|jpg|mov|dng|png|mp4|none)$' <<< "$r1" | sort -u)"
p2="$(grep -oE '[a-z0-9/_.-]+\.(heic|jpeg|jpg|mov|dng|png|mp4|none)$' <<< "$r2" | sort -u)"
[[ -n "$p1" && -n "$p2" ]] || fail "could not extract sampled paths"
overlap="$(comm -12 <(printf '%s\n' "$p1") <(printf '%s\n' "$p2") | grep -c . || true)"
[[ "$overlap" -eq 0 ]] \
  || fail "the second run re-proved $overlap already-proven file(s); coverage cannot grow"
echo "  run 2 shares no file with run 1"

echo "== accumulation: the cumulative figure grows and is reported =="
grep -q 'cumulative: 3 of' <<< "$r1" || fail "run 1 did not report 3 cumulative: $r1"
grep -q 'cumulative: 6 of' <<< "$r2" || fail "run 2 did not report 6 cumulative: $r2"
HIST="$TMP_DIR/state/restore-verification/cloud-sample-verified.jsonl"
[[ -f "$HIST" ]] || fail "no sample history was written"
[[ "$(stat -c %a "$HIST")" == "600" ]] || fail "the sample history is not mode 0600"
[[ "$(jq -s 'length' "$HIST")" == "6" ]] || fail "the history should hold 6 records"
echo "  3 then 6, recorded in a 0600 history that selection reads next time"

echo "== accumulation: once everything reachable is proven it says so =="
harness 'do_verify_sample cloud 3' >/dev/null 2>&1
out="$(harness 'do_verify_sample cloud 3' 2>&1)"
grep -q 'nothing left to sample' <<< "$out" \
  || fail "with everything proven it should say so: $out"
grep -q 'verify-large' <<< "$out" \
  || fail "it should point at verify-large for the over-cap files: $out"
grep -q 'match' <<< "$out" && fail "it restored something with nothing left to do"
echo "  no bytes are spent, and it names where the remaining gap lives"

echo "== accumulation: --revalidate deliberately proves them again =="
out="$(harness 'do_verify_sample cloud 3 --revalidate' 2>&1)"
grep -q 'match' <<< "$out" || fail "--revalidate proved nothing: $out"
rp="$(grep -oE '[a-z0-9/_.-]+\.(heic|jpeg|jpg|mov|dng|png|mp4|none)$' <<< "$out" | sort -u)"
same="$(comm -12 <(printf '%s\n' "$p1") <(printf '%s\n' "$rp") | grep -c . || true)"
[[ "$same" -gt 0 ]] || fail "--revalidate did not revisit the first run's files"
echo "  the history is ignored only when explicitly asked"

echo "== accumulation: the plan reflects what would ACTUALLY be picked =="
out="$(harness 'do_sample_plan 3 cloud' 2>&1)"
grep -q 'already proven' <<< "$out" || fail "the plan does not state the proven count: $out"
echo "  the plan reads the same history selection does"

echo "== mutation: ignoring the sample history must re-pick the same files =="
MUTA="$TMP_DIR/mutant-acc"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUTA"
python3 - "$MUTA" <<'PY2'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('if (( reval == 1 )); then : > "$done_file"; else sample_verified_paths "$target" > "$done_file"; fi',
            ': > "$done_file"', 1)
open(p,'w').write(s)
PY2
rm -f "$HIST"
m1="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_MEDIA_ROOT='$TMP_DIR/mediaroot'
IMMICH_LIBRARY_DIR='$LIB'
SAMPLE_MAX_FILE_BYTES=10000
SAMPLE_MAX_TOTAL_BYTES=1000000
source '$MUTA'
source '$TMP_DIR/stubs.sh'
do_verify_sample cloud 3" 2>&1)"
m2="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_MEDIA_ROOT='$TMP_DIR/mediaroot'
IMMICH_LIBRARY_DIR='$LIB'
SAMPLE_MAX_FILE_BYTES=10000
SAMPLE_MAX_TOTAL_BYTES=1000000
source '$MUTA'
source '$TMP_DIR/stubs.sh'
do_verify_sample cloud 3" 2>&1)"
q1="$(grep -oE '[a-z0-9/_.-]+\.(heic|jpeg|jpg|mov|dng|png|mp4|none)$' <<< "$m1" | sort -u)"
q2="$(grep -oE '[a-z0-9/_.-]+\.(heic|jpeg|jpg|mov|dng|png|mp4|none)$' <<< "$m2" | sort -u)"
mov="$(comm -12 <(printf '%s\n' "$q1") <(printf '%s\n' "$q2") | grep -c . || true)"
[[ "$mov" -gt 0 ]] \
  || fail "the mutant's two runs still differ; the history skip is not load-bearing"
echo "  without the skip both runs prove the same files -- coverage frozen at 3"

echo "== mutation: dropping the oversize tally must break the statement =="
mut="$TMP_DIR/mut"; rm -rf "$mut"; mkdir -p "$mut"
cp "$REPO_ROOT/bin/domum-media-backup" "$mut/domum-media-backup"
# Stop counting files above the cap. The population stays right; the gap vanishes.
sed -i 's/if ($1 > cap) { on++; ob += $1 }/if (0) { on++; ob += $1 }/' "$mut/domum-media-backup"
cmp -s "$REPO_ROOT/bin/domum-media-backup" "$mut/domum-media-backup" \
  && fail "the oversize tally is no longer written as matched"
out="$(bash -c "
set -uo pipefail
DOMUM_STATE_ROOT='$TMP_DIR/state2'
DOMUM_DATA_ROOT='$TMP_DIR/data'
DOMUM_MEDIA_ROOT='$TMP_DIR/mediaroot'
IMMICH_LIBRARY_DIR='$LIB'
SAMPLE_MAX_FILE_BYTES=10000
SAMPLE_MAX_TOTAL_BYTES=1000000
source '$mut/domum-media-backup'
source '$TMP_DIR/stubs.sh'
sample_report_coverage \"\$(_inv \"\$IMMICH_LIBRARY_DIR\")\" \"\$IMMICH_LIBRARY_DIR\" 0
" 2>&1)"
grep -q 'NEVER sampled: none by size' <<< "$out" \
  || fail "removing the tally did NOT change the statement, so the assertions above
prove nothing about where the count comes from: $out"
echo "  without the tally it claims nothing is excluded -- the count is load-bearing"

echo "PASS: sample-verification-smoke"
