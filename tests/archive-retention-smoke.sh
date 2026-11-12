#!/usr/bin/env bash
# `storage archive-retention` applies the OFF-SITE retention policy that
# docs/OFFSITE-COVERAGE-CLASSIFICATION.md §4b had only ever stated in prose.
#
# §4b lists five rules and says the CLI "can already answer" each one. It could,
# and nothing APPLIED them -- so an operator could not ask what the policy
# selects, and "designed" was the whole of the evidence. This suite drives the
# decision function against a fixture carrying every verdict.
#
# The two rules with teeth, and both are negative-controlled here:
#
#   NEVER SELECT BY FILENAME OR mtime. The record is `IMAGE_ARCHIVE=` in a
#   point's .recovery file and recency is `CAPTURED_AT`. This project has
#   reasoned from mtime wrongly three times, and the point NAME also carries a
#   timestamp, which is the same mistake wearing a different hat. The fixture
#   therefore sets mtime order OPPOSITE to CAPTURED_AT order and requires the
#   verdict not to move.
#
#   AN ARCHIVE THAT DOES NOT DEMONSTRABLY HOLD ITS IMAGE IS NOT COVERAGE, which
#   is a different claim from the file being intact. The fixture makes the
#   unverifiable archives NEWER than a good one, so a broken gate would promote
#   one to `retain`.
#
# Nothing here deletes: off-site retention and on-disk retention are different
# decisions, and §4b says conflating them is how a local rollback artefact gets
# deleted to save cloud bytes.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
# What the drivers LOAD. Defaults to the tracked CLI and is repointed at a
# mutated copy by mutate() below, so no mutation ever touches bin/.
MUTCLI="$CLI"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# Taken BEFORE the first section, so the guard at the end proves the tracked
# CLI was never mutated rather than that the last restore ran.
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"

# ---------------------------------------------------------------------------
#  The fixture: six archives, one per verdict.
# ---------------------------------------------------------------------------
build() {  # build <root>
  local r="$1"
  rm -rf -- "$r"; mkdir -p "$r/data/backups/images" "$r/state/snapshots"
  local n
  for n in plex-new plex-old plex-badsum plex-noident orphan-one navi-nocap; do
    printf 'archive-%s\n' "$n" > "$r/data/backups/images/$n.tar"
  done
  mkpoint "$r" plex-20261110-120000-pre plex      2026-11-10T12:00:00-05:00 plex-new     real
  mkpoint "$r" plex-20261101-120000-pre plex      2026-11-01T12:00:00-05:00 plex-old     real
  mkpoint "$r" plex-20261105-120000-pre plex      2026-11-05T12:00:00-05:00 plex-badsum  bogus
  mkpoint "$r" plex-20261112-120000-pre plex      2026-11-12T12:00:00-05:00 plex-noident real
  mkpoint "$r" navi-20261109-120000-pre navidrome ''                        navi-nocap   real
  # orphan-one.tar is deliberately named by NO point.

  # mtime order is the OPPOSITE of CAPTURED_AT order, so ranking by mtime would
  # invert the answer and the control below would catch it.
  touch -d '2020-01-01' "$r/data/backups/images/plex-new.tar"
  touch -d '2030-01-01' "$r/data/backups/images/plex-old.tar"
}

mkpoint() {  # mkpoint <root> <point> <service> <captured_at> <archive> real|bogus
  local r="$1" point="$2" svc="$3" cap="$4" arch="$5" shamode="$6"
  local tar="$r/data/backups/images/$arch.tar" sha
  if [[ "$shamode" == real ]]; then
    sha="$(sha256sum "$tar" | awk '{print $1}')"
  else
    sha="0000000000000000000000000000000000000000000000000000000000000000"
  fi
  {
    printf "FORMAT='1'\n"
    printf "SERVICE='%s'\n" "$svc"
    [[ -n "$cap" ]] && printf "CAPTURED_AT='%s'\n" "$cap"
    printf "RECOVERY_POINT='%s'\n" "$point"
    printf "DATA_PATH='/srv/data/%s'\n" "$svc"
    printf "RUNTIME_STATE_BEFORE='running'\n"
    printf "IMAGE_ARCHIVE='%s'\n" "$tar"
    printf "IMAGE_ARCHIVE_SHA256='%s'\n" "$sha"
  } > "$r/state/snapshots/$point.recovery"
}

# The ONE stubbed seam is the identity check: the real one needs a genuine
# `docker save` archive, which a fixture cannot produce without a daemon. The
# metadata read, the checksum comparison and the ranking are all production code.
write_driver() {  # write_driver <file> <extra stubs>
  cat > "$1" <<DRV
set -uo pipefail
source "\$CLI" >/dev/null 2>&1
die() { echo "DIE: \$*" >&2; exit 90; }
need_root() { :; }
load_cfg() { :; }
domum_archive_identity() {
  case "\$1" in *plex-noident.tar) printf 'undetermined' ;; *) printf 'verified' ;; esac
}
export DOMUM_DATA_ROOT="\$WORK/data" DOMUM_STATE_ROOT="\$WORK/state"
${2:-}
DRV
}

drive() {  # drive <root> <command...>
  local r="$1"; shift
  write_driver "$r/drv.sh" "$*"
  env WORK="$r" CLI="$MUTCLI" bash "$r/drv.sh" 2>&1
}

R="$TMP/fix"; build "$R"

# ===========================================================================
sect "1. every verdict is produced, and only one archive is off-site coverage"
out="$(drive "$R" archive_retention_decisions)"
[[ -n "$out" ]] || fail "1: no decisions at all"
for want in \
  "retain plex plex-new.tar" \
  "superseded plex plex-old.tar" \
  "checksum-mismatch plex plex-badsum.tar" \
  "identity-unverified plex plex-noident.tar" \
  "orphan unknown orphan-one.tar" \
  "recency-unknown navidrome navi-nocap.tar"; do
  grep -qF "$want" <<< "$out" || fail "1: missing verdict '$want' in:
$out"
done
[[ "$(grep -c '^retain ' <<< "$out")" == "1" ]] \
  || fail "1: exactly one archive should be off-site coverage: $out"
echo "   six verdicts, one retain"

# ===========================================================================
sect "2. RANKING IS CAPTURED_AT, NOT mtime -- the fixture inverts mtime"
# plex-new.tar has an mtime of 2020 and the NEWEST CAPTURED_AT; plex-old.tar has
# an mtime of 2030 and the OLDEST. Ranking by mtime would swap them.
newer_mtime="$(stat -c %Y "$R/data/backups/images/plex-old.tar")"
older_mtime="$(stat -c %Y "$R/data/backups/images/plex-new.tar")"
(( newer_mtime > older_mtime )) \
  || fail "2: the fixture does not actually invert mtime, so this proves nothing"
grep -qF "retain plex plex-new.tar" <<< "$out" \
  || fail "2: the archive with the OLDEST mtime and newest CAPTURED_AT was not retained"
grep -qF "superseded plex plex-old.tar" <<< "$out" \
  || fail "2: the archive with the NEWEST mtime was not superseded"
echo "   mtime inverted and the answer did not move"

# ===========================================================================
sect "3. an unverifiable archive cannot become the newest valid point"
# plex-badsum (11-05) is newer than plex-old (11-01), and plex-noident (11-12)
# is newer than EVERY other archive -- so if either slipped past its gate it
# would outrank the good one, and plex-noident would take the off-site slot.
grep -qF "retain plex plex-badsum.tar" <<< "$out" \
  && fail "3: a checksum mismatch was treated as coverage: $out"
grep -qF "retain plex plex-noident.tar" <<< "$out" \
  && fail "3: an unverified identity was treated as coverage: $out"
echo "   both excluded before ranking, though both are newer"

# ===========================================================================
sect "4. the human report and --json cannot disagree"
human="$(drive "$R" 'storage_archive_retention')"
jsonout="$(drive "$R" 'storage_archive_retention --json')"
json_line="$(sed -n '/^{/{p;q;}' <<< "$jsonout")"
[[ -n "$json_line" ]] || fail "4: --json printed no JSON line: $jsonout"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$json_line" \
  || fail "4: the JSON does not parse: $json_line"
n_json="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["archives"]))' "$json_line")"
n_dec="$(grep -c . <<< "$out")"
[[ "$n_json" == "$n_dec" ]] \
  || fail "4: --json has $n_json records, the decision function produced $n_dec"
# Every verdict word in the records must appear in the human report too.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  v="$(awk '{print $1}' <<< "$line")"; a="$(awk '{print $3}' <<< "$line")"
  grep -qF "$a" <<< "$human" || fail "4: the human report omits $a"
  grep -qF "$v" <<< "$human" || fail "4: the human report omits the verdict $v"
done <<< "$out"
echo "   $n_json records, same set in both renderings"

# ===========================================================================
sect "5. the JSON is the FIRST line beginning with '{'"
first_brace="$(grep -n '^{' <<< "$jsonout" | head -1 | cut -d: -f1)"
[[ "$first_brace" == "1" ]] \
  || fail "5: the JSON is not the first line (it is line ${first_brace:-none}): $jsonout"
grep -q '^{' <<< "$human" && fail "5: the plain report printed a JSON line: $human"
echo "   extractable with sed -n '/^{/{p;q;}'"

# ===========================================================================
sect "6. it is a report, not a disk decision"
grep -qiE 'NOTHING WAS DELETED' <<< "$human" \
  || fail "6: the report does not say it deleted nothing: $human"
grep -qiE 'separate|different' <<< "$human" \
  || fail "6: it does not distinguish off-site from on-disk retention: $human"
# Comments stripped, because a comment naming the banned form is how a fix
# documents itself.
body="$(awk '/^archive_retention_decisions\(\) \{/,/^\}/' "$CLI" | sed 's/#.*//')"
body="$body
$(awk '/^storage_archive_retention\(\) \{/,/^\}/' "$CLI" | sed 's/#.*//')"
for banned in 'rm -' 'docker load' 'find .*-delete' 'restic' 'compose_cmd'; do
  grep -qE "$banned" <<< "$body" \
    && fail "6: the retention path contains '$banned', which it must not"
done
for banned in 'stat -c %Y' 'mtime' 'ls -t'; do
  grep -qE "$banned" <<< "$body" \
    && fail "6: the retention path reads mtime via '$banned'"
done
echo "   no deletion, no load, no restic, no mtime"

# ===========================================================================
sect "7. no archives at all is reported, and is NOT a finding"
E="$TMP/empty"; rm -rf -- "$E"; mkdir -p "$E/data/backups/images" "$E/state/snapshots"
out_e="$(drive "$E" 'storage_archive_retention')"
grep -qi 'selects nothing' <<< "$out_e" || fail "7: an empty directory was not reported: $out_e"
grep -qi 'NOT a finding' <<< "$out_e" || fail "7: it reads as a problem: $out_e"
dec_e="$(drive "$E" archive_retention_decisions)"
[[ -z "$(grep -c . <<< "$dec_e" | grep -v '^0$')" ]] || true
echo "   stated plainly, no alarm"

# ===========================================================================
#  Mutations.
# ===========================================================================
# Mutations operate on a COPY, and MUTCLI is what the drivers below load.
# A suite that mutates the TRACKED file can be stopped mid-run and leave it
# mutated -- which happened twice -- and makes any concurrent run unsound: a
# deterministic suite failed because another full-suite loop had that file
# mutated while it read it. unmutate is therefore a pointer reset, not a file
# restore, so there is nothing to miss if the run stops early.
mutate() {  # mutate <python-file>
  MUTCLI="$TMP/cli-mutant"
  cp "$CLI" "$MUTCLI"
  python3 -I "$1" "$MUTCLI" || fail "the mutation did not apply"
}
unmutate() { MUTCLI="$CLI"; }

sect "8. MUTATION: ranking by mtime must flip the answer"
cat > "$TMP/m1.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''    rows+=("valid ${svc:-unknown} $base $point $bytes $cap")'''
new = '''    rows+=("valid ${svc:-unknown} $base $point $bytes $(stat -c %Y "$f")")'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
mutate "$TMP/m1.py"
mout="$(drive "$R" archive_retention_decisions)"
unmutate
grep -qF "retain plex plex-old.tar" <<< "$mout" \
  || fail "8: the mutant did not rank by mtime -- the mutation changed no ANSWER: $mout"
echo "   killed: ranking by mtime retains the wrong archive"

sect "9. MUTATION: dropping the identity gate promotes an unverified archive"
cat > "$TMP/m2.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''    if [[ "$ident" != "verified" ]]; then'''
new = '''    if [[ "$ident" != "$ident" ]]; then'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
mutate "$TMP/m2.py"
mout2="$(drive "$R" archive_retention_decisions)"
unmutate
# The harm, stated as the observable: with the gate neutralised the NEWEST
# point's archive is selected for off-site retention even though nothing shows
# it holds the image that point names.
grep -qF "retain plex plex-noident.tar" <<< "$mout2" \
  || fail "9: the mutant did not promote the unverified archive to the off-site slot: $mout2"
grep -qF "identity-unverified" <<< "$mout2" \
  && fail "9: the mutant still reported identity-unverified, so the gate was not removed: $mout2"
echo "   killed: an archive that may not hold its image becomes coverage"

cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first
section -- something mutated it IN PLACE, so stopping this suite part-way would
leave the change behind and any concurrent run would read it"

# ===========================================================================
sect "10. A POINT WHOSE ARCHIVE HAS VANISHED IS A VERDICT, NOT A SILENCE"
# Pass one walks the archives on DISK, so a recovery point naming an archive
# that is gone produced NO record at all -- the `0 named by a recovery point`
# defect: a candidate list cannot distinguish PROTECTED from NEVER CONSIDERED.
G="$TMP/gone"; rm -rf -- "$G"; mkdir -p "$G/data/backups/images" "$G/state/snapshots"
printf 'good\n' > "$G/data/backups/images/plex-good.tar"
mkpoint "$G" plex-20261110-120000-pre plex 2026-11-10T12:00:00-05:00 plex-good real
# A point naming an archive that does not exist. mkpoint needs the file for its
# checksum, so it is created and then removed -- the POINT keeps naming it.
printf 'temp\n' > "$G/data/backups/images/plex-gone.tar"
mkpoint "$G" plex-20261112-120000-pre plex 2026-11-12T12:00:00-05:00 plex-gone real
rm -f "$G/data/backups/images/plex-gone.tar"

gout="$(drive "$G" archive_retention_decisions)"
grep -qF "archive-missing plex plex-gone.tar plex-20261112-120000-pre" <<< "$gout" \
  || fail "10: a point whose archive is gone produced no record: $gout"
echo "   the vanished archive is named, with its point"

# ===========================================================================
sect "11. and the retained OLDER archive must not read as coverage"
ghuman="$(drive "$G" 'storage_archive_retention')"
grep -qF "THE NEWEST RECOVERY POINT HAS NO ARCHIVE for: plex" <<< "$ghuman" \
  || fail "11: the report did not escalate: $ghuman"
grep -qiE 'not a statement that this service is covered' <<< "$ghuman" \
  || fail "11: it does not say 'retain' is about an older point: $ghuman"
echo "   escalated, and 'retain' is explicitly not a coverage claim"

# ===========================================================================
sect "12. the escalation does NOT fire when the missing point is OLDER"
# A check that fires either way is noise. Here the gone archive belongs to an
# OLDER point, so the retained archive IS the newest and nothing is wrong.
O="$TMP/older"; rm -rf -- "$O"; mkdir -p "$O/data/backups/images" "$O/state/snapshots"
printf 'good\n' > "$O/data/backups/images/plex-good.tar"
mkpoint "$O" plex-20261112-120000-pre plex 2026-11-12T12:00:00-05:00 plex-good real
printf 'temp\n' > "$O/data/backups/images/plex-gone.tar"
mkpoint "$O" plex-20261101-120000-pre plex 2026-11-01T12:00:00-05:00 plex-gone real
rm -f "$O/data/backups/images/plex-gone.tar"

ohuman="$(drive "$O" 'storage_archive_retention')"
grep -qF "THE NEWEST RECOVERY POINT HAS NO ARCHIVE" <<< "$ohuman" \
  && fail "12: it escalated for an OLDER point's missing archive, which is noise: $ohuman"
# It must still be REPORTED, just not escalated.
odec="$(drive "$O" archive_retention_decisions)"
grep -qF "archive-missing plex plex-gone.tar" <<< "$odec" \
  || fail "12: an older point's missing archive was not reported at all: $odec"
echo "   reported but not escalated -- both directions asserted"

# ===========================================================================
sect "13. MUTATION: without the points pass the vanished archive is invisible"
cat > "$TMP/m3.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
start = s.index('  local pm pbody parch psvc pcap')
end = s.index('  done <<< "$point_metas"', start) + len('  done <<< "$point_metas"\n')
io.open(p, "w", encoding="utf-8").write(s[:start] + s[end:])
PY
mutate "$TMP/m3.py"
mout3="$(drive "$G" archive_retention_decisions)"
mhuman3="$(drive "$G" 'storage_archive_retention')"
unmutate
grep -qF "plex-gone.tar" <<< "$mout3" \
  && fail "13: the mutant still reported the vanished archive -- the mutation changed nothing: $mout3"
grep -qF "THE NEWEST RECOVERY POINT HAS NO ARCHIVE" <<< "$mhuman3" \
  && fail "13: the mutant still escalated, so the escalation does not depend on the points pass"
grep -qF "retain plex plex-good.tar" <<< "$mout3" \
  || fail "13: the mutant did not still retain the older archive, so the fixture proves nothing"
echo "   killed: the older archive reads as coverage and the gap is silent"

cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first
section -- something mutated it IN PLACE, so stopping this suite part-way would
leave the change behind and any concurrent run would read it"

echo
echo "PASS: archive-retention-smoke (13 sections, 3 mutants)"
