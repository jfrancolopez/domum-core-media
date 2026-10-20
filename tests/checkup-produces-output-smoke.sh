#!/usr/bin/env bash
# `checkup` must PRODUCE A REPORT. Silence is the one unacceptable outcome.
#
# Production, 2026-10-20: `sudo domum-media checkup` printed nothing at all --
# not a header, not an error. Every individual check can be correct and the
# command still useless, because the report is printed only after all of them
# have run: one abort under `set -euo pipefail` anywhere in the chain and the
# operator gets a blank line and no indication that anything was skipped.
#
# This drives checkup_cmd itself and asserts the report exists. It cannot prove
# the production host's exact configuration works, but it makes a silent death
# in the shared chain fail in CI instead of in front of the operator.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

mkdir -p "$TMP/bin" "$TMP/data/immich/library" "$TMP/state/restore-verification" \
         "$TMP/snapshots" "$TMP/media" "$TMP/secrets" "$TMP/meta"

# A minimal real config, so the real load_cfg runs and applies every default.
cat > "$TMP/domum-media.conf" <<CFG
DOMUM_DOMAIN=example.invalid
BACKUP_POLICY=BALANCED
DOMUM_DATA_ROOT=$TMP/data
DOMUM_MEDIA_ROOT=$TMP/media
DOMUM_SNAPSHOT_ROOT=$TMP/snapshots
DOMUM_STATE_ROOT=$TMP/state
SECRETS_DIR=$TMP/secrets
BACKUP_TARGETS=cloud
ENABLE_IMMICH=1
CFG

# Externals are stubbed so nothing can reach the host, and each returns
# something plausible rather than failing -- a check that aborts because its
# tool is missing is a different defect, covered elsewhere.
for s in docker systemctl btrfs lsblk smartctl apt-get curl restic age; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$s"; chmod +x "$TMP/bin/$s"
done
printf '#!/usr/bin/env bash\nprintf "btrfs\\n"\n' > "$TMP/bin/stat-fake"

run_checkup() {  # $1 = extra setup
  local setup="${1:-}" script="$TMP/run.sh"
  cat > "$script" <<SH
export PATH="$TMP/bin:\$PATH"
export DOMUM_DATA_ROOT="$TMP/data" DOMUM_MEDIA_ROOT="$TMP/media"
export DOMUM_STATE_ROOT="$TMP/state" DOMUM_SNAPSHOT_ROOT="$TMP/snapshots"
export SECRETS_DIR="$TMP/secrets" REPO_META_DIR="$TMP/meta"
export IMMICH_LIBRARY_DIR="$TMP/data/immich/library"
export CFG_FILE="$TMP/domum-media.conf"
source "$CLI" >/dev/null 2>&1
set +e
need_root() { :; }
# load_cfg is NOT stubbed. It is what applies every default the rest of the
# chain reads, and stubbing it left RECOVERY_PACK_DEST unbound -- which under
# set -u killed the shell before a single line of the report was printed.
# That is exactly the shape of the production symptom, so the fixture exercises
# the real function against a real config file.
# (No backticks here: this heredoc is UNQUOTED, so a backtick would be command
# substitution executed when the script is WRITTEN.)
export_env_for_compose() { :; }
$setup
checkup_cmd "\$@"
echo "EXITCODE=\$?"
SH
  shift || true
  bash "$script" "$@" 2>&1
}

sect "checkup prints a report, not silence"
out="$(run_checkup)"
[[ -n "${out//[[:space:]]/}" ]] || fail "checkup produced NO output at all"
grep -q 'domum-media checkup' <<< "$out" \
  || fail "the report header is missing -- something aborted before printing:
$out"
for section in 'Critical:' 'Warnings:' 'Healthy:' 'Suggested actions:'; do
  grep -q "$section" <<< "$out" \
    || fail "the '$section' section is missing, so the report is truncated:
$out"
done
echo "  header and all four sections present"

sect "every section is reached even when the new host checks find problems"
# The four host/storage/off-site checks run LAST, immediately before the
# report. If one of them aborts, the operator sees nothing -- which is exactly
# what happened in production.
out="$(run_checkup '
checkup_systemd_health() { checkup_add critical "a failed unit"; }
checkup_btrfs_health()   { checkup_add warning  "unreadable counters"; }
checkup_disk_health()    { checkup_add action   "install smartmontools"; }
checkup_immich_offsite() { checkup_add healthy  "all originals present"; }')"
grep -q 'a failed unit' <<< "$out"        || fail "the critical is missing: $out"
grep -q 'unreadable counters' <<< "$out"  || fail "the warning is missing: $out"
grep -q 'install smartmontools' <<< "$out" || fail "the action is missing: $out"
grep -q 'all originals present' <<< "$out" || fail "the healthy item is missing: $out"
echo "  findings from all four classes reach the report"

sect "a check that DIES must not silently empty the report"
# The guarantee that was missing. A check aborting mid-chain took the whole
# report with it; the operator could not tell a healthy server from a broken
# command. Driving that case here makes it a CI failure instead.
out="$(run_checkup 'checkup_btrfs_health() { return 1; }')"
grep -q 'domum-media checkup' <<< "$out" \
  || fail "a failing check swallowed the entire report:
$out"
echo "  a failing check does not erase the report"

sect "--json still emits parseable JSON with all four keys"
out="$(run_checkup '' --json)"
line="$(sed -n '/^{/,/^}/p' <<< "$out")"
[[ -n "$line" ]] || fail "no JSON was emitted: $out"
jq -e 'has("critical") and has("warnings") and has("healthy")
       and has("suggested_actions")' >/dev/null <<< "$line" \
  || fail "the JSON is missing a key: $line"
echo "  parseable, with critical/warnings/healthy/suggested_actions"

echo "PASS: checkup produces output"
