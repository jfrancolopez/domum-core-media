#!/usr/bin/env bash
set -uo pipefail

# Proves `verify-large` closes the gap the per-file sample cap leaves, WITHOUT
# buying coverage by the gigabyte.
#
# Measured on this host: 17 originals exceed the 256 MiB cap, totalling 7.9 GiB
# (15 .mov, 2 .mp4, 274 MB to 1.38 GB). They are the home videos -- the least
# replaceable files in the library and the least represented by a sample of
# photos. Raising the cap would pull 7.9 GiB from Hetzner on every run to move a
# percentage, so coverage must ACCUMULATE instead: a few files per run, a durable
# record of what is proven, and no file fetched twice unless asked.
#
# Hermetic: the repository is a stub, the host is unreachable, no production path.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"; LIB="$DATA/immich/library"; STATE="$TMP_DIR/state"
mkdir -p "$LIB/upload/aa" "$STATE" "$TMP_DIR/media" "$TMP_DIR/bin"
export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media" DOMUM_STATE_ROOT="$STATE"
export IMMICH_LIBRARY_DIR="$LIB" BACKUP_TARGETS=cloud

cat > "$TMP_DIR/bin/docker" <<'NODOCKER'
#!/usr/bin/env bash
echo "docker is deliberately unavailable in this test" >&2
exit 127
NODOCKER
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

# Four small originals and four "large" ones. The cap is tiny so the real
# selection and budget arithmetic run unchanged on bytes a test can afford.
CAP=1000
BUDGET=5000
mk() { head -c "$2" /dev/urandom > "$LIB/upload/aa/$1"; }
mk small1.heic 100
mk small2.jpg  200
mk big_a.mov   1500
mk big_b.mp4   1600
mk big_c.mov   2500
mk big_d.mov   4000

ORIGINALS="$(printf '%s\n' "$LIB/upload/aa/"{small1.heic,small2.jpg,big_a.mov,big_b.mp4,big_c.mov,big_d.mov})"
printf '%s\n' "$ORIGINALS" > "$TMP_DIR/originals.lst"

run() {  # $1 = extra setup, $2.. = args to do_verify_large
  local setup="$1"; shift
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    die() { echo "DIE: $*"; exit 9; }
    log() { :; }
    backup_target_enabled() { return 0; }
    immich_db_original_paths() { cat "$TMP_DIR/originals.lst"; }
    SAMPLE_MAX_FILE_BYTES="$CAP"
    LARGE_MAX_RUN_BYTES="$BUDGET"
    restic_for_target() {
      shift
      case "$1" in
        snapshots) echo '[{"short_id":"lsnap001"}]' ;;
        restore)
          local t="" prev=""
          for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
          local p
          for a in "$@"; do
            [[ "$prev2" == "--include" ]] && { mkdir -p "$t$(dirname "$a")"; cp -- "$a" "$t$a"; }
            prev2="$a"
          done
          if [[ -n "${RESTORE_CORRUPT:-}" ]]; then
            local victim; victim="$(find "$t" -type f | sort | head -1)"
            [[ -n "$victim" ]] && printf 'X' >> "$victim"
          fi
          ;;
      esac
      return 0
    }
    prev2=""
    [[ -n "$setup" ]] && eval "$setup"
    do_verify_large cloud "$@" 2>&1
    echo "EXITCODE=$?"
  )
}

HIST="$STATE/restore-verification/cloud-large-verified.jsonl"

# ---------------------------------------------------------------------------
sect "the population is exactly the over-cap originals"
out="$(run '' --plan)"
grep -q 'large population : 4 file(s)' <<< "$out" \
  || fail "the large population should be the 4 over-cap files: $out"
grep -q 'small1.heic' <<< "$out" && fail "an under-cap original was treated as large"
echo "  4 of 6 originals are over the cap; the small ones are not listed"

sect "--plan states the byte cost and records NOTHING"
grep -q 'to download' <<< "$out" || fail "the plan does not state bytes: $out"
grep -q 'This is a PLAN' <<< "$out" || fail "the plan does not say it is a plan: $out"
grep -q 'Nothing was restored' <<< "$out" || fail "the plan does not disclaim: $out"
[[ ! -f "$HIST" ]] || fail "--plan wrote a history file"
echo "  bytes stated, nothing restored, no evidence written"

sect "selection covers a new FORMAT before a second file of a proven one"
# Smallest per extension first: big_a.mov (1500) and big_b.mp4 (1600).
grep -q 'big_a.mov' <<< "$out" || fail "the smallest .mov was not chosen first: $out"
grep -q 'big_b.mp4' <<< "$out" || fail "the .mp4 format was not covered: $out"
grep -q 'big_d.mov' <<< "$out" && fail "a 4000-byte file was chosen before the small ones"
echo "  one .mov and one .mp4, smallest of each, so a run stays cheap"

sect "the per-run byte budget defers the rest and says so"
out="$(run '' 4 --plan)"
grep -q 'deferred' <<< "$out" || fail "nothing was deferred despite a 5000-byte budget: $out"
grep -q 'LARGE_MAX_RUN_BYTES' <<< "$out" || fail "the budget knob is not named: $out"
total="$(sed -n 's/.*this run         : [0-9]* file(s), \(.*\) to download/\1/p' <<< "$out")"
[[ -n "$total" ]] || fail "no byte total was printed"
echo "  the budget caps the run and names the knob that would raise it"

sect "a budget smaller than one file still makes progress"
out="$(run 'LARGE_MAX_RUN_BYTES=10' 2 --plan)"
grep -q 'this run         : 1 file(s)' <<< "$out" \
  || fail "a tiny budget blocked all progress instead of allowing one file: $out"
echo "  one file is always allowed, so a small budget cannot deadlock it"

# ---------------------------------------------------------------------------
sect "a real run verifies, records, and reports cumulative coverage"
out="$(run '' 2)"
grep -q 'EXITCODE=0' <<< "$out" || fail "the run failed: $out"
grep -c '  match ' <<< "$out" >/dev/null
[[ "$(grep -c 'match' <<< "$out")" -ge 2 ]] || fail "fewer than 2 matches: $out"
grep -q 'cumulative       : 2 of 4' <<< "$out" || fail "cumulative coverage is wrong: $out"
[[ -f "$HIST" ]] || fail "no history was written"
[[ "$(stat -c %a "$HIST")" == "600" ]] || fail "history is not mode 0600"
[[ "$(jq -s 'length' "$HIST")" == "2" ]] || fail "history should hold 2 records"
echo "  2 of 4 proven, history at 0600 with one record per file"

sect "a proven file is NEVER downloaded again"
out="$(run '' 2)"
grep -q 'big_a.mov' <<< "$out" && fail "an already-proven file was fetched again: $out"
grep -q 'big_c.mov' <<< "$out" || fail "the next unproven file was not chosen: $out"
grep -q 'already proven   : 2 file(s), 3.0 KiB' <<< "$out" \
  || fail "the proven set was not carried forward with its bytes: $out"
# The 5000-byte budget admits big_c (2500) and defers big_d (4000), so this run
# reaches 3 of 4 -- the budget is doing its job, not a shortfall.
grep -q 'cumulative       : 3 of 4' <<< "$out" || fail "coverage did not accumulate: $out"
grep -q 'still unproven; run again' <<< "$out" || fail "it did not say more remains: $out"
echo "  continues where the last run stopped: 3 of 4, the 4th deferred by budget"

sect "a further run finishes the set"
out="$(run '' 2)"
grep -q 'big_d.mov' <<< "$out" || fail "the last file was not chosen: $out"
grep -q 'cumulative       : 4 of 4' <<< "$out" || fail "the set did not complete: $out"
grep -q 'every large original has now been proven' <<< "$out" \
  || fail "completion is not reported: $out"
echo "  4 of 4, and completion is stated"

sect "with everything proven it does nothing rather than re-fetching"
out="$(run '' 2)"
grep -q 'nothing left to verify' <<< "$out" || fail "it did not report completion: $out"
grep -q 'to download' <<< "$out" && fail "it planned a download with nothing left to do"
grep -q 'revalidate' <<< "$out" || fail "it does not mention how to prove them again: $out"
echo "  no bytes are spent once coverage is complete"

sect "--revalidate deliberately proves them again"
out="$(run '' 2 --revalidate)"
grep -q 'already proven   : 0 file(s)' <<< "$out" \
  || fail "--revalidate did not clear the history for selection: $out"
grep -q 'to download' <<< "$out" || fail "--revalidate fetched nothing: $out"
echo "  the history is ignored only when explicitly asked"

# ---------------------------------------------------------------------------
sect "a corrupted large restore FAILS and is recorded as a mismatch"
rm -f "$HIST"
out="$(run 'RESTORE_CORRUPT=1' 2)"
grep -q 'EXITCODE=1' <<< "$out" || fail "a corrupted restore did not exit 1: $out"
grep -q 'MISMATCH' <<< "$out" || fail "the mismatch is not shown: $out"
grep -q 'FAILED -- a large original did not match' <<< "$out" \
  || fail "the failure is not stated: $out"
[[ "$(jq -rs '[.[] | select(.result=="MISMATCH")] | length' "$HIST")" -ge 1 ]] \
  || fail "the mismatch was not recorded in the history"
# And a mismatched file must NOT count as proven on the next run.
out="$(run '' 1 --plan)"
grep -q 'already proven   : 1 file(s)' <<< "$out" \
  || fail "the mismatched file was wrongly counted as proven: $out"
echo "  exit 1, recorded as MISMATCH, and not counted as proven"

# ---------------------------------------------------------------------------
sect "mutation: ignoring the history must re-download a proven file"
rm -f "$HIST"
run '' 2 >/dev/null
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('if (( reval == 1 )); then : > "$done_file"; else large_verified_paths "$target" > "$done_file"; fi',
            ': > "$done_file"', 1)
open(p,'w').write(s)
PY
mout="$(
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  log() { :; }
  backup_target_enabled() { return 0; }
  immich_db_original_paths() { cat "$TMP_DIR/originals.lst"; }
  SAMPLE_MAX_FILE_BYTES="$CAP"
  LARGE_MAX_RUN_BYTES="$BUDGET"
  do_verify_large cloud 2 --plan 2>&1
)"
grep -q 'already proven   : 0 file(s)' <<< "$mout" \
  || fail "the mutant still consulted the history; the skip is not load-bearing"
grep -q 'big_a.mov' <<< "$mout" \
  || fail "the mutant did not re-select an already-proven file: $mout"
echo "  without the history it re-fetches what was already proven"

echo "PASS: large-verification-smoke"
