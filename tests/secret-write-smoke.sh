#!/usr/bin/env bash
set -uo pipefail

# write_secret_file was in the never-executed set: nothing drove the function
# that creates every file under the secrets directory. Two defects, both
# measured before being fixed:
#
#   * `umask 077` is NOT scoped to a function, so it leaked to the rest of the
#     process -- a caller at umask 022 that created an ordinary file after
#     writing a secret got 600 instead of 644;
#   * `> "$path"` truncates before it writes, so an interruption left a
#     ZERO-BYTE secret. An empty credential file is exactly what `checkup`
#     reports as a problem, and the write path should not be able to create it.
#
# Hermetic: mktemp -d, no production path, no secret VALUE ever printed.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
MUTCLI="$CLI"
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"

probe() {  # $1 = body
  bash -c "
set -uo pipefail
source '$MUTCLI' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
ensure_secret_dir() { :; }
$1
" 2>&1
}

mkdir -p "$TMP/sec"

# ---------------------------------------------------------------------------
# 1. The caller's umask survives, and a later ordinary file keeps its mode.
# ---------------------------------------------------------------------------
out="$(probe "
umask 022
write_secret_file '$TMP/sec/a' 'SENTINEL-alpha'
printf 'x' > '$TMP/sec/plain'
echo \"umask=\$(umask) secret=\$(stat -c %a '$TMP/sec/a') plain=\$(stat -c %a '$TMP/sec/plain')\"")"
grep -q 'umask=0022' <<< "$out" \
  || fail "1: the caller's umask was changed -- a function-scoped umask is not scoped: $out"
grep -q 'secret=600' <<< "$out" || fail "1: the secret is not 600: $out"
grep -q 'plain=644' <<< "$out" \
  || fail "1: a file created AFTER the secret inherited the tightened umask: $out"
echo "  1: the umask does not leak, and the secret is still 600"

# ---------------------------------------------------------------------------
# 2. The content is exact -- no trailing newline, no shell mangling.
# ---------------------------------------------------------------------------
probe "write_secret_file '$TMP/sec/b' 'line1
line2'" >/dev/null
[ "$(wc -c < "$TMP/sec/b")" = "11" ] \
  || fail "2: a two-line secret is $(wc -c < "$TMP/sec/b") bytes, expected 11 with no trailing newline"
probe "write_secret_file '$TMP/sec/c' 'a b  \$notavar \`echo no\`'" >/dev/null
grep -qF 'notavar' "$TMP/sec/c" || fail "2: the value was expanded rather than written literally"
echo "  2: the value is written byte-exactly, unexpanded"

# ---------------------------------------------------------------------------
# 3. Replacing an existing secret is ATOMIC: the live file is never truncated,
#    and no temporary file is left beside it.
# ---------------------------------------------------------------------------
probe "write_secret_file '$TMP/sec/d' 'OLD-VALUE'" >/dev/null
probe "write_secret_file '$TMP/sec/d' 'NEW-VALUE'" >/dev/null
[ "$(cat "$TMP/sec/d")" = "NEW-VALUE" ] || fail "3: the replacement did not take"
[ "$(stat -c %a "$TMP/sec/d")" = "600" ] || fail "3: the replaced secret lost its mode"
strays="$(find "$TMP/sec" -name '.d.*' | wc -l)"
[ "$strays" = "0" ] || fail "3: $strays temporary file(s) left beside the secret"
# A rename gives the live file a NEW inode. An in-place rewrite would keep it,
# which is what section 6 drives from the other side.
probe "write_secret_file '$TMP/sec/d' 'THIRD-VALUE'" >/dev/null
ino3="$(stat -c %i "$TMP/sec/d")"
probe "write_secret_file '$TMP/sec/d' 'FOURTH-VALUE'" >/dev/null
[ "$(stat -c %i "$TMP/sec/d")" != "$ino3" ] \
  || fail "3: the live secret kept its inode across a replacement, so it was
rewritten in place rather than renamed into position"
echo "  3: a replacement is atomic and leaves no temporary behind"

# ---------------------------------------------------------------------------
# 4. A failure to stage must leave the EXISTING secret intact, not an empty
#    file. This is the case the atomic write exists for.
# ---------------------------------------------------------------------------
probe "write_secret_file '$TMP/sec/e' 'KEEP-ME'" >/dev/null
out="$(probe "
mktemp() { return 1; }
write_secret_file '$TMP/sec/e' 'WOULD-REPLACE'")"
grep -q 'DIE:' <<< "$out" || fail "4: a failed stage did not refuse: $out"
[ "$(cat "$TMP/sec/e")" = "KEEP-ME" ] \
  || fail "4: a failed write destroyed the existing secret -- it reads [$(cat "$TMP/sec/e")]"
[ -s "$TMP/sec/e" ] || fail "4: the existing secret was truncated to zero bytes"
echo "  4: a failed write leaves the existing secret intact, not empty"

# ---------------------------------------------------------------------------
# 5. No secret VALUE is ever printed, by the function or by its refusal.
# ---------------------------------------------------------------------------
out="$(probe "write_secret_file '$TMP/sec/f' 'SENTINEL-must-not-appear'")"
grep -q 'SENTINEL-must-not-appear' <<< "$out" \
  && fail "5: the secret value appeared on stdout/stderr: $out"
out="$(probe "
mktemp() { return 1; }
write_secret_file '$TMP/sec/g' 'SENTINEL-must-not-appear'")"
grep -q 'SENTINEL-must-not-appear' <<< "$out" \
  && fail "5: the refusal printed the secret value: $out"
echo "  5: no secret value reaches stdout or stderr, including on refusal"

# ---------------------------------------------------------------------------
# 6. MUTATIONS, against a COPY so a stopped run leaves nothing behind.
# ---------------------------------------------------------------------------
MUTCLI="$TMP/cli-mutant"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-umask.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''  local tmp
  tmp="$(
    umask 077'''
new = '''  local tmp
  umask 077
  tmp="$('''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
python3 -I "$TMP/mut-umask.py" "$MUTCLI" || fail "6: the umask mutation did not apply"
out="$(probe "
umask 022
write_secret_file '$TMP/sec/m1' 'x'
echo \"umask=\$(umask)\"")"
grep -q 'umask=0077' <<< "$out" \
  || fail "6: the mutation applied but the umask no longer leaks, so section 1
would pass without the subshell: $out"
echo "  6: an unsubshelled umask leaks to the caller again"

MUTCLI="$TMP/cli-mutant2"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-atomic.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "Could not install the secret at $path."; }'
new = '  rm -f -- "$tmp"\n  printf \'%s\' "$value" > "$path"\n  chmod 600 "$path"'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
python3 -I "$TMP/mut-atomic.py" "$MUTCLI" || fail "6: the atomicity mutation did not apply"
# The observable is the INODE, not an injected failure: a rename gives the live
# file a NEW inode, an in-place write preserves it. The first attempt stubbed
# printf to fail, which also broke the STAGING, so the function died before
# reaching the mutated write and the mutant looked safe -- name the observable
# the mutation actually changes.
probe "write_secret_file '$TMP/sec/m2' 'FIRST'" >/dev/null
ino_before="$(stat -c %i "$TMP/sec/m2")"
probe "write_secret_file '$TMP/sec/m2' 'SECOND'" >/dev/null
ino_after="$(stat -c %i "$TMP/sec/m2")"
[ "$ino_before" = "$ino_after" ] \
  || fail "6: the mutation applied but the live file still got a new inode, so
it is still being renamed into place and section 3/4 would pass without the fix"
echo "  6: a direct write rewrites the live file in place (inode $ino_after unchanged)"
MUTCLI="$CLI"

cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first section"

echo "PASS: secret write smoke test"
