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

# The audit strips comments before deciding what is captured, because a comment
# explaining why a function must NOT be captured contains the text `$(name)`.
# Stripping too much would blind it, so both directions are asserted here: the
# real tree is clean, and a genuine capture of a value-returning function is
# still caught.
MUT_DIR="$(mktemp -d)"
trap 'rm -rf -- "$MUT_DIR"' EXIT
mkdir -p "$MUT_DIR/bin"
cp "$REPO_ROOT/bin/domum-media-backup" "$REPO_ROOT/bin/domum-media-report" "$MUT_DIR/bin/"
# Introduce a REAL capture of a function whose stdout is its value.
awk '
  /^  health_summary_text > "\$body"$/ {
    print "  leaked=\"$(health_summary_text)\""
  }
  { print }
' "$REPO_ROOT/bin/domum-media" > "$MUT_DIR/bin/domum-media"
grep -q 'leaked="\$(health_summary_text)"' "$MUT_DIR/bin/domum-media" \
  || fail "the capture mutation was not applied; this assertion proves nothing"
if python3 "$REPO_ROOT/tests/lib-stdout-purity-audit.py" "$MUT_DIR" >/dev/null 2>&1; then
  fail "a real capture of a value-returning function was NOT caught -- the
comment stripping has blinded the audit"
fi
echo "  comments ignored, but a real capture is still caught"

echo "PASS: captured stdout purity smoke test"
