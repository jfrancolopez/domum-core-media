#!/usr/bin/env bash
set -uo pipefail

# Proves that a snapshot which could not be created cannot silently authorise a
# risky stateful operation.
#
# Every service state path here is an ordinary directory, which is exactly the
# current production condition: snapshots are skipped. The assertions below
# exercise the real shipped functions from bin/domum-media.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/data/immich" "$TMP_DIR/data/plex" "$TMP_DIR/snapshots" "$TMP_DIR/state"

# Harness: source the real CLI (its main() is guarded), then force every path to
# look like an ordinary directory by stubbing the subvolume probe.
harness() {
  cat <<EOF
set -uo pipefail
DOMUM_DIR="$REPO_ROOT"
CFG_FILE="$TMP_DIR/absent.conf"
source "$REPO_ROOT/bin/domum-media"
DOMUM_DATA_ROOT="$TMP_DIR/data"
DOMUM_SNAPSHOT_ROOT="$TMP_DIR/snapshots"
DOMUM_STATE_ROOT="$TMP_DIR/state"
is_btrfs_subvol() { return 1; }
service_data_path() { echo "$TMP_DIR/data/\$1"; }
EOF
}

# ---------------------------------------------------------------------------
# 1. snapshot_create must not report success when it created nothing.
# ---------------------------------------------------------------------------
out="$( { bash -c "$(harness); if snapshot_create testtag; then echo RC=0; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "snapshot_create reported success despite creating no snapshot: $out"
grep -q '0 created' <<< "$out" \
  || fail "snapshot_create did not report how many snapshots it created: $out"

# ...and it must still succeed when a snapshot really is taken. The stub creates
# the snapshot target (the last argument), because the implementation now
# verifies the snapshot exists rather than trusting btrfs's exit status.
out="$( { bash -c "$(harness); is_btrfs_subvol() { return 0; }; btrfs() { mkdir -p \"\${!#}\"; }; record_rollback_entry() { :; }; if snapshot_create realtag; then echo RC=0; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=0' <<< "$out" || fail "snapshot_create failed when a snapshot was created: $out"

# ---------------------------------------------------------------------------
# 2. The gate refuses by default, and only warns under SNAPSHOT_POLICY=WARN.
# ---------------------------------------------------------------------------
out="$( { bash -c "$(harness); snapshot_protection_unavailable 'test op' 'not a subvolume'; echo REACHED" ; } 2>&1 )"
grep -q 'REACHED' <<< "$out" && fail "gate allowed execution to continue under the default policy"
grep -qi 'refusing to continue' <<< "$out" \
  || fail "gate did not explain that it refused: $out"
grep -q 'SNAPSHOT_POLICY=WARN' <<< "$out" \
  || fail "gate did not tell the operator how to proceed deliberately: $out"

out="$( { bash -c "$(harness); SNAPSHOT_POLICY=WARN; snapshot_protection_unavailable 'test op' 'not a subvolume'; echo REACHED" ; } 2>&1 )"
grep -q 'REACHED' <<< "$out" || fail "SNAPSHOT_POLICY=WARN did not allow the operation to continue: $out"
grep -qi 'NO rollback point' <<< "$out" || fail "WARN path did not state that rollback is unavailable: $out"

# ---------------------------------------------------------------------------
# 3. The decisive property: the risky operation must not be reached.
#    Replays the real update sequence (snapshot -> gate -> compose up) using the
#    real functions, with the deployment step replaced by a tripwire.
# ---------------------------------------------------------------------------
tripwire="$TMP_DIR/deployed"
out="$( { bash -c "$(harness)
compose_cmd() { touch '$tripwire'; }
snapshot_name=\"\"
if ! snapshot_name=\"\$(create_service_snapshot plex pre-update imgA imgB)\"; then snapshot_name=\"\"; fi
if [[ -z \"\$snapshot_name\" ]]; then
  snapshot_protection_unavailable 'Cannot snapshot plex before updating it' 'not a Btrfs subvolume'
fi
compose_cmd up -d plex
echo DEPLOYED" ; } 2>&1 )"
[[ -e "$tripwire" ]] && fail "the stateful operation ran despite having no snapshot"
grep -q 'DEPLOYED' <<< "$out" && fail "the update sequence continued past the gate"

# Under WARN the same sequence is allowed through, deliberately.
out="$( { bash -c "$(harness)
SNAPSHOT_POLICY=WARN
compose_cmd() { touch '$tripwire'; }
snapshot_name=\"\"
if ! snapshot_name=\"\$(create_service_snapshot plex pre-update imgA imgB)\"; then snapshot_name=\"\"; fi
if [[ -z \"\$snapshot_name\" ]]; then
  snapshot_protection_unavailable 'Cannot snapshot plex before updating it' 'not a Btrfs subvolume'
fi
compose_cmd up -d plex
echo DEPLOYED" ; } 2>&1 )"
[[ -e "$tripwire" ]] || fail "SNAPSHOT_POLICY=WARN did not allow the operation through"
rm -f "$tripwire"

# ---------------------------------------------------------------------------
# 4. No risky call site may swallow a snapshot failure again.
# ---------------------------------------------------------------------------
if grep -nE 'create_service_snapshot[^)]*\|\| *true' "$REPO_ROOT/bin/domum-media"; then
  fail "a create_service_snapshot call still swallows failure with '|| true'"
fi
if grep -nE 'snapshot_create [^|]*\|\| *(echo|true)' "$REPO_ROOT/bin/domum-media"; then
  fail "a snapshot_create call still downgrades failure to a message"
fi

# Each risky site must be followed by the gate.
for tag in pre-update pre-immich-bundle pre-immich-reset; do
  awk -v tag="$tag" '
    index($0, tag) { found=1; window=12 }
    found && window-- > 0 && /snapshot_protection_unavailable/ { ok=1 }
    END { exit ok ? 0 : 1 }
  ' "$REPO_ROOT/bin/domum-media" || fail "risky snapshot site '$tag' is not followed by the safety gate"
done

# `snapshot create` must not return success when nothing was created.
grep -q 'No snapshot was created' "$REPO_ROOT/bin/domum-media" \
  || fail "the operator-facing 'snapshot create' can still exit 0 having created nothing"

# apply stays non-fatal by design, but must warn rather than claim success.
awk '
  /Pre-apply btrfs snapshot/ { found=1; window=8 }
  found && window-- > 0 && /no rollback point/ { ok=1 }
  END { exit ok ? 0 : 1 }
' "$REPO_ROOT/bin/domum-media" || fail "apply does not warn that it has no rollback point"

# ---------------------------------------------------------------------------
# 5. A btrfs command that FAILS on a real subvolume must not pass the gate.
#    Counting attempts rather than successes would let ENOSPC, or an existing
#    target, authorise a risky operation with no snapshot.
# ---------------------------------------------------------------------------
out="$( { bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { return 1; }          # the path IS a subvolume, but the snapshot fails
record_rollback_entry() { :; }
if snapshot_create failtag; then echo RC=0; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "snapshot_create reported success when the btrfs command failed: $out"
grep -q 'FAILED' <<< "$out" || fail "a failed snapshot command must be reported: $out"

# Same for the per-service snapshot: it must not return a name for a snapshot
# that was never created.
out="$( { bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { return 1; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { :; }
if name=\"\$(create_service_snapshot plex pre-update a b)\"; then echo \"RC=0 name=\$name\"; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "create_service_snapshot returned success for a snapshot that was never created: $out"

# And a btrfs command that exits 0 without producing the snapshot must also fail.
out="$( { bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { return 0; }          # claims success, creates nothing
record_rollback_entry() { :; }
if snapshot_create lyingtag; then echo RC=0; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "snapshot_create trusted btrfs's exit status without verifying the snapshot exists: $out"

# ---------------------------------------------------------------------------
# 6. Every mapped service must resolve a data path with NO config loaded.
#    A missing *_CONFIG_DIR previously made this fail with "unbound variable"
#    under `set -u` -- on a host bootstrapped from the example config, and on
#    the disaster-recovery rebuild path.
# ---------------------------------------------------------------------------
for svc in traefik immich jellyfin plex navidrome calibre-web kavita uptime-kuma; do
  out="$( { bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path $svc" ; } 2>&1 )"     || fail "service_data_path $svc failed with no config loaded: $out"
  case "$out" in
    /*) ;;
    *) fail "service_data_path $svc returned a non-absolute path with no config: [$out]" ;;
  esac
done

# An unmapped service must still be rejected rather than returning something.
if bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path definitely-not-a-service" >/dev/null 2>&1; then
  fail "service_data_path accepted an unknown service"
fi

# Every service the snapshot code iterates must also be resolvable.
while read -r cand; do
  svc="$(basename "$cand")"
  bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path $svc" >/dev/null 2>&1     || fail "snapshot candidate '$svc' has no service_data_path mapping"
done < <(awk '/^snapshot_subvolumes\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media"          | grep -oE 'DOMUM_DATA_ROOT/[a-z-]+' | sed 's|.*/||')

echo "PASS: snapshot safety gate smoke test"
