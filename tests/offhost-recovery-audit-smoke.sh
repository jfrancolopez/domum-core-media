#!/usr/bin/env bash
set -uo pipefail

# Proves `dr-offhost-audit` answers the question every other proof dodges:
# with Hetzner and nothing else, could a NEW machine rebuild?
#
# Every other check runs on the N100, with the N100's credentials, against
# images in the N100's docker store. None of that survives the machine.
#
# The load-bearing assertions:
#
#   * "absent" and "I cannot look" must be DIFFERENT answers. An audit that
#     reports unreadable-as-missing cries wolf, and one that cries wolf gets
#     ignored -- worse than not having it.
#   * a pack that never leaves the host is a BLOCKING gap, with the
#     consequence spelled out.
#   * no secret VALUE may ever appear in the output.
#
# Hermetic: a stub `docker`, fixture roots, no network.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP_DIR" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT
command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

DATA="$TMP_DIR/data"; STATE="$TMP_DIR/state"; SEC="$TMP_DIR/secrets"
mkdir -p "$DATA" "$STATE/recovery-pack" "$SEC" "$TMP_DIR/media" "$TMP_DIR/bin"
export DOMUM_DATA_ROOT="$DATA" DOMUM_MEDIA_ROOT="$TMP_DIR/media"
export DOMUM_STATE_ROOT="$STATE" SECRETS_DIR="$SEC"
export BACKUP_TARGETS=cloud BACKUP_INCLUDE_PATHS="$DATA"
export CFG_FILE="$TMP_DIR/domum-media.conf"
printf '# fixture config\n' > "$CFG_FILE"

# A SECRET VALUE that must never be echoed, so leakage is detectable.
CANARY='SECRET-CANARY-sk-do-not-print-9f3a'
printf '%s\n' "$CANARY" > "$SEC/restic_password_cloud"
printf 'RESTIC_REPOSITORY=sftp:u@host:/repo\n' > "$SEC/restic_cloud_env"
printf '%s\n' "$CANARY" > "$SEC/hetzner_storagebox_ed25519"
printf 'host ssh-ed25519 AAAA\n' > "$SEC/hetzner_storagebox_known_hosts"
printf 'age1fixturepubkey\n' > "$SEC/recovery_pack_pubkey"
: > "$STATE/recovery-pack/pack-20261011.age"

cat > "$TMP_DIR/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
case "$1" in
  inspect)
    case "$2" in
      immich_server)   echo "sha256:serverid" ;;
      immich_postgres) echo "sha256:pgid" ;;
      immich_redis)    echo "sha256:redisid" ;;
      *) exit 1 ;;
    esac ;;
  image)
    # $3 is the image id when called as: docker image inspect <id> --format ...
    [[ -n "${STUB_NO_DIGEST:-}" ]] && exit 0
    case "$3" in
      sha256:serverid) echo "ghcr.io/immich-app/immich-server@sha256:aaaa" ;;
      sha256:pgid)     echo "tensorchord/pgvecto-rs@sha256:bbbb" ;;
      sha256:redisid)  echo "redis@sha256:cccc" ;;
    esac ;;
  manifest) [[ -n "${STUB_REGISTRY_MISS:-}" ]] && exit 1; exit 0 ;;
  exec)
    # the vector-extension probe
    [[ -n "${STUB_VCHORD:-}" ]] && { echo vchord; exit 0; }
    [[ -n "${STUB_NO_DB:-}" ]] && exit 1
    echo vectors ;;
esac
exit 0
DOCKEREOF
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"

run_audit() {  # $1 = setup, rest = args
  local setup="${1:-}"; shift || true
  (
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bin/domum-media-backup" >/dev/null 2>&1
    set +e
    die() { echo "DIE: $*"; exit 9; }
    backup_target_enabled() { [[ "$1" == cloud ]]; }
    backup_target_value() {
      case "$2" in
        TYPE) echo repository ;;
        REPOSITORY) echo "sftp:u@host:/repo" ;;
        ENV_FILE) echo "$SECRETS_DIR/restic_cloud_env" ;;
        SFTP_KEY_FILE) echo "$SECRETS_DIR/hetzner_storagebox_ed25519" ;;
        SFTP_KNOWN_HOSTS_FILE) echo "$SECRETS_DIR/hetzner_storagebox_known_hosts" ;;
      esac
    }
    backup_target_password_file() { echo "$SECRETS_DIR/restic_password_cloud"; }
    recovery_pack_state_file() { echo "$DOMUM_STATE_ROOT/recovery-pack/last.env"; }
    RECOVERY_PACK_DEST="$DOMUM_STATE_ROOT/recovery-pack"
    RECOVERY_PACK_AGE_PUBKEY_FILE="$SECRETS_DIR/recovery_pack_pubkey"
    [[ -n "$setup" ]] && eval "$setup"
    do_dr_offhost_audit "$@" 2>&1
    echo "EXITCODE=$?"
  )
}

# ---------------------------------------------------------------------------
sect "a secret VALUE never appears in the output"
out="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1')"
grep -qF "$CANARY" <<< "$out" && fail "a secret value was printed"
grep -q 'restic_password_cloud' <<< "$out" || fail "the secret is not reported by NAME: $out"
echo "  reported by name; the value never appears"

sect "with everything in place and delivery enabled there is no blocking gap"
grep -qE 'restic password \(cloud\) +present' <<< "$out" || fail "a present secret was not reported: $out"
grep -qE 'off-host delivery +ENABLED' <<< "$out" || fail "enabled delivery not reported: $out"
grep -q 'NOT READY' <<< "$out" && fail "a healthy configuration was reported NOT READY"
echo "  present credentials, delivery enabled, no blocking gap"

sect "delivery DISABLED is a blocking gap, with the consequence stated"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=0')"
grep -qE 'off-host delivery +DISABLED' <<< "$o" || fail "disabled delivery not reported: $o"
grep -q 'lost with them' <<< "$o" || fail "the consequence is not stated: $o"
grep -q 'highest-consequence gap' <<< "$o" || fail "its severity is not stated: $o"
grep -q 'NOT READY' <<< "$o" || fail "it is not treated as blocking: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "a blocking gap did not exit 1: $o"
echo "  exit 1, named as the highest-consequence gap"

# ---------------------------------------------------------------------------
sect "a genuinely MISSING credential is a blocking gap"
mv "$SEC/restic_password_cloud" "$SEC/.hidden"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1')"
grep -qE 'restic password \(cloud\) +MISSING' <<< "$o" || fail "an absent secret was not reported: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "an absent secret did not exit 1: $o"
mv "$SEC/.hidden" "$SEC/restic_password_cloud"
echo "  absent means MISSING and blocks"

sect "an UNREADABLE secrets directory is NOT reported as missing"
# This is the cry-wolf case. The first version of this audit reported
# unreadable-as-MISSING and declared a blocking gap from an unprivileged run.
chmod 000 "$SEC"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1')"
chmod 700 "$SEC"
grep -qE 'restic password \(cloud\) +UNREADABLE' <<< "$o" \
  || fail "an unreadable secrets dir was not distinguished from absent: $o"
grep -q 'needs root' <<< "$o" || fail "it does not say why: $o"
grep -qE 'restic password \(cloud\) +MISSING' <<< "$o" && fail "unreadable was reported as MISSING"
grep -q 'NOT READY' <<< "$o" && fail "an unreadable path was treated as a blocking gap"
grep -q 'EXITCODE=2' <<< "$o" || fail "unreadable should exit 2 (unprovable), not 1: $o"
echo "  UNREADABLE, exit 2, and explicitly not a blocking gap"

sect "an unreadable CONFIG cannot mean 'delivery disabled'"
chmod 000 "$CFG_FILE"
o="$(run_audit '')"
chmod 644 "$CFG_FILE"
grep -qE 'off-host delivery +UNKNOWN' <<< "$o" \
  || fail "an unreadable config was not reported as UNKNOWN: $o"
grep -qE 'off-host delivery +DISABLED' <<< "$o" && fail "unread config was reported as DISABLED"
echo "  a value that was never read is UNKNOWN, not 0"

# ---------------------------------------------------------------------------
sect "a pack stored INSIDE the backup set is flagged as circular"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1
BACKUP_INCLUDE_PATHS="$DOMUM_STATE_ROOT"')"
grep -q 'CIRCULAR' <<< "$o" || fail "a pack inside the backup was not flagged: $o"
grep -q 'inside the repository they open' <<< "$o" || fail "the circularity is not explained: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "circularity did not block: $o"
echo "  you would need the credentials to fetch the credentials"

sect "no pack at all is a blocking gap"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1
RECOVERY_PACK_DEST="$TMP_DIR/empty-pack"; mkdir -p "$RECOVERY_PACK_DEST"')"
grep -qE 'pack present +NONE' <<< "$o" || fail "an empty pack dir was not reported: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "no pack did not block: $o"
echo "  an empty pack directory blocks"

sect "the age PRIVATE key is UNPROVABLE from this host, and says so"
grep -q 'age private key' <<< "$out" || fail "the private key is not mentioned: $out"
grep -q 'UNPROVABLE' <<< "$out" || fail "it claims something it cannot know: $out"
grep -q 'neither this machine nor the pack' <<< "$out" \
  || fail "it does not say where the key must be: $out"
echo "  stated as an operator-held dependency, not assumed"

# ---------------------------------------------------------------------------
sect "an image with no RepoDigest is a blocking gap"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1; export STUB_NO_DIGEST=1')"
grep -q 'NO DIGEST' <<< "$o" || fail "an undigested image was not flagged: $o"
grep -q 'not obtainable after this host is gone' <<< "$o" || fail "the consequence is not stated: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "an undigested image did not block: $o"
echo "  local-only images block: an ID is not obtainability"

sect "--probe reports registry reachability, in both directions"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1' --probe)"
grep -qE 'immich server +obtainable' <<< "$o" || fail "a resolvable digest was not reported: $o"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1; export STUB_REGISTRY_MISS=1' --probe)"
grep -q 'NOT IN REGISTRY' <<< "$o" || fail "an unresolvable digest was not flagged: $o"
grep -q 'EXITCODE=1' <<< "$o" || fail "an unobtainable image did not block: $o"
echo "  obtainable when it resolves, blocking when it does not"

sect "the deprecated vector extension narrows the recovery window"
grep -q 'pgvecto.rs' <<< "$out" || fail "the extension is not reported: $out"
grep -q 'SHRINKS over time' <<< "$out" || fail "the narrowing window is not explained: $out"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1; export STUB_VCHORD=1')"
grep -q 'SHRINKS over time' <<< "$o" && fail "a current extension was still warned about"
echo "  flagged for pgvecto.rs, silent for vchord"

sect "an unreachable database is UNKNOWN, not 'fine'"
o="$(run_audit 'RECOVERY_PACK_EMAIL_ENABLED=1; export STUB_NO_DB=1')"
grep -qE 'vector extension +UNKNOWN' <<< "$o" || fail "an unqueryable db was not UNKNOWN: $o"
echo "  it refuses to guess the extension"

# ---------------------------------------------------------------------------
sect "mutation: treating unreadable as present must hide the real gap"
MUT="$TMP_DIR/mutant"
cp "$REPO_ROOT/bin/domum-media-backup" "$MUT"
cat > "$TMP_DIR/mutate.py" <<'MUTPY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = '''    elif [[ ! -r "$(dirname "$path")" ]]; then
      offhost_audit_row "$label" "UNREADABLE" "$(dirname "$path") needs root"
      unknowns=$(( unknowns + 1 ))
'''
assert s.count(needle) == 1, "needle count: %d" % s.count(needle)
s = s.replace(needle, '', 1)
open(p, "w").write(s)
MUTPY
python3 "$TMP_DIR/mutate.py" "$MUT" || fail "the mutation script failed"
grep -q 'UNREADABLE' "$MUT" && fail "the mutation did not remove the branch"
chmod 000 "$SEC"
mout="$(
  source "$MUT" >/dev/null 2>&1
  set +e
  die() { echo "DIE: $*"; exit 9; }
  backup_target_enabled() { [[ "$1" == cloud ]]; }
  backup_target_value() {
    case "$2" in
      TYPE) echo repository ;; REPOSITORY) echo "sftp:u@host:/repo" ;;
      ENV_FILE) echo "$SECRETS_DIR/restic_cloud_env" ;;
      SFTP_KEY_FILE) echo "$SECRETS_DIR/hetzner_storagebox_ed25519" ;;
      SFTP_KNOWN_HOSTS_FILE) echo "$SECRETS_DIR/hetzner_storagebox_known_hosts" ;;
    esac
  }
  backup_target_password_file() { echo "$SECRETS_DIR/restic_password_cloud"; }
  recovery_pack_state_file() { echo "$DOMUM_STATE_ROOT/recovery-pack/last.env"; }
  RECOVERY_PACK_DEST="$DOMUM_STATE_ROOT/recovery-pack"
  RECOVERY_PACK_EMAIL_ENABLED=1
  do_dr_offhost_audit 2>&1
  echo "EXITCODE=$?"
)"
chmod 700 "$SEC"
grep -q 'MISSING' <<< "$mout" \
  || fail "the mutant did not report unreadable as MISSING; the branch is not load-bearing"
grep -q 'NOT READY' <<< "$mout" \
  || fail "the mutant did not raise a false blocking gap: $mout"
echo "  without it, an unprivileged run invents a blocking gap -- the cry-wolf failure"

echo "PASS: offhost-recovery-audit-smoke"
