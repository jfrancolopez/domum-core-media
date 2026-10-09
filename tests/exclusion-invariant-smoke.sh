#!/usr/bin/env bash
set -uo pipefail

# The permanent invariant:
#
#   NO Immich original photo or video may be excluded from the off-site backup.
#
# The derivative exclusion keys off a NAMING CONVENTION -- a transcode is
# <uuid>.mp4, a motion-photo original is <uuid>-MP.mp4 -- and a future Immich
# version may name a new kind of original anything it likes. The convention is
# evidence, not a guarantee. The asset table is the guarantee, so the exclusion
# is re-proven at RUN TIME and dropped when it cannot be proven.
#
# This suite attacks that invariant: it plants real originals inside the
# directories that normally hold only generated files, varies the case, and
# invents plausible future names, then requires the gate to notice every time.
#
# Failing toward MORE backup is safe -- excluding less costs money, never data --
# so the required behaviour is "drop the pattern and say so", never "refuse the
# backup" and never "exclude it anyway".
#
# Hermetic: no restic repository unless one can be created locally, no
# containers, no production paths.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA="$TMP_DIR/data"; LIB="$DATA/immich/library"
mkdir -p "$LIB/upload/aa/bb" "$LIB/encoded-video/cc/dd" "$LIB/thumbs/ee/ff" \
         "$TMP_DIR/media" "$TMP_DIR/bin"
export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export IMMICH_LIBRARY_DIR="$LIB"

# The host must be unreachable: an un-stubbed asset-table call silently queried
# the live production database once already.
cat > "$TMP_DIR/bin/docker" <<'NODOCKER'
#!/usr/bin/env bash
echo "docker is deliberately unavailable in this test" >&2
exit 127
NODOCKER
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

mk() { mkdir -p "$(dirname "$LIB/$1")"; head -c "${2:-64}" /dev/urandom > "$LIB/$1"; printf '%s' "$LIB/$1"; }

# A baseline library: ordinary originals, ordinary derivatives.
ORIG_HEIC="$(mk upload/aa/bb/11111111-2222-3333-4444-555555555555.heic)"
ORIG_MOV="$(mk upload/aa/bb/66666666-7777-8888-9999-aaaaaaaaaaaa.MOV)"
DERIV_MP4="$(mk encoded-video/cc/dd/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4)"
mk thumbs/ee/ff/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee_thumbnail.webp >/dev/null
mk thumbs/ee/ff/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee_preview.jpeg  >/dev/null

# $1 = newline-separated originals the "asset table" reports
# $2 = shell code to run
probe() {
  printf '%s\n' "$1" > "$TMP_DIR/originals.lst"
  shift
  bash -c "
set -uo pipefail
DOMUM_DATA_ROOT='$DATA'
DOMUM_MEDIA_ROOT='$TMP_DIR/media'
IMMICH_LIBRARY_DIR='$LIB'
source '$REPO_ROOT/bin/domum-media-backup' >/dev/null 2>&1
set +e
die() { echo \"DIE: \$*\"; exit 9; }
immich_db_original_paths() { cat '$TMP_DIR/originals.lst'; }
$1
"
}

BASE_ORIGINALS="$ORIG_HEIC
$ORIG_MOV"
PROPOSED="$LIB/thumbs/**
$LIB/encoded-video/**/*[0-9a-f].mp4"

patterns_applied() {  # $1 = originals list -> the pattern set the backup WOULD use
  probe "$1" 'BACKUP_EXCLUDE_IMMICH_DERIVATIVES=1 backup_exclude_patterns 2>/dev/null'
}

# ---------------------------------------------------------------------------
sect "baseline: with only ordinary originals the exclusion IS applied"
out="$(patterns_applied "$BASE_ORIGINALS")"
grep -q 'thumbs/\*\*' <<< "$out" || fail "the thumbs pattern was not applied: $out"
grep -q 'encoded-video' <<< "$out" || fail "the derivative pattern was not applied: $out"
echo "  both derivative patterns are in the applied set"

sect "the exclusion is OFF unless explicitly switched on"
out="$(probe "$BASE_ORIGINALS" 'backup_exclude_patterns 2>/dev/null')"
grep -q 'thumbs' <<< "$out" && fail "the derivative exclusion applied without the flag: $out"
grep -q 'backup-staging' <<< "$out" || fail "the always-on exclusions are missing: $out"
echo "  default is off; only the two long-standing exclusions remain"

# ---------------------------------------------------------------------------
# ADVERSARIAL: originals planted where only generated files normally live.
# ---------------------------------------------------------------------------
attack() {  # $1 = description, $2 = planted original path (relative to LIB)
  local victim; victim="$(mk "$2" 128)"
  local lst="$BASE_ORIGINALS
$victim"
  # 1. the audit core must NAME it
  local hits
  hits="$(probe "$lst" "originals_matched_by_patterns '$LIB/thumbs/**' '$LIB/encoded-video/**/*[0-9a-f].mp4'")"
  grep -qF "$victim" <<< "$hits" || fail "[$1] the planted original was NOT detected: $hits"
  # 2. the applied pattern set must DROP the derivative patterns entirely
  local applied
  applied="$(patterns_applied "$lst")"
  grep -q 'thumbs/\*\*' <<< "$applied" \
    && fail "[$1] the exclusion was applied anyway, so an original would be dropped"
  # 3. the always-on exclusions must survive: this is not an outage
  grep -q 'backup-staging' <<< "$applied" \
    || fail "[$1] dropping the proposal also dropped the ordinary exclusions"
  rm -f "$victim"
  printf '    %s\n' "$1"
}

sect "an ORIGINAL planted among generated files is always caught"
attack "a photo inside thumbs/"                   "thumbs/ee/ff/99999999-1111-2222-3333-444444444444.heic"
attack "a video inside thumbs/"                   "thumbs/ee/ff/99999999-1111-2222-3333-444444444444.mov"
attack "an original named like a transcode"        "encoded-video/cc/dd/12345678-9abc-def0-1234-56789abcdef0.mp4"
attack "a future original ending in a hex digit"   "encoded-video/cc/dd/motion-0000000000000000000000000000000a.mp4"
attack "a jpeg masquerading as a thumbnail"        "thumbs/ee/ff/deadbeef-0000-1111-2222-333333333333_preview.jpeg"
attack "a webp original among thumbnails"          "thumbs/ee/ff/deadbeef-0000-1111-2222-333333333333_thumbnail.webp"
echo "  every planted original is detected and the exclusion is withheld"

# ---------------------------------------------------------------------------
sect "case: the pattern must not silently depend on lowercase"
# An uppercase .MP4 original under encoded-video does NOT match the lowercase
# class, so it is NOT excluded -- which is the safe direction. Measured on the
# real library: upload/ holds 2 uppercase .MP4 originals, encoded-video/ holds
# zero, so Immich generates lowercase and preserves source case.
UP="$(mk encoded-video/cc/dd/0000000000000000000000000000000a.MP4 96)"
hits="$(probe "$BASE_ORIGINALS
$UP" "originals_matched_by_patterns '$LIB/encoded-video/**/*[0-9a-f].mp4'")"
grep -qF "$UP" <<< "$hits" \
  && fail "an uppercase .MP4 matched a lowercase pattern; restic matching is case-sensitive here"
applied="$(patterns_applied "$BASE_ORIGINALS
$UP")"
grep -q 'encoded-video' <<< "$applied" \
  || fail "an uppercase original is not excluded, so the proposal should still apply"
echo "  uppercase .MP4 is not matched, so it stays backed up and the proposal still applies"
rm -f "$UP"

sect "case: an uppercase pattern must not match a lowercase derivative"
hits="$(probe "$BASE_ORIGINALS" "path_matches_exclude '$DERIV_MP4' '$LIB/encoded-video/**/*.MP4' && echo MATCHED")"
grep -q MATCHED <<< "$hits" && fail "matching is case-insensitive; the audit's conclusions would not transfer"
echo "  matching is case-sensitive in both directions, as restic's is"

# ---------------------------------------------------------------------------
sect "an unreadable asset table withholds the exclusion and does NOT refuse the backup"
out="$(probe "$BASE_ORIGINALS" \
  'immich_db_original_paths() { return 1; }
   BACKUP_EXCLUDE_IMMICH_DERIVATIVES=1 backup_exclude_patterns 2>/dev/null')"
grep -q 'thumbs/\*\*' <<< "$out" && fail "the exclusion was applied without proof: $out"
grep -q 'backup-staging' <<< "$out" || fail "the backup lost its ordinary exclusions: $out"
echo "  unprovable means withheld, and the backup still has its normal exclusions"

sect "a failed path translation also withholds it"
# Untranslated paths match no host pattern, so "nothing matched" would be
# meaningless -- the vacuity hole, in the gate this time.
out="$(probe "/usr/src/app/upload/upload/aa/bb/x.heic" \
  'BACKUP_EXCLUDE_IMMICH_DERIVATIVES=1 backup_exclude_patterns 2>/dev/null')"
grep -q 'thumbs/\*\*' <<< "$out" \
  && fail "patterns were applied although not one original resolved under the library root"
echo "  no original under the library root means the proof is void, so it is withheld"

# ---------------------------------------------------------------------------
sect "restic really behaves the way the audit assumes"
if command -v restic >/dev/null 2>&1; then
  R="$TMP_DIR/resticrepo"; mkdir -p "$R"
  export RESTIC_REPOSITORY="$R" RESTIC_PASSWORD=invariant-test
  if restic init >/dev/null 2>&1; then
    MP="$(mk encoded-video/cc/dd/676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4 77)"
    restic backup --exclude "$LIB/encoded-video/**/*[0-9a-f].mp4" "$LIB" >/dev/null 2>&1 \
      || fail "the scratch backup failed"
    listing="$(restic ls latest 2>/dev/null)"
    grep -qF -- "-MP.mp4" <<< "$listing" \
      || fail "restic excluded the motion-photo ORIGINAL: the pattern is wrong"
    grep -qF "$DERIV_MP4" <<< "$listing" \
      && fail "restic did NOT exclude the derivative: the pattern does not work"
    grep -qF "$ORIG_HEIC" <<< "$listing" || fail "restic excluded an ordinary original"
    echo "  restic kept the -MP.mp4 original and dropped the derivative, as predicted"
    rm -f "$MP"
  else
    echo "  SKIPPED: restic is present but a scratch repository could not be created"
  fi
else
  echo "  SKIPPED: restic is not installed here (the behaviour is pinned in"
  echo "           docs/BACKUP-EXCLUSION-PROPOSAL.md with measured evidence)"
fi

# ---------------------------------------------------------------------------
sect "mutation: removing the gate must let an original be excluded"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('if (( ${#proposed[@]} > 0 )) && exclusion_safe_to_apply "${proposed[@]}"; then',
            'if (( ${#proposed[@]} > 0 )); then', 1)
open(p,'w').write(s)
PY
VICTIM="$(mk encoded-video/cc/dd/12345678-9abc-def0-1234-56789abcdef0.mp4 128)"
printf '%s\n' "$BASE_ORIGINALS" "$VICTIM" > "$TMP_DIR/originals.lst"
mout="$(bash -c "
set -uo pipefail
DOMUM_DATA_ROOT='$DATA'
DOMUM_MEDIA_ROOT='$TMP_DIR/media'
IMMICH_LIBRARY_DIR='$LIB'
source '$MUT' >/dev/null 2>&1
set +e
immich_db_original_paths() { cat '$TMP_DIR/originals.lst'; }
BACKUP_EXCLUDE_IMMICH_DERIVATIVES=1 backup_exclude_patterns 2>/dev/null
")"
grep -q 'encoded-video' <<< "$mout" \
  || fail "the mutant did not apply the unsafe exclusion; the gate is not load-bearing"
echo "  without the gate the pattern is applied even though it matches an original"

echo "PASS: exclusion-invariant-smoke"
