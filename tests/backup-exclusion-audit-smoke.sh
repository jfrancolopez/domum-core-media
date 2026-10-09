#!/usr/bin/env bash
set -uo pipefail

# Proves `exclusion-audit` makes a falsifiable claim about what the backup
# excludes:
#
#   * the backup and the audit read the SAME pattern source, so "the backup
#     excludes X" is a statement about behaviour rather than about source text;
#   * an exclusion pattern that reaches an Immich ORIGINAL fails, and names it;
#   * a pattern that reaches only derivatives passes;
#   * an unreadable database, and a failed container-to-host path translation,
#     both report UNKNOWN rather than a clean pass.
#
# The last one is the point of the suite. The audit's whole value is the
# negative result, and a check that compares nothing also reports zero matches.
#
# Hermetic: a stub `docker` on PATH, no real containers, no restic, no network,
# no production paths.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA="$TMP_DIR/data"
LIB="$DATA/immich/library"
mkdir -p "$LIB/upload/aa/bb" "$LIB/encoded-video/cc/dd" "$LIB/thumbs/ee/ff" "$TMP_DIR/bin"

# The fixture mirrors the real library's shape, including the awkward part:
# a motion-photo original that lives UNDER encoded-video/ and is named
# "<uuid>-MP.mp4", beside a derivative named "<uuid>.mp4".
# LIB_T is what the eval'd setup blocks below refer to; the subshell inherits it.
LIB_T="$LIB"
CONT_PREFIX="/usr/src/app/upload"
cat > "$TMP_DIR/originals.txt" <<EOF
$CONT_PREFIX/upload/aa/bb/11111111-2222-3333-4444-555555555555.heic
$CONT_PREFIX/upload/aa/bb/66666666-7777-8888-9999-aaaaaaaaaaaa.mov
$CONT_PREFIX/encoded-video/cc/dd/676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4
EOF

# A stub docker that answers the three questions the audit really asks.
cat > "$TMP_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps)      [[ -n "\${STUB_PG_DOWN:-}" ]] && exit 0; echo "deadbeefcafe" ;;
  inspect) printf '%s' "\${STUB_PREFIX:-$CONT_PREFIX}" ;;
  exec)    [[ -n "\${STUB_PG_DOWN:-}" ]] && exit 1; cat "$TMP_DIR/originals.txt" ;;
  *)       exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

export DOMUM_DATA_ROOT="$DATA"
export DOMUM_MEDIA_ROOT="$TMP_DIR/media"

# Run one audit in a subshell so each section gets a clean function table.
# $1 = extra setup sourced before the call, $2.. = audit args
run_audit() {
  local setup="$1"; shift
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    # AFTER the source: the sourced script sets -e, which would otherwise kill
    # this subshell on the non-zero return the test is trying to observe.
    set +e
    die() { echo "DIE: $*"; exit 9; }
    if [[ -n "$setup" ]]; then eval "$setup"; fi
    do_exclusion_audit "$@" 2>&1
    echo "EXITCODE=$?"
  )
}

# ---------------------------------------------------------------------------
sect "the backup's --exclude flags come from backup_exclude_patterns"
# Behavioural, not textual: override the pattern source and check the argv the
# restic invocation would really receive.
argv_out="$(
  source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
  set +e
  backup_exclude_patterns() { printf '%s\n' "/sentinel/one/*" "/sentinel/two/*"; }
  local_excl=()
  while IFS= read -r pat; do [[ -n "$pat" ]] && local_excl+=(--exclude "$pat"); done \
    < <(backup_exclude_patterns)
  printf '%s\n' "${local_excl[@]}"
)"
grep -q '/sentinel/one/\*' <<< "$argv_out" || fail "override did not reach the argv builder"
grep -q '/sentinel/two/\*' <<< "$argv_out" || fail "second pattern missing"
# And the real invocation must not carry a hand-written --exclude any more:
# if it did, overriding the function would not change the backup.
inline="$(awk '/restic_for_target "\$target" backup/,/paths\[@\]/' \
  "$REPO_ROOT/bin/domum-media-backup" | grep -c -- '--exclude "' || true)"
[[ "$inline" -eq 0 ]] || fail "the restic invocation still has $inline inline --exclude"
echo "  one source: the argv is built from the function, none inline"

# ---------------------------------------------------------------------------
sect "a pattern that reaches only derivatives PASSES"
out="$(run_audit 'backup_proposed_exclude_patterns() {
  printf "%s\n" "$LIB_T/thumbs/**" "$LIB_T/encoded-video/**/*[0-9a-f].mp4"
}' --proposed)"
grep -q 'EXITCODE=0' <<< "$out" || fail "clean proposal did not exit 0: $out"
grep -q 'MATCHED ORIGINALS  : 0 of 3' <<< "$out" || fail "expected 0 of 3: $out"
grep -q 'no Immich original is matched' <<< "$out" || fail "missing clean verdict"
echo "  3 originals, 0 matched, exit 0"

# ---------------------------------------------------------------------------
sect "excluding the whole encoded-video tree FAILS and names the original"
out="$(run_audit 'backup_proposed_exclude_patterns() {
  printf "%s\n" "$LIB_T/thumbs/**" "$LIB_T/encoded-video/**"
}' --proposed)"
grep -q 'EXITCODE=1' <<< "$out" || fail "naive proposal did not exit 1: $out"
grep -q 'MATCHED ORIGINALS  : 1 of 3' <<< "$out" || fail "expected 1 of 3: $out"
grep -q 'FAIL -- an exclusion pattern reaches irreplaceable data' <<< "$out" \
  || fail "missing FAIL verdict"
grep -q '676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4' <<< "$out" \
  || fail "the offending path was not named -- an unactionable FAIL"
echo "  the motion-photo original is caught and printed by name"

# ---------------------------------------------------------------------------
sect "a derivative-shaped name must NOT be reported as an original"
# The derivative is not in the asset table, so even a pattern that matches it
# is clean. This is what separates 'excluded' from 'lost'.
touch "$LIB/encoded-video/cc/dd/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4"
out="$(run_audit 'backup_proposed_exclude_patterns() {
  printf "%s\n" "$LIB_T/encoded-video/**/*[0-9a-f].mp4"
}' --proposed)"
grep -q 'EXITCODE=0' <<< "$out" || fail "derivative exclusion should be clean: $out"
echo "  excluding a derivative is not a finding"

# ---------------------------------------------------------------------------
sect "a path the table names but which is NOT on disk is still checked"
# Matching must be about PATHS, not presence. Making it depend on a stat of the
# file made the audit report a clean pass for a library whose files had not been
# created -- it compared nothing and said "0 matched". CI caught it.
rm -f "$LIB/encoded-video/cc/dd/676850ba-6d31-43a1-9a03-b7710f607bcc-MP.mp4"
out="$(run_audit 'backup_proposed_exclude_patterns() {
  printf "%s\n" "$LIB_T/encoded-video/**"
}' --proposed)"
grep -q 'EXITCODE=1' <<< "$out" \
  || fail "an absent-but-named original was not checked: $out"
grep -q '676850ba' <<< "$out" || fail "the absent original was not named: $out"
echo "  an original the table names is checked whether or not the file exists"

sect "an unreadable database reports UNKNOWN, not a pass"
out="$(STUB_PG_DOWN=1 run_audit '' --proposed)"
grep -q 'EXITCODE=2' <<< "$out" || fail "db down did not exit 2: $out"
grep -q 'UNKNOWN' <<< "$out" || fail "db down did not say UNKNOWN: $out"
grep -q 'Do not treat this as a pass' <<< "$out" || fail "missing the warning"
grep -q 'no Immich original is matched' <<< "$out" \
  && fail "db down claimed a clean result"
echo "  exit 2, UNKNOWN, and it does not claim cleanliness"

# ---------------------------------------------------------------------------
sect "a failed path translation reports UNKNOWN, not a vacuous pass"
# This is the dangerous one: untranslated paths match no host pattern, so a
# naive implementation reports '0 matched' having compared nothing.
out="$(STUB_PREFIX=/wrong/container/path run_audit 'backup_proposed_exclude_patterns() {
  printf "%s\n" "$LIB_T/encoded-video/**"
}' --proposed)"
grep -q 'EXITCODE=2' <<< "$out" || fail "bad prefix did not exit 2: $out"
grep -q 'not one original resolved under the library root' <<< "$out" \
  || fail "bad prefix did not explain itself: $out"
grep -q 'MATCHED ORIGINALS  : 0' <<< "$out" && fail "bad prefix reported a clean count"
echo "  the untranslated case refuses to answer instead of passing"

# ---------------------------------------------------------------------------
sect "the matcher handles restic's zero-component ** "
res="$(
  source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
  set +e
  path_matches_exclude "/a/b/x.mp4" "/a/b/**/*.mp4" && echo zero-ok
  path_matches_exclude "/a/b/c/x.mp4" "/a/b/**/*.mp4" && echo deep-ok
  path_matches_exclude "/a/b/c/x-MP.mp4" "/a/b/**/*[0-9a-f].mp4" || echo class-ok
)"
grep -q zero-ok  <<< "$res" || fail "zero-component ** not matched"
grep -q deep-ok  <<< "$res" || fail "deep ** not matched"
grep -q class-ok <<< "$res" || fail "-MP.mp4 wrongly matched the hex class"
echo "  zero and many components both match; the hex class excludes -MP.mp4"

# ---------------------------------------------------------------------------
sect "mutation: dropping the translation guard must let a vacuous pass through"
cp "$REPO_ROOT/bin/domum-media-backup" "$TMP_DIR/backup.orig"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('  if (( n_under == 0 )); then', '  if (( n_under == -1 )); then',1)
open(p,'w').write(s)
PY
mout="$(
  STUB_PREFIX=/wrong/container/path
  export STUB_PREFIX
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  backup_proposed_exclude_patterns() { printf '%s\n' "$LIB/encoded-video/**"; }
  do_exclusion_audit --proposed 2>&1
  echo "EXITCODE=$?"
)"
grep -q 'EXITCODE=0' <<< "$mout" || fail "mutant did not pass vacuously; guard is not load-bearing"
grep -q 'no Immich original is matched' <<< "$mout" \
  || fail "mutant did not produce the false clean verdict"
echo "  without the guard it reports a clean pass having compared nothing"

# ---------------------------------------------------------------------------
sect "mutation: dropping the collapsed-** variant must break zero-component matching"
MUT2="$TMP_DIR/mutant2"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT2"
python3 - "$MUT2" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('  collapsed="${pat//\\*\\*\\//}"', '  collapsed="$pat"',1)
open(p,'w').write(s)
PY
m2="$(
  source "$MUT2" >/dev/null 2>&1
  set +e
  path_matches_exclude "/a/b/x.mp4" "/a/b/**/*.mp4" && echo still-ok
  true
)"
grep -q still-ok <<< "$m2" && fail "the collapsed variant is not load-bearing"
echo "  the zero-component case stops matching -- the variant is load-bearing"

echo "PASS: backup-exclusion-audit-smoke"
