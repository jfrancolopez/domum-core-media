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
# Carried into the probe so a section's own stubs can refer to \$TMP_DIR.
# Without it they reached the inner shell with TMP_DIR unset, where set -u
# killed the stub -- and one case then passed for the WRONG reason, because an
# unset TMP_DIR made the "absent" fixture path /data/absent, which is also
# absent.
TMP_DIR="$TMP_DIR"
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
out="$( { bash -c "$(harness); is_btrfs_subvol() { return 0; }; btrfs() { mkdir -p \"\${!#}\"; }; record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }; if snapshot_create realtag; then echo RC=0; else echo RC=\$?; fi" ; } 2>&1 )"
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
#
# Scoped to the `if ! snapshot_create "pre-apply"` block and its closing `fi`,
# NOT to a fixed line window after the echo: a window makes the assertion
# sensitive to comment length, so adding an explanatory comment inside the block
# broke this check while the behaviour it tests was correct.
awk '
  /if ! snapshot_create "pre-apply"/ { inblock=1 }
  inblock && /no rollback point/     { ok=1 }
  inblock && /^  fi$/                { inblock=0 }
  END { exit ok ? 0 : 1 }
' "$REPO_ROOT/bin/domum-media" || fail "apply does not warn that it has no rollback point"

# ...and it must NOT assert a cause it cannot know. While no service path was a
# subvolume, "service state paths are not Btrfs subvolumes" was the only possible
# reason. With migrated services present, snapshot_create also returns non-zero
# when a subvolume's snapshot genuinely FAILED, and naming the old cause would
# hide the new one.
#
# Enforced over the WHOLE file, not just this block: the same sentence sat at the
# operator-facing `snapshot create` site too, and a block-scoped check caught only
# one of the two. `snapshot_protection_unavailable` says "must be Btrfs
# subvolumes" -- a requirement, which is still true -- so only the diagnostic
# phrasing is banned.
src_nocomments="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media")"
if grep -q 'are not Btrfs subvolumes' <<< "$src_nocomments"; then
  grep -n 'are not Btrfs subvolumes' "$REPO_ROOT/bin/domum-media" >&2
  fail "a snapshot failure asserts 'paths are not Btrfs subvolumes' as its cause.
That was the only possible reason while none of them was. With migrated services
present, snapshot_create also returns non-zero when a real subvolume's snapshot
FAILED, and naming the old cause hides the new one."
fi

# ...and each site must still say something, rather than failing mutely.
for site in 'snapshot_create "pre-apply"' 'snapshot_create "${1:-manual}"'; do
  awk -v site="$site" '
    index($0, site) { inblock=1 }
    inblock && /SNAPSHOT-MODEL\.md/ { ok=1 }
    inblock && /^      fi$|^  fi$/ { inblock=0 }
    END { exit ok ? 0 : 1 }
  ' "$REPO_ROOT/bin/domum-media" \
    || fail "the failure path at '$site' points the operator nowhere"
done

# ---------------------------------------------------------------------------
# 5. A btrfs command that FAILS on a real subvolume must not pass the gate.
#    Counting attempts rather than successes would let ENOSPC, or an existing
#    target, authorise a risky operation with no snapshot.
# ---------------------------------------------------------------------------
out="$( { bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { return 1; }          # the path IS a subvolume, but the snapshot fails
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
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
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
if name=\"\$(create_service_snapshot plex pre-update a b)\"; then echo \"RC=0 name=\$name\"; else echo RC=\$?; fi" ; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "create_service_snapshot returned success for a snapshot that was never created: $out"

# And a btrfs command that exits 0 without producing the snapshot must also fail.
out="$( { bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { return 0; }          # claims success, creates nothing
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
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
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path $svc" ; } 2>&1 )"     || fail "service_data_path $svc failed with no config loaded: $out"
  case "$out" in
    /*) ;;
    *) fail "service_data_path $svc returned a non-absolute path with no config: [$out]" ;;
  esac
done

# A trailing slash on a config value must not change the resolved state root.
#
# `${dir%/config}` does not strip when the value ends "…/config/", so the
# resolved path stayed at the CONFIG directory -- and a migration would then
# convert that subdirectory into a subvolume while its parent stayed an ordinary
# directory, leaving `report` saying "unprotected" after a migration that
# reported success.
for svc_var in "jellyfin JELLYFIN_CONFIG_DIR" "plex PLEX_CONFIG_DIR" \
               "calibre-web CALIBRE_WEB_CONFIG_DIR" "kavita KAVITA_CONFIG_DIR"; do
  set -- $svc_var
  svc="$1"; var="$2"
  for suffix in "" "/"; do
    got="$(bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
$var='/srv/data/$svc/config$suffix'
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path $svc")"
    [[ "$got" == "/srv/data/$svc" ]] \
      || fail "service_data_path $svc with $var='/srv/data/$svc/config$suffix' resolved to [$got], not the service root"
  done
done

# The same for a data dir given with a trailing slash.
got="$(bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
NAVIDROME_DATA_DIR='/srv/data/navidrome/'
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path navidrome")"
[[ "$got" == "/srv/data/navidrome" ]] \
  || fail "service_data_path navidrome kept a trailing slash: [$got]"

# An unmapped service must still be rejected rather than returning something.
if bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path definitely-not-a-service" >/dev/null 2>&1; then
  fail "service_data_path accepted an unknown service"
fi

# Every service the snapshot code iterates must also be resolvable.
while read -r cand; do
  svc="$(basename "$cand")"
  bash -c "set -uo pipefail
DOMUM_DATA_ROOT=/srv/data
eval \"\$(awk '/^strip_config_suffix\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
eval \"\$(awk '/^service_data_path\(\) \{/,/^\}/' '$REPO_ROOT/bin/domum-media')\"
service_data_path $svc" >/dev/null 2>&1     || fail "snapshot candidate '$svc' has no service_data_path mapping"
done < <(awk '/^snapshot_subvolumes\(\) \{/,/^\}/' "$REPO_ROOT/bin/domum-media"          | grep -oE 'DOMUM_DATA_ROOT/[a-z-]+' | sed 's|.*/||')

# ---------------------------------------------------------------------------
# A snapshot of SOME OTHER SERVICE must never authorise destroying this one.
#
# `snapshot_create` succeeds on a global count. The moment any single service
# path becomes a Btrfs subvolume -- which the Jellyfin pilot is designed to do
# -- a Jellyfin snapshot would have satisfied the gate that guards
# `rm -rf /srv/data/immich/postgres`. The gate must be service-scoped.
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR/data/immich/postgres" "$TMP_DIR/data/jellyfin"

# Only jellyfin is a subvolume -- exactly the post-pilot production state.
only_jellyfin_is_subvol() {
  cat <<EOF
$(harness)
is_btrfs_subvol() { [[ "\$1" == *"/jellyfin"* ]]; }
btrfs() { mkdir -p "\${!#}"; }
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
record_service_snapshot_metadata() { :; }
EOF
}

# Sanity: the global helper really does pass in this state. If this ever stops
# being true the rest of this section is testing nothing.
out="$( { bash -c "$(only_jellyfin_is_subvol); if snapshot_create t; then echo RC=0; else echo RC=1; fi"; } 2>&1 )"
grep -q 'RC=0' <<< "$out" \
  || fail "fixture is wrong: snapshot_create should succeed when jellyfin is a subvolume: $out"

# The service-scoped gate must REFUSE for immich in that same state.
out="$( { bash -c "$(only_jellyfin_is_subvol); if assert_service_snapshot_covers immich pre-immich-reset '$TMP_DIR/data/immich/postgres'; then echo RC=0; else echo RC=1; fi"; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "a jellyfin snapshot authorised destroying immich state: $out"
grep -q 'Not covered' <<< "$out" \
  || fail "the refusal did not name the uncovered path: $out"

# ...and it must PASS for jellyfin, so the gate is not simply always-refuse.
out="$( { bash -c "$(only_jellyfin_is_subvol); if assert_service_snapshot_covers jellyfin pre-test '$TMP_DIR/data/jellyfin'; then echo RC=0; else echo RC=1; fi"; } 2>&1 )"
grep -q 'RC=0' <<< "$out" \
  || fail "the gate refused a service that really was snapshotted: $out"

# Btrfs snapshots are not recursive: a nested subvolume is an EMPTY DIRECTORY in
# the parent's snapshot. A differing st_dev proves the boundary, so a path that
# lives in a nested subvolume must not count as covered by the parent snapshot.
out="$( { bash -c "$(only_jellyfin_is_subvol)
path_covered_by_subvolume() { return 1; }
if assert_service_snapshot_covers jellyfin pre-test '$TMP_DIR/data/jellyfin'; then echo RC=0; else echo RC=1; fi"; } 2>&1 )"
grep -q 'RC=1' <<< "$out" \
  || fail "a path outside the snapshotted subvolume was treated as covered: $out"

# The real st_dev check must agree with itself on a path that is genuinely
# inside the subvolume, and reject one that is outside it entirely.
bash -c "$(harness); path_covered_by_subvolume '$TMP_DIR/data/immich' '$TMP_DIR/data/immich/postgres'" \
  || fail "path_covered_by_subvolume rejected a path plainly inside the subvolume"
bash -c "$(harness); path_covered_by_subvolume '$TMP_DIR/data/immich' '$TMP_DIR/data/jellyfin'" \
  && fail "path_covered_by_subvolume accepted a path outside the subvolume"

# A differing st_dev means a subvolume boundary was crossed somewhere between
# the two paths. The fixture is one filesystem, so the boundary is simulated by
# stubbing stat -- the logic under test is the comparison, not stat itself.
bash -c "$(harness)
stat() { if [[ \"\${*: -1}\" == *postgres ]]; then echo 99; else echo 45; fi; }
path_covered_by_subvolume '$TMP_DIR/data/immich' '$TMP_DIR/data/immich/postgres'" \
  && fail "a path on a different st_dev was treated as covered by the parent snapshot"

# ...and a nested subvolume must be rejected even if st_dev were to match, since
# the st_dev premise is only demonstrated for separately mounted subvolumes.
bash -c "$(harness)
path_is_subvolume() { [[ \"\$1\" == *postgres ]]; }
path_covered_by_subvolume '$TMP_DIR/data/immich' '$TMP_DIR/data/immich/postgres'" \
  && fail "a nested subvolume was treated as covered by its parent's snapshot"

# ---------------------------------------------------------------------------
# create_service_snapshot RETURNS the snapshot name on stdout. Anything else it
# writes there becomes part of the return value.
#
# It used to `echo "[domum-media] Snapshot: ..."` to stdout, so every caller
# captured two lines and passed the pair to restore_snapshot_for_service, which
# cannot find it. The auto-rollback after a failed health check would refuse --
# leaving the service on the broken image with a good snapshot unused -- and
# update history would record the mangled name as the rollback pointer.
#
# Unreachable while no service path was a subvolume, because the function
# returns 1 before printing anything. Armed by the first migration.
# ---------------------------------------------------------------------------
snapname="$( bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { mkdir -p \"\${!#}\"; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
create_service_snapshot immich pre-test a b" 2>/dev/null )"

[[ "$snapname" == *$'"'"'\n'"'"'* ]] \
  && fail "create_service_snapshot returned more than one line: [$snapname]"
[[ "$snapname" == immich-* ]] \
  || fail "create_service_snapshot did not return a bare snapshot name: [$snapname]"
[[ "$snapname" != *"domum-media"* ]] \
  || fail "a log line leaked into the returned snapshot name: [$snapname]"
[[ -d "$TMP_DIR/snapshots/$snapname" ]] \
  || fail "the returned name does not resolve to a snapshot, so a rollback could not find it: [$snapname]"

# And the progress line must still be produced -- on stderr.
snaperr="$( bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { mkdir -p \"\${!#}\"; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
create_service_snapshot immich pre-test2 a b" 2>&1 >/dev/null )"
grep -q 'Snapshot:' <<< "$snaperr" \
  || fail "the progress line was not written to stderr: [$snaperr]"

# ---------------------------------------------------------------------------
# A snapshot that would silently omit part of the tree must be refused.
#
# Btrfs snapshots are not recursive, so a nested subvolume appears as an EMPTY
# DIRECTORY in the parent's snapshot. "A snapshot of the service was created"
# therefore does not mean "the service's state is recoverable": if
# /srv/data/immich/postgres were ever a nested subvolume, the pre-update and
# pre-bundle gates would both pass on a snapshot holding an empty database.
# Verified against real Btrfs in tests/integration/btrfs-migration-integration.sh.
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR/data/immich/postgres"
nested_probe() {  # $1 = extra shell
  bash -c "$(harness)
is_btrfs_subvol() { return 0; }
btrfs() { mkdir -p \"\${!#}\"; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { printf '%s' 'rb-0000000000-stub'; }
subvolume_nested_children() { printf '%s\n' '$TMP_DIR/data/immich/postgres'; }
$1" 2>&1
}
out="$(nested_probe "create_service_snapshot immich nestedtag a b && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" || fail "a snapshot was taken despite a nested subvolume: $out"
grep -qi 'nested subvolume' <<< "$out" || fail "the refusal did not name the cause: $out"
grep -qi 'not recursive' <<< "$out" || fail "the refusal did not explain why it matters: $out"

# It must refuse BEFORE creating anything: a snapshot that exists but omits part
# of the tree is worse than none, because every gate would accept it.
[[ -z "$(find "$TMP_DIR/snapshots" -maxdepth 1 -name 'immich-*-nestedtag' 2>/dev/null)" ]] \
  || fail "a misleading snapshot was created before the refusal"

# The fleet-wide helper must count it as a FAILURE, not a skip. A skip would let
# the aggregate gate pass on some other service's snapshot.
out="$(nested_probe "snapshot_subvolumes() { printf '%s\n' '$TMP_DIR/data/immich'; }
snapshot_create nested && echo RC=0 || echo RC=1")"
grep -q 'RC=1' <<< "$out" || fail "snapshot_create succeeded despite a nested subvolume: $out"
grep -q '1 failed' <<< "$out" || fail "a nested subvolume was counted as a skip, not a failure: $out"

# ---------------------------------------------------------------------------
# snapshot_subvolumes must resolve through service_data_path, not hardcode paths.
#
# service_data_path honours JELLYFIN_CONFIG_DIR, PLEX_CONFIG_DIR,
# NAVIDROME_DATA_DIR, CALIBRE_WEB_CONFIG_DIR and KAVITA_CONFIG_DIR. The
# migration, create_service_snapshot and the report all go through it; this
# function used "$DOMUM_DATA_ROOT/<name>" literals, so with any of those set
# elsewhere it operated on a path that does not exist -- silently skipped --
# while the report said protected and per-service snapshots worked.
# ---------------------------------------------------------------------------
if grep -nE 'candidates\+=\("\$DOMUM_DATA_ROOT/' "$REPO_ROOT/bin/domum-media"; then
  fail "snapshot_subvolumes still hardcodes service paths instead of using service_data_path"
fi

mkdir -p "$TMP_DIR/elsewhere/jellyfin-custom/config" "$TMP_DIR/data/plex"
out="$(bash -c "
set -uo pipefail
DOMUM_DIR='$REPO_ROOT'
CFG_FILE='$TMP_DIR/absent.conf'
source '$REPO_ROOT/bin/domum-media'
DOMUM_DATA_ROOT='$TMP_DIR/data'
JELLYFIN_CONFIG_DIR='$TMP_DIR/elsewhere/jellyfin-custom/config'
snapshot_subvolumes" 2>/dev/null)"
grep -q 'elsewhere/jellyfin-custom$' <<< "$out" \
  || fail "snapshot_subvolumes ignored JELLYFIN_CONFIG_DIR; it would snapshot a path that does not exist: $out"
grep -q "$TMP_DIR/data/plex" <<< "$out" \
  || fail "snapshot_subvolumes lost a default-located service: $out"

# ---------------------------------------------------------------------------
# 7. service_snapshot_possible AGREES WITH create_service_snapshot.
#
#    It mirrors the creator's three conditions rather than sharing them,
#    because the creator's refusal messages are detailed, operator-facing and
#    asserted by nine suites. The agreement is therefore enforced here: the
#    predicate must succeed exactly when the creator returns a name. If this
#    fails, the predicate is wrong -- not the test.
# ---------------------------------------------------------------------------
agree() {  # $1 = stubs describing the fixture
  bash -c "$(harness)
die() { echo \"DIE: \$*\"; exit 9; }
record_service_snapshot_metadata() { :; }
record_rollback_entry() { :; }
btrfs() { mkdir -p \"\${!#}\"; return 0; }
$1
poss=0; service_snapshot_possible immich >/dev/null 2>&1 || poss=1
name=\"\$(create_service_snapshot immich tag 2>/dev/null || true)\"
made=1; [ -n \"\$name\" ] && made=0
printf '%s %s\n' \"\$poss\" \"\$made\"
" 2>/dev/null
}
check_agree() {  # $1 = label, $2 = stubs, $3 = expected (0 possible / 1 not)
  local got; got="$(agree "$2")"
  local poss="${got%% *}" made="${got##* }"
  [ "$poss" = "$made" ] \
    || fail "7: $1 -- the predicate says possible=$poss while the creator made=$made;
they must agree or a preflight will refuse what would have worked, or permit
what cannot"
  [ "$poss" = "$3" ] || fail "7: $1 -- expected possible=$3, got $poss"
}
check_agree "an ordinary directory" 'is_btrfs_subvol() { return 1; }' 1
check_agree "the path does not exist" "service_data_path() { echo '$TMP_DIR/data/absent'; }
is_btrfs_subvol() { return 0; }
subvolume_nested_children() { printf ''; }" 1
check_agree "nested subvolumes" "is_btrfs_subvol() { return 0; }
subvolume_nested_children() { printf '%s' '$TMP_DIR/data/immich/n'; }" 1
check_agree "no data path configured" 'service_data_path() { return 1; }
is_btrfs_subvol() { return 0; }
subvolume_nested_children() { printf ""; }' 1
check_agree "a clean subvolume" "is_btrfs_subvol() { return 0; }
subvolume_nested_children() { printf ''; }" 0
# The reason has to name the cause, or the refusal below is unactionable.
why="$(bash -c "$(harness)
service_snapshot_possible immich || true" 2>/dev/null)"
grep -qi 'not a Btrfs subvolume' <<< "$why" \
  || fail "7: the reason does not name the cause: $why"
echo "  7: the predicate and the creator agree on all five fixtures"

# ---------------------------------------------------------------------------
# 8. `immich reset-db` MUST NOT STOP ANYTHING IT THEN REFUSES TO RESET.
#
#    The snapshot gate fires after `compose stop` AND `compose rm -f`, and that
#    ordering is deliberate -- the database has to be quiesced before it is
#    snapshotted. The consequence was not. Measured on this host,
#    /srv/data/immich is inode 273 on st_dev 45, the same device as its parent,
#    so it is an ordinary directory and create_service_snapshot returns 1. The
#    command would therefore stop and REMOVE all four Immich containers and only
#    then refuse: Immich down, nothing reset -- and because `rm -f` removes the
#    containers, recovering needs `up -d`, which reconciles, so the remedy for
#    the downtime is itself an image-deployment vector.
#
#    A closed gate that still causes downtime is not a closed gate.
#
#    No `rm` is stubbed anywhere below, deliberately: every case here must
#    refuse long before the deletion, so reaching an `rm` at all would be the
#    failure.
# ---------------------------------------------------------------------------
reset_probe() {  # $1 = extra stubs
  bash -c "$(harness)
die() { echo \"DIE: \$*\"; exit 9; }
warn() { echo \"WARN: \$*\"; }
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
ENABLE_IMMICH=1
immich_postgres_data_dir() { printf '%s' \"\$TMP_DIR/data/immich/postgres\"; }
immich_db_password_fingerprint_file() { printf '%s' \"\$TMP_DIR/state/fp\"; }
immich_library_data_dir() { printf '%s' \"\$TMP_DIR/data/immich/library\"; }
compose_cmd() { echo \"COMPOSE \$*\"; }
snapshot_policy() { printf '%s' \"\${SNAPSHOT_POLICY:-STRICT}\"; }
$1
immich_reset_db < /dev/null
" 2>&1
}
out="$(reset_probe '')"
grep -qi 'Cannot snapshot Immich state' <<< "$out" \
  || fail "8: it did not refuse on a host where no snapshot is possible: $out"
grep -q 'COMPOSE' <<< "$out" \
  && fail "8: it stopped or removed containers for an operation it then refused: $out"
grep -q 'wipe immich' <<< "$out" \
  && fail "8: it asked the operator to type the confirmation for an operation
that cannot proceed: $out"
grep -qi 'not a Btrfs subvolume' <<< "$out" \
  || fail "8: the refusal does not name why no snapshot is possible: $out"

# SNAPSHOT_POLICY=WARN is the documented override and must still work -- and the
# warning must come BEFORE the confirmation, so the operator knows there will be
# no rollback point before they type it.
out="$(reset_probe 'SNAPSHOT_POLICY=WARN')"
grep -qi 'NO rollback point' <<< "$out" \
  || fail "8: WARN did not produce the documented override warning: $out"
grep -q 'wipe immich' <<< "$out" \
  || fail "8: under WARN it must go on to ask for the confirmation: $out"
warn_at="$(grep -n 'NO rollback point' <<< "$out" | head -1 | cut -d: -f1)"
ask_at="$(grep -n 'wipe immich' <<< "$out" | head -1 | cut -d: -f1)"
[ "$warn_at" -lt "$ask_at" ] \
  || fail "8: the operator is asked to confirm before being told there is no
rollback point (warning at $warn_at, prompt at $ask_at)"

# The recovery half must be reachable BEFORE the destructive half runs: an exec
# that fails after the rm -rf leaves the database deleted and nothing reapplied.
printf 'not executable\n' > "$TMP_DIR/noexec"
out="$(reset_probe "is_btrfs_subvol() { return 0; }
subvolume_nested_children() { printf ''; }
DOMUM_SELF_CLI=\"\$TMP_DIR/noexec\"")"
grep -qi 'could not be reapplied after the wipe' <<< "$out" \
  || fail "8: it did not refuse an unreachable recovery copy: $out"
grep -q 'COMPOSE' <<< "$out" \
  && fail "8: it stopped containers before checking the recovery copy: $out"
echo "  8: reset-db refuses before the confirmation, the stop, and the wipe"

# ---------------------------------------------------------------------------
# 9. THE CLI EXECS THE COPY THAT IS RUNNING, not whatever is installed.
#
#    repo_update's exec of the installed path is CORRECT and deliberately
#    unchanged: converge_local_installation runs immediately before it, so it
#    really is handing off to its freshly installed replacement -- the same
#    pattern as the deployment script re-executing itself. The other two sites
#    had no install step, so the halves could be different revisions.
# ---------------------------------------------------------------------------
printf '#!/bin/sh\necho "MARKER-BACKUP-CLI $*"\n' > "$TMP_DIR/fake-backup"
chmod +x "$TMP_DIR/fake-backup"
# The observable is the process being REPLACED: the line after the exec must not
# run. A source assertion could not tell that from a function that never execs.
out="$(bash -c "$(harness)
need_root() { :; }
DOMUM_BACKUP_CLI=\"\$TMP_DIR/fake-backup\"
main backup verify cloud
echo 'NOT-REPLACED'
" 2>&1)"
grep -q 'MARKER-BACKUP-CLI verify cloud' <<< "$out" \
  || fail "9: the backup arm did not exec the resolved CLI with its arguments: $out"
grep -q 'NOT-REPLACED' <<< "$out" \
  && fail "9: exec did not replace the process: $out"

out="$(bash -c "$(harness)
echo \"override=\$(DOMUM_SELF_CLI=/x/y self_cli_path)\"
echo \"default=\$(self_cli_path)\"
" 2>&1)"
grep -qx 'override=/x/y' <<< "$out" \
  || fail "9: self_cli_path does not honour the fixture override: $out"
grep -q "default=.*bin/domum-media\$" <<< "$out" \
  || fail "9: self_cli_path does not resolve to the running file: $out"

# repo_update is the ONE site that should still name the installed path, and the
# reason is in its comment. Asserted on the stripped source, because a comment
# mentioning the path is not a use of it.
src="$(sed 's/#.*//' "$REPO_ROOT/bin/domum-media")"
ru="$(awk '/^repo_update\(\) \{/,/^\}/' <<< "$src")"
grep -q 'exec /usr/local/bin/domum-media apply' <<< "$ru" \
  || fail "9: repo_update no longer execs its freshly installed replacement,
which is the one place that is correct"
grep -q 'converge_local_installation' <<< "$ru" \
  || fail "9: repo_update execs the installed path without installing first"
others="$(grep -c 'exec /usr/local/bin/domum-media' <<< "$src" || true)"
[ "$others" = "1" ] \
  || fail "9: expected exactly one deliberate exec of an installed path
(repo_update's), found $others"
echo "  9: the running copy is exec'd, except where a replacement was just installed"

# ---------------------------------------------------------------------------
# 10. MUTATIONS, against a COPY so a stopped run leaves nothing behind.
# ---------------------------------------------------------------------------
cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/mut-cli"
cat > "$TMP_DIR/mut10.py" <<'PY'
import io, sys
p, which = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8").read()
if which == "preflight":
    old = '  local snap_why\n  if ! snap_why="$(service_snapshot_possible immich)"; then'
    new = '  local snap_why\n  if ! snap_why="$(service_snapshot_possible immich)" && false; then'
elif which == "predicate":
    # Drop the predicate's subvolume check. The creator still has its own, so
    # the two DISAGREE -- which is the only thing making "mirror rather than
    # share" defensible.
    old = ('  if ! is_btrfs_subvol "$data_path"; then\n'
           "    printf '%s is an ordinary directory, not a Btrfs subvolume, so no per-service snapshot can be taken of it' \"$data_path\"\n"
           '    return 1\n  fi\n')
    new = ''
elif which == "selfexec":
    old = '  exec "$self_cli" apply\n'
    new = '  exec /usr/local/bin/domum-media apply\n'
else:
    raise SystemExit("unknown mutation")
assert s.count(old) == 1, "anchor %s matched %d times" % (which, s.count(old))
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
print("applied")
PY
python3 -I "$TMP_DIR/mut10.py" "$TMP_DIR/mut-cli" preflight >/dev/null \
  || fail "10: the preflight mutation did not apply"
out="$(bash -c "set -uo pipefail
DOMUM_DIR=\"$REPO_ROOT\"
CFG_FILE=\"$TMP_DIR/absent.conf\"
source \"$TMP_DIR/mut-cli\"
DOMUM_DATA_ROOT=\"$TMP_DIR/data\"
DOMUM_SNAPSHOT_ROOT=\"$TMP_DIR/snapshots\"
DOMUM_STATE_ROOT=\"$TMP_DIR/state\"
is_btrfs_subvol() { return 1; }
service_data_path() { echo \"$TMP_DIR/data/\$1\"; }
die() { echo \"DIE: \$*\"; exit 9; }
warn() { echo \"WARN: \$*\"; }
need_root() { :; }
load_cfg() { :; }
export_env_for_compose() { :; }
ENABLE_IMMICH=1
immich_postgres_data_dir() { printf '%s' \"$TMP_DIR/data/immich/postgres\"; }
immich_db_password_fingerprint_file() { printf '%s' \"$TMP_DIR/state/fp\"; }
immich_library_data_dir() { printf '%s' \"$TMP_DIR/data/immich/library\"; }
compose_cmd() { echo \"COMPOSE \$*\"; }
snapshot_policy() { printf '%s' STRICT; }
immich_reset_db < /dev/null" 2>&1)"
grep -q 'wipe immich' <<< "$out" \
  || fail "10: the mutation applied but the preflight still refused, so section 8
would pass without it: $out"
echo " 10: without the preflight the operator is asked to confirm an impossible reset"

# The agreement in section 7 must be able to DETECT a disagreement, or
# "mirror rather than share" is just a comment. Driven against the real suite's
# own predicate, in the fixture where the two would part company.
cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/mut-cli"
python3 -I "$TMP_DIR/mut10.py" "$TMP_DIR/mut-cli" predicate >/dev/null \
  || fail "10: the predicate mutation did not apply"
poss=0
bash -c "set -uo pipefail
DOMUM_DIR=\"$REPO_ROOT\"
CFG_FILE=\"$TMP_DIR/absent.conf\"
source \"$TMP_DIR/mut-cli\"
DOMUM_DATA_ROOT=\"$TMP_DIR/data\"
DOMUM_SNAPSHOT_ROOT=\"$TMP_DIR/snapshots\"
DOMUM_STATE_ROOT=\"$TMP_DIR/state\"
is_btrfs_subvol() { return 1; }
service_data_path() { echo \"$TMP_DIR/data/\$1\"; }
service_snapshot_possible immich >/dev/null 2>&1" || poss=1
[ "$poss" = "0" ] \
  || fail "10: the mutation applied but the predicate still refused an ordinary
directory, so section 7 would agree for the wrong reason"
echo " 10: a predicate that stops matching the creator is detected"

cp "$REPO_ROOT/bin/domum-media" "$TMP_DIR/mut-cli"
python3 -I "$TMP_DIR/mut10.py" "$TMP_DIR/mut-cli" selfexec >/dev/null \
  || fail "10: the self-exec mutation did not apply"
src_mut="$(sed 's/#.*//' "$TMP_DIR/mut-cli")"
[ "$(grep -c 'exec /usr/local/bin/domum-media apply' <<< "$src_mut" || true)" = "2" ] \
  || fail "10: the mutation did not reintroduce a second installed-path exec"
echo " 10: reintroducing the hardcoded installed exec is detectable"

echo "PASS: snapshot safety gate smoke test"
