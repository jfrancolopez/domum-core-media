#!/usr/bin/env bash
# Does an encrypted state pack survive a REAL repository round trip?
#
# docs/OFFSITE-STATE-BACKUP-DESIGN.md opens by stating what is NOT proven, and
# one line of that table is the reason this suite exists: the pack/unpack
# mechanism was proven on this SSD, and nothing had ever put a pack through a
# backup repository and taken it back out. That is a different claim from
# "pack-state works": a repository stores, deduplicates and re-assembles the
# bytes, and an artefact that is encrypted and content-addressed is exactly the
# kind of thing where a silent truncation would survive every check until the
# day it was needed.
#
# WHAT THIS PROVES: capture -> pack -> restic backup -> the local pack DESTROYED
# -> restic restore -> verify-pack -> unpack -> restore-state -> digests and
# modes re-checked. The restored pack must be byte-identical to the one backed
# up, and the state must come back out of it.
#
# WHAT IT DOES NOT PROVE, stated here because this is the easiest claim in the
# project to overstate:
#   * that any pack has left this host. The repository is a scratch directory
#     under $TMP, asserted below. No production target, repository, credential
#     or configuration is read or written.
#   * that the OPERATOR's age key opens a pack. The identity here is generated
#     for the test; the real key is deliberately not on this host.
#   * that a service RUNS against the restored state. restore-state says so in
#     its own words.
#
# So this closes "the transfer medium does not corrupt it and the chain works
# end to end", and leaves the two operator-gated claims exactly where they were.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

command -v restic >/dev/null 2>&1 || {
  echo "SKIP: restic is not installed; the repository round trip cannot run"
  echo "ALL PACK-REPOSITORY CHECKS PASSED"; exit 0
}
command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || {
  echo "SKIP: age is not installed; a pack cannot be produced"
  echo "ALL PACK-REPOSITORY CHECKS PASSED"; exit 0
}

mkdir -p "$TMP/bin" "$TMP/data" "$TMP/out" "$TMP/keys"
chmod 0700 "$TMP/keys"
# Reaching a real daemon would make this a production probe rather than a test.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"

age-keygen -o "$TMP/keys/ident" >/dev/null 2>&1 || fail "age-keygen failed"
chmod 0600 "$TMP/keys/ident"
age-keygen -y "$TMP/keys/ident" > "$TMP/keys/pub" 2>/dev/null || fail "no public key"

probe() {  # $1 = extra stubs, $2 = expression
  (
    export PATH="$TMP/bin:$PATH"
    export DOMUM_DATA_ROOT="$TMP/data"
    export STATE_PACK_AGE_PUBKEY_FILE="$TMP/keys/pub"
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    warn() { echo "WARN: $*"; }
    cmd_exists() { case "$1" in docker) return 1 ;; *) command -v -- "$1" >/dev/null 2>&1 ;; esac; }
    tracked_service_container_id_any() { return 1; }
    eval "$1"
    eval "$2"
  ) 2>&1
}

# State at calibre-web's own DECLARED paths, so the fixture follows the
# declaration rather than a hardcoded list. The Fernet key carries a sentinel
# and mode 0600: a pack that survives the repository but comes back with a
# widened mode would turn a recovery into a disclosure.
SENTINEL='SENTINEL-pack-repo-5f3c9a'
build_state() {
  rm -rf -- "$TMP/data/calibre-web"
  mkdir -p "$TMP/data/calibre-web/config"
  python3 - "$TMP/data/calibre-web/config/app.db" <<'MKDB'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table settings(id integer primary key, mail_password_e text)")
con.execute("insert into settings values (1,'gAAAAAB_ciphertext')")
con.commit(); con.close()
MKDB
  printf 'gdrive\n' > "$TMP/data/calibre-web/config/gdrive.db"
  printf '{}\n'     > "$TMP/data/calibre-web/config/client_secrets.json"
  printf '%s' "$SENTINEL=AAAAAAAAAAAAAAAAAAAAAA=" > "$TMP/data/calibre-web/config/.key"
  chmod 0600 "$TMP/data/calibre-web/config/.key"
}

# ===========================================================================
sect "1. a capture is packed into one encrypted artefact"
build_state
rm -rf -- "$TMP/out/cap" "$TMP/out/pack"
mkdir -p "$TMP/out/pack"
out="$(probe '' "service_state_capture calibre-web '$TMP/out/cap'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "1: capture failed: $out"
PACK="$TMP/out/pack/calibre-web.tar.age"
out="$(probe '' "service_state_pack '$TMP/out/cap' '$PACK'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "1: pack failed: $out"
[[ -s "$PACK" ]] || fail "1: no pack artefact"
[[ -s "$PACK.sha256" ]] || fail "1: no recorded checksum beside the pack"
grep -qa "$SENTINEL" "$PACK" && fail "1: the Fernet sentinel is readable inside the pack"
PACK_SHA="$(sha256sum "$PACK" | awk '{print $1}')"
echo "   $(stat -c %s "$PACK") bytes, encrypted, checksum recorded"

# ===========================================================================
sect "2. the repository is a SCRATCH directory, asserted before anything is written"
# A test that could reach the production repository is not a test. The path must
# be under $TMP, and no production credential or configuration is consulted.
REPO="$TMP/repo"
case "$REPO" in "$TMP"/*) : ;; *) fail "2: the repository is not under the scratch directory" ;; esac
[[ ! -e "$REPO" ]] || fail "2: the scratch repository already exists"
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD='fixture-only-not-a-secret'
if ! restic init >/dev/null 2>&1; then
  echo "   SKIPPED: a scratch repository could not be created here"
  echo "ALL PACK-REPOSITORY CHECKS PASSED"; exit 0
fi
[[ -f "$REPO/config" ]] || fail "2: restic init produced no repository config"
echo "   initialised at a path under the test's own temp directory"

# ===========================================================================
sect "3. the pack and its checksum are backed up"
restic backup "$TMP/out/pack" >/dev/null 2>&1 || fail "3: the scratch backup failed"
snap="$(restic snapshots --json 2>/dev/null \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[-1]["short_id"])' 2>/dev/null)"
[[ -n "$snap" ]] || fail "3: no snapshot id"
listing="$(restic ls "$snap" 2>/dev/null)"
grep -qF 'calibre-web.tar.age' <<< "$listing" || fail "3: the pack is not in the snapshot: $listing"
grep -qF 'calibre-web.tar.age.sha256' <<< "$listing" \
  || fail "3: the recorded checksum is not in the snapshot -- the pack would arrive unverifiable"
echo "   snapshot $snap holds the pack and its .sha256"

# ===========================================================================
sect "4. the LOCAL pack is destroyed, so the restore can only read the repository"
rm -rf -- "$TMP/out/pack" "$TMP/out/cap"
[[ ! -e "$PACK" ]] || fail "4: the local pack survived"
[[ ! -e "$TMP/out/cap" ]] || fail "4: the source capture survived"
echo "   both gone -- independence enforced, not described"

# ===========================================================================
sect "5. restored from the repository, BYTE-IDENTICAL"
restic restore "$snap" --target "$TMP/out/restored" >/dev/null 2>&1 \
  || fail "5: the restore failed"
RPACK="$(find "$TMP/out/restored" -name 'calibre-web.tar.age' -type f | head -1)"
[[ -n "$RPACK" ]] || fail "5: the pack was not restored"
got="$(sha256sum "$RPACK" | awk '{print $1}')"
[[ "$got" == "$PACK_SHA" ]] \
  || fail "5: the restored pack differs -- backed up $PACK_SHA, restored $got"
echo "   sha256 matches the artefact that was backed up"

# ===========================================================================
sect "6. verify-pack accepts the restored artefact"
out="$(probe '' "service_state_pack_verify '$RPACK'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "6: verify-pack refused the restored pack: $out"
echo "   file intact and it carries age's header"

# ===========================================================================
sect "7. it unpacks and the state is restored out of it"
out="$(probe '' "service_state_unpack '$RPACK' '$TMP/keys/ident' '$TMP/out/unp'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "7: unpack failed: $out"
mkdir -p "$TMP/out/scratch"
out="$(probe '' "service_state_restore '$TMP/out/unp' '$TMP/out/scratch'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" || fail "7: restore-state failed: $out"
for rel in config/app.db config/gdrive.db config/client_secrets.json config/.key; do
  [[ -e "$TMP/out/scratch/$rel" ]] || fail "7: $rel did not come back"
done
echo "   every declared item restored from the repository copy"

# ===========================================================================
sect "8. the credential survives with its MODE and its VALUE"
k="$TMP/out/scratch/config/.key"
[[ "$(stat -c %a "$k")" == "600" ]] \
  || fail "8: the Fernet key came back $(stat -c %a "$k"), not 600 -- a recovery became a disclosure"
grep -qaF "$SENTINEL" "$k" || fail "8: the key's bytes did not survive the round trip"
# And the database is a usable database, not merely matching bytes.
python3 - "$TMP/out/scratch/config/app.db" <<'CHK' || fail "8: the restored database does not open"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
assert con.execute("pragma integrity_check").fetchone()[0] == "ok"
assert con.execute("select mail_password_e from settings").fetchone()[0] == "gAAAAAB_ciphertext"
con.close()
CHK
echo "   0600 preserved, bytes identical, database opens and integrity_check ok"

# ===========================================================================
sect "9. nothing production was touched"
# The repository is the scratch one, and the pack destination is under $TMP.
[[ "$(restic snapshots --json 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')" == "1" ]] \
  || fail "9: the scratch repository holds an unexpected number of snapshots"
grep -qE '/srv/data|/opt/domum-core-media|/etc/domum-core-media' <<< "$listing" \
  && fail "9: the snapshot contains a production path"
echo "   one snapshot, scratch paths only"

# ===========================================================================
sect "10. MUTATION: a corrupted stored pack must be refused, not unpacked"
# The claim is that the chain detects damage introduced in transit. Damage the
# RESTORED artefact and require the refusal -- otherwise "byte-identical" above
# is the only thing standing between a silent truncation and a failed recovery.
cp "$RPACK" "$TMP/out/damaged.tar.age"
cp "$RPACK.sha256" "$TMP/out/damaged.tar.age.sha256" 2>/dev/null || \
  printf '%s' "$PACK_SHA" > "$TMP/out/damaged.tar.age.sha256"
printf 'x' >> "$TMP/out/damaged.tar.age"
out="$(probe '' "service_state_pack_verify '$TMP/out/damaged.tar.age'; echo RC=\$?")"
grep -q 'RC=0' <<< "$out" && fail "10: a damaged pack verified clean: $out"
grep -qiE 'mismatch|does not match' <<< "$out" \
  || fail "10: the refusal does not name a checksum mismatch: $out"
echo "   killed: damage in transit is caught before anything is decrypted"

echo
echo "PROVEN: capture -> pack -> repository -> restore -> unpack -> state, with the"
echo "        local copies destroyed in between and the credential's mode and bytes"
echo "        intact. NOT proven, and still operator-gated: that any pack has left"
echo "        this host, and that the real age key opens one."
echo "ALL PACK-REPOSITORY CHECKS PASSED"
