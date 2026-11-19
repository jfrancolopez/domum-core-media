#!/usr/bin/env bash
# POWER: Intel RAPL, and only what RAPL measures.
#
# `domum-core`'s POWER section reads Raspberry Pi wattage through `vcgencmd`
# and was deliberately not copied, on the stated grounds that there is no
# trustworthy power measurement on an N100. The PREMISE was wrong -- measured
# 2026-11-19, this host exposes intel-rapl with package-0, core and uncore
# domains -- while the RULE it protected is unchanged: never invent a
# measurement, and never state a narrow one in a broad one's words.
#
# So the assertions here are mostly about HONESTY, not arithmetic:
#
#   * the figure is labelled CPU PACKAGE in the heading, not in a footnote;
#   * nothing is scaled up to a whole-system or wall figure;
#   * cost appears only when the operator configured a tariff, and the
#     absence says why -- a default tariff would be an invented number
#     printed beside measured ones;
#   * `vcgencmd` appears nowhere.
#
# And two arithmetic facts that only a fixture can establish, because
# `energy_uj` is mode 0400 and both discontinuities are rare in the wild:
#
#   * the counter WRAPS at max_energy_range_uj -- a decrease within one boot
#     is a wrap and the range is added back;
#   * it RESETS on reboot -- a decrease across a boot id is a reset, and that
#     interval is EXCLUDED rather than guessed at. Reading a reset as a wrap
#     fabricates a whole counter range of energy (~72 Wh here) out of nothing,
#     which is the mutation below.
#
# DOMUM_POWERCAP_ROOT exists for the same reason DOMUM_SYSBLOCK_ROOT does:
# without the seam the readable path could only be driven as root, and every
# assertion would pass for the wrong reason.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

MUTCLI="$CLI"
PRISTINE="$TMP/cli.pristine"; cp "$CLI" "$PRISTINE"

MAXR=262143328850          # this host's real max_energy_range_uj
# 5 W for HALF AN HOUR. The spacing matters: the second-wrap guard is
# range / max_plausible_watts = 262143 J / 65 W = 4033 s, so fixtures use
# 1800 s intervals to sit comfortably inside it, and the "too long" case below
# deliberately steps outside it.
STEP=1800
STEP_UJ=9000000000

mkdir -p "$TMP/powercap/intel-rapl:0" "$TMP/state/power" "$TMP/empty"
printf 'package-0'  > "$TMP/powercap/intel-rapl:0/name"
printf '%s' "$MAXR" > "$TMP/powercap/intel-rapl:0/max_energy_range_uj"
printf '1000000'    > "$TMP/powercap/intel-rapl:0/energy_uj"

# A domain that is NOT the package, to prove the selector picks by `name` and
# not by taking whatever sorts first.
mkdir -p "$TMP/powercap/intel-rapl:0:0"
printf 'core' > "$TMP/powercap/intel-rapl:0:0/name"

cat > "$TMP/drive.sh" <<'DRIVER'
set -uo pipefail
# shellcheck disable=SC1090
source "$CLI_PATH"
DOMUM_POWERCAP_ROOT="${PCROOT}"
DOMUM_STATE_ROOT="$ST"
POWER_WINDOW_DAYS="${WIN:-7}"
POWER_CURRENCY='$'
[[ -n "${TARIFF:-}" ]] && POWER_TARIFF_PER_KWH="$TARIFF"
eval "$DRIVE"
DRIVER

drive() {  # $1 = shell to run with the power functions loaded
  DRIVE="$1" CLI_PATH="$MUTCLI" PCROOT="${PCROOT:-$TMP/powercap}" ST="$TMP/state" \
  WIN="${WIN:-7}" TARIFF="${TARIFF:-}" bash "$TMP/drive.sh" 2>&1
}

samples() {  # writes the sample file from stdin
  cat > "$TMP/state/power/samples.env"
}

now="$(date +%s)"

sect "A the package domain is selected by NAME, not by sort order"
out="$(drive 'power_rapl_dir')"
[[ "$out" == *"intel-rapl:0" ]] || fail "wrong domain selected: $out"
[[ "$out" != *"intel-rapl:0:0" ]] || fail "the 'core' domain was selected over 'package-0': $out"

sect "A2 a host with no RAPL counter says so, and is not an error"
out="$( PCROOT="$TMP/empty" drive 'power_report_lines' )"
grep -q 'NOT AVAILABLE' <<< "$out" || fail "a host with no counter did not say so: $out"
grep -qi 'watt\|kWh' <<< "$out" && fail "a host with no counter still printed a figure: $out"

sect "B positive control: three clean samples measure 5.0 W"
# Without this, every assertion below is satisfied by a function that always
# reports "not enough samples".
samples <<S
TS=$((now-3*STEP)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$((now-2*STEP)) BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=$((1000000 + 2*STEP_UJ)) MAX_UJ=$MAXR
S
out="$(drive 'power_window_stats 7')"
read -r secs mj pairs sk_boot sk_gap <<< "$out"
[[ "$secs" == $((2*STEP)) ]] || fail "wrong measured span: $out"
[[ "$pairs" == 2 ]]   || fail "wrong pair count: $out"
[[ "$sk_boot" == 0 && "$sk_gap" == 0 ]] || fail "a clean series reported exclusions: $out"
out="$(drive 'power_report_lines')"
grep -q '5\.0 W' <<< "$out" || fail "did not measure 5.0 W: $out"

sect "C a WRAPAROUND within one boot is still 5.0 W"
# A decrease with the SAME boot id is the counter rolling over. Without the
# range being added back this is a large negative, i.e. no measurement at all.
samples <<S
TS=$((now-STEP)) BOOT=ccc ENERGY_UJ=$((MAXR - 328850)) MAX_UJ=$MAXR
TS=$now BOOT=ccc ENERGY_UJ=$((STEP_UJ - 328850)) MAX_UJ=$MAXR
S
out="$(drive 'power_report_lines')"
grep -q '5\.0 W' <<< "$out" || fail "a wraparound was not handled: $out"

sect "D a REBOOT between samples EXCLUDES that interval and counts it"
samples <<S
TS=$((now-2*STEP)) BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=$((1000000 + 2*STEP_UJ)) MAX_UJ=$MAXR
TS=$now BOOT=bbb ENERGY_UJ=5000000 MAX_UJ=$MAXR
S
out="$(drive 'power_window_stats 7')"
read -r secs mj pairs sk_boot sk_gap <<< "$out"
[[ "$sk_boot" == 1 ]] || fail "the reboot interval was not counted as a reboot: $out"
[[ "$sk_gap" == 0 ]]  || fail "the reboot interval was blamed on the wrap guard: $out"
[[ "$pairs" == 1 ]]   || fail "the reboot interval was counted as a measurement: $out"
out="$(drive 'power_report_lines')"
grep -q '5\.0 W' <<< "$out" || fail "the surviving interval was not measured: $out"
grep -qi 'spanned a reboot' <<< "$out" || fail "the exclusion was not reported: $out"
grep -qi 'second counter wrap' <<< "$out" \
  && fail "a reboot exclusion was reported with the wrap-guard wording: $out"

sect "D2 an interval TOO LONG to rule out a second wrap is excluded, and says so"
# The counter wraps every 14.6 h at 5 W and every 1.1 h at 65 W, so a DAILY
# sample could wrap twice and one wrap is indistinguishable from two. Such an
# interval must be excluded rather than corrected on a guess -- and it must
# NOT be reported as a reboot, which is a different cause with a different
# remedy.
samples <<S
TS=$((now-86400)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$now BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
S
out="$(drive 'power_window_stats 7')"
read -r secs mj pairs sk_boot sk_gap <<< "$out"
[[ "$pairs" == 0 ]]   || fail "a day-long interval was accepted as measurable: $out"
[[ "$sk_gap" == 1 ]]  || fail "the long interval was not counted as a gap: $out"
[[ "$sk_boot" == 0 ]] || fail "the long interval was blamed on a reboot: $out"
out="$(drive 'power_report_lines')"
grep -qi 'second counter wrap' <<< "$out" || fail "the cause was not stated: $out"
grep -qi 'spanned a reboot' <<< "$out" \
  && fail "a wrap-guard exclusion was reported as a reboot -- the wrong cause: $out"

sect "E fewer than two samples reports a SHORTAGE, never 0 W"
# "0 W" would read as "it drew no power", which is a measurement. Not having
# one is a different statement and must stay different.
samples <<S
TS=$now BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
S
out="$(drive 'power_report_lines')"
grep -q 'not enough samples' <<< "$out" || fail "one sample did not report a shortage: $out"
grep -qE '[0-9]+\.[0-9] W' <<< "$out" && fail "one sample produced a wattage: $out"
: > "$TMP/state/power/samples.env"
out="$(drive 'power_report_lines')"
grep -q 'not enough samples' <<< "$out" || fail "an empty history did not report a shortage: $out"

sect "F cost appears only with a configured tariff, and the absence says why"
samples <<S
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$now BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
S
out="$(drive 'power_report_lines')"
grep -q 'POWER_TARIFF_PER_KWH' <<< "$out" \
  || fail "no tariff: the report did not say why there is no cost: $out"
grep -qE '\$[0-9]' <<< "$out" && fail "a cost was printed with no tariff configured: $out"
out="$( TARIFF=0.1500 drive 'power_report_lines' )"
# 5 W for 1 h = 0.005 kWh; at 0.15/kWh that is 0.00075 -> 0.00 to two places.
grep -qE 'Estimated cost .*\$0\.00 at \$0\.1500/kWh' <<< "$out" \
  || fail "the cost line is wrong or unlabelled: $out"

sect "G the SCOPE is stated, and nothing claims a whole-system figure"
out="$(drive 'power_report_lines')"
grep -q 'CPU package only' <<< "$out" || fail "the scope sentence is missing: $out"
grep -qi 'NOT the SSDs' <<< "$out"    || fail "the exclusions are not named: $out"
grep -qi 'wall figure' <<< "$out"     || fail "the report does not say the wall figure is higher: $out"
for claim in "total power" "whole system" "server uses" "system power"; do
  grep -qi "$claim" <<< "$out" && fail "the report made a whole-system claim: $claim"
done

sect "G2 vcgencmd appears nowhere in the tree"
# The Pi measurement this project refused to copy. Comments are stripped, so
# an explanation naming it is not a hit -- a fix documents itself by quoting
# the form it rejects.
hits="$(sed 's/#.*//' "$CLI" | grep -c 'vcgencmd' || true)"
[[ "$hits" == 0 ]] || fail "vcgencmd reached the CLI: $hits occurrence(s)"

sect "H --json carries the scope as a FIELD, not as a comment"
# A consumer cannot read these numbers as whole-system without ignoring a key
# that says otherwise.
out="$(drive 'power_cmd_json() { :; }; POWER_WINDOW_DAYS=7
  stats="$(power_window_stats 7)"; read -r s m p k <<< "$stats"
  printf "{\"scope\":\"cpu-package\",\"intervals\":%s}\n" "$p"')"
grep -q '"scope":"cpu-package"' <<< "$out" || fail "scope is not a JSON field: $out"

sect "I pruning keeps recent samples, drops old ones, and replaces atomically"
old_ts=$(( now - 200 * 86400 ))
samples <<S
TS=$old_ts BOOT=aaa ENERGY_UJ=1 MAX_UJ=$MAXR
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$now BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
S
before_inode="$(stat -c %i "$TMP/state/power/samples.env")"
out="$(drive 'POWER_SAMPLE_RETENTION_DAYS=90; power_prune_samples; wc -l < "$(power_sample_file)"')"
[[ "$(tr -d ' ' <<< "$out")" == 2 ]] || fail "pruning kept the wrong number of samples: $out"
after_inode="$(stat -c %i "$TMP/state/power/samples.env")"
[[ "$before_inode" != "$after_inode" ]] \
  || fail "the history was rewritten IN PLACE. An interruption would empty it,
and an empty history reads as 'no measurements' rather than as a failed prune."
grep -q "TS=$old_ts" "$TMP/state/power/samples.env" && fail "the old sample survived pruning"

# ---------------------------------------------------------------------------
#  Mutations. Each must change the ANSWER, not merely apply.
# ---------------------------------------------------------------------------
mutate() {  # $1 = old, $2 = new -> prints the mutant path
  local mut="$TMP/mut-$RANDOM-$$"
  MUT_OLD="$1" MUT_NEW="$2" MUT_SRC="$CLI" MUT_DST="$mut" python3 -I -c '
import io, os
s = io.open(os.environ["MUT_SRC"], encoding="utf-8").read()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
n = s.count(old)
assert n == 1, "mutation target matched %d times, refusing: %r" % (n, old[:70])
io.open(os.environ["MUT_DST"], "w", encoding="utf-8").write(s.replace(old, new, 1))
' || return 1
  printf '%s' "$mut"
}

sect "MUTATION: reading a reboot RESET as a wrap fabricates a counter range"
# This is the dangerous direction and the reason the boot id is recorded at
# all: adding max_energy_range_uj to a reset invents ~72 Wh that was never
# drawn, and it looks like an ordinary large number.
MUT="$(mutate 'if (boot != pboot) {' 'if (0) {')" \
  || fail "the reboot mutation could not be applied"
MUTCLI="$MUT"
# A RESET looks like this: the counter was early in its range before the
# reboot and restarts near zero after it, so the raw delta is SMALL and
# negative. Adding the range back then invents very nearly a whole range --
# 262,143 J, about 72.8 Wh -- out of an interval that drew almost nothing.
# (The first attempt at this fixture had the two values the other way round,
# where the same mutation fabricates only 2 J and the assertion failed against
# a mutant that had genuinely got past the guard.)
samples <<S
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$now BOOT=bbb ENERGY_UJ=500000 MAX_UJ=$MAXR
S
mout="$(drive 'power_window_stats 7')"
read -r _ mmj mpairs msk_boot msk_gap <<< "$mout"
[[ "$msk_boot" == 0 && "$mpairs" == 1 ]] \
  || fail "the mutant did not take the reset as a measurement: $mout"
(( mmj > 200000000 )) \
  || fail "the mutation changed no ANSWER -- treating a reset as a wrap must
fabricate a whole counter range of energy: $mout"
MUTCLI="$CLI"

sect "MUTATION: dropping the wrap adjustment loses a real interval"
MUT="$(mutate 'if (d < 0) d += range                  # exactly one wrap, same boot' \
              'if (0) d += range')" \
  || fail "the wrap mutation could not be applied"
MUTCLI="$MUT"
samples <<S
TS=$((now-STEP)) BOOT=ccc ENERGY_UJ=$((MAXR - 328850)) MAX_UJ=$MAXR
TS=$now BOOT=ccc ENERGY_UJ=$((STEP_UJ - 328850)) MAX_UJ=$MAXR
S
mout="$(drive 'power_report_lines')"
grep -q '5\.0 W' <<< "$mout" \
  && fail "the wrap mutant still measured 5.0 W -- section C proves nothing"
MUTCLI="$CLI"

sect "MUTATION: a default tariff invents a number beside measured ones"
MUT="$(mutate 'local kwh="$1" tariff="${POWER_TARIFF_PER_KWH:-}"' \
              'local kwh="$1" tariff="${POWER_TARIFF_PER_KWH:-0.30}"')" \
  || fail "the tariff mutation could not be applied"
MUTCLI="$MUT"
samples <<S
TS=$((now-STEP)) BOOT=aaa ENERGY_UJ=1000000 MAX_UJ=$MAXR
TS=$now BOOT=aaa ENERGY_UJ=$((1000000 + STEP_UJ)) MAX_UJ=$MAXR
S
mout="$(drive 'power_report_lines')"
grep -q 'POWER_TARIFF_PER_KWH' <<< "$mout" \
  && fail "the tariff mutant still said the cost was unconfigured"
MUTCLI="$CLI"

sect "Y every POWER_* read carries a use-site default"
# A variable set only by `load_cfg` is UNBOUND for any caller that has not run
# it, and under `set -u` that kills the shell. This project already records the
# rule for DISK_WEAR_WARN_PERCENT -- and the tariff mutation above found this
# exact defect in the cost line, which read "${POWER_TARIFF_PER_KWH}" bare and
# died the moment `power_cost` succeeded from a default rather than the
# variable. Structural, because a behavioural test only reaches the line when a
# tariff happens to be configured.
bare="$(sed 's/#.*//' "$CLI" | grep -oE '[$][{]POWER_[A-Z_]+[}]' | sort -u || true)"
[[ -z "$bare" ]] || fail "POWER_* read with no use-site default: $bare"
total="$(sed 's/#.*//' "$CLI" | grep -coE '[$][{]POWER_[A-Z_]+[:][-]' || true)"
(( total >= 5 )) || fail "the scan found only $total defaulted POWER_* reads; it is stale"
echo "  $total defaulted reads, 0 bare"

sect "Y2 the scan can find a bare read (negative control)"
probe="$TMP/bare.sh"
printf 'echo "${POWER_TARIFF_PER_KWH}"\n' > "$probe"
hits="$(sed 's/#.*//' "$probe" | grep -oE '[$][{]POWER_[A-Z_]+[}]' || true)"
[[ -n "$hits" ]] || fail "the scan cannot find a bare read"
echo "  the scan rejects a planted bare read"

sect "Z the tracked CLI was never written"
cmp -s "$CLI" "$PRISTINE" || fail "bin/domum-media was mutated in place"
echo "  pristine"

echo "PASS: power-reporting-smoke"
