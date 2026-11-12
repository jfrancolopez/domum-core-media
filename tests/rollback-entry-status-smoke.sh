#!/usr/bin/env bash
set -uo pipefail

# update_rollback_entry_status marks a rollback entry applied, and the entries
# it rewrites are SOURCED by both rollback loops. It was in the never-executed
# set, and carried three defects, each measured before being fixed:
#
#   * an entry with NO `STATUS=` line silently kept none, so marking it applied
#     changed nothing and the entry would be offered again;
#   * the value was wrapped in single quotes BY HAND, so a status containing one
#     produced STATUS='it's' -- broken shell. Because the entries are sourced,
#     that does not corrupt one entry: it aborts the loop and takes every other
#     entry with it;
#   * `awk -v` escape-processes its assignment, so a backslash was interpreted
#     rather than carried -- the defect already recorded for config_set.
#
# Hermetic: mktemp -d, no production path.

fail() { echo "FAIL: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
MUTCLI="$CLI"
PRISTINE="$TMP/cli.pristine"
cp "$CLI" "$PRISTINE"

mark() {  # $1 = file, $2 = new status
  bash -c "
set -uo pipefail
source '$MUTCLI' >/dev/null 2>&1
die() { echo \"DIE: \$*\"; exit 9; }
umask 022
update_rollback_entry_status '$1' \"\$1\"" _ "$2" 2>&1
}
# The VALUE as a sourced entry yields it -- the only reading that matters,
# because that is how the rollback loops consume these files.
status_of() {
  bash -c "unset STATUS; source '$1' >/dev/null 2>&1 || exit 1; printf '%s' \"\${STATUS:-}\""
}

# ---------------------------------------------------------------------------
# 1. An existing STATUS line is replaced, and nothing else is disturbed.
# ---------------------------------------------------------------------------
printf "ID='e1'\nSERVICE='plex'\nSTATUS='available'\nSNAPSHOT='plex-x'\n" > "$TMP/a.env"
mark "$TMP/a.env" applied >/dev/null
[ "$(status_of "$TMP/a.env")" = "applied" ] || fail "1: the status was not updated"
grep -q "SERVICE='plex'" "$TMP/a.env" || fail "1: another key was lost"
grep -q "SNAPSHOT='plex-x'" "$TMP/a.env" || fail "1: the snapshot pointer was lost"
[ "$(grep -c '^STATUS=' "$TMP/a.env")" = "1" ] || fail "1: more than one STATUS line"
echo "  1: an existing status is replaced and the other keys survive"

# ---------------------------------------------------------------------------
# 2. An entry with NO status line GETS one. Silently keeping none meant an
#    applied entry stayed offered.
# ---------------------------------------------------------------------------
printf "ID='e2'\nSERVICE='plex'\n" > "$TMP/b.env"
mark "$TMP/b.env" applied >/dev/null
[ "$(status_of "$TMP/b.env")" = "applied" ] \
  || fail "2: an entry with no STATUS line silently kept none, so marking it
applied changes nothing and it would be offered again"
[ "$(grep -c '^STATUS=' "$TMP/b.env")" = "1" ] || fail "2: expected exactly one STATUS line"
echo "  2: an entry with no status line gets one"

# ---------------------------------------------------------------------------
# 3. The entry stays SOURCEABLE whatever the status contains -- the property
#    that matters, since both rollback loops source every entry in turn.
# ---------------------------------------------------------------------------
for v in "it's" 'a\tb' 'two words' '$(echo no)' '`echo no`' 'semi;colon' '"dq"'; do
  printf "ID='e3'\nSTATUS='old'\n" > "$TMP/c.env"
  mark "$TMP/c.env" "$v" >/dev/null
  got="$(status_of "$TMP/c.env")" \
    || fail "3: the entry became unsourceable after a status of [$v] -- this
aborts the loop and takes every OTHER entry with it: $(cat "$TMP/c.env")"
  [ "$got" = "$v" ] \
    || fail "3: the status did not round-trip: wrote [$v], read back [$got]"
done
echo "  3: every awkward status round-trips and leaves the entry sourceable"

# ---------------------------------------------------------------------------
# 4. A command substitution in the value must not EXECUTE when sourced.
# ---------------------------------------------------------------------------
printf "ID='e4'\nSTATUS='old'\n" > "$TMP/d.env"
mark "$TMP/d.env" '$(touch '"$TMP"'/EXECUTED)' >/dev/null
bash -c "source '$TMP/d.env'" >/dev/null 2>&1
[ ! -e "$TMP/EXECUTED" ] \
  || fail "4: a command substitution in the status EXECUTED when the entry was sourced"
echo "  4: a command substitution in the status is data, not code"

# ---------------------------------------------------------------------------
# 5. The entry is 600 even when the caller's umask is loose, and the mode is
#    set before the rename rather than after.
# ---------------------------------------------------------------------------
printf "ID='e5'\nSTATUS='old'\n" > "$TMP/e.env"
chmod 644 "$TMP/e.env"
mark "$TMP/e.env" applied >/dev/null
[ "$(stat -c %a "$TMP/e.env")" = "600" ] || fail "5: the entry is $(stat -c %a "$TMP/e.env"), not 600"
[ "$(find "$TMP" -maxdepth 1 -name 'e.env.*' | wc -l)" = "0" ] \
  || fail "5: a temporary file was left beside the entry"
echo "  5: the entry ends 600 and no temporary is left behind"

# ---------------------------------------------------------------------------
# 6. An absent file is a no-op, not a failure or a created file.
# ---------------------------------------------------------------------------
out="$(mark "$TMP/absent.env" applied)"
grep -q 'DIE' <<< "$out" && fail "6: an absent entry must be a no-op: $out"
[ ! -e "$TMP/absent.env" ] || fail "6: it created an entry that did not exist"
echo "  6: an absent entry is a no-op"

# ---------------------------------------------------------------------------
# 7. MUTATIONS, against a COPY.
# ---------------------------------------------------------------------------
MUTCLI="$TMP/cli-mutant"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-end.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '        END { if (!seen) print ENVIRON["STATUS_LINE"] }\n'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PY
python3 -I "$TMP/mut-end.py" "$MUTCLI" || fail "7: the END mutation did not apply"
printf "ID='m1'\nSERVICE='plex'\n" > "$TMP/m1.env"
mark "$TMP/m1.env" applied >/dev/null
[ -z "$(status_of "$TMP/m1.env")" ] \
  || fail "7: the mutation applied but the status was still added, so section 2
would pass without the END block"
echo "  7: without the END block an entry with no status line silently keeps none"

MUTCLI="$TMP/cli-mutant2"
cp "$CLI" "$MUTCLI"
cat > "$TMP/mut-quote.py" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = "  printf -v rendered '%s=%q' STATUS \"$new_status\"\n"
new = "  rendered=\"STATUS='$new_status'\"\n"
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
python3 -I "$TMP/mut-quote.py" "$MUTCLI" || fail "7: the quoting mutation did not apply"
printf "ID='m2'\nSTATUS='old'\n" > "$TMP/m2.env"
mark "$TMP/m2.env" "it's" >/dev/null
status_of "$TMP/m2.env" >/dev/null 2>&1 \
  && fail "7: the mutation applied but the entry is still sourceable, so section 3
would pass without %q quoting"
echo "  7: hand-rolled single quotes make a quote break the sourced entry again"
MUTCLI="$CLI"

cmp -s "$CLI" "$PRISTINE" \
  || fail "the tracked CLI differs from the pristine copy taken before the first section"

echo "PASS: rollback entry status smoke test"
