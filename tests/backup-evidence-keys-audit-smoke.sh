#!/usr/bin/env bash
set -uo pipefail

# Drives tests/backup-evidence-keys-audit.py in both directions.
#
# WHY IT EXISTS. The audit guards a contract whose two ends are in different
# files: the `<target>-run.env` / `-check.env` / `-retention.env` evidence is
# written in bin/domum-media-backup and read in bin/domum-media and
# bin/domum-media-report. A key read but never written is silently empty -- no
# error, well-formed output, wrong answer -- and that defect has shipped in
# this repository once already.
#
# The load-bearing assertions are the ones that must FAIL: an audit that can
# only pass is indistinguishable from one that is not looking, and this one has
# three ways to stop looking -- a stale READERS table, stale discovery markers,
# and comment text counted as code.

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/tests/backup-evidence-keys-audit.py"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[[ -f "$AUDIT" ]] || fail "the audit is missing: $AUDIT"

# A fixture tree shaped like the repository, because the audit derives its root
# from its own location. Every root a test uses must be redirected into it.
make_tree() {  # $1 = destination
  local d="$1"
  mkdir -p "$d/tests" "$d/bin"
  cp "$AUDIT" "$d/tests/audit.py"
  cp "$REPO_ROOT/bin/domum-media" "$REPO_ROOT/bin/domum-media-backup" \
     "$REPO_ROOT/bin/domum-media-report" "$d/bin/"
}

# Deliberately NOT a helper that sets a variable. A helper called as
# `out="$(f)"` assigns in the SUBSHELL and the parent never sees it -- the
# defect this project records about dr-status's memoised inventory, and the
# first version of this suite had exactly it: the status came back unbound. So
# each site captures the status where it runs.

# ---------------------------------------------------------------------------
sect "the live repository is clean, and the audit says what it compared"
out="$(python3 -I "$AUDIT" 2>&1)" || fail "the audit fails against the real tree:
$out"
printf '%s\n' "$out" | sed -n '1,12p'
grep -q 'written by record_backup_target_run' <<< "$out" \
  || fail "the run-evidence writer was not found: $out"
grep -q 'written by record_restic_operation' <<< "$out" \
  || fail "the check/retention writer was not found: $out"
reader_lines="$(grep -c '^   ok ' <<< "$out" || true)"
[[ "${reader_lines:-0}" -ge 4 ]] \
  || fail "only $reader_lines reader(s) were reported; the evidence is read in
three CLIs and a silent drop to zero is how this audit stops looking: $out"
echo "  clean, and it names every writer and reader it compared"

sect "a key no writer emits is a MISMATCH, named"
# The recorded defect: `..._IMAGE_VERSION` read while the writer emitted
# `..._IMAGE_LABEL_VERSION`. sed matched nothing, the value was empty, and the
# surrounding output was still well-formed.
T1="$TMP/t1"; make_tree "$T1"
python3 -I - "$T1/bin/domum-media" <<'PYM' || fail "mutation 1 did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "    unset RESULT FINISHED_TS SNAPSHOT_ID\n"
assert s.count(old) >= 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(
    s.replace(old, "    unset RESULT FINISHED_TS SNAPSHOT_IDENT\n", 1))
PYM
grep -q 'SNAPSHOT_IDENT$' "$T1/bin/domum-media" || fail "mutation 1 is not in the file"
rc=0; out="$(python3 -I "$T1/tests/audit.py" 2>&1)" || rc=$?
(( rc != 0 )) || fail "a key no writer emits was accepted: $out"
grep -q 'MISMATCH' <<< "$out" || fail "the mismatch was not labelled: $out"
grep -q 'SNAPSHOT_IDENT' <<< "$out" || fail "the offending key is not named: $out"
grep -q 'silently empty' <<< "$out" || fail "it does not say what the consequence is: $out"
echo "  killed: an unwritten key fails and the key is named"

sect "a NEW reader the table does not classify is a failure, not a skip"
# This audit's own first run found `dr_last_success_run` that way, which the
# hand-written table had missed. Without this direction the table rots and the
# audit quietly checks fewer and fewer readers.
T2="$TMP/t2"; make_tree "$T2"
python3 -I - "$T2/bin/domum-media-report" <<'PYM' || fail "mutation 2 did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
new = '''
brand_new_evidence_reader() {
  local file
  file="$meta_dir/$1-run.env"
  (
    unset RESULT FINISHED_TS
    . "$file" >/dev/null 2>&1 || exit 1
    printf '%s' "${RESULT:-}"
  )
}
'''
io.open(p, "w", encoding="utf-8").write(s + new)
PYM
rc=0; out="$(python3 -I "$T2/tests/audit.py" 2>&1)" || rc=$?
(( rc != 0 )) || fail "an unclassified reader was skipped silently: $out"
grep -q 'brand_new_evidence_reader' <<< "$out" \
  || fail "the unclassified reader is not named: $out"
grep -q 'not classified' <<< "$out" || fail "it does not say why: $out"
echo "  killed: a new reader must be classified before it can pass"

sect "stale discovery markers cannot read as a clean tree"
# The vacuity hole. If discovery stops matching, every reader disappears and
# the comparison is of nothing -- which must not look like agreement. This is
# the mistake the pipefail audit's vacuity guard exists for, one audit over.
T3="$TMP/t3"; make_tree "$T3"
python3 -I - "$T3/tests/audit.py" <<'PYM' || fail "mutation 3 did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''PATH_MARKERS = (
    "-run.env",
    "-$2.env",
    "restic_op_evidence_file",
)'''
new = '''PATH_MARKERS = (
    "-no-such-evidence.env",
)'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYM
rc=0; out="$(python3 -I "$T3/tests/audit.py" 2>&1)" || rc=$?
(( rc != 0 )) || fail "a discovery that matched nothing reported a clean tree: $out"
grep -q 'discovery markers are stale' <<< "$out" \
  || fail "it does not say the discovery is the problem: $out"
echo "  killed: comparing nothing is not agreement"

sect "comment text is not code, in both directions"
# Four audits in this repository have each made this mistake once: a comment
# naming a key counted as a use of it. Here the false direction is a false
# POSITIVE -- a commented-out `unset` would be reported as a read.
T4="$TMP/t4"; make_tree "$T4"
python3 -I - "$T4/bin/domum-media" <<'PYM' || fail "mutation 4 did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "    unset RESULT FINISHED_TS SNAPSHOT_ID\n"
assert s.count(old) >= 1
io.open(p, "w", encoding="utf-8").write(
    s.replace(old,
              "    # unset RESULT FINISHED_TS NEVER_WRITTEN_KEY\n" + old, 1))
PYM
rc=0; out="$(python3 -I "$T4/tests/audit.py" 2>&1)" || rc=$?
(( rc == 0 )) || fail "a COMMENT naming a key was counted as reading it: $out"
grep -q 'NEVER_WRITTEN_KEY' <<< "$out" \
  && fail "the commented key appears in the report, so it was parsed: $out"
echo "  a commented-out unset is prose, and the tree stays clean"

sect "a writer that stops emitting is a failure, not an empty set"
# If the recording function is renamed or gutted, every reader's key becomes
# unwritten. The audit must say the WRITER is missing rather than report four
# mismatches and send the operator to the readers.
T5="$TMP/t5"; make_tree "$T5"
python3 -I - "$T5/bin/domum-media-backup" <<'PYM' || fail "mutation 5 did not apply"
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "record_restic_operation() {"
new = "record_restic_operation_renamed() {"
assert s.count(old) >= 1
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYM
rc=0; out="$(python3 -I "$T5/tests/audit.py" 2>&1)" || rc=$?
(( rc != 0 )) || fail "a missing writer was accepted: $out"
grep -q 'was not found' <<< "$out" \
  || fail "it does not say the writer is missing: $out"
echo "  killed: a missing writer is reported as a missing writer"

echo "PASS: backup-evidence-keys-audit smoke test"
