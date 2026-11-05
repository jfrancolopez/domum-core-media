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
grepF_q() {  # $1 = fixed string, $2 = already-captured text
  grep -qF -- "$1" <<< "$2"
}

build_calibre_web() {
  rm -rf "$TMP/data/calibre-web"
  mkdir -p "$TMP/data/calibre-web/config"
  # A REAL database with calibre-web's encrypted-column convention, so the
  # premise of declaring the key is visible in the fixture rather than only in
  # a comment: the `_e` suffix is what calibre-web uses for a Fernet-encrypted
  # value.
  python3 - "$TMP/data/calibre-web/config/app.db" <<'MKCW'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table settings(id integer primary key, mail_password_e text,"
            " config_ldap_serv_password_e text)")
con.execute("insert into settings values (1,'gAAAAAB_ciphertext','gAAAAAB_more')")
con.commit(); con.close()
MKCW
  printf 'gdrive-placeholder\n' > "$TMP/data/calibre-web/config/gdrive.db"
  printf '{}\n' > "$TMP/data/calibre-web/config/client_secrets.json"
  # 44 bytes, 0600: the real shape of a Fernet key as calibre-web creates it.
  # Exactly 44 bytes: a Fernet key is 43 urlsafe-base64 characters plus the
  # '=' pad. The first version of this fixture was 43 and the assertion below
  # failed on the FIXTURE rather than on the code.
  printf '%s' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
    > "$TMP/data/calibre-web/config/.key"
  chmod 0600 "$TMP/data/calibre-web/config/.key"
  # Regenerable, and deliberately NOT declared.
  printf 'log noise\n' > "$TMP/data/calibre-web/config/calibre-web.log"
}

build_kavita() {
  rm -rf "$TMP/data/kavita"
  mkdir -p "$TMP/data/kavita/config/templates" "$TMP/data/kavita/config/logs"
  python3 - "$TMP/data/kavita/config/kavita.db" <<'MKKV'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table AppUser(Id integer primary key, UserName text)")
con.execute("insert into AppUser values (1,'operator')")
con.commit(); con.close()
MKKV
  printf '<t/>\n' > "$TMP/data/kavita/config/templates/EmailTemplate.html"
  # The JWT TokenKey lives here. A restored kavita.db without it means Kavita
  # mints a NEW key and every session and API key silently stops working.
  printf '{"TokenKey":"%s","Port":5000}\n' "$(printf 'k%.0s' $(seq 1 338))" \
    > "$TMP/data/kavita/config/appsettings.json"
  # Regenerable, and deliberately NOT declared.
  printf 'log noise\n' > "$TMP/data/kavita/config/logs/kavita.log"
}

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
  # The server's IDENTITY, 35 bytes in production and on a fresh install. Same
  # artefact class as plex's Preferences.xml, which is declared for exactly
  # this reason.
  printf '%s\n' '01234567890123456789012345678901234' \
    > "$TMP/data/jellyfin/config/data/data/device.txt"
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
# 7 since device.txt was declared: the server's IDENTITY, the same artefact
# class as plex's Preferences.xml. This count moved because the DECLARATION
# was wrong, not because the test was -- a restored jellyfin without it is a
# new server and every client must re-pair.
[[ "$n_items" == "7" ]] || fail "expected 7 captured items, manifest has $n_items"
# Nothing regenerable came along.
stray="$(find "$TMP/out/jf/files" -name '*jellyfin.log*')"
[[ -z "$stray" ]] || fail "the capture included the log directory, which is not declared: $stray"
echo "  7 items, manifest COMPLETE, mode recorded, no undeclared files"

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
# Anchored on the FINAL arm only: the function grew an `elif
# sqlite_helper_image` branch when the helper path landed, so the old
# whole-body anchor matched zero times and the mutation silently stopped
# applying. Forcing the fallback arm to claim consistency is what this section
# is actually about.
old = '''  else
    printf 'unproven'
  fi'''
new = '''  else
    printf 'consistent'
  fi'''
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


sect "calibre-web declares the KEY that decrypts what is in its database"
# config/.key is 44 bytes -- a Fernet key -- and app.db stores credentials
# encrypted with it. Measured 2026-11-04 from the PRODUCTION schema (names
# only, no value read): the `_e` suffix is calibre-web's own convention, and
# app.db carries settings.mail_password_e,
# settings.config_ldap_serv_password_e and
# settings.config_reverse_proxy_login_header_secret_e.
#
# The declaration used to be app.db + gdrive.db and MISS the key, so a restore
# would have brought those values back as undecryptable bytes and calibre-web
# would have come up and silently failed to send mail or bind to LDAP. That is
# exactly the case jellyfin's .aspnet/DataProtection-Keys is declared for.
out="$(probe '' 'service_essential_state calibre-web')"
for want in 'config/app.db' 'config/gdrive.db' 'config/.key' 'config/client_secrets.json'; do
  grepF_q "$want" "$out" \
    || fail "calibre-web does not declare $want: $out"
done
grepF_q 'calibre-web.log' "$out" \
  && fail "calibre-web declares its LOG, which is regenerable: $out"
grepF_q 'backups' "$out" \
  && fail "calibre-web declares a backups directory: $out"
echo "  app.db, gdrive.db, the key and the gdrive client secret; not the log"

sect "and the key is CAPTURED with its mode, not just declared"
# A declaration is a list; this drives the capture and asserts the key arrives
# as a 0600 item. A Fernet key restored world-readable would be a disclosure,
# and the digest alone would not notice -- it covers contents, not modes.
build_calibre_web
rm -rf "$TMP/out/cap-cw" "$TMP/out/scratch-cw"
out="$(probe '' "service_state_capture calibre-web '$TMP/out/cap-cw'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the calibre-web capture failed: $out"
grep -q '^ITEMS=4$' "$TMP/out/cap-cw/MANIFEST" || fail "expected 4 items: $(cat "$TMP/out/cap-cw/MANIFEST")"
grep -q 'config/\.key|file-copy|44|600|' "$TMP/out/cap-cw/MANIFEST" \
  || fail "the key was not captured as a 44-byte mode-600 item:
$(cat "$TMP/out/cap-cw/MANIFEST")"
out="$(probe '' "service_state_restore '$TMP/out/cap-cw' '$TMP/out/scratch-cw'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the calibre-web restore failed: $out"
rkey="$(find "$TMP/out/scratch-cw" -name '.key' | head -1)"
[[ -n "$rkey" ]] || fail "the key was not restored"
[[ "$(stat -c %a "$rkey")" == "600" ]] \
  || fail "the key restored as mode $(stat -c %a "$rkey"), not 600"
echo "  captured 44|600 and restored 600"

sect "MUTATION: dropping the key from the declaration must change the ANSWER"
# Not a presence assertion on source text -- that would pass for any list. The
# observable is the CAPTURE: three items instead of four, and no key to
# decrypt app.db's _e columns with.
MUTK="$TMP/mut-key"; mkdir -p "$MUTK"; cp "$CLI" "$MUTK/domum-media"
python3 -I - "$MUTK/domum-media" <<'PYMK' || fail "the key mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "      printf 'file|config/.key\\n'\n"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PYMK
build_calibre_web
rm -rf "$TMP/out/cap-cw-m"
saved_cli="$CLI"; CLI="$MUTK/domum-media"
out="$(probe '' "service_state_capture calibre-web '$TMP/out/cap-cw-m'; echo RC=\$?")"
CLI="$saved_cli"
grep -q 'RC=0' <<< "$out" || fail "the mutant capture failed for an unrelated reason: $out"
grep -q 'config/\.key' "$TMP/out/cap-cw-m/MANIFEST" \
  && fail "the mutation changed no ANSWER -- without the declaration the key
must not be captured"
grep -q '^ITEMS=3$' "$TMP/out/cap-cw-m/MANIFEST" \
  || fail "expected 3 items in the mutant capture: $(cat "$TMP/out/cap-cw-m/MANIFEST")"
echo "  killed: without it the capture is 3 items and app.db's _e values are undecryptable"


sect "kavita declares the TOKEN KEY that signs its sessions"
# appsettings.json holds the JWT TokenKey -- measured 2026-11-04 from the
# production file, key names and lengths only, no value read: TokenKey is 338
# characters, with OpenIdConnectSettings beside it. Restore kavita.db without
# it and Kavita mints a NEW key on startup: every existing session and API key
# stops working, silently, against a database that restored perfectly. Same
# class as calibre-web's Fernet key and jellyfin's DataProtection-Keys.
out="$(probe '' 'service_essential_state kavita')"
for want in 'config/kavita.db' 'config/templates' 'config/appsettings.json'; do
  grepF_q "$want" "$out" || fail "kavita does not declare $want: $out"
done
grepF_q 'config/backups' "$out" \
  && fail "kavita declares its own backups directory, which CLAUDE.md measured at
3.1x the database it backs up: $out"
grepF_q 'cache.db' "$out" && fail "kavita declares its CACHE database: $out"
echo "  kavita.db, templates and the token key; not backups, not the cache"

sect "jellyfin declares its server IDENTITY, as plex does"
out="$(probe '' 'service_essential_state jellyfin')"
grepF_q 'config/data/data/device.txt' "$out" \
  || fail "jellyfin does not declare device.txt -- without it a restored server is
a NEW identity and every client must re-pair, which is the stated reason plex's
Preferences.xml is declared: $out"
echo "  device.txt is declared"

sect "and both arrive in the CAPTURE, not just in the declaration"
build_kavita
rm -rf "$TMP/out/cap-kv" "$TMP/out/scratch-kv"
out="$(probe '' "service_state_capture kavita '$TMP/out/cap-kv'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the kavita capture failed: $out"
grep -q '^ITEMS=3$' "$TMP/out/cap-kv/MANIFEST" \
  || fail "expected 3 kavita items: $(cat "$TMP/out/cap-kv/MANIFEST")"
grep -q 'config/appsettings.json|file-copy|' "$TMP/out/cap-kv/MANIFEST" \
  || fail "the token key file was not captured: $(cat "$TMP/out/cap-kv/MANIFEST")"
out="$(probe '' "service_state_restore '$TMP/out/cap-kv' '$TMP/out/scratch-kv'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the kavita restore failed: $out"
[[ -s "$(find "$TMP/out/scratch-kv" -name appsettings.json | head -1)" ]] \
  || fail "appsettings.json was not restored"
build_jellyfin
rm -rf "$TMP/out/cap-jf-id"
out="$(probe '' "service_state_capture jellyfin '$TMP/out/cap-jf-id'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the jellyfin capture failed: $out"
grep -q 'config/data/data/device.txt|file-copy|' "$TMP/out/cap-jf-id/MANIFEST" \
  || fail "device.txt was not captured: $(cat "$TMP/out/cap-jf-id/MANIFEST")"
echo "  both captured and restored"

sect "MUTATION: dropping either must change the capture, not just the text"
for target in "file|config/appsettings.json" "file|config/data/data/device.txt"; do
  MUTD="$TMP/mut-decl"; rm -rf "$MUTD"; mkdir -p "$MUTD"; cp "$CLI" "$MUTD/domum-media"
  TARGET="$target" python3 -I - "$MUTD/domum-media" <<'PYMD' || fail "the declaration mutation did not apply for $target"
import io, os, sys
p = sys.argv[1]
t = os.environ["TARGET"]
s = io.open(p, encoding="utf-8").read()
old = "      printf '%s\\n'\n" % t
assert s.count(old) == 1, "anchor %r matched %d times" % (old, s.count(old))
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PYMD
  svc=kavita; rel='config/appsettings.json'
  case "$target" in *device.txt) svc=jellyfin; rel='config/data/data/device.txt' ;; esac
  "build_$(tr - _ <<< "$svc")"
  rm -rf "$TMP/out/cap-mutd"
  saved_cli="$CLI"; CLI="$MUTD/domum-media"
  out="$(probe '' "service_state_capture $svc '$TMP/out/cap-mutd'; echo RC=\$?")"
  CLI="$saved_cli"
  grep -q 'RC=0' <<< "$out" || fail "the mutant capture of $svc failed unexpectedly: $out"
  grep -qF "$rel" "$TMP/out/cap-mutd/MANIFEST" \
    && fail "the mutation changed no ANSWER -- without the declaration $rel must
not be captured"
done
echo "  killed: each one disappears from the capture when undeclared"


sect "a captured SECRET never reaches stdout, stderr or the manifest"
# The capture now deliberately contains encryption keys (calibre-web's Fernet
# key), a JWT signing key (kavita) and a server token (plex). So "does a secret
# value leak" stops being hypothetical, and the honest way to ask it is with a
# sentinel rather than by reading the code: put a unique string IN the key and
# require it to appear nowhere but the stored copy.
build_calibre_web
SENTINEL='SeNtInEl-7Q4w9ZxK-do-not-leak'
printf '%s' "$SENTINEL" > "$TMP/data/calibre-web/config/.key"
chmod 0600 "$TMP/data/calibre-web/config/.key"
rm -rf "$TMP/out/cap-leak" "$TMP/out/scratch-leak"
leak_out="$(probe '' "service_state_capture calibre-web '$TMP/out/cap-leak'
service_state_verify '$TMP/out/cap-leak'
service_state_restore '$TMP/out/cap-leak' '$TMP/out/scratch-leak'
echo RC=\$?")"
grep -q 'RC=0' <<< "$leak_out" || fail "the capture/verify/restore chain failed: $leak_out"
grepF_q "$SENTINEL" "$leak_out" \
  && fail "the key's VALUE appeared on stdout/stderr. A capture that contains
credentials must never print them -- the operator pastes this output into
issues and transcripts"
grep -qF "$SENTINEL" "$TMP/out/cap-leak/MANIFEST" \
  && fail "the key's VALUE is in the MANIFEST, which records digests and modes.
A digest identifies the bytes; it must not BE the bytes"
# It MUST be in the stored copy -- that is the backup. Anywhere else is a leak.
holders="$(grep -rlF "$SENTINEL" "$TMP/out/cap-leak" "$TMP/out/scratch-leak" 2>/dev/null | sort)"
expected="$TMP/out/cap-leak/files/config_.key
$TMP/out/scratch-leak/config/.key"
[[ "$holders" == "$(sort <<< "$expected")" ]] \
  || fail "the secret is in files it should not be in.
expected only the stored copy and the restored copy:
$(sort <<< "$expected")
found:
$holders"
echo "  present in the stored and restored copies, and nowhere else"

sect "EVERY directory down to the capture is 0700, not just files/"
# Measured 2026-11-04: `install -d -m 0700 "$dest/files"` applies the mode to
# the LEAF only, so backups/, backups/state/, <service>/ and <stamp>/ came out
# 0755 -- install's own default, not the umask (the mutation below returns 0755
# under a umask of 0002, where a umask-derived mode would be 0775). The
# credential was shielded by ONE directory with four world-traversable parents,
# and the stored key itself is 0644 whenever production's is.
rm -rf "$TMP/data/backups" "$TMP/out/cap-modes"
dest_default="$(probe '' 'state_capture_dir')/calibre-web/stamp1"
build_calibre_web
probe '' "service_state_capture calibre-web '$dest_default'" >/dev/null
for d in "$(probe '' 'state_capture_dir')" \
         "$(probe '' 'state_capture_dir')/calibre-web" \
         "$dest_default" "$dest_default/files"; do
  m="$(stat -c %a "$d" 2>/dev/null || echo MISSING)"
  printf '  %-4s %s\n' "$m" "${d#"$TMP/"}"
  [[ "$m" == "700" ]] \
    || fail "$d is mode $m, not 700 -- a capture containing an encryption key
must not depend on the invoking umask for its confidentiality"
done
echo "  the whole chain is 0700"

sect "MUTATION: hardening only the leaf must leave a parent open"
MUTP2="$TMP/mut-perm"; mkdir -p "$MUTP2"; cp "$CLI" "$MUTP2/domum-media"
python3 -I - "$MUTP2/domum-media" <<'PYMP' || fail "the permission mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  install -d -m 0700 -- "$cap_root" || return 1'
new = '  install -d -- "$cap_root" || return 1'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMP
rm -rf "$TMP/data/backups"
build_calibre_web
saved_cli="$CLI"; CLI="$MUTP2/domum-media"
probe '' "service_state_capture calibre-web '$dest_default'" >/dev/null
CLI="$saved_cli"
mroot="$(stat -c %a "$(probe '' 'state_capture_dir')" 2>/dev/null || echo MISSING)"
[[ "$mroot" != "700" ]] \
  || fail "the mutation changed no ANSWER -- without the explicit mode the
capture root must come back at install's default of 0755, not 0700 (got $mroot)"
echo "  killed: without it the root is $mroot -- install's default, not 0700"


sect "no SHARED production path is re-moded by a capture"
# `install -d -m MODE` sets the mode on an EXISTING directory too, so hardening
# the chain could silently re-mode <data>/backups -- which images/
# (drwxr-x--- root in production) and volumes/ share. The capture creates that
# directory if absent and never passes -m for it. Asserted here rather than
# intended, because "it does not touch it" is exactly the kind of claim this
# project requires evidence for.
rm -rf "$TMP/data/backups"
install -d -m 0755 "$TMP/data/backups"
install -d -m 0750 "$TMP/data/backups/images"
install -d -m 0751 "$TMP/data/backups/volumes"
before_backups="$(stat -c %a "$TMP/data/backups")"
before_images="$(stat -c %a "$TMP/data/backups/images")"
before_volumes="$(stat -c %a "$TMP/data/backups/volumes")"
build_calibre_web
probe '' "service_state_capture calibre-web '$(probe '' 'state_capture_dir')/calibre-web/shared1'" >/dev/null
after_backups="$(stat -c %a "$TMP/data/backups")"
after_images="$(stat -c %a "$TMP/data/backups/images")"
after_volumes="$(stat -c %a "$TMP/data/backups/volumes")"
printf '  backups %s -> %s   images %s -> %s   volumes %s -> %s\n' \
  "$before_backups" "$after_backups" "$before_images" "$after_images" \
  "$before_volumes" "$after_volumes"
[[ "$before_backups" == "$after_backups" ]] \
  || fail "the capture re-moded the SHARED <data>/backups directory
($before_backups -> $after_backups). images/ and volumes/ live there too, and
silently changing a production directory's mode is not this function's business"
[[ "$before_images" == "$after_images" ]] \
  || fail "the capture re-moded <data>/backups/images ($before_images -> $after_images)"
[[ "$before_volumes" == "$after_volumes" ]] \
  || fail "the capture re-moded <data>/backups/volumes ($before_volumes -> $after_volumes)"
# And its own subtree IS hardened, so this is not passing by doing nothing.
[[ "$(stat -c %a "$TMP/data/backups/state")" == "700" ]] \
  || fail "the capture's own root is not 0700, so this section proves nothing"
echo "  shared paths untouched; the capture's own subtree still 0700"


sect "a service with no sqlite3 reaches CONSISTENT when a helper image exists"
# jellyfin and kavita ship no sqlite3 and this host has none, so their captures
# were `file-copy-unproven` -- a copy of a WAL database taken while the service
# may be writing -- and the stated remedy was to STOP the service. That was
# wrong. Measured 2026-11-04 against disposable live databases of the REAL
# images, with a helper container that ships sqlite3:
#
#   kavita    main 966,656  -wal 4,132,392  -> .backup 1,105,920, 84 tables, ok
#   jellyfin  main   4,096  -wal 3,188,912  -> .backup   475,136, 33 tables, ok
#
# Both stayed RUNNING. jellyfin's main file was essentially empty, so its 33
# tables came out of the WAL -- exactly what a plain copy loses.
out="$(probe 'sqlite_helper_image() { printf sha256:helperimage; }' \
  'service_state_capture_mode jellyfin')"
[[ "$out" == "consistent" ]] \
  || fail "with a helper available jellyfin must be consistent, got: $out"
out="$(probe 'sqlite_helper_image() { printf sha256:helperimage; }' \
  'service_state_capture_mode kavita')"
[[ "$out" == "consistent" ]] || fail "kavita must be consistent too, got: $out"
echo "  jellyfin and kavita are consistent when a helper is available"

sect "and falls back to UNPROVEN when no helper is present -- never claims more"
out="$(probe 'sqlite_helper_image() { return 1; }' 'service_state_capture_mode jellyfin')"
[[ "$out" == "unproven" ]] \
  || fail "with NO helper the mode must be unproven, not $out. A capture that
claims consistency it cannot deliver is the defect this project exists to
prevent"
echo "  no helper -> unproven, as before"

sect "the helper NEVER pulls, and resolves only from a RUNNING container"
# Comments STRIPPED before asserting absence: the function's own comment
# explains why plex is deliberately not a helper source, and the first version
# of the assertion below flagged that explanation. Seventh recorded instance of
# an assertion catching its author's own prose.
body_raw="$(sed -n '/^sqlite_helper_image() {/,/^}/p' "$CLI")"
body="$(sed 's/#.*//' <<< "$body_raw")"
[[ -n "$body_raw" ]] || fail "sqlite_helper_image was not found"
grep -qE 'docker (pull|image pull)' <<< "$body" \
  && fail "the helper resolver pulls. What gets used must be what is already
here -- the same rule verify-db-restore follows for the postgres image"
grep -q "State.Status" <<< "$body" \
  || fail "it does not require the container to be running, so it could name an
image that is not actually present"
grep -qE '\bnavidrome\b' <<< "$body" \
  || fail "the helper list no longer names a service measured to ship sqlite3"
grep -q 'plex' <<< "$body" \
  && fail "plex is in the helper list. Its binary is 'Plex SQLite' at another
path, and it is the service that NEEDS its own -- a stock sqlite3 cannot read
its collating FTS tables"
echo "  no pull, running containers only, and plex is not a helper source"

sect "the live database is mounted READ-ONLY, and output goes elsewhere"
# The safety property, measured 2026-11-04: SQLite can read a WAL database
# read-only when the -shm already exists, and it does, because the service
# holds it open. So the helper never needs write access to live application
# data -- which is the one thing this path must not have.
hbody="$(sed -n '/^sqlite_backup_via_helper() {/,/^}/p' "$CLI")"
[[ -n "$hbody" ]] || fail "sqlite_backup_via_helper was not found"
grep -q -- '-v "\$dbdir:/dbsrc:ro"' <<< "$hbody" \
  || fail "the live database directory is NOT mounted read-only:
$hbody"
grep -q -- '--network none' <<< "$hbody" || fail "the helper is not network-isolated"
grep -q -- '--rm' <<< "$hbody" || fail "the helper container is not disposable"
echo "  db :ro, --network none, --rm, output to a separate mount"

sect "a helper capture is labelled DIFFERENTLY from the application's own sqlite"
# `sqlite-backup` means the application's own binary answered -- the only one
# that can read plex's collating FTS tables. A stock sqlite3 from another image
# is sound for an ordinary database and is NOT the same evidence. Two claims
# must not wear one label.
build_jellyfin
rm -rf "$TMP/out/cap-helper"
out="$(probe 'sqlite_helper_image() { printf sha256:helperimage; }
sqlite_backup_via_helper() { cp -p -- "$1" "$2"; }' \
  "service_state_capture jellyfin '$TMP/out/cap-helper'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the helper capture failed: $out"
grep -q 'jellyfin.db|sqlite-backup-helper|' "$TMP/out/cap-helper/MANIFEST" \
  || fail "the item is not labelled sqlite-backup-helper:
$(cat "$TMP/out/cap-helper/MANIFEST")"
grep -q 'jellyfin.db|sqlite-backup|' "$TMP/out/cap-helper/MANIFEST" \
  && fail "a helper capture is labelled 'sqlite-backup', which claims the
application's OWN binary answered. jellyfin has none"
echo "  recorded as sqlite-backup-helper, distinct from sqlite-backup"

sect "the application's OWN sqlite still wins where there is one"
# Order matters: plex must never be captured through a stock sqlite3 while its
# own binary is available.
build_calibre_web
rm -rf "$TMP/out/cap-own"
out="$(probe 'sqlite_helper_image() { printf sha256:helperimage; }
service_sqlite_backup() { cp -p -- "$2" "$3"; }
sqlite_backup_via_helper() { echo "HELPER WAS USED" >&2; return 1; }' \
  "service_state_capture calibre-web '$TMP/out/cap-own'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the capture failed: $out"
grep -q 'HELPER WAS USED' <<< "$out" \
  && fail "the helper was tried for a service that ships its own sqlite3"
grep -q 'config/app.db|sqlite-backup|' "$TMP/out/cap-own/MANIFEST" \
  || fail "calibre-web's own sqlite3 was not credited:
$(cat "$TMP/out/cap-own/MANIFEST")"
echo "  in-image sqlite3 is preferred, and the helper is not even tried"

sect "MUTATION: removing the helper arm must send jellyfin back to UNPROVEN"
MUTH="$TMP/mut-helper"; mkdir -p "$MUTH"; cp "$CLI" "$MUTH/domum-media"
python3 -I - "$MUTH/domum-media" <<'PYMH' || fail "the helper mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "  elif sqlite_helper_image >/dev/null 2>&1; then"
new = "  elif false; then"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMH
saved_cli="$CLI"; CLI="$MUTH/domum-media"
mout="$(probe 'sqlite_helper_image() { printf sha256:helperimage; }' \
  'service_state_capture_mode jellyfin')"
CLI="$saved_cli"
[[ "$mout" == "unproven" ]] \
  || fail "the mutation changed no ANSWER -- without the helper arm jellyfin
must report unproven, got: $mout"
echo "  killed: without the arm, jellyfin is unproven and would need downtime"

sect "MUTATION: a read-write live mount must be rejected"
# The whole safety argument is that the helper cannot write to live application
# data. If the :ro is dropped, the assertion above must fail.
MUTR="$TMP/mut-rw"; mkdir -p "$MUTR"; cp "$CLI" "$MUTR/domum-media"
python3 -I - "$MUTR/domum-media" <<'PYMR' || fail "the rw mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '-v "$dbdir:/dbsrc:ro"'
new = '-v "$dbdir:/dbsrc"'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMR
rwbody="$(sed -n '/^sqlite_backup_via_helper() {/,/^}/p' "$MUTR/domum-media")"
grep -q -- '-v "\$dbdir:/dbsrc:ro"' <<< "$rwbody" \
  && fail "the mutation changed no ANSWER -- dropping :ro must make the
read-only assertion fail"
echo "  killed: without :ro the helper could write to live application data"


# ===========================================================================
# ENCRYPTED OFF-SITE PACKS. The captures are 8.90 MiB across five services and
# they sit on the same SSD as every snapshot and every .premigration copy, so a
# capture that never leaves is lost with the disk it protects against.
# ===========================================================================
command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || {
  echo "SKIP: age is not installed; the pack sections cannot run"
  echo "ALL STATE-CAPTURE CHECKS PASSED"; exit 0
}
mkdir -p "$TMP/keys"; chmod 0700 "$TMP/keys"
age-keygen -o "$TMP/keys/ident" >/dev/null 2>&1 || fail "age-keygen failed"
chmod 0600 "$TMP/keys/ident"
age-keygen -y "$TMP/keys/ident" > "$TMP/keys/pub" 2>/dev/null || fail "no public key"
PACKENV="STATE_PACK_AGE_PUBKEY_FILE='$TMP/keys/pub'"

sect "a pack REFUSES a capture that does not match its own manifest"
# The gate, and it is first. Encrypting an unverifiable capture produces an
# artefact whose integrity can be proven and whose contents cannot -- the shape
# of every reporting defect this project has corrected.
build_calibre_web
rm -rf "$TMP/out/cap-pk" "$TMP/out/packs"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-pk'" >/dev/null
printf 'tampered\n' >> "$TMP/out/cap-pk/files/config_gdrive.db"
out="$(probe "$PACKENV" "service_state_pack '$TMP/out/cap-pk' '$TMP/out/packs/a.tar.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "a tampered capture was packed: $out"
grep -q 'does not match its own manifest' <<< "$out" || fail "wrong refusal: $out"
[[ ! -e "$TMP/out/packs/a.tar.age" ]] || fail "a pack was written for a tampered capture"
echo "  refused, and no artefact was produced"

sect "a good capture packs, 0600 inside a 0700 directory, and is really encrypted"
build_calibre_web
rm -rf "$TMP/out/cap-pk2" "$TMP/out/packs"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-pk2'" >/dev/null
out="$(probe "$PACKENV" "service_state_pack '$TMP/out/cap-pk2' '$TMP/out/packs/b.tar.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the pack failed: $out"
[[ -s "$TMP/out/packs/b.tar.age" ]] || fail "no pack written"
[[ "$(stat -c %a "$TMP/out/packs/b.tar.age")" == "600" ]] \
  || fail "the pack is mode $(stat -c %a "$TMP/out/packs/b.tar.age"), not 600"
[[ "$(stat -c %a "$TMP/out/packs")" == "700" ]] || fail "the pack directory is not 0700"
[[ -s "$TMP/out/packs/b.tar.age.sha256" ]] || fail "no .sha256 beside the pack"
hdr="$(head -c 64 "$TMP/out/packs/b.tar.age" || true)"
grep -q 'age-encryption.org' <<< "$hdr" || fail "the pack has no age header"
# The capture contains a Fernet key. It must not be readable in the artefact.
# Searched in the FILE with `grep -qa`, not through a command substitution:
# bash strips null bytes from $( ), so capturing a binary artefact first would
# have made this assertion search something other than the artefact.
grep -qaF 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$TMP/out/packs/b.tar.age" \
  && fail "the fixture's key is readable in the ENCRYPTED pack"
echo "  0600 in a 0700 dir, age header present, key not readable"

sect "no PLAINTEXT staging file survives, on success or on failure"
# The staging tar holds a decrypted Fernet key for as long as it exists, which
# is why it is staged inside the 0700 destination rather than in /tmp.
left="$(find "$TMP/out/packs" -name '.pack.*' || true)"
[[ -z "$left" ]] || fail "a plaintext staging file survived a successful pack: $left"
# Force age to fail by pointing at a recipient file that is not a key.
build_calibre_web
rm -rf "$TMP/out/cap-pk3" "$TMP/out/packs3"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-pk3'" >/dev/null
printf 'not-an-age-key\n' > "$TMP/keys/bogus"
out="$(probe "STATE_PACK_AGE_PUBKEY_FILE='$TMP/keys/bogus'" \
  "service_state_pack '$TMP/out/cap-pk3' '$TMP/out/packs3/c.tar.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "a bogus recipient still produced a pack: $out"
left="$(find "$TMP/out/packs3" -name '.pack.*' -o -name '*.age' || true)"
[[ -z "$left" ]] || fail "a failed pack left plaintext or a partial artefact: $left"
echo "  nothing left behind either way"

sect "unpack checks the pack's sha256, and a WRONG identity cannot open it"
rm -rf "$TMP/out/unp"
out="$(probe '' "service_state_unpack '$TMP/out/packs/b.tar.age' '$TMP/keys/ident' '$TMP/out/unp'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "unpack failed: $out"
grep -q 'matches its recorded sha256' <<< "$out" || fail "the checksum was not checked: $out"
[[ -f "$TMP/out/unp/MANIFEST" ]] || fail "no manifest after unpack"
age-keygen -o "$TMP/keys/wrong" >/dev/null 2>&1 || fail "age-keygen failed"
chmod 0600 "$TMP/keys/wrong"
rm -rf "$TMP/out/unp-wrong"
out="$(probe '' "service_state_unpack '$TMP/out/packs/b.tar.age' '$TMP/keys/wrong' '$TMP/out/unp-wrong'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "the WRONG identity opened the pack: $out"
grep -q 'could not decrypt' <<< "$out" || fail "the refusal does not say what happened: $out"
echo "  checksum verified; the wrong key is refused"

sect "unpack refuses a NON-EMPTY target, so restored content is never ambiguous"
mkdir -p "$TMP/out/unp-busy"; printf 'pre-existing\n' > "$TMP/out/unp-busy/other"
out="$(probe '' "service_state_unpack '$TMP/out/packs/b.tar.age' '$TMP/keys/ident' '$TMP/out/unp-busy'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "it unpacked into a non-empty directory: $out"
grep -q 'not empty' <<< "$out" || fail "wrong refusal: $out"
echo "  refused"

sect "MUTATION: without the verify gate, a tampered capture gets encrypted"
MUTP3="$TMP/mut-pack"; mkdir -p "$MUTP3"; cp "$CLI" "$MUTP3/domum-media"
python3 -I - "$MUTP3/domum-media" <<'PYMP3' || fail "the pack mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  service_state_verify "$cap" >/dev/null 2>&1 \\\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
new = '  true \\\n'
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMP3
build_calibre_web
rm -rf "$TMP/out/cap-m5" "$TMP/out/packs5"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-m5'" >/dev/null
printf 'tampered\n' >> "$TMP/out/cap-m5/files/config_gdrive.db"
saved_cli="$CLI"; CLI="$MUTP3/domum-media"
out="$(probe "$PACKENV" "service_state_pack '$TMP/out/cap-m5' '$TMP/out/packs5/d.tar.age'; echo RC=\$?")"
CLI="$saved_cli"
grep -q 'RC=0' <<< "$out" \
  || fail "the mutation changed no ANSWER -- without the gate a tampered
capture must be packed: $out"
[[ -s "$TMP/out/packs5/d.tar.age" ]] \
  || fail "the mutant produced no artefact, so the gate is not what stopped it"
echo "  killed: without the gate the artefact has provable integrity and unprovable contents"

sect "MUTATION: without the sha256 check, a tampered PACK unpacks silently"
MUTP4="$TMP/mut-unpack"; mkdir -p "$MUTP4"; cp "$CLI" "$MUTP4/domum-media"
python3 -I - "$MUTP4/domum-media" <<'PYMP4' || fail "the unpack mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Anchored on text unique to service_state_unpack: the identical
# `if [[ -s "$pack.sha256" ]]` line now also appears in
# service_state_pack_verify, so the shorter anchor matched twice. The
# "matched %d times" assertion is what caught that -- second time adding
# similar code has made a mutation anchor ambiguous.
old = '''  if [[ -s "$pack.sha256" ]]; then
    want="$(sed -n '1p' "$pack.sha256")"
    got="$(sha256_of_file "$pack")"
    if [[ "$want" != "$got" ]]; then'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
new = '''  if false; then
    want="$(sed -n '1p' "$pack.sha256")"
    got="$(sha256_of_file "$pack")"
    if [[ "$want" != "$got" ]]; then'''
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMP4
# Corrupt the RECORDED checksum rather than the pack, so the real code must
# refuse while the mutant proceeds -- the pack itself stays decryptable.
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
  > "$TMP/out/packs/b.tar.age.sha256"
rm -rf "$TMP/out/unp-m"
out="$(probe '' "service_state_unpack '$TMP/out/packs/b.tar.age' '$TMP/keys/ident' '$TMP/out/unp-m'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "the real code unpacked a pack whose recorded checksum does not match: $out"
grep -q 'checksum mismatch' <<< "$out" || fail "it does not say the checksum is wrong: $out"
rm -rf "$TMP/out/unp-m2"
saved_cli="$CLI"; CLI="$MUTP4/domum-media"
out="$(probe '' "service_state_unpack '$TMP/out/packs/b.tar.age' '$TMP/keys/ident' '$TMP/out/unp-m2'; echo RC=\$?")"
CLI="$saved_cli"
grep -q 'RC=0' <<< "$out" \
  || fail "the mutation changed no ANSWER -- without the check a mismatched
checksum must be ignored: $out"
echo "  killed: without it a pack whose checksum does not match unpacks anyway"


sect "verify-pack: four states, and UNKNOWN is not a pass"
# The only claim this host can make about a production pack, because it holds
# only the public key. Three claims stay apart on purpose: verify-pack says the
# FILE is intact and carries age's header; unpack-state says it DECRYPTS;
# restore-state says the capture RESTORES. Collapsing them is how "the backup
# is verified" comes to mean "a file exists".
printf 'plaintext\n' > "$TMP/vp-plain"
age -r "$(cat "$TMP/keys/pub")" -o "$TMP/vp-good.age" "$TMP/vp-plain" 2>/dev/null \
  || fail "could not build a pack fixture"
sha256sum "$TMP/vp-good.age" | cut -d' ' -f1 > "$TMP/vp-good.age.sha256"
cp "$TMP/vp-good.age" "$TMP/vp-nosum.age"
cp "$TMP/vp-good.age" "$TMP/vp-bad.age"
printf '%064d\n' 0 > "$TMP/vp-bad.age.sha256"
printf 'not encrypted at all\n' > "$TMP/vp-notpack.age"
sha256sum "$TMP/vp-notpack.age" | cut -d' ' -f1 > "$TMP/vp-notpack.age.sha256"

out="$(probe '' "service_state_pack_verify '$TMP/vp-good.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "a good pack did not verify: $out"
grep -q 'format        : age-encrypted' <<< "$out" || fail "the format line is wrong: $out"
grep -q 'file integrity: VERIFIED' <<< "$out" || fail "it did not report VERIFIED: $out"
grep -q 'does NOT prove' <<< "$out" \
  || fail "it does not state what it fails to prove. A host that cannot decrypt
must not let 'verified' read as 'recoverable': $out"

out="$(probe '' "service_state_pack_verify '$TMP/vp-nosum.age'; echo RC=\$?")"
grep -q 'RC=2' <<< "$out" || fail "a pack with no recorded checksum must exit 2, not pass or fail: $out"
grep -q 'file integrity: UNKNOWN' <<< "$out" \
  || fail "no checksum was reported as something other than UNKNOWN -- the
weaker claim in the stronger claim's words: $out"
grep -q 'file integrity: VERIFIED' <<< "$out" && fail "it claimed VERIFIED with no checksum: $out"

out="$(probe '' "service_state_pack_verify '$TMP/vp-bad.age'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a checksum mismatch must exit 1: $out"
grep -q 'file integrity: MISMATCH' <<< "$out" || fail "the mismatch is not named: $out"

out="$(probe '' "service_state_pack_verify '$TMP/vp-notpack.age'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a file that is not a pack must exit 1: $out"
grep -q 'format        : NOT RECOGNISED' <<< "$out" || fail "it did not say the format is wrong: $out"
# An intact file that is NOT a pack: both facts are reported, and they are
# different claims -- the checksum says nothing about the format.
grep -q 'file integrity: VERIFIED' <<< "$out" \
  || fail "it stopped reporting file integrity for a non-pack; those are two
independent claims and both belong in the report: $out"

out="$(probe '' "service_state_pack_verify '$TMP/does-not-exist.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "an absent pack verified: $out"
echo "  verified / unknown / mismatch / not-a-pack, with distinct statuses"

sect "MUTATION: treating a missing checksum as VERIFIED must break that"
MUTV2="$TMP/mut-vp"; mkdir -p "$MUTV2"; cp "$CLI" "$MUTV2/domum-media"
python3 -I - "$MUTV2/domum-media" <<'PYMV2' || fail "the verify-pack mutation did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''    echo "file integrity: UNKNOWN -- no .sha256 beside the pack"
    rc=2'''
new = '''    echo "file integrity: VERIFIED"
    rc=0'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMV2
saved_cli="$CLI"; CLI="$MUTV2/domum-media"
out="$(probe '' "service_state_pack_verify '$TMP/vp-nosum.age'; echo RC=\$?")"
CLI="$saved_cli"
grep -q 'RC=0' <<< "$out" \
  || fail "the mutation changed no ANSWER -- a pack with no recorded checksum
must be able to read as VERIFIED once the UNKNOWN branch is removed: $out"
echo "  killed: without the third state, an unverifiable pack reads as verified"


sect "UNPROVEN now says WHICH kind, because it has two meanings"
# Before the helper existed `unproven` meant exactly one thing: no sqlite3
# anywhere. It now means two, and they call for different actions -- the
# service genuinely has none and none is reachable, versus a helper exists on
# this host and was not found. Auditing the jellyfin/kavita evidence is what
# surfaced it: the mode degrades SILENTLY.
build_jellyfin
rm -rf "$TMP/out/cap-unp"
out="$(probe 'sqlite_helper_image() { return 1; }' \
  "service_state_capture jellyfin '$TMP/out/cap-unp'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the capture failed: $out"
grep -q 'capture mode UNPROVEN' <<< "$out" \
  || fail "an unproven capture said nothing about why: $out"
# Matched on a phrase that does not straddle the wrap: "no other running
# service" is split across two output lines, so the obvious pattern failed
# against correct output. Same line-at-a-time trap as the scrub claim.
grep -q "offers one either" <<< "$out" \
  || fail "it does not distinguish 'no helper exists' from 'a helper was missed': $out"
grep -q '^SQLITE_IN_IMAGE=no$' "$TMP/out/cap-unp/MANIFEST" \
  || fail "the manifest does not record that the image ships no sqlite3"
grep -q '^SQLITE_HELPER=none$' "$TMP/out/cap-unp/MANIFEST" \
  || fail "the manifest does not record that no helper was available"
echo "  says no helper exists, and records both facts in the manifest"

sect "and an unproven capture WITH a helper available is a WARNING, not a note"
# That combination is a defect rather than a limitation: a consistent capture
# was possible and was not taken.
rm -rf "$TMP/out/cap-unp2"
out="$(probe 'sqlite_helper_image() { printf sha256:aaaabbbbccccdddd; }
service_state_capture_mode() { printf unproven; }' \
  "service_state_capture jellyfin '$TMP/out/cap-unp2'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the capture failed: $out"
grep -q 'WARN' <<< "$out" \
  || fail "a consistent capture was possible and not taken, and nothing warned: $out"
grep -q 'was possible and was not taken' <<< "$out" || fail "the warning does not say what happened: $out"
grep -q '^SQLITE_HELPER=sha256:aaaabbbbccccdddd$' "$TMP/out/cap-unp2/MANIFEST" \
  || fail "the manifest does not record which helper was available"
echo "  warned, and the available helper is named in the manifest"

sect "a CONSISTENT capture records which sqlite answered"
build_calibre_web
rm -rf "$TMP/out/cap-insitu"
out="$(probe 'sqlite_helper_image() { printf sha256:aaaabbbbccccdddd; }
service_sqlite_backup() { cp -p -- "$2" "$3"; }' \
  "service_state_capture calibre-web '$TMP/out/cap-insitu'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the capture failed: $out"
grep -q '^SQLITE_IN_IMAGE=yes$' "$TMP/out/cap-insitu/MANIFEST" \
  || fail "calibre-web ships sqlite3 and the manifest does not say so"
grep -q 'capture mode UNPROVEN' <<< "$out" && fail "a consistent capture reported UNPROVEN: $out"
echo "  SQLITE_IN_IMAGE=yes, and no unproven notice"

# ---------------------------------------------------------------------------
# The manifest records its own schema, completeness and item count. Nothing
# read any of the three, so `service_state_verify` -- the single gate that
# `restore-state` and `pack-state` both consult -- answered only from the ITEM
# lines, and could not tell "every declared item verified" from "every item
# still LISTED verified".
sect "a WHOLE capture verifies, and says what the denominator was"
build_jellyfin
rm -rf "$TMP/out/vf-ok"
probe '' "service_state_capture jellyfin '$TMP/out/vf-ok'" >/dev/null 2>&1
out="$(probe '' "service_state_verify '$TMP/out/vf-ok'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "an intact capture failed to verify: $out"
# The denominator is stated: "7 item(s) match" cannot be falsified without
# knowing how many there should have been.
grep -qE 'capture verified: 7 of 7 item' <<< "$out" \
  || fail "the clean verdict does not state its denominator: $out"
echo "  7 of 7, rc=0"

sect "a TRUNCATED manifest is refused -- the tail is where RESULT and ITEMS live"
# Reproduced against the real writer before this was fixed: dropping the last
# ITEM line plus the trailing RESULT and ITEMS lines from a 7-item jellyfin
# capture reported "capture verified: 6 item(s)" and exit 0. The item dropped
# here is device.txt, jellyfin's SERVER IDENTITY -- the artefact whose absence
# makes a restored jellyfin a new server that every client must re-pair with.
rm -rf "$TMP/out/vf-tr"
probe '' "service_state_capture jellyfin '$TMP/out/vf-tr'" >/dev/null 2>&1
grepF_q 'device.txt' "$(cat "$TMP/out/vf-tr/MANIFEST")" \
  || fail "the fixture capture does not contain the item this section removes"
awk '/device\.txt/ {next} /^RESULT=|^ITEMS=/ {next} {print}' \
  "$TMP/out/vf-tr/MANIFEST" > "$TMP/vf-tr.m"
mv "$TMP/vf-tr.m" "$TMP/out/vf-tr/MANIFEST"
out="$(probe '' "service_state_verify '$TMP/out/vf-tr'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a truncated manifest verified clean: $out"
grepF_q 'TRUNCATED' "$out" || fail "the refusal does not name truncation: $out"
# The gate is what pack and restore consult, so neither may proceed.
out="$(probe '' "service_state_restore '$TMP/out/vf-tr' '$TMP/out/vf-tr-rst'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a restore accepted a truncated capture: $out"
[[ -z "$(ls -A "$TMP/out/vf-tr-rst" 2>/dev/null || true)" ]] \
  || fail "the restore wrote something from a truncated capture"
echo "  refused, and the restore refused with it"

sect "an ITEM line gone from the MIDDLE is refused by the COUNT, not by RESULT"
# A distinct, independently reachable failure: the writer counts an item it
# then fails to append, so RESULT=COMPLETE is written truthfully by its own
# lights while the manifest is one line short. The RESULT check cannot see
# this one, which is why both checks exist rather than either.
rm -rf "$TMP/out/vf-mid"
probe '' "service_state_capture jellyfin '$TMP/out/vf-mid'" >/dev/null 2>&1
grep -v 'device.txt' "$TMP/out/vf-mid/MANIFEST" > "$TMP/vf-mid.m"
mv "$TMP/vf-mid.m" "$TMP/out/vf-mid/MANIFEST"
grep -q '^RESULT=COMPLETE$' "$TMP/out/vf-mid/MANIFEST" \
  || fail "this section needs RESULT=COMPLETE intact, or it tests the other check"
out="$(probe '' "service_state_verify '$TMP/out/vf-mid'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a manifest one item line short verified clean: $out"
grepF_q 'ITEMS=7' "$out" || fail "the refusal does not quote the recorded count: $out"
echo "  6 lines against ITEMS=7, refused"

sect "an unrecognised SCHEMA_VERSION is refused rather than parsed anyway"
# The ITEM grammar is versioned -- schema 2 added a file item's MODE field, so
# a schema-1 line parsed here would land its checksum in the mode column. A
# version key nothing checks is a version gate that does not exist.
rm -rf "$TMP/out/vf-sch"
probe '' "service_state_capture jellyfin '$TMP/out/vf-sch'" >/dev/null 2>&1
sed -i 's/^SCHEMA_VERSION=2$/SCHEMA_VERSION=3/' "$TMP/out/vf-sch/MANIFEST"
out="$(probe '' "service_state_verify '$TMP/out/vf-sch'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a manifest of an unknown schema was parsed anyway: $out"
grepF_q 'schema is 3' "$out" || fail "the refusal does not name the schema it saw: $out"
# An ABSENT version is not the current one either.
rm -rf "$TMP/out/vf-sch0"
probe '' "service_state_capture jellyfin '$TMP/out/vf-sch0'" >/dev/null 2>&1
sed -i '/^SCHEMA_VERSION=/d' "$TMP/out/vf-sch0/MANIFEST"
out="$(probe '' "service_state_verify '$TMP/out/vf-sch0'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "a manifest with no schema line verified: $out"
grepF_q 'unrecorded' "$out" || fail "an absent schema must read as unrecorded: $out"
echo "  unknown and absent both refused"

sect "RESULT=INCOMPLETE is refused by name, not merely via its bad item lines"
rm -rf "$TMP/out/vf-inc"
probe '' "service_state_capture jellyfin '$TMP/out/vf-inc'" >/dev/null 2>&1
sed -i 's/^RESULT=COMPLETE$/RESULT=INCOMPLETE/' "$TMP/out/vf-inc/MANIFEST"
out="$(probe '' "service_state_verify '$TMP/out/vf-inc'; echo RC=\$?")"
grep -q 'RC=1' <<< "$out" || fail "RESULT=INCOMPLETE verified clean: $out"
grepF_q 'RESULT=INCOMPLETE' "$out" || fail "the refusal does not quote RESULT: $out"
echo "  named explicitly"

sect "the restore names the APPLICATION that wrote the state"
# A recovery point is service + state + the application that wrote it. The
# capture has always recorded IMAGE_ID; no reader surfaced it, so a restore
# reported matching digests while withholding the state's provenance.
build_calibre_web
rm -rf "$TMP/out/vf-img" "$TMP/out/vf-img-rst"
out="$(probe 'tracked_service_container_id_any() { printf "cid42"; }
       docker() { case "$*" in *"{{.Image}}"*) printf "sha256:feedfacefeedface\n" ;; *) return 1 ;; esac; }' \
  "service_state_capture calibre-web '$TMP/out/vf-img'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the capture failed: $out"
img="$(sed -nE 's/^IMAGE_ID=(.*)$/\1/p' "$TMP/out/vf-img/MANIFEST" | head -1)"
[[ -n "$img" && "$img" != unknown ]] || fail "the fixture recorded no image id: $img"
out="$(probe '' "service_state_restore '$TMP/out/vf-img' '$TMP/out/vf-img-rst'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "the restore failed: $out"
grepF_q "application that wrote this state: $img" "$out" \
  || fail "the restore does not name the application half: $out"
grepF_q 'half of a recovery point' "$out" \
  && fail "an image WAS recorded, so nothing may call it half a point: $out"
echo "  named: $img"

sect "an UNRECORDED image is reported as half a recovery point, not omitted"
rm -rf "$TMP/out/vf-noimg" "$TMP/out/vf-noimg-rst"
probe '' "service_state_capture calibre-web '$TMP/out/vf-noimg'" >/dev/null 2>&1
sed -i '/^IMAGE_ID=/d' "$TMP/out/vf-noimg/MANIFEST"
out="$(probe '' "service_state_restore '$TMP/out/vf-noimg' '$TMP/out/vf-noimg-rst'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "deleting IMAGE_ID must not fail the restore: $out"
grepF_q 'unrecorded' "$out" || fail "an absent image id must read as unrecorded: $out"
grepF_q 'half of a recovery point' "$out" \
  || fail "an unrecorded image must be reported as half a recovery point: $out"
echo "  unrecorded, and said to be half a point"

sect "the UNPROVEN restore states the recorded cause, never an assumed one"
# `unproven` had one cause before the helper existed and has had two since.
# The capture records which; the restore used to assert the first regardless.
build_jellyfin
rm -rf "$TMP/out/vf-up" "$TMP/out/vf-up-rst"
probe '' "service_state_capture jellyfin '$TMP/out/vf-up'" >/dev/null 2>&1
grep -q '^CAPTURE_MODE=unproven$' "$TMP/out/vf-up/MANIFEST" \
  || fail "this section needs an unproven capture: $(cat "$TMP/out/vf-up/MANIFEST")"
# No helper recorded -- the genuine limitation.
out="$(probe '' "service_state_restore '$TMP/out/vf-up' '$TMP/out/vf-up-rst'; echo RC=\$?")"
grepF_q 'no helper image was' "$out" || fail "the genuine no-sqlite cause is not stated: $out"
grepF_q 'WAS available' "$out" && fail "no helper was recorded, so none may be claimed: $out"
# A helper recorded and the capture still unproven: a DEFECT in the capture
# rather than a limitation of the service, and it must not borrow the
# reassuring wording.
rm -rf "$TMP/out/vf-up2" "$TMP/out/vf-up2-rst"
cp -a "$TMP/out/vf-up" "$TMP/out/vf-up2"
sed -i 's|^SQLITE_HELPER=none$|SQLITE_HELPER=sha256:deadbeefdeadbeef|' "$TMP/out/vf-up2/MANIFEST"
out="$(probe '' "service_state_restore '$TMP/out/vf-up2' '$TMP/out/vf-up2-rst'; echo RC=\$?")"
grepF_q 'WAS available' "$out" || fail "a recorded helper must change the stated cause: $out"
grepF_q 'is a defect in' "$out" || fail "an avoidable unproven capture must read as a defect: $out"
grepF_q 'no helper image was' "$out" && fail "the mutually exclusive cause is also claimed: $out"
# An UNRECORDED fact is neither excused nor blamed.
rm -rf "$TMP/out/vf-up3" "$TMP/out/vf-up3-rst"
cp -a "$TMP/out/vf-up" "$TMP/out/vf-up3"
sed -i '/^SQLITE_HELPER=/d' "$TMP/out/vf-up3/MANIFEST"
out="$(probe '' "service_state_restore '$TMP/out/vf-up3' '$TMP/out/vf-up3-rst'; echo RC=\$?")"
grepF_q 'not recorded by this capture' "$out" \
  || fail "an absent SQLITE_HELPER must read as not recorded: $out"
echo "  all three causes distinguished"

sect "MUTATION: without the summary checks a truncated manifest verifies clean"
build_jellyfin
rm -rf "$TMP/out/vf-mut"
probe '' "service_state_capture jellyfin '$TMP/out/vf-mut'" >/dev/null 2>&1
awk '/device\.txt/ {next} /^RESULT=|^ITEMS=/ {next} {print}' \
  "$TMP/out/vf-mut/MANIFEST" > "$TMP/vf-mut.m"
mv "$TMP/vf-mut.m" "$TMP/out/vf-mut/MANIFEST"
cp "$CLI" "$TMP/cli.origvf"
cat > "$TMP/mutate-vf.py" <<'PYMUTVF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Neutralise the COMPARISONS. Never "&& false" inside [[ ]]: there the bare
# word is a non-empty STRING, so the mutation applies and changes nothing.
pairs = [
    ('  case "$result" in\n    COMPLETE) ;;',
     '  case "COMPLETE" in\n    COMPLETE) ;;'),
    ('  if (( seen != declared )); then',
     '  if (( seen != seen )); then'),
    # The absent-count refusal fires before either of the above for this
    # fixture, so it has to go too or the mutant is killed by the wrong check.
    ('  if ! [[ "$declared" =~ ^[0-9]+$ ]]; then',
     '  if ! [[ "0$declared" =~ ^[0-9]+$ ]]; then'),
]
for old, new in pairs:
    assert s.count(old) == 1, "anchor %r matched %d times" % (old[:40], s.count(old))
    s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8").write(s)
PYMUTVF
( python3 -I "$TMP/mutate-vf.py" "$CLI" ) || { cp "$TMP/cli.origvf" "$CLI"; fail "the verify mutation did not apply"; }
mout="$(probe '' "service_state_verify '$TMP/out/vf-mut'; echo RC=\$?")"
cp "$TMP/cli.origvf" "$CLI"
grep -q 'RC=0' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the summary checks a
truncated manifest must verify clean again: $mout"
echo "  killed: the mutant reports a truncated capture as verified"

sect "MUTATION: asserting the unproven cause brings the confident wrong cause back"
build_jellyfin
rm -rf "$TMP/out/vf-mut2" "$TMP/out/vf-mut2-rst"
probe '' "service_state_capture jellyfin '$TMP/out/vf-mut2'" >/dev/null 2>&1
sed -i 's|^SQLITE_HELPER=none$|SQLITE_HELPER=sha256:deadbeefdeadbeef|' "$TMP/out/vf-mut2/MANIFEST"
cp "$CLI" "$TMP/cli.origvf2"
cat > "$TMP/mutate-vf2.py" <<'PYMUTVF2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '        case "$cap_in_image/$cap_helper" in'
new = '        case "no/none" in'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUTVF2
( python3 -I "$TMP/mutate-vf2.py" "$CLI" ) || { cp "$TMP/cli.origvf2" "$CLI"; fail "the cause mutation did not apply"; }
mout="$(probe '' "service_state_restore '$TMP/out/vf-mut2' '$TMP/out/vf-mut2-rst'; echo RC=\$?")"
cp "$TMP/cli.origvf2" "$CLI"
grepF_q 'no helper image was' "$mout" \
  || fail "the mutation changed no ANSWER -- it must assert the no-sqlite cause
for a capture that recorded a helper: $mout"
echo "  killed: the mutant blames the service for an avoidable unproven capture"

# ---------------------------------------------------------------------------
# A failed operation that cannot say WHY is an unactionable FAIL, and this
# project already fixed four such sites in the volume dump/restore. The pack
# path was not swept at the time -- and it is the artefact meant to leave the
# host, so a failure there is the worst place for one identical sentence
# covering permission denied, no space and an unusable key.
sect "a FAILED pack names its cause, not just the fact"
build_calibre_web
rm -rf "$TMP/out/cap-cz" "$TMP/out/packsz"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-cz'" >/dev/null
printf 'not-a-key\n' > "$TMP/keys/bogus"
out="$(probe "STATE_PACK_AGE_PUBKEY_FILE='$TMP/keys/bogus'" \
  "service_state_pack '$TMP/out/cap-cz' '$TMP/out/packsz/z.tar.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "a bogus recipient still produced a pack: $out"
grepF_q 'age could not encrypt' "$out" || fail "the pack did not report the encryption step: $out"
# The point of the section: age's OWN diagnostic has to reach the operator.
grepF_q 'no diagnostic was produced' "$out" \
  && fail "age's stderr was discarded, so the cause is unavailable: $out"
grep -qiE 'age could not encrypt the state pack: .*[a-z]' <<< "$out" \
  || fail "no cause is attached to the failure: $out"
echo "  cause attached"

sect "a FAILED unpack names its cause, and keeps the design note"
# The design note alone asserted ONE of the reasons this fails. A corrupt pack
# and an unreadable identity look identical without the diagnostic.
rm -rf "$TMP/out/unpz" "$TMP/out/cap-uz" "$TMP/out/packsuz"
# Its OWN pack: an earlier section deliberately corrupts b.tar.age's recorded
# checksum to drive the MISMATCH state, so reusing it means the checksum check
# fires first and age is never reached.
build_calibre_web
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-uz'" >/dev/null
probe "$PACKENV" "service_state_pack '$TMP/out/cap-uz' '$TMP/out/packsuz/u.tar.age'" >/dev/null \
  || fail "could not build the pack this section needs"
age-keygen -o "$TMP/keys/wrong2" >/dev/null 2>&1 || fail "age-keygen failed"
chmod 0600 "$TMP/keys/wrong2"
out="$(probe '' "service_state_unpack '$TMP/out/packsuz/u.tar.age' '$TMP/keys/wrong2' '$TMP/out/unpz'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "the wrong identity opened the pack: $out"
grepF_q 'matches its recorded sha256' "$out" \
  || fail "this section needs the checksum to PASS so age is reached: $out"
grepF_q 'is the design' "$out" || fail "the design note was dropped: $out"
grepF_q 'not the only reason' "$out" \
  || fail "the note must stop implying a wrong key is the only cause: $out"
grepF_q 'no diagnostic was produced' "$out" \
  && fail "age's stderr was discarded on the decrypt path: $out"
echo "  cause attached, note kept, and no longer the only stated reason"

sect "a pack that DECRYPTS but is not a tar names the extract failure"
# By this point the plaintext exists, so a failure here leaves the operator
# with nothing -- the same argument as the volume restore, where the volume has
# already been cleared. Reaching it needs a pack whose payload is not a tar.
rm -rf "$TMP/out/unpnt" "$TMP/out/packsnt"
mkdir -p "$TMP/out/packsnt"
recip="$(cat "$TMP/keys/pub")"
printf 'this is not a tar archive at all\n' > "$TMP/notatar"
age -r "$recip" -o "$TMP/out/packsnt/nt.tar.age" "$TMP/notatar" 2>/dev/null \
  || fail "could not build the not-a-tar fixture"
sha256sum "$TMP/out/packsnt/nt.tar.age" | awk '{print $1}' > "$TMP/out/packsnt/nt.tar.age.sha256"
out="$(probe '' "service_state_unpack '$TMP/out/packsnt/nt.tar.age' '$TMP/keys/ident' '$TMP/out/unpnt'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "a non-tar payload unpacked successfully: $out"
grepF_q 'could not unpack' "$out" || fail "the extract failure is not reported: $out"
grepF_q 'no diagnostic was produced' "$out" \
  && fail "tar's stderr was discarded, so the cause is unavailable: $out"
echo "  extract failure reported with tar's own reason"

sect "a failed docker save names its cause -- the archive is the only proven copy"
# CLAUDE.md: the `docker save` archive is the only PROVEN copy of the
# application half of every recovery point on this host.
out="$(probe 'docker() {
                case "$1" in
                  save) echo "Error response from daemon: no space left on device" >&2; return 1 ;;
                  *) return 0 ;;
                esac
              }' \
  "archive_image_to_file sha256:deadbeef '$TMP/out/arch/x.tar'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "a failed docker save reported success: $out"
grepF_q 'docker save failed' "$out" || fail "the failure is not reported: $out"
grepF_q 'no space left on device' "$out" \
  || fail "docker's own diagnostic did not reach the operator: $out"
[[ ! -e "$TMP/out/arch/x.tar" ]] || fail "a partial archive was published"
echo "  docker's own reason reported, and nothing published"

sect "MUTATION: discarding the diagnostic makes every pack failure identical"
build_calibre_web
rm -rf "$TMP/out/cap-cz2" "$TMP/out/packsz2"
probe "$PACKENV" "service_state_capture calibre-web '$TMP/out/cap-cz2'" >/dev/null
cp "$CLI" "$TMP/cli.origcz"
cat > "$TMP/mutate-cz.py" <<'PYMUTCZ'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''  if ! age -r "$recipient" -o "$tmp" "$plain" 2>"$perr"; then
    warn "age could not encrypt the state pack: $(first_error_line "$perr")"'''
new = '''  if ! age -r "$recipient" -o "$tmp" "$plain" 2>/dev/null; then
    warn "age could not encrypt the state pack"'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYMUTCZ
( python3 -I "$TMP/mutate-cz.py" "$CLI" ) || { cp "$TMP/cli.origcz" "$CLI"; fail "the cause mutation did not apply"; }
mout="$(probe "STATE_PACK_AGE_PUBKEY_FILE='$TMP/keys/bogus'" \
  "service_state_pack '$TMP/out/cap-cz2' '$TMP/out/packsz2/z.tar.age'; echo RC=\$?")"
cp "$TMP/cli.origcz" "$CLI"
grep -qE 'age could not encrypt the state pack$' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- without the captured stderr the
failure must carry no cause at all: $mout"
echo "  killed: the mutant reports the fact with no cause"

echo "ALL STATE-CAPTURE CHECKS PASSED"
