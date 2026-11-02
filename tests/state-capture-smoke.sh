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
  printf 'SQLite format 3\000library-rows' > "$TMP/data/jellyfin/config/data/data/jellyfin.db"
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
    cmd_exists() { [[ "$1" != docker ]]; }
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

echo "ALL STATE-CAPTURE CHECKS PASSED"
