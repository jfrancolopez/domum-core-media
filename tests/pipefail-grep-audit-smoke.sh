#!/usr/bin/env bash
# Prove tests/pipefail-grep-audit.py actually rejects the banned pipeline, and
# does not reject the fix that replaces it.
#
# `cmd | grep -q` under pipefail reports 141 when grep exits at the first match,
# so a MATCH READS AS NO-MATCH. The audit is only worth having if it catches the
# real historical shapes, so each is driven through it as a fixture.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/pipefail-grep-audit.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# A fixture repository with only the file shapes the audit scans.
mk() {  # $1 = fixture dir, stdin = body of bin/domum-media
  local d="$1"
  mkdir -p "$d/bin" "$d/operator" "$d/tests"
  cat > "$d/bin/domum-media"
  : > "$d/bin/domum-media-backup"
  : > "$d/bin/domum-media-report"
  : > "$d/install.sh"
}

sect "the live repository is clean"
out="$(python3 "$AUDIT" "$REPO_ROOT" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
(( rc == 0 )) || fail "the repository still contains a banned pipeline"
grep -q 'scanned' <<< "$out" || fail "the audit reported nothing; it is not scanning"
echo "  no captured-match pipeline remains"

sect "the banned single-line form is REJECTED"
mk "$TMP/a" <<'EOF'
f() { docker ps --format '{{.Names}}' | grep -qxF "$1" && return 1; }
EOF
out="$(python3 "$AUDIT" "$TMP/a" 2>&1)"; rc=$?
(( rc == 1 )) || fail "the banned form was accepted: $out"
grep -q 'grep -qxF' <<< "$out" || fail "the audit did not name the offending line: $out"
echo "  caught, and the offending line is named"

sect "every quiet-flag spelling is caught, not just -q"
for flag in -q -qxF -Fxq -qiE -qFx; do
  mk "$TMP/b" <<EOF
f() { echo hi | grep $flag 'x'; }
EOF
  python3 "$AUDIT" "$TMP/b" >/dev/null 2>&1 \
    && fail "grep $flag was not recognised as a quiet grep"
done
echo "  -q -qxF -Fxq -qiE -qFx all recognised"

sect "a pipeline split with the PIPE LEADING the line is caught"
# Both real instances in this repository had this shape -- the PostgreSQL dump
# footer check, which decides whether a dump is a valid backup artifact.
mk "$TMP/c" <<'EOF'
f() {
  gzip -dc "$1" \
    | tail -5 \
    | grep -Fqx -- '-- PostgreSQL database dump complete'
}
EOF
out="$(python3 "$AUDIT" "$TMP/c" 2>&1)"
grep -q 'grep -Fqx' <<< "$out" || fail "the leading-pipe form was missed: $out"
echo "  the dump-footer shape is caught"

sect "a pipeline split with the PIPE TRAILING the line is caught"
# The other way to write it: the pipe ends one line and grep opens the next, so
# neither line contains `| grep` on its own. This is the shape that needs the
# continuation lines joined.
mk "$TMP/c2" <<'EOF'
f() {
  docker ps --format '{{.Names}}' | \
    grep -qxF "$1"
}
EOF
out="$(python3 "$AUDIT" "$TMP/c2" 2>&1)"
grep -q 'grep -qxF\|docker ps' <<< "$out" || fail "the trailing-pipe form was missed: $out"
echo "  a trailing-backslash pipeline is joined before matching"

sect "the CAPTURE-FIRST fix is ACCEPTED"
# Including the or-list form, whose `||` must not read as a pipe. An audit that
# flags its own prescribed fix is one somebody switches off.
mk "$TMP/d" <<'EOF'
f() {
  local names
  names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  grep -qxF -- "$1" <<< "$names" && return 1
  if [[ "$x" == *'{{'* ]] || grep -qE '\$\{[A-Z_]+\}' <<< "$x"; then return 1; fi
  return 0
}
EOF
out="$(python3 "$AUDIT" "$TMP/d" 2>&1)"; rc=$?
(( rc == 0 )) || fail "the correct capture-first form was rejected: $out"
echo "  <<< \"\$out\" is accepted, and '|| grep -q' is not mistaken for a pipe"

sect "a grep WITHOUT a quiet flag is not flagged"
mk "$TMP/e" <<'EOF'
f() { docker ps | grep -c . ; echo hi | grep -E 'x' ; }
EOF
python3 "$AUDIT" "$TMP/e" >/dev/null 2>&1 \
  || fail "a non-quiet grep was flagged; it reads its input to completion"
echo "  only the quiet form short-circuits, so only it is banned"

sect "a COMMENT quoting the banned form does not fail the audit"
# Strip comments before asserting that code does not contain something: this
# audit's own docstring quotes `cmd | grep -q`, and so does every comment that
# documents a fix. Three assertions in this repository have flagged their own
# explanatory comments.
mk "$TMP/f" <<'EOF'
f() {
  # Capture first: docker ps | grep -qxF reports 141 on a match.
  local n; n="$(docker ps)"
  grep -qxF -- "$1" <<< "$n"
}
EOF
out="$(python3 "$AUDIT" "$TMP/f" 2>&1)"; rc=$?
(( rc == 0 )) || fail "an explanatory comment was flagged as code: $out"
echo "  comments are stripped before matching"

sect "mutation: without comment-stripping the audit must fail on its own fixture"
mut="$TMP/mut.py"
cp "$AUDIT" "$mut"
python3 - "$mut" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = '        code = re.sub(r"(^|\\s)#.*$", "", subject)'
assert s.count(a) == 1, "the comment-stripping line moved; update this mutation"
p.write_text(s.replace(a, '        code = subject'))
PY
grep -q 'code = subject' "$mut" || fail "the mutation was not applied"
python3 "$mut" "$TMP/f" >/dev/null 2>&1 \
  && fail "without comment-stripping the commented fixture still passed"
echo "  killed: the stripping is load-bearing, not decoration"

sect "mutation: without line-joining the split pipeline must pass"
mut2="$TMP/mut2.py"
cp "$AUDIT" "$mut2"
python3 - "$mut2" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = '''                       if ln.rstrip().endswith("\\\\") else ln))'''
assert s.count(a) == 1, "the line-joining expression moved; update this mutation"
p.write_text(s.replace(a, '''                       if False else ln))'''))
PY
grep -q 'if False else ln' "$mut2" || fail "the mutation was not applied"
python3 "$mut2" "$TMP/c2" >/dev/null 2>&1 \
  || fail "the trailing-pipe split was still caught without line-joining"
# The leading-pipe shape is caught either way -- a line beginning `| grep -q`
# matches on its own -- so the mutation is driven against the shape that
# genuinely depends on joining. Asserting it against the other fixture would
# have passed vacuously.
python3 "$mut2" "$TMP/c" >/dev/null 2>&1 \
  && fail "the leading-pipe form should be caught with or without joining"
echo "  killed: joining is what catches a pipe left at the end of a line"

# ---------------------------------------------------------------------------
#  The suites are scanned too. They were not, and that was a blind spot in the
#  one place where an assertion that silently stops asserting is worst.
# ---------------------------------------------------------------------------
sect "the SUITES are scanned, not just the production files"
out="$(python3 "$AUDIT" "$REPO_ROOT" 2>&1)"
suites="$(sed -nE 's/^== scanned .* ([0-9]+) of them suites$/\1/p' <<< "$out")"
[ -n "$suites" ] || fail "the audit does not report how many suites it scanned: $out"
(( suites > 10 )) \
  || fail "only $suites suite(s) were scanned; the tests/ glob is not working: $out"
echo "  $suites suites scanned"

sect "a banned pipeline IN A SUITE is rejected"
# The whole point. Before this, a suite could carry the shape indefinitely.
mkdir -p "$TMP/suite/bin" "$TMP/suite/operator" "$TMP/suite/tests"
: > "$TMP/suite/bin/domum-media"; : > "$TMP/suite/bin/domum-media-backup"
: > "$TMP/suite/bin/domum-media-report"; : > "$TMP/suite/install.sh"
cat > "$TMP/suite/tests/x-smoke.sh" <<'EOF'
out="$(printf 'hello\n')"
printf '%s\n' "$out" | grep -q hello || fail "nope"
EOF
out="$(python3 "$AUDIT" "$TMP/suite" 2>&1)"; rc=$?
(( rc == 1 )) || fail "a banned pipeline inside a suite was accepted: $out"
grep -q 'x-smoke.sh' <<< "$out" || fail "the offending suite is not named: $out"
echo "  caught, and the suite is named"

sect "a QUOTED heredoc body is data, and is not scanned"
# A suite reproducing the historical operator wrapper it must reject, or
# feeding this very audit a fixture, legitimately contains the banned shape.
# Demanding those be "fixed" would make a test stop describing the defect it
# exists to catch.
cat > "$TMP/suite/tests/x-smoke.sh" <<'EOF'
cat > "$d/bad.sh" <<'INNER'
domum-media storage protection plex | grep -q protected || abort "nope"
INNER
EOF
out="$(python3 "$AUDIT" "$TMP/suite" 2>&1)"; rc=$?
(( rc == 0 )) || fail "a quoted heredoc body was scanned as code: $out"
echo "  quoted heredoc bodies are exempt"

sect "an UNQUOTED heredoc body is still scanned"
# There `$( )` IS command substitution, so its contents can execute.
cat > "$TMP/suite/tests/x-smoke.sh" <<'EOF'
cat > "$d/bad.sh" <<INNER
value=$(docker ps | grep -q plex)
INNER
EOF
out="$(python3 "$AUDIT" "$TMP/suite" 2>&1)"; rc=$?
(( rc == 1 )) || fail "an UNQUOTED heredoc body was exempted; substitution runs there: $out"
echo "  unquoted heredoc bodies are still scanned"

sect "the marker exempts ONE line, and the exemption is PRINTED"
# An allowance nobody can see is how a real defect gets a marker stuck on it.
cat > "$TMP/suite/tests/x-smoke.sh" <<'EOF'
printf 'docker ps | grep -q plex\n' >> "$d/fixture.sh"  # pipefail-audit: fixture
printf 'docker ps | grep -q kavita\n' >> "$d/other.sh"
EOF
out="$(python3 "$AUDIT" "$TMP/suite" 2>&1)"; rc=$?
(( rc == 1 )) || fail "the unmarked line was exempted by its neighbour's marker: $out"
grep -q 'exempt (fixture)' <<< "$out" || fail "the exemption is not printed: $out"
grep -q 'kavita' <<< "$out" || fail "the unmarked line was not reported: $out"
echo "  one line each, and every exemption is visible"

sect "a broken tests/ glob cannot pass as a clean tree"
# Counted with os.listdir, deliberately NOT the glob that built TARGETS:
# re-asking the same glob would report zero expected and zero scanned and call
# that agreement.
mut3="$TMP/audit-noglob.py"
cp "$AUDIT" "$mut3"
cat > "$TMP/mutate-noglob.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '+ sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests").glob("*.sh")))'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, '+ [])'))
PYMUT
( python3 -I "$TMP/mutate-noglob.py" "$mut3" ) || fail "the glob mutation did not apply"
rm -f "$TMP/suite/tests/x-smoke.sh"
cat > "$TMP/suite/tests/clean-smoke.sh" <<'EOF'
out="$(printf 'hi\n')"
grep -q hi <<< "$out" || fail "nope"
EOF
out="$(python3 "$mut3" "$TMP/suite" 2>&1)"; rc=$?
(( rc == 1 )) \
  || fail "with the suites glob removed and a suite present, the audit passed: $out"
grep -q 'the glob broke' <<< "$out" || fail "the vacuity guard did not name the cause: $out"
# And with no suite present at all it must NOT fire -- the fixtures above are
# exactly that case, and requiring suites unconditionally rejected every one.
rm -f "$TMP/suite/tests/clean-smoke.sh"
python3 "$mut3" "$TMP/suite" >/dev/null 2>&1 \
  || fail "an empty tests/ directory was treated as a broken glob"
echo "  killed: a broken glob cannot read as clean, and an empty dir is not a break"

echo "PASS: pipefail-grep-audit smoke test"
