#!/usr/bin/env bash
# Prove the conflict-marker audit catches the form that actually got through,
# and does not fire on ordinary Markdown.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/no-conflict-markers-audit.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

mk() {  # $1 = fixture dir; stdin = the file content
  local d="$1"
  mkdir -p "$d"
  git init -q -b main "$d"
  cat > "$d/NOTES.md"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@e -c user.name=t commit -qm one
}

sect "the live repository is clean"
out="$(python3 "$AUDIT" "$REPO_ROOT" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
(( rc == 0 )) || fail "a conflict marker is committed in this repository"
grep -q 'scanned' <<< "$out" || fail "the audit reported nothing; it is not scanning"

sect "the zdiff3 BASE marker is caught -- the one that reached main"
# `|||||||` is the section a two-way resolver misses entirely.
# The marker is COMPOSED rather than written literally at the start of a line:
# this file is itself a tracked text file, so a literal one would make the audit
# flag its own fixture. Composing it needs no exemption and keeps the audit at
# full strictness.
BASE_MARK="$(printf '%s' '|||' ; printf '%s' '||||')"
mk "$TMP/base" <<EOF
Some rule.
$BASE_MARK parent of abc1234 (a commit subject)
the common ancestor text
EOF
out="$(python3 "$AUDIT" "$TMP/base" 2>&1)"; rc=$?
(( rc == 1 )) || fail "the base marker was not caught: $out"
grep -q 'NOTES.md:2' <<< "$out" || fail "the offending line is not located: $out"
grep -q 'zdiff3' <<< "$out" || fail "the message does not explain the three sections: $out"
echo "  caught, located, and the cause explained"

sect "the ours and theirs markers are caught too"
for m in '<<<<<<< HEAD' '>>>>>>> abc1234'; do
  mk "$TMP/m" <<EOF
Some rule.
$m
EOF
  python3 "$AUDIT" "$TMP/m" >/dev/null 2>&1 \
    && fail "marker '$m' was not caught"
  rm -rf "$TMP/m"
done
echo "  <<<<<<< and >>>>>>> both caught"

sect "a setext heading underline is NOT a conflict marker"
# `=======` under a line is ordinary Markdown. Flagging it would fire on
# perfectly good documents, and an audit that cries wolf gets switched off.
mk "$TMP/setext" <<'EOF'
A Real Heading
==============

Body text.
EOF
out="$(python3 "$AUDIT" "$TMP/setext" 2>&1)"; rc=$?
(( rc == 0 )) || fail "a Markdown setext heading was flagged: $out"
echo "  ordinary Markdown passes"

sect "a marker INSIDE a line is not flagged"
# Only a marker at the start of a line is a conflict marker; prose quoting one
# mid-sentence is how a fix documents itself.
mk "$TMP/inline" <<'EOF'
The resolver missed the ||||||| base section entirely.
EOF
out="$(python3 "$AUDIT" "$TMP/inline" 2>&1)"; rc=$?
(( rc == 0 )) || fail "prose quoting a marker was flagged: $out"
echo "  only line-initial markers count"

sect "it cannot pass vacuously on an empty repository"
mkdir -p "$TMP/empty"; git init -q -b main "$TMP/empty"
out="$(python3 "$AUDIT" "$TMP/empty" 2>&1)"; rc=$?
(( rc == 1 )) || fail "an empty repository must not report a clean pass: $out"
grep -q 'vacuously' <<< "$out" || fail "it does not say why: $out"
echo "  zero files scanned is a failure, not a pass"

echo "PASS: no-conflict-markers smoke test"
