#!/usr/bin/env bash
set -uo pipefail

# A shell function that RETURNS a value does so on stdout. Anything else it
# writes there silently becomes part of that value.
#
# create_service_snapshot shipped with exactly this defect: a progress line on
# stdout meant every caller captured it as part of the snapshot name, and the
# auto-rollback after a failed health check would then fail to find the
# snapshot. It was unreachable only because no service path was a subvolume yet.
#
# This scans every function whose output is captured with $(...) and fails if it
# writes a human-readable line to stdout without redirecting to stderr.

fail() { echo "FAIL: $*" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

out="$(python3 "$REPO_ROOT/tests/lib-stdout-purity-audit.py" "$REPO_ROOT" 2>&1)"
rc=$?
printf '%s\n' "$out"
(( rc == 0 )) \
  || fail "a captured function writes a human-readable line to stdout; it would contaminate the caller's captured value"
grep -q 'captured with' <<< "$out" \
  || fail "the audit reported nothing; it is not actually scanning"

echo "PASS: captured stdout purity smoke test"
