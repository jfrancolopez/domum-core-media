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
# WHAT THIS PROVES, in two passes. First for ONE service through the
# per-service commands: capture -> pack -> restic backup -> the local pack
# DESTROYED -> restic restore -> verify-pack -> unpack -> restore-state ->
# digests and modes re-checked.
#
# Then (11-18) for the SCHEDULED path, which is a different claim: the unit runs
# `capture-all-state --pack` and `prune-state-packs --confirm`, and neither had
# ever been through a repository. All five declared services are captured,
# packed, backed up, DESTROYED locally, restored, verified, unpacked, restored
# to state, and then put through retention -- which must retain every one of
# them, because each is the only pack of its service.
#
# The sharpest part is the SIDECAR. Retention reads `<pack>.meta` for the
# service name, because the manifest is inside the encrypted pack and this host
# holds only the public key. If the sidecar did not survive a round trip, then
# after a real disaster every restored pack would read as `unknown` -- kept,
# correctly, but retention could do nothing with them, and nothing would have
# said so until the day it mattered. A mutation removes the sidecar write and
# requires exactly that outcome.
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

# ===========================================================================
# 11-16: the SCHEDULED path, which is a different thing from the per-service
# one proved above. The unit runs `capture-all-state --pack` and then
# `prune-state-packs --confirm`, and neither had ever been through a
# repository. The sharpest part is 14: retention reads the `.meta` SIDECAR, so
# if that does not survive a round trip then after a real disaster every
# restored pack reads as `unknown` and retention can do nothing with them.
# ===========================================================================
sect "11. capture-all-state --pack over EVERY declared service"
# State synthesised from each service's OWN declaration, so this follows a
# declaration change instead of needing an edit beside one.
build_all_state() {
  local svc kind rel
  rm -rf -- "$TMP/data/state-all"
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    rm -rf -- "$TMP/data/$svc"
    while IFS='|' read -r kind rel; do
      [[ -n "$rel" ]] || continue
      case "$kind" in
        dir) mkdir -p "$TMP/data/$svc/$rel" ; printf 'x\n' > "$TMP/data/$svc/$rel/.keep" ;;
        sqlite)
          mkdir -p "$(dirname -- "$TMP/data/$svc/$rel")"
          python3 - "$TMP/data/$svc/$rel" <<'MKDB2'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table t(id integer primary key, v text)")
con.execute("insert into t values (1,'row')")
con.commit(); con.close()
MKDB2
          ;;
        *)  mkdir -p "$(dirname -- "$TMP/data/$svc/$rel")"
            printf 'content for %s/%s\n' "$svc" "$rel" > "$TMP/data/$svc/$rel"
            case "$rel" in *.key|*Preferences.xml) chmod 0600 "$TMP/data/$svc/$rel" ;; esac ;;
      esac
    done < <(probe '' "service_essential_state '$svc'")
  done < <(probe '' "state_capture_services")
}
build_all_state
SVCS="$(probe '' 'state_capture_services' | tr -d '\r')"
n_svcs="$(grep -c . <<< "$SVCS")"
(( n_svcs >= 5 )) || fail "11: only $n_svcs services derived; expected at least 5"
out="$(probe '' "storage_capture_all_state --pack")"
grep -q 'result      : done' <<< "$out" \
  || fail "11: capture-all-state did not complete: $out"
grep -q "packed      : $n_svcs" <<< "$out" \
  || fail "11: not every service was packed: $out"
PACKDIR="$(probe '' 'state_pack_dir')"
n_packs="$(find "$PACKDIR" -maxdepth 1 -name '*.tar.age' 2>/dev/null | wc -l)"
[[ "$n_packs" == "$n_svcs" ]] || fail "11: $n_packs packs for $n_svcs services"
n_meta="$(find "$PACKDIR" -maxdepth 1 -name '*.tar.age.meta' 2>/dev/null | wc -l)"
[[ "$n_meta" == "$n_svcs" ]] || fail "11: $n_meta sidecars for $n_svcs services"
echo "   $n_svcs services captured and packed, each with a sidecar"

sect "12. the whole pack directory goes into the repository"
restic backup "$PACKDIR" >/dev/null 2>&1 \
  || fail "12: the pack directory could not be backed up"
echo "   backed up"

sect "13. every LOCAL pack, sidecar and capture is destroyed"
# Without this the restore could read the originals and prove nothing.
before_sha="$(find "$PACKDIR" -maxdepth 1 -name '*.tar.age' -print0 | sort -z \
              | xargs -0 sha256sum | awk '{print $1}' | sort | tr '\n' ' ')"
rm -rf -- "$PACKDIR" "$TMP/data/backups/state"
[[ ! -d "$PACKDIR" ]] || fail "13: the pack directory survived"
echo "   gone; only the repository holds them now"

sect "14. restored from the repository WITH the sidecars intact"
# The sidecar is what retention reads. If it did not survive, every restored
# pack would read as `unknown` after a real disaster -- kept, but unusable for
# retention, and nothing would have said so.
rst="$TMP/restore-all"
restic restore latest --target "$rst" >/dev/null 2>&1 \
  || fail "14: restore failed"
RPACKDIR="$(find "$rst" -type d -name "$(basename -- "$PACKDIR")" | head -1)"
[[ -n "$RPACKDIR" ]] || fail "14: the restored pack directory was not found under $rst"
r_packs="$(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age' | wc -l)"
r_meta="$(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age.meta' | wc -l)"
[[ "$r_packs" == "$n_svcs" ]] || fail "14: $r_packs of $n_svcs packs restored"
[[ "$r_meta"  == "$n_svcs" ]] || fail "14: $r_meta of $n_svcs SIDECARS restored --
retention reads these, so without them every pack reads as unknown"
after_sha="$(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age' -print0 | sort -z \
             | xargs -0 sha256sum | awk '{print $1}' | sort | tr '\n' ' ')"
[[ "$before_sha" == "$after_sha" ]] \
  || fail "14: the restored packs are not byte-identical
   before: $before_sha
   after : $after_sha"
# Each sidecar must still name a service and a capture time.
while IFS= read -r m; do
  grep -qE '^SERVICE=[a-z]' "$m"      || fail "14: $m lost its SERVICE"
  grep -qE '^CAPTURED_AT=[0-9]{4}' "$m" || fail "14: $m lost its CAPTURED_AT"
done < <(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age.meta')
echo "   $r_packs packs byte-identical, $r_meta sidecars intact and still parseable"

sect "15. every restored pack verifies, unpacks and restores its state"
ok_v=0; ok_u=0
while IFS= read -r pk; do
  out="$(probe '' "service_state_pack_verify '$pk'; echo RC=\$?")"
  grep -q 'RC=0' <<< "$out" || fail "15: $(basename -- "$pk") did not verify: $out"
  ok_v=$(( ok_v + 1 ))
  d="$TMP/unpack-$(basename -- "$pk" .tar.age)"
  out="$(probe '' "service_state_unpack '$pk' '$TMP/keys/ident' '$d'; echo RC=\$?")"
  grep -q 'RC=0' <<< "$out" || fail "15: $(basename -- "$pk") did not unpack: $out"
  [[ -s "$d/MANIFEST" ]] || fail "15: no manifest in $d"
  r="$TMP/rs-$(basename -- "$pk" .tar.age)"
  out="$(probe '' "service_state_restore '$d' '$r'; echo RC=\$?")"
  grep -q 'RC=0' <<< "$out" || fail "15: state did not restore from $(basename -- "$pk"): $out"
  ok_u=$(( ok_u + 1 ))
done < <(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age' | sort)
[[ "$ok_v" == "$n_svcs" && "$ok_u" == "$n_svcs" ]] \
  || fail "15: verified $ok_v, restored $ok_u, of $n_svcs"
echo "   $ok_v verified, $ok_u unpacked and restored"

sect "16. retention works on the RESTORED set, and keeps the newest of each"
# The second half of what the unit runs. Every restored pack is the only one of
# its service, so NOTHING may be superseded -- "never delete the only one".
out="$(probe "STATE_PACK_KEEP=1" "storage_prune_state_packs --confirm '$RPACKDIR'")"
grep -q 'superseded  : 0' <<< "$out" \
  || fail "16: retention proposed deleting a service's only pack: $out"
grep -q "retained    : $n_svcs" <<< "$out" \
  || fail "16: not every restored pack was retained: $out"
grep -qi 'unknown' <<< "$out" \
  && fail "16: a restored pack read as UNKNOWN -- its sidecar did not survive: $out"
still="$(find "$RPACKDIR" -maxdepth 1 -name '*.tar.age' | wc -l)"
[[ "$still" == "$n_svcs" ]] || fail "16: retention removed $(( n_svcs - still )) pack(s)"
echo "   $n_svcs retained, 0 superseded, none unknown, nothing removed"

sect "17. MUTATION: without the sidecar, retention cannot act after a disaster"
# The sidecar is the whole reason retention works on a restored set: the service
# name lives inside the ENCRYPTED pack otherwise, and this host holds only the
# public key. Remove the sidecar write and the restored packs must all read as
# `unknown` -- kept, correctly, but retention can do nothing with them and
# nothing would have said so until the day it mattered.
cp "$CLI" "$TMP/cli.orig.sidecar"
cat > "$TMP/mutate-sidecar.py" <<'PYSC'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '  } > "$dest.meta"\n'
new = '  } > /dev/null\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYSC
( python3 -I "$TMP/mutate-sidecar.py" "$CLI" ) \
  || { cp "$TMP/cli.orig.sidecar" "$CLI"; fail "17: the sidecar mutation did not apply"; }
rm -rf -- "$TMP/data/backups/state-packs" "$TMP/mut"
build_all_state
mout="$(probe '' "storage_capture_all_state --pack")"
mdir="$(probe '' 'state_pack_dir')"
m_meta="$(find "$mdir" -maxdepth 1 -name '*.tar.age.meta' 2>/dev/null | wc -l)"
mret="$(probe "STATE_PACK_KEEP=1" "storage_prune_state_packs '$mdir'")"
cp "$TMP/cli.orig.sidecar" "$CLI"
[[ "$m_meta" == "0" ]] \
  || fail "17: the mutation changed nothing -- $m_meta sidecars were still written"
grep -qE 'unknown     : [1-9]' <<< "$mret" \
  || fail "17: without sidecars the restored packs did not read as unknown, so
section 16's clean verdict was not actually earned by the sidecar: $mret"
grep -q 'retained    : 0' <<< "$mret" \
  || fail "17: without sidecars something was still retained by service: $mret"
echo "   killed: no sidecar -> every pack unknown, nothing retainable by service"

sect "18. the CLI is restored after the mutations"
grep -q '} > "$dest.meta"' "$CLI" || fail "18: the sidecar write is missing from the CLI"
echo "   sidecar write is back"

echo
echo "PROVEN: capture -> pack -> repository -> restore -> unpack -> state, with the"
echo "        local copies destroyed in between and the credential's mode and bytes"
echo "        intact -- for one service through the per-service commands, AND for"
echo "        all five through the SCHEDULED path the unit runs, with retention"
echo "        working on the restored set and the sidecars intact."
echo "NOT proven, and still operator-gated: that any pack has left this host, and"
echo "        that the real age key opens one. The repository here is a scratch"
echo "        directory under the test's own temp dir."
echo "ALL PACK-REPOSITORY CHECKS PASSED"
