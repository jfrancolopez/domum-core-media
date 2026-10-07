#!/usr/bin/env bash
set -uo pipefail

# One service upgraded, proven to be one; and a rollback that restores BOTH
# halves or refuses.
#
# WHY NOT refresh_images. It cannot take a service argument -- it dies on any
# positional -- and its scope is every service with ENABLE_*=1 and
# *_AUTO_UPDATE=1, pulling each. With staged images for plex, calibre-web,
# traefik and uptime-kuma, using it for a plex upgrade risks a four-service
# deployment. It also snapshots while the service RUNS and writes no recovery
# metadata, so its rollback point is crash-consistent and unpaired.
#
# TASK-24. The pre-existing auto-rollback restores the snapshot and brings the
# service back with `compose start` -- onto the container the upgrade created,
# i.e. the NEW image. Old data under a newer application is the pairing failure
# the recovery evidence exists to prevent.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"

up="$(awk '/^service_upgrade\(\) \{/,/^\}/' "$CLI")"
rb="$(awk '/^rollback_upgrade\(\) \{/,/^\}/' "$CLI")"
[ -n "$up" ] || fail "could not isolate service_upgrade"
[ -n "$rb" ] || fail "could not isolate rollback_upgrade"
line_in() { grep -n "$2" <<< "$1" | head -1 | cut -d: -f1; }

echo "== 1. --service is a different operation, not a filter on the fleet path =="
disp="$(awk '/^updates_cmd\(\) \{/,/^\}/' "$CLI")"
grep -q 'service_upgrade "\$1"' <<< "$disp" \
  || fail "updates apply --service does not route to service_upgrade"
grep -q 'refresh_images --apply-now --force' <<< "$disp" \
  || fail "bare `updates apply` no longer reaches the fleet path; that is a separate change"
# The fleet path must NOT be reachable when --service was given.
svc_branch="$(awk '/if \[\[ "\$\{1:-\}" == "--service" \]\]; then/,/else/' <<< "$disp")"
grep -q 'refresh_images' <<< "$svc_branch" \
  && fail "the --service branch can still reach refresh_images, so a scoped request
could widen to the whole fleet:
$svc_branch"
echo "  --service -> service_upgrade; fleet path unreachable from that branch"

echo "== 2. an unknown service FAILS CLOSED, it does not widen =="
grep -q "managed_image_specs | cut -d'|' -f1 | grep -qxF \"\$service\"" <<< "$up" \
  || fail "service_upgrade does not validate the name against managed_image_specs"
val_block="$(awk "/managed_image_specs \| cut -d'\\|' -f1 \| grep -qxF/,/^  assert_pre_upgrade_possible/" <<< "$up")"
grep -q 'die ' <<< "$val_block" \
  || fail "an unknown service name does not abort. A typo must never fall back to
fleet-wide operation:
$val_block"
grep -q 'grep -qxF' <<< "$up" \
  || fail "the name check is not an exact whole-line match, so a substring like
'plex' could match another service's key"
echo "  unknown name dies; exact whole-line match"

echo "== 3. the scope proof is captured BEFORE and compared AFTER =="
grep -q 'other_container_identities' <<< "$up" || fail "no scope capture at all"
n="$(grep -c 'other_container_identities' <<< "$up")"
[ "$n" -ge 2 ] || fail "other_container_identities is called $n time(s); it must be
captured before the deploy and again after, or nothing is proven"
oc="$(awk '/^other_container_identities\(\) \{/,/^\}/' "$CLI")"
grep -q '{{.Id}}' <<< "$oc" || fail "the scope capture does not record container IDs"
grep -q '{{.Image}}' <<< "$oc" || fail "the scope capture does not record image IDs"
grep -q 'ps -a ' <<< "$oc" \
  || fail "the capture must use 'ps -a': a stopped container that gets recreated
would otherwise be invisible"
grep -q 'others_before" == "\$others_after' <<< "$up" \
  || fail "the before/after capture is never compared"
l_before="$(line_in "$up" 'others_before="\$(other_container_identities')"
l_deploy="$(line_in "$up" 'compose_cmd up -d \$compose_svcs')"
l_after="$(line_in "$up" 'others_after="\$(other_container_identities')"
[ "$l_before" -lt "$l_deploy" ] || fail "the scope baseline is taken after the deploy ($l_before vs $l_deploy)"
[ "$l_after" -gt "$l_deploy" ] || fail "the scope comparison happens before the deploy ($l_after vs $l_deploy)"
echo "  captured($l_before) < deploy($l_deploy) < compared($l_after); ids and images, ps -a"

echo "== 4. pre-upgrade protection cannot be skipped, and precedes the deploy =="
grep -q 'create_upgrade_rollback_point' <<< "$up" \
  || fail "service_upgrade does not create a pre-upgrade point"
shim="$(awk '/^create_upgrade_rollback_point\(\) \{/,/^\}/' "$CLI")"
grep -q -- '--archive-image' <<< "$shim" \
  || fail "the upgrade path can create an UNARCHIVED point; the archive is the half
that makes it a rollback rather than a museum piece"
l_point="$(line_in "$up" 'create_upgrade_rollback_point')"
l_verify="$(line_in "$up" 'storage_verify_archive "\$point"')"
[ "$l_point" -lt "$l_verify" ] || fail "the archive is verified before it is created"
[ "$l_verify" -lt "$l_deploy" ] || fail "the archive is verified AFTER the deploy ($l_verify vs $l_deploy)"
# And each must abort rather than warn.
pb="$(awk '/if ! create_upgrade_rollback_point/,/^  fi$/' <<< "$up")"
grep -q 'die ' <<< "$pb" || fail "a failed pre-upgrade point does not abort the upgrade:
$pb"
grep -q 'was NOT deployed' <<< "$up" \
  || fail "the refusal does not state that the staged image was not deployed"
echo "  point($l_point) < verify($l_verify) < deploy($l_deploy); both abort on failure"

echo "== 5. the deployed image comes from the LOCAL staged object, not a pull =="
grep -q 'service_staged_image_changes' <<< "$up" \
  || fail "the target image is not read from the staged-image verdicts"
grep -qE 'compose_cmd pull|docker pull' <<< "$(grep -v '^ *#' <<< "$up")" \
  && fail "service_upgrade pulls. That resolves a mutable tag at upgrade time, so
what runs need not be what was reviewed."
grep -q 'no staged image locally' <<< "$up" \
  || fail "it does not handle the case where nothing is staged"
echo "  target from local staged verdicts; no pull"

echo "== 6. the cleanup proof runs as a DRY RUN, never with --confirm =="
grep -q 'cleanup_images_execute 1 0' <<< "$up" \
  || fail "the post-upgrade cleanup proof is missing or not a dry run"
# Only an actual INVOCATION counts. The first version of this also matched the
# comment and the echo that say "no --confirm", so it failed on correct code.
up_exec="$(grep -v '^ *#' <<< "$up" | grep -v '^ *echo ' | grep -v '^ *warn ')"
grep -qE 'cleanup_images_execute +[^1]' <<< "$up_exec" \
  && fail "cleanup is invoked with something other than dry-run=1"
grep -qE 'cleanup_images_execute +1 +[^0]' <<< "$up_exec" \
  && fail "cleanup is invoked with confirm != 0"
grep -qE -- '--confirm' <<< "$up_exec" \
  && fail "service_upgrade passes --confirm somewhere executable"
grep -q 'withheld from cleanup' <<< "$up" \
  || fail "it does not assert that the old image was withheld"
# The CHECK must read the value-returning selector, not grep the human report.
# Capturing cleanup_images_execute made the log the value, which the stdout
# purity audit caught.
grep -q 'collect_cleanup_image_ids' <<< "$up" \
  || fail "the withheld check does not use the value-returning selector"
grep -q 'cleanup_out="\$(cleanup_images_execute' <<< "$up" \
  && fail "cleanup_images_execute is captured; it writes a human report, so its
log would become the value"
echo "  cleanup_images_execute 1 0 only; asserts the old image is withheld"

echo "== 7. ROLLBACK refuses when the application half is unknown =="
grep -q "CONTAINER_1_IMAGE_ID" <<< "$rb" || fail "the rollback does not read the recorded image id"
ub="$(awk '/\[\[ -n "\$want_img" \]\]/,/^$/' <<< "$rb")"
grep -q 'die ' <<< "$ub" \
  || fail "a point with no recorded image identity does not refuse. Restoring the data
under whatever is running now is the pairing failure:
$ub"
echo "  no recorded identity -> refuses"

echo "== 8. ROLLBACK verifies the archive BEFORE loading it =="
l_sha="$(line_in "$rb" 'got_sha="\$(sha256sum')"
l_load="$(line_in "$rb" 'docker load -i "\$arch"')"
[ -n "$l_sha" ] && [ -n "$l_load" ] || fail "could not locate the checksum and the load"
[ "$l_sha" -lt "$l_load" ] || fail "the archive is loaded before its checksum is checked ($l_load vs $l_sha)"
shab="$(awk '/\[\[ "\$got_sha" == "\$want_sha" \]\]/,/^$/' <<< "$rb")"
grep -q 'die ' <<< "$shab" || fail "a checksum mismatch does not refuse to load:
$shab"
echo "  checksum($l_sha) < load($l_load); mismatch refuses"

echo "== 9. ROLLBACK compares the LOADED id to the recorded id =="
grep -q 'Loaded image ID' <<< "$rb" \
  || fail "the rollback does not read back what docker load actually restored"
lb="$(awk '/\[\[ "\$loaded" == "\$want_img" \]\]/,/^$/' <<< "$rb")"
grep -q 'die ' <<< "$lb" \
  || fail "a load that restores a DIFFERENT image does not abort. The checksum proves
the file; only this comparison proves the identity:
$lb"
echo "  loaded id compared to the record; mismatch aborts"

echo "== 10. ROLLBACK pins the image and never resolves a mutable tag =="
# The variable name is indirect ("$image_var"), so assert the MECHANISM, not a
# literal. And assert it is an export, not `env VAR=... compose_cmd`: compose_cmd
# is a shell function and env can only exec a binary -- measured, `env X=1 f`
# gives "env: 'f': No such file or directory", so that form fails every time. A
# grep for the text alone passed while the code could not run.
grep -qE 'export "\$image_var=\$want_img"' <<< "$rb" \
  || fail "the rollback does not EXPORT <SERVICE>_IMAGE pinned to the recorded id,
so compose would resolve the mutable tag and could start the image being rolled
back FROM"
grep -qE '\benv "\$image_var=' <<< "$rb" \
  && fail "the pin uses 'env VAR=... compose_cmd'. compose_cmd is a shell function
and env can only exec a binary, so this cannot work."
grep -q 'uppercase_token' <<< "$rb" || fail "the pinned variable name is not derived from the service"
# The export must be scoped, or it silently changes later compose calls.
grep -qE '\( *export "\$image_var=' <<< "$rb" \
  || fail "the pin is not confined to a subshell, so it would leak into any later
compose invocation in this function"
grep -q 'compose_cmd start' <<< "$rb" \
  && fail "the rollback uses 'compose start'. The container that exists belongs to
the image being rolled back FROM, so starting it would restart the failed
application on restored data -- task-24's exact defect."
echo "  pins <SERVICE>_IMAGE; deliberately recreates instead of start"

echo "== 11. ROLLBACK preserves the failed state and deletes nothing =="
grep -q 'failed-\$(date' <<< "$rb" || fail "the failed state is not preserved under a timestamped name"
grep -qE '^\s*rm -rf|^\s*btrfs subvolume delete' <<< "$rb" \
  && fail "the rollback deletes something; the failed state must be retained for investigation"
grep -q 'retained deliberately' <<< "$rb" || fail "it does not tell the operator the failed state was kept"
# And a failure mid-restore must put the previous state back.
grep -q 'mv -- "\$failed" "\$path"' <<< "$rb" \
  || fail "if the restore fails, the preserved state is never put back"
echo "  failed state kept under .failed-<timestamp>; nothing deleted; restore failure reverts"

echo "== 12. both new paths are classified at the reconcile boundary =="
aud="$REPO_ROOT/tests/reconcile-boundary-audit.py"
grep -q '"service_upgrade"' "$aud" || fail "service_upgrade is not classified"
grep -q '"rollback_upgrade"' "$aud" || fail "rollback_upgrade is not classified"
grep -q 'reconcile-boundary-audit.py' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "the reconcile audit is not wired into CI"
grep -q 'service-upgrade-smoke.sh' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "this suite is not wired into CI, so it proves nothing about main"
echo "  both classified; audit and this suite wired into CI"

echo "PASS: service upgrade smoke test"
