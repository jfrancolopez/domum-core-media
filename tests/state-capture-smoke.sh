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

sect "the restore report states the CAPTURE MODE, not only the digests"
# A digest proves the bytes restored are the bytes captured. It says nothing
# about whether those bytes were a consistent point in time, and jellyfin's and
# kavita's databases are BOTH WAL-mode (measured from the SQLite header, bytes
# 18/19) with no sqlite3 in their image or on the host -- so their captures are
# copies taken while the service may be writing. A restore report that omits
# the mode reads as strong for an unproven capture as for a consistent one.
build_jellyfin
rm -rf "$TMP/out/capm" "$TMP/out/scratchm"
probe '' "service_state_capture jellyfin '$TMP/out/capm'" >/dev/null
out="$(probe '' "service_state_restore '$TMP/out/capm' '$TMP/out/scratchm'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the restore did not succeed: $out"
grep -q 'capture mode: UNPROVEN' <<< "$out" \
  || fail "jellyfin's restore does not say its capture mode was unproven: $out"
grep -qi 'while the service could be writing' <<< "$out" \
  || fail "it does not say WHY unproven means what it means: $out"
echo "  UNPROVEN stated, with the reason"

sect "a CONSISTENT capture says so, so the unproven wording is not boilerplate"
# Without this, 'capture mode: UNPROVEN' could be printed unconditionally and
# the assertion above would pass against a report that cannot tell the two
# apart.
sed -i 's/^CAPTURE_MODE=unproven$/CAPTURE_MODE=consistent/' "$TMP/out/capm/MANIFEST"
rm -rf "$TMP/out/scratchc"
out="$(probe '' "service_state_restore '$TMP/out/capm' '$TMP/out/scratchc'; echo RC=\$?")"
grep -q 'capture mode: consistent' <<< "$out" || fail "a consistent capture is not reported as one: $out"
grep -q 'UNPROVEN' <<< "$out" && fail "it printed UNPROVEN for a consistent capture: $out"
echo "  consistent reported distinctly"

sect "a mode key that was NEVER WRITTEN must not read as the reassuring value"
# The metadata-key family: a key the writer never emitted matches nothing and
# yields an empty string, which must become 'unknown', never 'consistent'.
sed -i '/^CAPTURE_MODE=/d' "$TMP/out/capm/MANIFEST"
rm -rf "$TMP/out/scratchu"
out="$(probe '' "service_state_restore '$TMP/out/capm' '$TMP/out/scratchu'; echo RC=\$?")"
grep -q 'consistency is unknown' <<< "$out" \
  || fail "an absent CAPTURE_MODE did not read as unknown: $out"
grep -q 'capture mode: consistent' <<< "$out" \
  && fail "an absent key read as consistent, which is the metadata-key defect: $out"
echo "  absent key reads as unknown"

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

# ---------------------------------------------------------------------------
# The QUIESCED capture -- the only capture path that causes downtime.
#
# Measured 2026-11-02 from the SQLite file header: jellyfin.db and kavita.db are
# BOTH WAL-mode, and neither their images nor this host has an sqlite3, so their
# ordinary captures are copies of a WAL database taken while the service may be
# writing. A quiesce is the only way to make them consistent.
# ---------------------------------------------------------------------------
QSTUB='
need_root() { :; }
compose_cmd() { printf "compose %s\n" "$*" >> "$CALLS"; }
service_compose_services() { printf "jellyfin"; }
service_runtime_state() { printf "%s" "${FAKE_RUNTIME:-running}"; }
migrate_assert_quiesced() { [[ -z "${FAKE_NOT_QUIESCED:-}" ]]; }
domum_acquire_lock() { printf "lock %s\n" "$*" >> "$CALLS"; return 0; }
domum_lock_holder() { printf "nobody"; }
'

sect "ROOT is required BEFORE the stop, not discovered after it"
# Measured 2026-11-03 against the real Jellyfin image: its DataProtection key is
# `-rw------- root root`, so an unprivileged run stopped the service, could not
# read the one item that decrypts its stored secrets, and reported INCOMPLETE.
# Failing closed was right; spending downtime on a capture that could never
# succeed was not. "A closed gate that still causes downtime is not a closed
# gate" applies to a missing privilege exactly as to a feature flag.
#
# need_root is deliberately NOT stubbed here, and the real one dies.
build_jellyfin
rm -rf "$TMP/out/r0"; : > "$TMP/calls"
out="$(CALLS="$TMP/calls" QUIESCED_CAPTURE_ENABLED=1 \
       probe 'compose_cmd() { printf "compose %s\n" "$*" >> "$CALLS"; }
domum_acquire_lock() { printf "lock\n" >> "$CALLS"; return 0; }' \
       "service_state_capture_quiesced jellyfin '$TMP/out/r0'; echo RC=\$?")"
grep -qi 'run as root' <<< "$out" \
  || fail "an unprivileged quiesced capture did not demand root: $out"
[[ ! -s "$TMP/calls" ]] \
  || fail "it took the lock or stopped something before finding out it needed
root -- downtime spent on a capture that cannot succeed: $(cat "$TMP/calls")"
[[ ! -d "$TMP/out/r0" ]] || fail "it created a destination it could not fill"
# And the root check must come before the GATE too, so the ordering is pinned
# in the source: a reader must not have to guess which refusal happens first.
fn="$(awk '/^service_state_capture_quiesced\(\) \{/,/^\}/' "$CLI")"
r_line="$(grep -n '^  need_root$' <<< "$fn" | head -1 | cut -d: -f1)"
g_line="$(grep -n 'QUIESCED_CAPTURE_ENABLED' <<< "$fn" | head -1 | cut -d: -f1)"
s_line="$(grep -n 'compose_cmd stop' <<< "$fn" | head -1 | cut -d: -f1)"
[[ -n "$r_line" && -n "$g_line" && -n "$s_line" ]] || fail "could not locate root, gate and stop"
(( r_line < g_line )) || fail "need_root at $r_line is after the gate at $g_line"
(( g_line < s_line )) || fail "the gate at $g_line is after the stop at $s_line"
echo "  root($r_line) < gate($g_line) < stop($s_line); nothing locked or stopped"

sect "an UNREADABLE item is recorded as FAILED:UNREADABLE, not a bare FAILED"
# An unactionable FAIL trains the operator to ignore it. The overwhelming cause
# is a privilege problem, so the record says so.
build_jellyfin
chmod 0000 "$TMP/data/jellyfin/config/system.xml"
rm -rf "$TMP/out/unread"
out="$(probe "$QSTUB" "service_state_capture jellyfin '$TMP/out/unread'; echo RC=\$?")"
chmod 0644 "$TMP/data/jellyfin/config/system.xml"
grep -q 'RC=1' <<< "$out" || fail "an unreadable declared item did not fail the capture: $out"
grep -q 'FAILED:UNREADABLE' "$TMP/out/unread/MANIFEST" \
  || fail "the manifest does not say WHY the item could not be captured: $(cat "$TMP/out/unread/MANIFEST")"
# verify and restore must treat the labelled form exactly like the bare one --
# matching only bare FAILED would make it look like something to restore.
out="$(probe "$QSTUB" "service_state_verify '$TMP/out/unread'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "verification accepted a capture with an unreadable item: $out"
grep -q 'FAILED:\*' "$CLI" || fail "nothing matches the labelled form"
[[ "$(grep -c 'FAILED:\*' "$CLI")" -ge 3 ]] \
  || fail "the labelled form is matched in fewer than the three places that
examine an item mode (capture's verify, verify-state, restore-state)"
echo "  cause recorded, and every reader treats FAILED:REASON as never-captured"

sect "the gate REFUSES before the lock and before any stop"
# A closed gate that still causes downtime is not a closed gate.
build_jellyfin
rm -rf "$TMP/out/q1"; : > "$TMP/calls"
out="$(CALLS="$TMP/calls" probe "$QSTUB" "service_state_capture_quiesced jellyfin '$TMP/out/q1'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "the gate did not refuse: $out"
grep -q 'REFUSING' <<< "$out" || fail "it does not say it is refusing: $out"
[[ ! -s "$TMP/calls" ]] \
  || fail "the refusal took the lock or stopped something: $(cat "$TMP/calls")"
[[ ! -d "$TMP/out/q1" ]] || fail "it created a destination for a capture it refused"
echo "  refused, no lock, no stop, no destination"

sect "with the gate OPEN it stops, proves quiescence, captures and uses compose START"
build_jellyfin
rm -rf "$TMP/out/q2"; : > "$TMP/calls"
out="$(CALLS="$TMP/calls" QUIESCED_CAPTURE_ENABLED=1 \
       probe "$QSTUB" "service_state_capture_quiesced jellyfin '$TMP/out/q2'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a clean quiesced capture failed: $out
calls: $(cat "$TMP/calls")"
grep -q '^compose stop jellyfin$' "$TMP/calls" || fail "it never stopped the service: $(cat "$TMP/calls")"
grep -q '^compose start jellyfin$' "$TMP/calls" || fail "it never restarted the service: $(cat "$TMP/calls")"
grep -qE '^compose up' "$TMP/calls" \
  && fail "it used 'up -d', which RECONCILES -- that turns a capture into an
unreviewed deployment of whatever the tag now resolves to: $(cat "$TMP/calls")"
grep -q '^RESULT=COMPLETE$' "$TMP/out/q2/MANIFEST" || fail "the capture is not complete"
grep -q '^CAPTURE_MODE=quiesced$' "$TMP/out/q2/MANIFEST" \
  || fail "the mode is not recorded as quiesced: $(cat "$TMP/out/q2/MANIFEST")"
grep -q 'file-copy-quiesced' "$TMP/out/q2/MANIFEST" \
  || fail "the database item is not recorded as a quiesced copy: $(cat "$TMP/out/q2/MANIFEST")"
grep -q 'file-copy-unproven' "$TMP/out/q2/MANIFEST" \
  && fail "a stopped service's copy is still called unproven: $(cat "$TMP/out/q2/MANIFEST")"
echo "  stop -> quiesce proof -> capture -> compose start; mode quiesced"

sect "the LOCK is taken before the stop, and nothing invents a release"
# The lock must be taken before the stop, or a concurrent operation could run
# against a service this one has stopped.
#
# There is no release assertion, because there is no release FUNCTION:
# domum_acquire_lock holds the lock through a file descriptor for the life of
# the process, it is re-entrant, and storage_pre_upgrade_point does not release
# it either. The first version of this test stubbed a `domum_release_lock` --
# a stub of a function the CLI does not have, which is precisely how the
# invented call survived until tests/function-definition-audit.py found it.
l="$(grep -n '^lock' "$TMP/calls" | head -1 | cut -d: -f1)"
st="$(grep -n '^compose stop' "$TMP/calls" | head -1 | cut -d: -f1)"
sr="$(grep -n '^compose start' "$TMP/calls" | head -1 | cut -d: -f1)"
[[ -n "$l" && -n "$st" && -n "$sr" ]] || fail "missing a call: $(cat "$TMP/calls")"
(( l < st )) || fail "the lock was taken at $l, AFTER the stop at $st"
(( st < sr )) || fail "the restart at $sr precedes the stop at $st"
# Comments stripped: the comment explaining this very mistake names the
# function, and the first version of this assertion flagged it. That is the
# rule this project records -- strip comments before asserting code does NOT
# contain something -- broken in the assertion written to enforce it.
code="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media")"
grep -q 'domum_release_lock' <<< "$code" \
  && fail "something CALLS domum_release_lock, which does not exist"
echo "  lock($l) < stop($st) < start($sr); no invented release"

sect "a STOPPED service is captured without starting it"
# A capture preserves runtime state: stopped before -> stopped after. Starting
# it would be a side effect nobody asked for.
build_jellyfin
rm -rf "$TMP/out/q3"; : > "$TMP/calls"
out="$(CALLS="$TMP/calls" QUIESCED_CAPTURE_ENABLED=1 FAKE_RUNTIME=stopped \
       probe "$QSTUB" "service_state_capture_quiesced jellyfin '$TMP/out/q3'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "capturing an already-stopped service failed: $out"
grep -qE '^compose (stop|start)' "$TMP/calls" \
  && fail "it stopped or started a service that was already stopped: $(cat "$TMP/calls")"
grep -q '^CAPTURE_MODE=quiesced$' "$TMP/out/q3/MANIFEST" || fail "mode not quiesced"
echo "  no stop, no start, still a quiesced capture"

sect "quiescence that cannot be PROVEN refuses, and restarts the service"
build_jellyfin
rm -rf "$TMP/out/q4"; : > "$TMP/calls"
out="$(CALLS="$TMP/calls" QUIESCED_CAPTURE_ENABLED=1 FAKE_NOT_QUIESCED=1 \
       probe "$QSTUB" "service_state_capture_quiesced jellyfin '$TMP/out/q4'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "an unquiesced state still produced a capture: $out"
grep -q 'not quiesced' <<< "$out" || fail "it does not say why it refused: $out"
grep -q '^compose start jellyfin$' "$TMP/calls" \
  || fail "it refused and left the service DOWN: $(cat "$TMP/calls")"
[[ ! -d "$TMP/out/q4" ]] || fail "it wrote a capture it had refused to make"
echo "  refused, service restarted, nothing captured"

sect "a RESTORE of a quiesced capture states the stronger claim"
rm -rf "$TMP/out/q2restored"
out="$(probe '' "service_state_restore '$TMP/out/q2' '$TMP/out/q2restored'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a quiesced capture did not restore: $out"
grep -q 'capture mode: quiesced' <<< "$out" || fail "the quiesced mode is not reported: $out"
grep -q 'strongest capture mode' <<< "$out" \
  || fail "it does not distinguish quiesced from the other two modes: $out"
grep -q 'UNPROVEN' <<< "$out" && fail "a quiesced restore was called unproven: $out"
echo "  reported as the strongest mode, and not as unproven"

sect "the DISPATCH reaches the quiesced path only with --quiesce"
# A function that works when called directly but is unreachable through the
# dispatcher is the defect the capabilities audit exists for. `load_cfg` runs
# before the dispatch and needs a real config, so it is stubbed here and the
# real `storage_cmd` arm is what gets driven.
DSTUB='
load_cfg() { :; }
service_state_capture() { printf "PLAIN %s %s\n" "$1" "$2"; }
service_state_capture_quiesced() { printf "QUIESCED %s %s\n" "$1" "$2"; }
'
out="$(probe "$DSTUB" "storage_cmd capture-state jellyfin /tmp/x --quiesce")"
grep -q '^QUIESCED jellyfin /tmp/x$' <<< "$out" \
  || fail "--quiesce does not reach the quiesced path through storage_cmd: $out"
out="$(probe "$DSTUB" "storage_cmd capture-state jellyfin /tmp/x")"
grep -q '^PLAIN jellyfin /tmp/x$' <<< "$out" \
  || fail "the ordinary capture is not reached without the flag: $out"
# An unknown third argument must not silently select the downtime path.
out="$(probe "$DSTUB" "storage_cmd capture-state jellyfin /tmp/x --quiesceee")"
grep -q '^PLAIN ' <<< "$out" \
  || fail "a misspelled flag selected something other than the ordinary path: $out"
echo "  --quiesce routes to the quiesced path; absent or misspelled routes to the plain one"

sect "the destination DEFAULTS, so a capture is schedulable"
# Without a default every invocation needs an operator-invented path, which
# means nothing can be scheduled and a backup scope has nothing stable to name.
# It deliberately does NOT put the capture off-site: the cloud target is
# immich-only, so the default is on the protected local tier and nowhere else.
DEFSTUB='
load_cfg() { :; }
service_state_capture() { printf "PLAIN %s|%s\n" "$1" "$2"; }
service_state_capture_quiesced() { printf "QUIESCED %s|%s\n" "$1" "$2"; }
'
out="$(probe "$DEFSTUB" "DOMUM_DATA_ROOT=/d storage_cmd capture-state kavita")"
grep -qE '^PLAIN kavita\|/d/backups/state/kavita/[0-9]{8}-[0-9]{6}$' <<< "$out" \
  || fail "no default destination, so a capture cannot be scheduled: $out"
# A sibling of the service directory, never inside it: a capture written under
# /srv/data/<service> would duplicate into every per-service snapshot.
grep -q '|/d/kavita' <<< "$out" \
  && fail "the default is INSIDE the service directory, so it would duplicate
into every per-service snapshot of that service: $out"
echo "  defaults to <data>/backups/state/<service>/<stamp>, beside the service"

sect "an explicit destination still wins, and --quiesce works in either position"
out="$(probe "$DEFSTUB" "DOMUM_DATA_ROOT=/d storage_cmd capture-state kavita /tmp/mine")"
grep -q '^PLAIN kavita|/tmp/mine$' <<< "$out" || fail "an explicit path was ignored: $out"
out="$(probe "$DEFSTUB" "DOMUM_DATA_ROOT=/d storage_cmd capture-state kavita /tmp/mine --quiesce")"
grep -q '^QUIESCED kavita|/tmp/mine$' <<< "$out" || fail "--quiesce after a path did not route: $out"
# --quiesce in the destination slot must not be taken AS the destination, or the
# capture would be written to a directory called "--quiesce".
out="$(probe "$DEFSTUB" "DOMUM_DATA_ROOT=/d storage_cmd capture-state kavita --quiesce")"
grep -qE '^QUIESCED kavita\|/d/backups/state/kavita/[0-9]{8}-[0-9]{6}$' <<< "$out" \
  || fail "--quiesce in the destination slot was mishandled: $out"
grep -q 'quiesce' <<< "${out#*|}" \
  && fail "it used the flag as the destination path: $out"
echo "  explicit path wins; --quiesce in either slot never becomes the path"

sect "the stale 'in the backup set' claim is gone from the archive comment"
# It read "an archive here IS in the off-host backup set (measured)", which was
# true of the GLOBAL include set and false of the target that runs: the cloud
# target is immich-only and /srv/data/backups/images is NOT COVERED. The
# operator found that by listing the Hetzner snapshot from another machine.
arch="$(sed -n '/^# \/srv\/data\/backups is the right tier/,/^image_archive_dir() {/p' "$CLI")"
[[ -n "$arch" ]] || fail "could not locate the archive-dir comment block"
grep -q 'IS in the off-host backup set' <<< "$arch" \
  && fail "the archive comment still claims an archive there is in the off-host
backup set. The cloud target is immich-only: $arch"
grep -q 'NOT COVERED' <<< "$arch" \
  || fail "the corrected comment does not say the archives are not covered: $arch"
echo "  corrected, and it says what is actually true"

sect "--quiesce is in the usage text, so the operator can find it"
grep -q "capture-state <service> \[dir\] \[--quiesce\]" "$CLI" \
  || fail "--quiesce is not documented in the storage usage string"
echo "  documented"

sect "MUTATION: without the gate it STOPS a production service"
build_jellyfin
rm -rf "$TMP/out/qm"; : > "$TMP/calls"
cp "$CLI" "$TMP/cli.origq"
cat > "$TMP/mutq.py" <<'PYMUTQ'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  if (( ${QUIESCED_CAPTURE_ENABLED:-0} != 1 )); then'
new = '  if (( 1 != 1 )); then'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUTQ
( python3 -I "$TMP/mutq.py" "$CLI" ) || { cp "$TMP/cli.origq" "$CLI"; fail "the gate mutation did not apply"; }
mout="$(CALLS="$TMP/calls" probe "$QSTUB" "service_state_capture_quiesced jellyfin '$TMP/out/qm'" 2>&1)"
stopped=0; grep -q '^compose stop' "$TMP/calls" && stopped=1
cp "$TMP/cli.origq" "$CLI"
[[ "$stopped" == "1" ]] \
  || fail "the mutation changed no ANSWER -- with the gate neutralised and the
flag unset, the service must actually be stopped: $mout
calls: $(cat "$TMP/calls")"
echo "  killed: without the gate, an unset flag still stops the service"


sect "a database the HOST cannot read is checked by the APPLICATION's own sqlite"
# This function's comment said restored databases are asked "by the
# application's own SQLite where there is one". That was true of the comment
# and false of the code: it called domum_sqlite_check, which tries the HOST's
# sqlite3 and then the host's python3, and never
# domum_sqlite_check_via_container -- the one that uses service_sqlite_binary.
# The migration path has used the container since the `collating` defect; the
# restore did not.
#
# Found by rehearsing against the REAL images, 2026-11-04. navidrome's restored
# database reported `1 checked sound` because the host python3 can read it,
# while PLEX's reported `0 checked sound, 2 not checked` -- its FTS tables use
# Plex's own `collating` tokenizer, which only `Plex SQLite` registers.
# Externally, those exact restored bytes answer `ok` with 82 tables under that
# binary. So the one service whose image is the only PROVEN copy of its
# application half was also the one whose restore could not tell a sound
# database from a broken one.
build_jellyfin
rm -rf "$TMP/out/cap-via" "$TMP/out/scratch-via"
probe '' "service_state_capture jellyfin '$TMP/out/cap-via'" >/dev/null
# The host cannot read it (the `collating` shape), and the application can.
VIA_STUBS='domum_sqlite_check() { printf "unsupported: unknown tokenizer: collating"; }
domum_sqlite_check_via_container() { printf "ok"; return 0; }'
out="$(probe "$VIA_STUBS" "service_state_restore '$TMP/out/cap-via' '$TMP/out/scratch-via'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the restore failed: $out"
grep -q 'restored databases: 1 checked sound, 0 not checked' <<< "$out" \
  || fail "a database the host cannot read but the application CAN was still
reported as not checked: $out"
grep -q "checked with jellyfin's own sqlite3" <<< "$out" \
  || fail "it does not say WHICH sqlite answered, so 'checked sound' cannot be
distinguished from a host check: $out"
echo "  the application answered, and the report says so"

sect "and the container is asked ONLY when the host could not answer"
# A host check that says the database is BROKEN must not be retried against the
# container: a second opinion overturning a real failure is the wrong direction
# for a restore. The stub RECORDS whether it was called, because asserting that
# the restore failed would pass even if the fallback had run and agreed.
rm -rf "$TMP/out/scratch-via2"; : > "$TMP/via-called"
BAD_STUBS='domum_sqlite_check() { printf "integrity_check: database disk image is malformed"; }
domum_sqlite_check_via_container() { echo called >> "'"$TMP"'/via-called"; printf "ok"; return 0; }'
out="$(probe "$BAD_STUBS" "service_state_restore '$TMP/out/cap-via' '$TMP/out/scratch-via2'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a broken database restored successfully: $out"
grep -q 'not a sound database after restore' <<< "$out" || fail "it does not say what is wrong: $out"
[[ ! -s "$TMP/via-called" ]] \
  || fail "the container was asked about a database the host already called BROKEN --
a second opinion must not be able to overturn a real failure"
echo "  a broken verdict stands; the fallback is not consulted"

sect "and a database NEITHER can read is still 'not checked', never a pass"
rm -rf "$TMP/out/scratch-via3"
NONE_STUBS='domum_sqlite_check() { printf "unsupported: unknown tokenizer: collating"; }
domum_sqlite_check_via_container() { return 1; }'
out="$(probe "$NONE_STUBS" "service_state_restore '$TMP/out/cap-via' '$TMP/out/scratch-via3'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "an unreadable-but-not-broken database failed the restore: $out"
grep -q 'restored databases: 0 checked sound, 1 not checked' <<< "$out" \
  || fail "'I could not check it' was not reported as exactly that: $out"
grep -q "checked with jellyfin's own sqlite3" <<< "$out" \
  && fail "it claimed the application answered when the fallback returned nothing: $out"
echo "  not checked, and it does not claim otherwise"

sect "MUTATION: without the fallback, the application's own sqlite is never asked"
MUTV="$TMP/mut-via"; mkdir -p "$MUTV"; cp "$CLI" "$MUTV/domum-media"
python3 -I - "$MUTV/domum-media" <<'PYMV' || fail "the fallback mutation did not apply"
import io, sys
# Anchored on a SINGLE-LINE unique substring with no backslash in it.
# Expressing the real line's trailing continuation through two heredoc layers
# needs enough escaping to silently not match -- and a mutation that does not
# match is one that applies textually while changing nothing, which this
# project has paid for before.
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Narrowed to the RESTORE's call: migrate_sqlite_integrity makes the same call
# with different arguments, so the shorter prefix matched twice.
old = 'if via="$(domum_sqlite_check_via_container "$service" "$dst"'
new = 'if false && via="$(domum_sqlite_check_via_container "$service" "$dst"'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMV
grep -q 'if false && via=' "$MUTV/domum-media" \
  || fail "the mutation is not in the file"
rm -rf "$TMP/out/scratch-via4"
saved_cli="$CLI"; CLI="$MUTV/domum-media"
out="$(probe "$VIA_STUBS" "service_state_restore '$TMP/out/cap-via' '$TMP/out/scratch-via4'; echo RC=\$?")"
CLI="$saved_cli"
grep -q 'restored databases: 0 checked sound, 1 not checked' <<< "$out" \
  || fail "the mutation changed no ANSWER -- without the fallback a database the
host cannot read must read as 'not checked': $out"
echo "  killed: without it, plex's databases are unverifiable on restore"

echo "ALL STATE-CAPTURE CHECKS PASSED"
