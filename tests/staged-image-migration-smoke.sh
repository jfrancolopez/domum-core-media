#!/usr/bin/env bash
set -uo pipefail

# A storage migration must not UPGRADE the application as a side effect. For a
# long the control was: refuse if a newer image is merely STAGED. Its own text
# said "restarting it would DEPLOY that image", which was true when the migration
# restarted with `up -d` and is NOT true of `compose start`.
#
# Measured on this host, disposable compose project, no pull/retag/prune:
#   container created on image A -> stopped -> compose file repointed at B
#   `compose start` -> still A        `up -d` -> recreated on B
#
# So the prediction-based refusal deadlocked the project: plex could not be
# UPGRADED (state unprotected) and could not be MIGRATED to gain protection
# (an upgrade was staged). Each gate was right; together they were a trap.
#
# The control is now verification rather than prediction:
#   STAGED  -> reported, does NOT refuse
#   UNKNOWN -> still refuses BEFORE the stop (identity must be knowable)
#   an image that actually changed across the restart -> HARD failure
#
# This suite pins all three, so neither half can be loosened alone.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"

# ---------------------------------------------------------------------------
echo "== 1. the restart path resolves no image reference =="
# The whole narrowing rests on this. Assert the mechanism, not the comment.
mr="$(awk '/^  migrate_restart\(\) \{/,/^  \}/' "$CLI")"
[ -n "$mr" ] || fail "could not isolate migrate_restart"
grep -q 'compose_cmd start' <<< "$mr" || fail "migrate_restart no longer uses 'compose start'"
grep -qE 'compose_cmd up -d|compose up -d' <<< "$(grep -v '^ *#' <<< "$mr" | grep -v '^ *warn ')" \
  && fail "migrate_restart has an executable 'up -d'; a staged image could then be deployed
and the narrowed preflight would be unsafe"
echo "  migrate_restart: 'compose start' only, no executable 'up -d'"

# ---------------------------------------------------------------------------
echo "== 2. a merely STAGED image no longer refuses =="
mig="$(awk '/^storage_migrate_subvolume\(\) \{/,/^\}/' "$CLI")"
[ -n "$mig" ] || fail "could not isolate storage_migrate_subvolume"
# The staged branch must not die.
staged_branch="$(awk '/elif \[\[ -n "\$staged_images" \]\]; then/,/else/' <<< "$mig")"
[ -n "$staged_branch" ] || fail "the staged-image branch is gone"
grep -q '^ *die ' <<< "$staged_branch" \
  && fail "the staged-image branch still refuses. compose start cannot deploy a staged
image, and refusing here is what deadlocked plex:
$staged_branch"
grep -q 'STAGED' <<< "$staged_branch" || fail "the staged branch no longer reports what is staged"
echo "  staged -> reported, not refused"

# ---------------------------------------------------------------------------
echo "== 3. UNKNOWN identity still refuses, before the stop =="
unknown_branch="$(awk '/# "I could not tell" must never read as/,/^    fi/' <<< "$mig")"
[ -n "$unknown_branch" ] || fail "the UNKNOWN branch is gone"
grep -q '^ *die ' <<< "$unknown_branch" \
  || fail "UNKNOWN identity no longer refuses. A recovery point whose application is
unknown cannot be paired, so this must still stop before anything is touched."
echo "  unknown -> still refuses"
# And it must refuse BEFORE the stop: the refusal has to precede the stop stage.
u_line="$(grep -n 'cannot determine whether restarting' <<< "$mig" | head -1 | cut -d: -f1)"
s_line="$(grep -n 'migrate_stage stop "stopping' <<< "$mig" | head -1 | cut -d: -f1)"
[ -n "$u_line" ] && [ -n "$s_line" ] || fail "could not locate the refusal and the stop"
[ "$u_line" -lt "$s_line" ] \
  || fail "the UNKNOWN refusal (line $u_line) comes AFTER the stop (line $s_line)"
echo "  and it precedes the stop (relative lines $u_line < $s_line)"

# ---------------------------------------------------------------------------
echo "== 4. an image that ACTUALLY changed is a HARD failure =="
# This is what replaces the removed refusal. If it is only a warning, the
# narrowing has no backstop at all.
grep -q 'image_changed=1' <<< "$mig" \
  || fail "nothing records that the image changed; stage 8 is advisory again"
grep -qE 'if \(\( image_changed == 1 \)\); then' <<< "$mig" \
  || fail "the summary does not act on image_changed"
after="$(awk '/if \(\( image_changed == 1 \)\); then/,/fi/' <<< "$mig")"
grep -q 'complete=0' <<< "$after" \
  || fail "an image change does not make the migration INCOMPLETE:
$after"
echo "  image change -> complete=0, reported as UPGRADED"

# ---------------------------------------------------------------------------
echo "== 5. the deliberate override still exists, and is opt-in =="
# EVERY test of it must be the exact-value form. Checking only that one is
# left the post-restart check free to accept any non-empty value -- measured:
# that mutant survived until this counted both sides.
tests_total="$(grep -c 'MIGRATE_ALLOW_IMAGE_CHANGE:-' <<< "$mig")"
tests_exact="$(grep -c 'MIGRATE_ALLOW_IMAGE_CHANGE:-0}" == "1"' <<< "$mig")"
[ "$tests_total" -ge 2 ] \
  || fail "expected the override tested in both the preflight and the post-restart check, found $tests_total"
[ "$tests_exact" = "$tests_total" ] \
  || fail "$tests_total test(s) of MIGRATE_ALLOW_IMAGE_CHANGE but only $tests_exact use the exact-value
form. A -n or != test would let any non-empty value enable it."
echo "  opt-in on the exact value 1, in all $tests_total test(s)"

# ---------------------------------------------------------------------------
echo "== 6. the verdict producer still distinguishes all three =="
prod="$(awk '/^service_staged_image_changes\(\) \{/,/^\}/' "$CLI")"
for v in "ABSENT" "UNKNOWN" "STAGED"; do
  grep -q "printf '$v" <<< "$prod" || fail "service_staged_image_changes no longer emits $v"
done
# `compose ps -q` lists RUNNING containers only and conflates stopped with
# absent, which is how a staged image on a stopped container went unseen. Assert
# the helper is used AND that no bare `ps -q` crept back in -- checking only for
# the symbol let the mutant through, because it still appeared in a comment.
# -F, not a regex: GNU grep reads the `$` in `$(` as an anchor, so the BRE form
# of this pattern matched NOTHING -- including the correct code -- and the check
# silently never fired. Measured: grep -F finds 7 occurrences, plain grep finds 0.
grep -qF 'cid="$(tracked_service_container_id_any' <<< "$prod" \
  || fail "the producer no longer resolves containers via tracked_service_container_id_any,
so a STOPPED container's image identity may be missed"
grep -qE 'compose_cmd ps -q[^a]' <<< "$prod" \
  && fail "the producer uses 'compose ps -q', which lists running containers only and
conflates stopped with absent"
echo "  ABSENT / UNKNOWN / STAGED all still produced, stopped containers inspected"

# ---------------------------------------------------------------------------
echo "== 7. the reconcile boundary is unchanged by this =="
# Narrowing a preflight must not have introduced a reconcile into a preserving
# function. The dedicated audit owns the rule; assert it is still wired.
grep -q 'reconcile-boundary-audit.py' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "reconcile-boundary-audit.py is not in the CI workflow"
grep -q 'staged-image-migration-smoke.sh' "$REPO_ROOT/.github/workflows/compose-validate.yml" \
  || fail "this suite is not wired into CI, so it proves nothing about main"
echo "  reconcile audit and this suite both wired into CI"

echo "PASS: staged image migration smoke test"
