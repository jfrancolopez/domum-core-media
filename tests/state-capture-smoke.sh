#!/usr/bin/env bash
# Selective capture of media-service state, driven against fixtures.
#
# Measured (docs/SELECTIVE-STATE-PROTECTION.md): the five migrated services
# hold 352.28 MiB of directories and 8.90 MiB of irreplaceable state -- 2.5%.
# Plex's `Drivers/` alone is 230.6 MiB and is downloaded on demand. So the
# capture is selective by design; taking the directories would pay 40x for the
# same recovery.
#
# Nothing here activates a backup, and nothing reaches the host: a `docker`
# stub that exits non-zero is on PATH, so a path that tried to reach the real
# daemon FAILS instead of quietly succeeding.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/data" "$TMP/out"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"

# A jellyfin-shaped state tree: a database, four XML files, and the
# DataProtection keys whose modes must survive.
build_jellyfin() {
  rm -rf "$TMP/data/jellyfin"
  mkdir -p "$TMP/data/jellyfin/config/data/data" \
           "$TMP/data/jellyfin/config/.aspnet/DataProtection-Keys" \
           "$TMP/data/jellyfin/config/log"
  # A REAL database, not a file that merely starts with the magic: the restore
  # opens what it restored, so a stub would fail for the wrong reason.
  python3 - "$TMP/data/jellyfin/config/data/data/jellyfin.db" <<'MKDB'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table t(id integer primary key, v text)")
con.execute("insert into t values (1,'library-rows')")
con.commit(); con.close()
MKDB
  for x in system encoding network database; do
    printf '<%s/>\n' "$x" > "$TMP/data/jellyfin/config/$x.xml"
  done
  printf '<key id="a"/>\n' > "$TMP/data/jellyfin/config/.aspnet/DataProtection-Keys/key-a.xml"
  chmod 0600 "$TMP/data/jellyfin/config/.aspnet/DataProtection-Keys/key-a.xml"
  # Regenerable, and deliberately NOT declared -- if it appears in a capture
  # the declaration has grown something it should not have.
  printf 'log noise\n' > "$TMP/data/jellyfin/config/log/jellyfin.log"
}

probe() {  # $1 = extra stubs, $2 = expression
  (
    export PATH="$TMP/bin:$PATH"
    export DOMUM_DATA_ROOT="$TMP/data"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    warn() { echo "WARN: $*"; }
    # Hide ONLY docker. A stub that claimed every tool exists would send
    # domum_sqlite_check down its sqlite3 branch on a host that has none, and
    # the resulting "command not found" would read as a corrupt database.
    cmd_exists() { case "$1" in docker) return 1 ;; *) command -v -- "$1" >/dev/null 2>&1 ;; esac; }
    tracked_service_container_id_any() { return 1; }
    eval "$1"
    eval "$2"
  ) 2>&1
}

# ---------------------------------------------------------------------------
sect "the declaration covers what was measured, and excludes what is regenerable"
out="$(probe '' 'service_essential_state jellyfin')"
for want in 'config/data/data/jellyfin.db' 'config/system.xml' 'config/.aspnet/DataProtection-Keys'; do
  grep -qF -- "$want" <<< "$out" || fail "jellyfin does not declare $want: $out"
done
grep -qF 'DataProtection-Keys' <<< "$out" \
  || fail "the keys that decrypt jellyfin's stored secrets are not declared -- a
capture built from 'the database' alone would miss them"
# The big regenerable trees must NOT be declared. Measured: plex Drivers/ is
# 230.6 MiB of 248.1, navidrome cache/ is 95.4 of 97.6, kavita backups/ is
# 3.1x the database it backs up.
for svc_bad in 'plex:Drivers' 'plex:Logs' 'navidrome:cache' 'kavita:backups' 'kavita:logs' 'jellyfin:log'; do
  svc="${svc_bad%%:*}"; bad="${svc_bad#*:}"
  d="$(probe '' "service_essential_state $svc")"
  grep -qE "\\|.*(^|/)$bad(/|$)" <<< "$d" \
    && fail "$svc declares the regenerable '$bad', which is most of its bytes: $d"
done
echo "  databases, config and keys declared; Drivers/cache/backups/logs excluded"

sect "every migrated service declares something, and an unknown one refuses"
for svc in plex navidrome jellyfin kavita calibre-web; do
  d="$(probe '' "service_essential_state $svc")"
  [[ -n "$d" ]] || fail "$svc declares no essential state"
  grep -qE '^(sqlite|file|dir)\|' <<< "$d" \
    || fail "$svc's declaration has no recognised kind: $d"
done
out="$(probe '' 'service_essential_state nosuchservice >/dev/null; echo RC=$?')"
grep -q 'RC=1' <<< "$out" \
  || fail "an unknown service must refuse rather than return an empty capture plan"
echo "  five services declared; an unknown one refuses"

sect "capture mode is CONSISTENT only where the service ships an sqlite3"
# Measured 2026-11-03 by exec'ing the running containers. The host has none at
# all, so an undeclared service cannot have a proven-consistent capture.
for svc in plex navidrome calibre-web; do
  [[ "$(probe '' "service_state_capture_mode $svc")" == "consistent" ]] \
    || fail "$svc ships its own sqlite3 and should capture consistently"
done
for svc in jellyfin kavita; do
  [[ "$(probe '' "service_state_capture_mode $svc")" == "unproven" ]] \
    || fail "$svc has no sqlite3 in its image or on the host, so its capture
cannot be claimed consistent"
done
echo "  plex/navidrome/calibre-web consistent; jellyfin/kavita unproven"

sect "a capture writes every declared item, a manifest, and COMPLETE"
build_jellyfin
rm -rf "$TMP/out/jf"
out="$(probe '' "service_state_capture jellyfin '$TMP/out/jf'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a complete capture did not succeed: $out"
[[ -f "$TMP/out/jf/MANIFEST" ]] || fail "no manifest was written"
grep -q '^RESULT=COMPLETE$' "$TMP/out/jf/MANIFEST" || fail "not reported COMPLETE: $(cat "$TMP/out/jf/MANIFEST")"
grep -q '^SERVICE=jellyfin$' "$TMP/out/jf/MANIFEST" || fail "the manifest does not name the service"
grep -q '^CAPTURE_MODE=unproven$' "$TMP/out/jf/MANIFEST" \
  || fail "jellyfin's capture mode must be recorded as unproven: $(cat "$TMP/out/jf/MANIFEST")"
n_items="$(grep -c '^ITEM=' "$TMP/out/jf/MANIFEST")"
[[ "$n_items" == "6" ]] || fail "expected 6 captured items, manifest has $n_items"
# Nothing regenerable came along.
stray="$(find "$TMP/out/jf/files" -name '*jellyfin.log*')"
[[ -z "$stray" ]] || fail "the capture included the log directory, which is not declared: $stray"
echo "  6 items, manifest COMPLETE, mode recorded, no undeclared files"

sect "the capture records a digest for every item, and verify re-reads them"
items="$(grep -E '^ITEM=' "$TMP/out/jf/MANIFEST")"
while IFS= read -r l; do
  [[ -z "$l" ]] && continue
  sum="${l##*|}"
  # A digest field that is empty, or that is just the previous field repeated
  # because the line has too few parts, means nothing was hashed.
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] \
    || fail "an item has no sha256 digest: $l"
done <<< "$items"
out="$(probe '' "service_state_verify '$TMP/out/jf'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a freshly written capture did not verify: $out"
grep -qi 'capture verified' <<< "$out" || fail "verification said nothing: $out"
echo "  every item digested, and the capture verifies"

sect "file MODES survive, because a restore must not widen a permission"
key="$(find "$TMP/out/jf/files" -name 'key-a.xml' | head -1)"
[[ -n "$key" ]] || fail "the DataProtection key was not captured"
m="$(stat -c '%a' "$key")"
[[ "$m" == "600" ]] || fail "the key came back mode $m, not 600 -- a recovery
that widens a permission is a disclosure"
echo "  0600 preserved through the capture"

sect "TAMPERING is detected -- a digest written and never re-read proves nothing"
printf 'tampered\n' >> "$(find "$TMP/out/jf/files" -name '*jellyfin.db*' | head -1)"
out="$(probe '' "service_state_verify '$TMP/out/jf'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a modified capture still verified: $out"
grep -qi 'does not match its recorded digest' <<< "$out" || fail "it does not say what is wrong: $out"
echo "  a changed byte fails verification, and is named"

sect "a changed MODE inside a captured directory is detected too"
build_jellyfin
rm -rf "$TMP/out/jf2"
probe '' "service_state_capture jellyfin '$TMP/out/jf2'" >/dev/null
chmod 0644 "$(find "$TMP/out/jf2/files" -name 'key-a.xml' | head -1)"
out="$(probe '' "service_state_verify '$TMP/out/jf2'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" \
  || fail "widening a captured key's mode was not detected -- the directory
digest must cover modes, or a disclosure would verify clean: $out"
echo "  a widened mode fails verification"

sect "a MISSING declared item makes the capture INCOMPLETE, and it FAILS"
build_jellyfin
rm -f "$TMP/data/jellyfin/config/system.xml"
rm -rf "$TMP/out/jf3"
out="$(probe '' "service_state_capture jellyfin '$TMP/out/jf3'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" \
  || fail "a capture missing a declared item reported success -- a partial
capture presented as a backup is the defect this project keeps correcting: $out"
grep -q '^RESULT=INCOMPLETE$' "$TMP/out/jf3/MANIFEST" || fail "not recorded INCOMPLETE"
grep -q 'MISSING' "$TMP/out/jf3/MANIFEST" || fail "the manifest does not say which item was missing"
grep -qi 'not a backup' <<< "$out" || fail "the warning does not say what it means: $out"
echo "  fails closed, names the item, and says what it means"

sect "verify REFUSES a capture whose manifest records a missing item"
out="$(probe '' "service_state_verify '$TMP/out/jf3'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "verification accepted an incomplete capture: $out"
echo "  an incomplete capture never verifies"

sect "the manifest records the IMAGE, because state alone is not a recovery point"
build_jellyfin
rm -rf "$TMP/out/jf4"
probe 'tracked_service_container_id_any() { printf "cid123"; }
       docker() { case "$*" in *"{{.Image}}"*) printf "sha256:feedface\n" ;; *) return 1 ;; esac; }
       cmd_exists() { return 0; }' \
  "service_state_capture jellyfin '$TMP/out/jf4'" >/dev/null
grep -q '^IMAGE_ID=sha256:feedface$' "$TMP/out/jf4/MANIFEST" \
  || fail "the image identity is not recorded; state restored under a different
application version is the pairing failure: $(cat "$TMP/out/jf4/MANIFEST")"
echo "  image id recorded alongside the state"

sect "a missing state ROOT refuses before writing anything"
rm -rf "$TMP/data/jellyfin" "$TMP/out/jf5"
out="$(probe '' "service_state_capture jellyfin '$TMP/out/jf5'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a capture with no state directory did not refuse: $out"
[[ ! -d "$TMP/out/jf5" ]] || fail "it created a destination for a capture it could not make"
echo "  refuses, and leaves no empty capture behind"

sect "a captured FILE's mode is checked too, not only its contents"
# plex's Preferences.xml holds the server token. A file item's digest is over
# its contents, so the mode is recorded and compared separately.
build_jellyfin
rm -rf "$TMP/out/fm"
probe '' "service_state_capture jellyfin '$TMP/out/fm'" >/dev/null
grep -qE '^ITEM=file\|config/system\.xml\|file-copy\|[0-9]+\|[0-7]{3,4}\|[0-9a-f]{64}$' "$TMP/out/fm/MANIFEST" \
  || fail "a file item does not record its mode: $(grep '^ITEM=file' "$TMP/out/fm/MANIFEST")"
chmod 0666 "$TMP/out/fm/files/config_system.xml"
out="$(probe '' "service_state_verify '$TMP/out/fm'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "widening a captured file's mode was not detected: $out"
grep -q 'but was captured as' <<< "$out" || fail "it does not say what changed: $out"
echo "  mode recorded per item, and a widened one fails verification"

sect "a stored-name COLLISION is refused, never silently overwritten"
# The stored name folds '/' and ' ' to '_', and plex's declared paths contain
# spaces -- so two declared paths CAN map to one name. Capture must refuse.
build_jellyfin
mkdir -p "$TMP/data/jellyfin/config/a"
printf 'one\n' > "$TMP/data/jellyfin/config/a/b"
printf 'two\n' > "$TMP/data/jellyfin/config/a b"
rm -rf "$TMP/out/col"
out="$(probe 'service_essential_state() { printf "file|config/a/b\nfile|config/a b\n"; }' \
  "service_state_capture jellyfin '$TMP/out/col'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" \
  || fail "two items mapping to one stored name was accepted -- one would have
overwritten the other and both digests would read the same file: $out"
grep -q 'COLLISION' "$TMP/out/col/MANIFEST" || fail "the collision is not recorded: $(cat "$TMP/out/col/MANIFEST")"
echo "  refused, and recorded as a collision"

# ---------------------------------------------------------------------------
sect "a restore REFUSES to write into the service's live state"
build_jellyfin
rm -rf "$TMP/out/cap"
probe '' "service_state_capture jellyfin '$TMP/out/cap'" >/dev/null
for bad_target in "$TMP/data/jellyfin" "$TMP/data/jellyfin/config/restored" "$TMP/data/jellyfin/../jellyfin/x"; do
  out="$(probe '' "service_state_restore '$TMP/out/cap' '$bad_target'; echo RC=\$?")"
  grep -q 'RC=1' <<< "$out" \
    || fail "a restore into '$bad_target' was allowed -- writing into live state is a
production mutation wearing a verification's clothes: $out"
  grep -q 'REFUSING' <<< "$out" || fail "it does not say it is refusing: $out"
done
# And the live tree is untouched by the refusals.
[[ -f "$TMP/data/jellyfin/config/system.xml" ]] || fail "the refusal damaged the live tree"
[[ ! -d "$TMP/data/jellyfin/config/restored" ]] || fail "the refusal created a directory in live state"
echo "  the live root, a path inside it, and a '..' path all refused"

sect "a NON-EMPTY target is refused"
mkdir -p "$TMP/out/busy"; printf 'pre-existing\n' > "$TMP/out/busy/already-here"
out="$(probe '' "service_state_restore '$TMP/out/cap' '$TMP/out/busy'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a restore into a non-empty directory was allowed: $out"
[[ "$(cat "$TMP/out/busy/already-here")" == "pre-existing" ]] || fail "it overwrote existing content"
echo "  refused, and the existing content is intact"

sect "a restore puts every item back at its declared path and PROVES the digests"
rm -rf "$TMP/out/scratch"
out="$(probe '' "service_state_restore '$TMP/out/cap' '$TMP/out/scratch'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a sound capture did not restore: $out"
for rel in 'config/data/data/jellyfin.db' 'config/system.xml' 'config/.aspnet/DataProtection-Keys/key-a.xml'; do
  [[ -e "$TMP/out/scratch/$rel" ]] || fail "$rel was not restored to its declared path"
done
[[ "$(stat -c '%a' "$TMP/out/scratch/config/.aspnet/DataProtection-Keys/key-a.xml")" == "600" ]] \
  || fail "the DataProtection key came back with a widened mode"
cmp -s "$TMP/data/jellyfin/config/system.xml" "$TMP/out/scratch/config/system.xml" \
  || fail "the restored file does not match the original"
grep -q 'all matching their recorded digests' <<< "$out" || fail "it does not state the proof: $out"
echo "  every item back at its declared path, bytes and modes intact"

sect "the restore states its own LIMIT -- a capture is not a running service"
grep -qi 'not a proof that' <<< "$out" \
  || fail "the restore claims more than it proved. A restored capture says the
BYTES came back; nothing here shows jellyfin runs against them: $out"
echo "  the claim stops where the evidence does"

sect "a DAMAGED capture is refused before anything is written"
rm -rf "$TMP/out/scratch2"
cp -a "$TMP/out/cap" "$TMP/out/cap-bad"
printf 'rot\n' >> "$TMP/out/cap-bad/files/config_system.xml"
out="$(probe '' "service_state_restore '$TMP/out/cap-bad' '$TMP/out/scratch2'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a capture that does not verify was restored anyway: $out"
[[ ! -d "$TMP/out/scratch2" ]] || fail "it created a target for a restore it refused"
echo "  refused on verification, and nothing was written"

sect "an INCOMPLETE capture is refused"
build_jellyfin
rm -f "$TMP/data/jellyfin/config/network.xml"
rm -rf "$TMP/out/cap-inc" "$TMP/out/scratch3"
probe '' "service_state_capture jellyfin '$TMP/out/cap-inc'" >/dev/null 2>&1
out="$(probe '' "service_state_restore '$TMP/out/cap-inc' '$TMP/out/scratch3'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "an incomplete capture was restored as though whole: $out"
echo "  refused"

sect "a restored DATABASE is asked whether it is sound"
build_jellyfin
rm -rf "$TMP/out/cap-db" "$TMP/out/scratch4"
probe '' "service_state_capture jellyfin '$TMP/out/cap-db'" >/dev/null
out="$(probe '' "service_state_restore '$TMP/out/cap-db' '$TMP/out/scratch4'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a sound database did not restore: $out"
grep -q 'restored databases: 1 checked sound' <<< "$out" \
  || fail "the restored database was not integrity-checked: $out"
echo "  checked sound by the host's own sqlite"

sect "a CORRUPT database fails the restore, even though its digest matches"
# The capture's digest is of the bytes that were captured; if those bytes are a
# broken database the digest matches perfectly. Only opening it finds out.
build_jellyfin
python3 - "$TMP/data/jellyfin/config/data/data/jellyfin.db" <<'MKBAD'
import sys
# Corrupt page content, leaving the header magic intact so the file is still
# recognised as SQLite and integrity_check actually runs.
p = sys.argv[1]
d = bytearray(open(p,'rb').read())
for i in range(100, min(len(d), 400)):
    d[i] = 0xFF
open(p,'wb').write(bytes(d))
MKBAD
rm -rf "$TMP/out/cap-bad-db" "$TMP/out/scratch5"
probe '' "service_state_capture jellyfin '$TMP/out/cap-bad-db'" >/dev/null
out="$(probe '' "service_state_restore '$TMP/out/cap-bad-db' '$TMP/out/scratch5'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" \
  || fail "a corrupt database restored with a matching digest and reported success --
a digest proves the bytes arrived, not that they are a usable database: $out"
grep -q 'not a sound database after restore' <<< "$out" || fail "it does not say what is wrong: $out"
echo "  digest matched, the database did not, and the restore failed"

# ---------------------------------------------------------------------------
sect "STRICT MODE: the capture survives production's own shell options"
# A test that relaxes production's shell options is not a test of production.
# `probe` runs `set +e`, so an abort under `set -euo pipefail` cannot show
# there -- and the digest helpers are pipelines, exactly the shape that has
# aborted this project's functions before. Drive it in its own bash process.
build_jellyfin
rm -rf "$TMP/out/strict"
cat > "$TMP/strict.sh" <<STRICT
set -euo pipefail
export PATH="$TMP/bin:\$PATH"
export DOMUM_DATA_ROOT="$TMP/data"
DOMUM_DIR=$(printf '%q' "$REPO_ROOT")
CFG_FILE="$TMP/absent.conf"
source $(printf '%q' "$CLI") >/dev/null 2>&1
tracked_service_container_id_any() { return 1; }
service_state_capture jellyfin "$TMP/out/strict"
service_state_verify "$TMP/out/strict"
service_state_restore "$TMP/out/strict" "$TMP/out/strict-restored"
echo STRICT-OK
STRICT
out="$(bash "$TMP/strict.sh" 2>&1)" || true
grep -q 'STRICT-OK' <<< "$out" \
  || fail "the capture/verify/restore chain aborts under 'set -euo pipefail',
which is what production runs: $out"
echo "  capture, verify and restore all complete under set -euo pipefail"

# ---------------------------------------------------------------------------
sect "MUTATION: accepting a missing item makes a partial capture look COMPLETE"
build_jellyfin
rm -f "$TMP/data/jellyfin/config/encoding.xml"
cp "$CLI" "$TMP/cli.orig"
cat > "$TMP/mutate.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''  if (( bad > 0 )); then
    printf 'RESULT=INCOMPLETE\\n' >> "$manifest"'''
new = '''  if (( bad < 0 )); then
    printf 'RESULT=INCOMPLETE\\n' >> "$manifest"'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT
( python3 -I "$TMP/mutate.py" "$CLI" ) || { cp "$TMP/cli.orig" "$CLI"; fail "the mutation did not apply"; }
rm -rf "$TMP/out/mut"
mout="$(probe '' "service_state_capture jellyfin '$TMP/out/mut'; echo RC=\$?")"
cp "$TMP/cli.orig" "$CLI"
grep -q 'RC=0' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the bad-item check a
capture missing a declared file must report success: $mout"
grep -q '^RESULT=COMPLETE$' "$TMP/out/mut/MANIFEST" \
  || fail "the mutant did not mark the partial capture COMPLETE: $(cat "$TMP/out/mut/MANIFEST")"
echo "  killed: without the check, a capture missing a declared file reads COMPLETE"

sect "MUTATION: copying a database instead of .backup loses the consistency claim"
# The claim, not the bytes, is what this protects: a service that ships sqlite3
# must not silently fall back to a file copy and still be recorded consistent.
cp "$CLI" "$TMP/cli.orig2"
cat > "$TMP/mutate2.py" <<'PYMUT2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''  if service_sqlite_binary "$1" >/dev/null 2>&1; then
    printf 'consistent'
  else
    printf 'unproven'
  fi'''
new = "  printf 'consistent'"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT2
( python3 -I "$TMP/mutate2.py" "$CLI" ) || { cp "$TMP/cli.orig2" "$CLI"; fail "the second mutation did not apply"; }
m2="$(probe '' 'service_state_capture_mode jellyfin')"
cp "$TMP/cli.orig2" "$CLI"
[[ "$m2" == "consistent" ]] \
  || fail "the mutation changed no ANSWER -- declaring every service consistent
must make jellyfin, which has no sqlite3 anywhere, claim consistency: $m2"
echo "  killed: a service with no sqlite3 would claim a consistent capture"

sect "MUTATION: without the overlap guard a restore writes into LIVE state"
build_jellyfin
rm -rf "$TMP/out/cap-m3"
probe '' "service_state_capture jellyfin '$TMP/out/cap-m3'" >/dev/null
cp "$CLI" "$TMP/cli.orig3"
cat > "$TMP/mutate3.py" <<'PYMUT3'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  if [[ "$rtarget" == "$rlive" || "$rtarget" == "$rlive"/* || "$rlive" == "$rtarget"/* ]]; then'
new = '  if [[ "$rtarget" == "$rtarget/cannot-hold" ]]; then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT3
( python3 -I "$TMP/mutate3.py" "$CLI" ) || { cp "$TMP/cli.orig3" "$CLI"; fail "the third mutation did not apply"; }
# An EMPTY path inside the live tree: the non-empty guard cannot catch this
# one, so the overlap guard is the only thing standing in the way.
mout="$(probe '' "service_state_restore '$TMP/out/cap-m3' '$TMP/data/jellyfin/config/restored'; echo RC=\$?")"
wrote=0; [[ -e "$TMP/data/jellyfin/config/restored/config/system.xml" ]] && wrote=1
cp "$TMP/cli.orig3" "$CLI"
rm -rf "$TMP/data/jellyfin/config/restored"
[[ "$wrote" == "1" ]] \
  || fail "the mutation changed no ANSWER -- with the overlap comparison
neutralised, a restore into the live tree must actually write there: $mout"
echo "  killed: without the guard, a restore writes inside the live state tree"

sect "MUTATION: without the verify gate it writes before knowing the capture is sound"
build_jellyfin
rm -rf "$TMP/out/cap-m4" "$TMP/out/scratch-m4"
probe '' "service_state_capture jellyfin '$TMP/out/cap-m4'" >/dev/null
printf 'rot\n' >> "$TMP/out/cap-m4/files/config_system.xml"
cp "$CLI" "$TMP/cli.orig4"
cat > "$TMP/mutate4.py" <<'PYMUT4'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  service_state_verify "$dir" >/dev/null 2>&1 || {'
new = '  true || {'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUT4
( python3 -I "$TMP/mutate4.py" "$CLI" ) || { cp "$TMP/cli.orig4" "$CLI"; fail "the fourth mutation did not apply"; }
mout="$(probe '' "service_state_restore '$TMP/out/cap-m4' '$TMP/out/scratch-m4'; echo RC=\$?")"
created=0; [[ -d "$TMP/out/scratch-m4" ]] && created=1
cp "$TMP/cli.orig4" "$CLI"
[[ "$created" == "1" ]] \
  || fail "the mutation changed no ANSWER -- without the gate, a damaged capture
must get as far as creating its target: $mout"
# The per-item digest comparison is the second layer and must still catch it.
grep -q 'RC=1' <<< "$mout" \
  || fail "a damaged capture restored and reported SUCCESS even with the
per-item digest comparison in place: $mout"
echo "  killed: the refusal-before-writing is gone; the per-item digest still catches it"

echo "ALL STATE-CAPTURE CHECKS PASSED"
