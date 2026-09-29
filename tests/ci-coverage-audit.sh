#!/usr/bin/env bash
set -uo pipefail

# Every test file must actually be run by CI.
#
# `.github/workflows/compose-validate.yml` enumerates each test by name -- there
# is no glob -- so a new suite is only enforced once somebody remembers to add a
# step. Seven did not get added: storage-topology, migration-recovery-point,
# two-migrated-services, image-identity-preservation, fail-closed-recovery, and
# both python audits. They passed locally and were reported as "CI green"; CI had
# never seen them.
#
# A suite that exists but is not run is worse than no suite, because it is counted
# as coverage. This is the check that makes forgetting impossible.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/compose-validate.yml"

[[ -r "$WORKFLOW" ]] || fail "cannot read $WORKFLOW"
workflow="$(cat "$WORKFLOW")"

missing=()
checked=0
while IFS= read -r f; do
  rel="${f#"$REPO_ROOT"/}"
  checked=$(( checked + 1 ))
  grep -qF -- "$rel" <<< "$workflow" || missing+=("$rel")
done < <(find "$REPO_ROOT/tests" -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' \) | sort)

if (( ${#missing[@]} > 0 )); then
  printf 'FAIL: %d test file(s) exist but are not run by CI:\n' "${#missing[@]}" >&2
  printf '  %s\n' "${missing[@]}" >&2
  printf '\nAdd a step to %s. A suite CI never runs is reported as coverage it is not.\n' \
    "${WORKFLOW#"$REPO_ROOT"/}" >&2
  exit 1
fi

# And the reverse: a step naming a test that no longer exists would pass silently
# in this direction, so check it too.
while IFS= read -r ref; do
  [[ -e "$REPO_ROOT/$ref" ]] || fail "CI runs $ref, which does not exist"
done < <(grep -oE 'tests/[A-Za-z0-9._/-]+\.(sh|py)' <<< "$workflow" | sort -u)

echo "PASS: ci coverage audit ($checked test files, all wired into CI)"
