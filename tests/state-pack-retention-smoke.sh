#!/usr/bin/env bash
# State-pack retention: the §3 rules of docs/OFFSITE-STATE-BACKUP-DESIGN.md,
# driven rather than described.
#
# The two rules with teeth are negative-controlled, because a retention rule
# that is only read has not been tested and this one DELETES:
#
#   - ranking is by the sidecar's CAPTURED_AT, never mtime and never the
#     filename. The fixture therefore sets mtime order OPPOSITE to CAPTURED_AT
#     order, so a selector that reads mtime returns the opposite answer. This
#     project has reasoned from mtime wrongly three times, and the filename
#     carries a timestamp too, which is the same mistake in a new hat.
#   - an unverifiable pack is EVIDENCE, not garbage. It is kept and reported.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# $1 service, $2 CAPTURED_AT, $3 basename, $4 mtime, $5 (optional) "nosha"|"badsha"|"nometa"
mkpack() {
  local d="$TMP/packs" svc="$1" at="$2" n="$3" mt="$4" mode="${5:-}"
  mkdir -p "$d"
  printf 'age-encryption.org/v1\nbody for %s %s\n' "$svc" "$at" > "$d/$n"
  case "$mode" in
    nosha)  ;;
    badsha) echo deadbeef > "$d/$n.sha256" ;;
    *)      sha256sum "$d/$n" | cut -d' ' -f1 > "$d/$n.sha256" ;;
  esac
  [[ "$mode" == nometa ]] || printf 'SERVICE=%s\nCAPTURED_AT=%s\nCAPTURE_MODE=consistent\n' "$svc" "$at" > "$d/$n.meta"
  touch -d "$mt" "$d/$n"
}

reset_packs() { rm -rf -- "$TMP/packs"; mkdir -p "$TMP/packs"; }

# $1 = extra shell, $2.. = argv for the function under test
probe() {
  local extra="$1"; shift
  (
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    set +e
    warn() { echo "WARN|$*"; }
    die()  { echo "DIE|$*"; exit 1; }
    domum_acquire_lock() { :; }
    eval "$extra"
    "$@"
  ) 2>&1
}

# ---------------------------------------------------------------------------
sect "ranking follows CAPTURED_AT, with mtime order DELIBERATELY INVERTED"
reset_packs
# newest capture gets the OLDEST mtime and vice versa.
mkpack navidrome 2026-11-09T04:00:00Z a.tar.age 2030-01-01
mkpack navidrome 2026-11-10T04:00:00Z b.tar.age 2029-01-01
mkpack navidrome 2026-11-11T04:00:00Z c.tar.age 2020-01-01
out="$(probe 'STATE_PACK_KEEP=2' state_pack_retention_decisions "$TMP/packs")"
grep -q "^retain navidrome 2026-11-11T04:00:00Z .*c\.tar\.age$" <<< "$out" \
  || fail "the newest CAPTURED_AT was not retained: $out"
grep -q "^superseded navidrome 2026-11-09T04:00:00Z .*a\.tar\.age$" <<< "$out" \
  || fail "the oldest CAPTURED_AT was not superseded: $out"
grep -q "^superseded .*c\.tar\.age$" <<< "$out" \
  && fail "mtime order won -- c has the OLDEST mtime and the NEWEST capture: $out"
echo "  CAPTURED_AT decides, and the inverted mtimes do not"

sect "the only pack for a service is never superseded, whatever its age"
reset_packs
mkpack plex 2020-01-01T00:00:00Z only.tar.age 2020-01-01
out="$(probe 'STATE_PACK_KEEP=2' state_pack_retention_decisions "$TMP/packs")"
grep -q '^retain plex ' <<< "$out" || fail "a lone pack was not retained: $out"
grep -q '^superseded' <<< "$out" && fail "a lone pack was superseded: $out"
echo "  retained, even at six years old"

sect "retention is PER SERVICE, so one service cannot age out another"
reset_packs
mkpack navidrome 2026-11-09T04:00:00Z n1.tar.age 2026-11-09
mkpack navidrome 2026-11-10T04:00:00Z n2.tar.age 2026-11-10
mkpack navidrome 2026-11-11T04:00:00Z n3.tar.age 2026-11-11
mkpack plex      2026-11-01T04:00:00Z p1.tar.age 2026-11-01
out="$(probe 'STATE_PACK_KEEP=2' state_pack_retention_decisions "$TMP/packs")"
grep -q '^retain plex .*p1\.tar\.age$' <<< "$out" \
  || fail "plex's only pack was not retained alongside three navidrome packs: $out"
[[ "$(grep -c '^superseded' <<< "$out")" == 1 ]] \
  || fail "expected exactly one superseded pack: $out"
echo "  plex keeps its own, navidrome sheds exactly one"

sect "an unverifiable pack is EVIDENCE: kept and reported, never superseded"
for mode in badsha nosha; do
  reset_packs
  mkpack kavita 2026-11-11T04:00:00Z k1.tar.age 2026-11-11 "$mode"
  mkpack kavita 2026-11-10T04:00:00Z k2.tar.age 2026-11-10
  mkpack kavita 2026-11-09T04:00:00Z k3.tar.age 2026-11-09
  out="$(probe 'STATE_PACK_KEEP=1' state_pack_retention_decisions "$TMP/packs")"
  grep -q '^unverifiable kavita .*k1\.tar\.age$' <<< "$out" \
    || fail "[$mode] a pack whose checksum cannot be confirmed was not flagged: $out"
  grep -q '^superseded .*k1\.tar\.age$' <<< "$out" \
    && fail "[$mode] an unverifiable pack was marked for deletion: $out"
done
echo "  a mismatching checksum and an absent one are both KEPT"

sect "a pack with no readable sidecar is UNKNOWN, not deleted"
reset_packs
mkpack kavita 2026-11-11T04:00:00Z ok.tar.age 2026-11-11
mkpack kavita 2026-11-10T04:00:00Z no.tar.age 2026-11-10 nometa
out="$(probe 'STATE_PACK_KEEP=1' state_pack_retention_decisions "$TMP/packs")"
grep -q '^unknown - - .*no\.tar\.age$' <<< "$out" \
  || fail "a sidecar-less pack was not reported unknown: $out"
grep -q '^superseded .*no\.tar\.age$' <<< "$out" \
  && fail "a pack whose service could not be established was deleted: $out"
echo "  'I could not tell' is not 'delete it'"

# ---------------------------------------------------------------------------
sect "the command is a DRY RUN by default and removes nothing"
reset_packs
mkpack navidrome 2026-11-09T04:00:00Z a.tar.age 2030-01-01
mkpack navidrome 2026-11-10T04:00:00Z b.tar.age 2029-01-01
mkpack navidrome 2026-11-11T04:00:00Z c.tar.age 2020-01-01
before="$(ls -1 "$TMP/packs"/*.tar.age | wc -l)"
out="$(probe 'STATE_PACK_KEEP=2' storage_prune_state_packs "$TMP/packs")"
grep -q 'DRY RUN' <<< "$out" || fail "the default run did not say it was a dry run: $out"
after="$(ls -1 "$TMP/packs"/*.tar.age | wc -l)"
[[ "$before" == "$after" ]] || fail "the dry run removed files: $before -> $after"
echo "  $after packs before and after"

sect "--confirm removes the superseded pack AND its sidecar and checksum"
out="$(probe 'STATE_PACK_KEEP=2' storage_prune_state_packs --confirm "$TMP/packs")"
grep -q 'result      : done' <<< "$out" || fail "the confirmed run did not complete: $out"
[[ -e "$TMP/packs/a.tar.age" ]] && fail "the superseded pack is still present"
[[ -e "$TMP/packs/a.tar.age.sha256" ]] && fail "its checksum was left orphaned"
[[ -e "$TMP/packs/a.tar.age.meta" ]] && fail "its sidecar was left orphaned"
[[ -e "$TMP/packs/c.tar.age" && -e "$TMP/packs/b.tar.age" ]] \
  || fail "a retained pack was removed"
echo "  one pack and its two companions gone; both retained packs intact"

sect "an absent or empty directory is explicitly NOT a finding"
out="$(probe '' storage_prune_state_packs "$TMP/nonexistent")"
grep -q 'NOT a finding' <<< "$out" || fail "an absent directory was treated as a problem: $out"
reset_packs
out="$(probe '' storage_prune_state_packs "$TMP/packs")"
grep -qi 'not a finding' <<< "$out" || fail "an empty directory was treated as a problem: $out"
echo "  that is what an unscheduled host looks like"

sect "it refuses an unknown flag rather than treating it as a directory"
out="$(probe '' storage_prune_state_packs --delete-everything "$TMP/packs")"
grep -q '^DIE|' <<< "$out" || fail "an unknown flag was not refused: $out"
echo "  refused"

# ---------------------------------------------------------------------------
sect "the pack writes an unencrypted sidecar that leaks no capture content"
if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "  SKIP: age is not installed, so a real pack cannot be produced here"
else
  age-keygen -o "$TMP/id" >/dev/null 2>&1
  age-keygen -y "$TMP/id" > "$TMP/pub" 2>/dev/null
  mkdir -p "$TMP/cap/files"
  printf 'SERVICE=navidrome\nSCHEMA_VERSION=2\nCAPTURE_MODE=consistent\nITEM=sqlite|navidrome.db|sqlite-backup|4096|644|SENTINELDIGEST\nRESULT=COMPLETE\nITEMS=1\n' \
    > "$TMP/cap/MANIFEST"
  out="$(probe 'service_state_verify() { return 0; }
    STATE_PACK_AGE_PUBKEY_FILE="'"$TMP/pub"'"' \
    service_state_pack "$TMP/cap" "$TMP/real.tar.age")"
  [[ -s "$TMP/real.tar.age.meta" ]] || fail "no sidecar was written: $out"
  [[ "$(stat -c %a "$TMP/real.tar.age.meta")" == 600 ]] \
    || fail "the sidecar is not 0600: $(stat -c %a "$TMP/real.tar.age.meta")"
  grep -qx 'SERVICE=navidrome' "$TMP/real.tar.age.meta" || fail "no SERVICE in the sidecar"
  grep -qx 'CAPTURE_MODE=consistent' "$TMP/real.tar.age.meta" || fail "no CAPTURE_MODE in the sidecar"
  grep -q 'SENTINELDIGEST' "$TMP/real.tar.age.meta" \
    && fail "the sidecar leaked a digest from the manifest BODY"
  grep -q 'navidrome\.db' "$TMP/real.tar.age.meta" \
    && fail "the sidecar leaked an item PATH from the capture"
  # And the retention reader must accept what the writer produced.
  mkdir -p "$TMP/realdir" && cp "$TMP/real.tar.age" "$TMP/real.tar.age.sha256" "$TMP/real.tar.age.meta" "$TMP/realdir/"
  rout="$(probe 'STATE_PACK_KEEP=4' state_pack_retention_decisions "$TMP/realdir")"
  grep -q '^retain navidrome ' <<< "$rout" \
    || fail "the reader did not accept the writer's own sidecar: $rout"
  echo "  0600, SERVICE and CAPTURE_MODE present, no item path and no body digest,"
  echo "  and the retention reader accepts the writer's own output"
fi

# ---------------------------------------------------------------------------
sect "MUTATION: ranking by mtime instead of CAPTURED_AT"
reset_packs
mkpack navidrome 2026-11-09T04:00:00Z a.tar.age 2030-01-01
mkpack navidrome 2026-11-10T04:00:00Z b.tar.age 2029-01-01
mkpack navidrome 2026-11-11T04:00:00Z c.tar.age 2020-01-01
cp "$CLI" "$TMP/cli.orig.rank"
cat > "$TMP/mutate-rank.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# Matched by a BACKSLASH-FREE fragment and replaced whole-line. The read it
# targets contains `\\1`, and expressing that through a nested heredoc needs one
# more escaping layer than is obvious -- the first attempt matched 0 times.
lines = s.split("\n")
hits = [i for i, l in enumerate(lines) if 'at="$(sed' in l]
assert len(hits) == 1, "anchor matched %d times" % len(hits)
lines[hits[0]] = '      at="$(stat -c %Y "$p" 2>/dev/null || echo 0)"'
io.open(p, "w", encoding="utf-8").write("\n".join(lines))
PYMUT
( python3 -I "$TMP/mutate-rank.py" "$CLI" ) \
  || { cp "$TMP/cli.orig.rank" "$CLI"; fail "the ranking mutation did not apply"; }
mout="$(probe 'STATE_PACK_KEEP=2' state_pack_retention_decisions "$TMP/packs")"
cp "$TMP/cli.orig.rank" "$CLI"
grep -q '^superseded .*c\.tar\.age$' <<< "$mout" \
  || fail "the mutation changed no ANSWER -- ranking by mtime must supersede the
NEWEST capture, because the fixture gives it the oldest mtime: $mout"
echo "  killed: by mtime, the newest capture is the one thrown away"

sect "MUTATION: treating an unverifiable pack as superseded"
reset_packs
mkpack kavita 2026-11-11T04:00:00Z k1.tar.age 2026-11-11 badsha
mkpack kavita 2026-11-10T04:00:00Z k2.tar.age 2026-11-10
cp "$CLI" "$TMP/cli.orig.unver"
cat > "$TMP/mutate-unver.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
old = '''    if [[ "$want" != "$got" ]]; then
      printf 'unverifiable %s %s %s\\n' "$svc" "$at" "$p"
      continue
    fi
'''
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
io.open(p, "w", encoding="utf-8").write(s.replace(old, "", 1))
PYMUT
( python3 -I "$TMP/mutate-unver.py" "$CLI" ) \
  || { cp "$TMP/cli.orig.unver" "$CLI"; fail "the unverifiable mutation did not apply"; }
mout="$(probe 'STATE_PACK_KEEP=1' state_pack_retention_decisions "$TMP/packs")"
cp "$TMP/cli.orig.unver" "$CLI"
grep -q '^unverifiable' <<< "$mout" \
  && fail "the mutation changed no ANSWER -- without the check nothing should be
reported unverifiable: $mout"
echo "  killed: without the check, evidence enters the deletable set"

sect "MUTATION: removing the --confirm gate"
reset_packs
mkpack navidrome 2026-11-09T04:00:00Z a.tar.age 2026-11-09
mkpack navidrome 2026-11-10T04:00:00Z b.tar.age 2026-11-10
mkpack navidrome 2026-11-11T04:00:00Z c.tar.age 2026-11-11
cp "$CLI" "$TMP/cli.orig.gate"
cat > "$TMP/mutate-gate.py" <<'PYMUT'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
# SCOPED to the function: `if (( confirm == 0 ))` is a shared idiom and matches
# three times across the CLI, so an unscoped anchor mutates the wrong command.
i = s.index("storage_prune_state_packs() {")
j = s.index("\n}\n", i)
body = s[i:j]
old = '  if (( confirm == 0 )); then\n'
assert body.count(old) == 1, "anchor matched %d times inside the function" % body.count(old)
io.open(p, "w", encoding="utf-8").write(
    s[:i] + body.replace(old, '  if (( confirm == 99 )); then\n', 1) + s[j:])
PYMUT
( python3 -I "$TMP/mutate-gate.py" "$CLI" ) \
  || { cp "$TMP/cli.orig.gate" "$CLI"; fail "the gate mutation did not apply"; }
probe 'STATE_PACK_KEEP=2' storage_prune_state_packs "$TMP/packs" >/dev/null
left="$(ls -1 "$TMP/packs"/*.tar.age 2>/dev/null | wc -l)"
cp "$TMP/cli.orig.gate" "$CLI"
[[ "$left" == 3 ]] \
  && fail "the mutation changed no ANSWER -- without the gate a default run must
delete: $left pack(s) remain"
echo "  killed: without the gate a plain run deletes ($left of 3 left)"

sect "the CLI is restored after every mutation"
grep -q 'CAPTURED_AT=(\.\*)\$/' "$CLI" || fail "the CAPTURED_AT read is missing from the CLI"
grep -q 'if (( confirm == 0 )); then' "$CLI" || fail "the --confirm gate is missing from the CLI"
grep -q "printf 'unverifiable %s %s %s" "$CLI" || fail "the unverifiable branch is missing from the CLI"
echo "  all three mutation targets are back"

# ---------------------------------------------------------------------------
#  capture-all-state: the entry point a scheduled job invokes. There was none
#  before, so the schedule in the design had nothing to point at.
# ---------------------------------------------------------------------------
sect "the service set is DERIVED from the two declarations, not listed"
out="$(probe '' state_capture_services)"
for svc in jellyfin plex navidrome calibre-web kavita; do
  grep -qx "$svc" <<< "$out" || fail "$svc is missing from the derived set: $out"
done
grep -qx immich <<< "$out" \
  && fail "immich is in the capture set -- it is protected-tier but declares no
essential state, because its library is the restic backup's job: $out"
[[ "$(grep -c . <<< "$out")" == 5 ]] || fail "expected exactly 5 services: $out"
echo "  five services, derived; immich correctly absent"

sect "a service that stops declaring essential state leaves the set"
# This is why the set is derived. A hardcoded list would keep capturing a
# service whose declaration had gone, or miss one that gained it.
out="$(probe 'service_essential_state() { [[ "$1" == navidrome ]] || return 0; printf "sqlite|navidrome.db\n"; }' \
  state_capture_services)"
[[ "$(grep -c . <<< "$out")" == 1 ]] || fail "the set did not follow the declaration: $out"
grep -qx navidrome <<< "$out" || fail "the one declaring service is not in the set: $out"
echo "  the set follows the declaration"

sect "capture-all CONTINUES past a failing service and fails at the END"
# One service's problem must not cost the other four their capture. That is the
# shape of the retention failure which aborted before `heartbeat` and made a
# successful backup report as stale.
STUBS='
  service_state_capture() { echo "CAPTURE|$1"; [[ "$1" != plex ]]; }
  service_state_pack()    { echo "PACK|$1"; return 0; }
  state_capture_dir()     { printf "%s" "'"$TMP"'/caps"; }
'
out="$(probe "$STUBS" storage_capture_all_state)"
for svc in jellyfin plex navidrome calibre-web kavita; do
  grep -q "^CAPTURE|.*$svc" <<< "$out" \
    || fail "$svc was never attempted -- a failure stopped the loop: $out"
done
grep -q 'INCOMPLETE' <<< "$out" || fail "a failed service did not make the run INCOMPLETE: $out"
grep -q 'captured    : 4' <<< "$out" || fail "the four that succeeded were not counted: $out"
echo "  all five attempted, 4 captured, verdict INCOMPLETE"

sect "a clean run reports done and says nothing was transmitted"
out="$(probe '
  service_state_capture() { return 0; }
  service_state_pack()    { return 0; }
  state_capture_dir()     { printf "%s" "'"$TMP"'/caps"; }' storage_capture_all_state)"
grep -q 'result      : done' <<< "$out" || fail "a clean run did not report done: $out"
grep -q 'Nothing was transmitted' <<< "$out" \
  || fail "it did not state that nothing left the host: $out"
grep -q 'INCOMPLETE' <<< "$out" && fail "a clean run reported INCOMPLETE: $out"
echo "  done, and it says nothing left the host"

sect "--pack is OPT-IN, and without it no pack is produced"
out="$(probe "$STUBS
  service_state_capture() { return 0; }" storage_capture_all_state)"
grep -q '^PACK|' <<< "$out" && fail "packing happened without --pack: $out"
grep -q 'packing     : no' <<< "$out" || fail "it did not say packing was off: $out"
out="$(probe "$STUBS
  service_state_capture() { return 0; }" storage_capture_all_state --pack)"
[[ "$(grep -c '^PACK|' <<< "$out")" == 5 ]] || fail "--pack did not pack all five: $out"
grep -q 'packed      : 5' <<< "$out" || fail "the packed count is wrong: $out"
echo "  off by default, five packs with --pack"

sect "a pack failure is reported WITHOUT discarding the capture"
out="$(probe '
  service_state_capture() { return 0; }
  service_state_pack()    { [[ "$1" != *navidrome* ]]; }
  state_capture_dir()     { printf "%s" "'"$TMP"'/caps"; }' storage_capture_all_state --pack)"
grep -q 'pack FAILED' <<< "$out" || fail "a failed pack was not reported: $out"
grep -q 'the capture is intact' <<< "$out" \
  || fail "it did not say the capture survives a failed pack: $out"
grep -q 'INCOMPLETE' <<< "$out" || fail "a failed pack did not make the run INCOMPLETE: $out"
echo "  the capture is kept and the run still fails"

sect "an empty service set is REFUSED, never reported as success"
out="$(probe 'service_state_models() { :; }' storage_capture_all_state)"
grep -q '^DIE|' <<< "$out" || fail "an empty set did not refuse: $out"
grep -q 'empty set' <<< "$out" || fail "the refusal did not say why: $out"
echo "  refused -- zero services is not a clean run"

sect "an unknown argument is refused rather than ignored"
out="$(probe '' storage_capture_all_state --prune-everything)"
grep -q '^DIE|' <<< "$out" || fail "an unknown argument was accepted: $out"
echo "  refused"

# ---------------------------------------------------------------------------
#  The unit. Its ExecStart ORDER is §3's fourth retention rule.
# ---------------------------------------------------------------------------
sect "the unit packs BEFORE it prunes, and neither step is '-' prefixed"
U="$REPO_ROOT/systemd/domum-media-state-capture.service"
[[ -r "$U" ]] || fail "the unit file does not exist: $U"
cap_line="$(grep -n '^ExecStart=.*capture-all-state' "$U" | cut -d: -f1)"
pru_line="$(grep -n '^ExecStart=.*prune-state-packs' "$U" | cut -d: -f1)"
[[ -n "$cap_line" && -n "$pru_line" ]] || fail "the unit does not run both steps"
(( cap_line < pru_line )) \
  || fail "the prune runs BEFORE the pack, so a failed pack would still delete --
that ordering IS the rule 'delete nothing on a run that failed to produce a new
pack' (line $cap_line vs $pru_line)"
# A `-` prefix on either would break the rule: systemd keeps going after a
# tolerated failure, so a failed pack would reach the prune.
grep -qE '^ExecStart=-' "$U" \
  && fail "an ExecStart is '-' prefixed, so a failed step no longer stops the unit"
grep -q 'prune-state-packs --confirm' "$U" \
  || fail "the prune step does not pass --confirm, so it would never delete"
echo "  pack at line $cap_line, prune at $pru_line, neither tolerated"

sect "the timer is Sunday 04:00, between the backup and the snapshot prune"
T="$REPO_ROOT/systemd/domum-media-state-capture.timer"
[[ -r "$T" ]] || fail "the timer file does not exist: $T"
grep -qx 'OnCalendar=Sun \*-\*-\* 04:00:00' "$T" || fail "the schedule is not Sunday 04:00: $(grep OnCalendar "$T")"
grep -qx 'Persistent=true' "$T" || fail "Persistent=true is missing"
grep -qE '^(OnBootSec|OnStartupSec)=' "$T" \
  && fail "a boot trigger would make a REBOOT a capture trigger in its own right"
echo "  Sun 04:00, Persistent, no boot trigger"

sect "the unit requires /srv/data and nothing it does not use"
grep -qx 'RequiresMountsFor=/srv/data' "$U" || fail "the protected tier is not required"
grep -qE 'RequiresMountsFor=.*(srv/media|srv/snapshots)' "$U" \
  && fail "it requires a filesystem it does not use, so that filesystem's failure
would stop a job which could have run"
echo "  /srv/data only"

echo "PASS: state pack retention smoke test"
