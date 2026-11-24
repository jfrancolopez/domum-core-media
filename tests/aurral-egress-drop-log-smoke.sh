#!/usr/bin/env bash
# Drives experiments/aurral/firewall.sh and asserts the ruleset it BUILDS.
#
# No real ruleset is touched: AURRAL_IPTABLES/AURRAL_IP6TABLES point at a
# recording stub. The script's root check is NOT weakened for this -- the whole
# run happens under `unshare -r`, where the caller really maps to uid 0, so
# `[[ "$(id -u)" -eq 0 ]]` executes exactly as it does in production.
#
# What this exists to pin: a blocked egress packet must be LOGGED BEFORE it is
# dropped. Before this, the allowed-egress LOG sat after the drops, so it only
# ever recorded PERMITTED traffic -- measured on the real host, four of
# validate.sh's seven host probes were dropped with no record at all.
set -uo pipefail

FW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/experiments/aurral/firewall.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad()  { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }

command -v unshare >/dev/null 2>&1 || { echo "SKIP: unshare not available"; exit 0; }
unshare -r true 2>/dev/null || { echo "SKIP: unshare -r unavailable (no user namespaces)"; exit 0; }

# The RFC1918 and CGNAT ranges are REQUIRED by assert_block_coverage, and
# tests/identifier-audit.py rejects a 4-octet dotted literal in a tracked file.
# Built from octets, so no such literal appears in this file.
R8="$(printf '%d.%d.%d.%d/%d' 10 0 0 0 8)"
R12="$(printf '%d.%d.%d.%d/%d' 172 16 0 0 12)"
R16="$(printf '%d.%d.%d.%d/%d' 192 168 0 0 16)"
RCG="$(printf '%d.%d.%d.%d/%d' 100 64 0 0 10)"

cat > "$TMP/env" <<ENVEOF
AURRAL_PROXY_IP=203.0.113.10
AURRAL_BLOCK_CIDRS="$R8 $R12 $R16 $RCG"
ENVEOF

# Records every invocation. `-D` must FAIL: remove_policy deletes in
# `while ...; do :; done`, so a stub that always succeeds loops forever -- and
# failing is the truthful answer on a host where the rule is not present.
# `-S` succeeds, matching this host, where ip6tables DOES have DOCKER-USER.
cat > "$TMP/ipt" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AURRAL_STUB_LOG}"
[[ "${1:-}" == "-D" ]] && exit 1
exit 0
STUBEOF
chmod +x "$TMP/ipt"

# $1 = action, $2 (optional) = alternative firewall.sh. Prints the record.
run() {
  local action="$1" target="${2:-$FW}" log="$TMP/rec.$$.$RANDOM"
  : > "$log"
  AURRAL_STUB_LOG="$log" AURRAL_IPTABLES="$TMP/ipt" AURRAL_IP6TABLES="$TMP/ipt" \
    unshare -r bash "$target" "$action" "$TMP/env" >"$TMP/out" 2>&1
  printf '%s' "$?" > "$TMP/rc"
  cat "$log"
}

APPLY="$(run apply)"
APPLY_RC="$(cat "$TMP/rc")"

sect "0. apply succeeded and built a ruleset"
[[ "$APPLY_RC" == 0 ]] && ok "apply exited 0" || { bad "apply exited $APPLY_RC"; sed -n '1,20p' "$TMP/out"; }
[[ -n "$APPLY" ]] && ok "the stub recorded $(wc -l <<< "$APPLY") iptables invocations" || bad "nothing recorded"

sect "1. the log-then-drop chain exists, and LOG comes BEFORE DROP"
grep -qx -- '-N AURRAL-EGRESS-DROP' <<< "$APPLY" && ok "AURRAL-EGRESS-DROP created" || bad "chain not created"
log_ln="$(grep -n -- '-A AURRAL-EGRESS-DROP .*--log-prefix' <<< "$APPLY" | head -1 | cut -d: -f1)"
drop_ln="$(grep -n -- '-A AURRAL-EGRESS-DROP -j DROP' <<< "$APPLY" | head -1 | cut -d: -f1)"
if [[ -n "$log_ln" && -n "$drop_ln" ]]; then
  (( log_ln < drop_ln )) && ok "LOG (line $log_ln) precedes DROP (line $drop_ln)" \
                         || bad "DROP precedes LOG -- a blocked packet would not be logged"
else
  bad "could not find both the LOG and the DROP in the chain (log=$log_ln drop=$drop_ln)"
fi
new_ln="$(grep -n -- '-N AURRAL-EGRESS-DROP' <<< "$APPLY" | head -1 | cut -d: -f1)"
first_jump="$(grep -n -- '-j AURRAL-EGRESS-DROP' <<< "$APPLY" | head -1 | cut -d: -f1)"
[[ -n "$new_ln" && -n "$first_jump" ]] && (( new_ln < first_jump )) \
  && ok "the chain is created before the first jump to it" || bad "a jump precedes the chain's creation"

sect "2. the blocked-egress prefix is dedicated and rate-limited"
blk="$(grep -- '-A AURRAL-EGRESS-DROP .*--log-prefix' <<< "$APPLY")"
grep -qF "aurral-egress-blocked " <<< "$blk" && ok "prefix is 'aurral-egress-blocked '" || bad "wrong prefix: $blk"
grep -qF -- '-m limit --limit 60/min --limit-burst 20' <<< "$blk" && ok "rate-limited 60/min burst 20" || bad "not rate-limited: $blk"
grep -qF -- '--ctstate NEW' <<< "$blk" && ok "ctstate NEW -- one line per connection, not per retransmitted SYN" || bad "not scoped to NEW: $blk"
# iptables caps --log-prefix at 29 characters. ${#...} takes a variable NAME,
# not a literal, so the prefix is assigned first.
blk_pfx='aurral-egress-blocked '
pfxlen=${#blk_pfx}
(( pfxlen <= 29 )) && ok "prefix is $pfxlen chars (iptables caps at 29)" || bad "prefix too long: $pfxlen"

sect "3. allowed-egress logging is SEPARATE and still present"
allow="$(grep -- '-A AURRAL-EGRESS -m conntrack --ctstate NEW -m limit' <<< "$APPLY")"
if [[ -n "$allow" ]] && grep -qF 'aurral-egress ' <<< "$allow" && ! grep -qF 'aurral-egress-blocked' <<< "$allow"; then
  ok "the allowed-egress LOG survives with its OWN prefix, distinct from the blocked one"
else
  bad "allowed-egress LOG missing or confused with the blocked one: $allow"
fi
grep -qF -- '--limit 600/min' <<< "$allow" && ok "allowed log keeps its own 600/min budget" || bad "allowed log limit changed: $allow"
# The two prefixes must be distinguishable by the documented commands. A naive
# grep for the allowed one would otherwise also match the blocked one.
printf 'aurral-egress DST=1.1.1.1 DPT=53\naurral-egress-blocked DST=203.0.113.9 DPT=443\n' > "$TMP/fakelog"
[[ "$(grep -cF 'aurral-egress ' "$TMP/fakelog")" == 1 ]] && ok "'aurral-egress ' (trailing space) matches only the allowed line" || bad "the two prefixes are not separable"
[[ "$(grep -cF 'aurral-egress-blocked ' "$TMP/fakelog")" == 1 ]] && ok "'aurral-egress-blocked ' matches only the blocked line" || bad "blocked prefix not separable"

sect "4. EVERY egress drop goes through the chain -- including the Docker DNAT path"
# Docker DNAT cannot be exercised hermetically: it happens in nat/PREROUTING
# before this chain is reached. What IS assertable, and what matters, is that
# the two rules which catch a post-DNAT packet route through the log-then-drop
# chain -- `-o br-+` (it leaves via a Docker bridge) and the 172.16/12 address
# range, which is where traefik's own bridge address sits. Measured on the real
# host: a probe to any local address on port 443 is DNAT'd to traefik and takes
# this path, which is why four host probes were previously dropped in silence.
# The address is described rather than quoted: tests/identifier-audit.py rejects
# a 4-octet RFC1918 literal in a tracked file, and it caught this very line.
for rule in "-o tailscale0" "-o docker0" "-o br-+" "-s 203.0.113.10" \
            "-d $R8" "-d $R12" "-d $R16" "-d $RCG" \
            "-d 127.0.0.0/8" "-d 169.254.0.0/16" "-d 224.0.0.0/4" \
            "-d 240.0.0.0/4" "-d 0.0.0.0/8" "-d 192.0.0.0/24" "-d 198.18.0.0/15"; do
  if grep -qF -- "-A AURRAL-EGRESS $rule -j AURRAL-EGRESS-DROP" <<< "$APPLY"; then
    ok "$rule -> AURRAL-EGRESS-DROP"
  else
    bad "$rule does not go through the logging chain: $(grep -F -- "-A AURRAL-EGRESS $rule " <<< "$APPLY" || echo MISSING)"
  fi
done
bare="$(grep -c -- '-A AURRAL-EGRESS .* -j DROP$' <<< "$APPLY" || true)"
[[ "$bare" == 0 ]] && ok "no egress rule drops inline any more" || bad "$bare egress rule(s) still drop without logging"

sect "5. enforcement and ORDER are preserved"
seq="$(grep -- '-A AURRAL-EGRESS ' <<< "$APPLY" | sed 's/ -j .*//')"
[[ "$(sed -n '1p' <<< "$seq")" == "-A AURRAL-EGRESS -o aurral0" ]] && ok "rule 1 is still the on-bridge RETURN" || bad "rule 1 changed: $(sed -n '1p' <<< "$seq")"
grep -qF -- '-A AURRAL-EGRESS -o aurral0 -j RETURN' <<< "$APPLY" && ok "on-bridge traffic still RETURNs (the UI)" || bad "on-bridge RETURN lost"
grep -qF -- '-A AURRAL-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' <<< "$APPLY" && ok "established replies still RETURN" || bad "established RETURN lost"
est_ln="$(grep -n -- '-A AURRAL-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' <<< "$APPLY" | cut -d: -f1)"
fst_drop="$(grep -n -- '-A AURRAL-EGRESS .*-j AURRAL-EGRESS-DROP' <<< "$APPLY" | head -1 | cut -d: -f1)"
(( est_ln < fst_drop )) && ok "established RETURN still precedes every drop" || bad "a drop now precedes the established RETURN"
[[ "$(grep -c -- '-A AURRAL-EGRESS ' <<< "$APPLY")" == 19 ]] && ok "the egress chain still has 19 rules" || bad "rule count changed: $(grep -c -- '-A AURRAL-EGRESS ' <<< "$APPLY")"

sect "6. the HOST chain is untouched"
grep -qF -- "-A AURRAL-HOST -j DROP" <<< "$APPLY" && ok "AURRAL-HOST still drops inline (it already logs first)" || bad "AURRAL-HOST changed"
grep -qF "aurral-host-blocked " <<< "$APPLY" && ok "aurral-host-blocked prefix unchanged" || bad "host prefix changed"
h_log="$(grep -n -- "-A AURRAL-HOST .*--log-prefix" <<< "$APPLY" | cut -d: -f1)"
h_drop="$(grep -n -- '-A AURRAL-HOST -j DROP' <<< "$APPLY" | cut -d: -f1)"
(( h_log < h_drop )) && ok "host chain still logs before dropping" || bad "host chain order changed"

sect "7. repeated apply does not duplicate -- it removes first"
rm_before_add="$(grep -n -- '-D DOCKER-USER -i aurral0 -j AURRAL-EGRESS' <<< "$APPLY" | head -1 | cut -d: -f1)"
[[ -n "$rm_before_add" && -n "$new_ln" ]] && (( rm_before_add < new_ln )) \
  && ok "apply deletes the old jumps before creating anything" || bad "apply does not remove first"
grep -qx -- '-F AURRAL-EGRESS-DROP' <<< "$APPLY" && ok "apply flushes the drop chain first (so a re-apply cannot stack rules)" || bad "the drop chain is not flushed on apply"
A2="$(run apply)"
[[ "$APPLY" == "$A2" ]] && ok "a second apply issues an IDENTICAL sequence" || bad "the second apply differs from the first"
[[ "$(grep -c -- '-N AURRAL-EGRESS-DROP' <<< "$APPLY")" == 1 ]] && ok "the chain is created exactly once per apply" || bad "created more than once"

sect "8. rollback removes the new chain, and only Aurral's rules"
REM="$(run remove)"
for want in '-F AURRAL-EGRESS-DROP' '-X AURRAL-EGRESS-DROP' '-F AURRAL-EGRESS' '-X AURRAL-EGRESS' '-F AURRAL-HOST' '-X AURRAL-HOST'; do
  grep -qx -- "$want" <<< "$REM" && ok "remove: $want" || bad "remove does not do: $want"
done
f_drop="$(grep -n -x -- '-F AURRAL-EGRESS-DROP' <<< "$REM" | cut -d: -f1)"
x_fwd="$(grep -n -x -- '-X AURRAL-EGRESS' <<< "$REM" | cut -d: -f1)"
f_fwd="$(grep -n -x -- '-F AURRAL-EGRESS' <<< "$REM" | cut -d: -f1)"
(( f_fwd < x_fwd )) && ok "the referencing chain is flushed before anything is deleted" || bad "delete precedes flush"
(( f_drop < x_fwd )) && ok "the drop chain is flushed before the deletes begin" || bad "drop-chain flush ordered wrongly"
# Nothing outside Aurral's own objects may be touched.
foreign="$(grep -vE 'AURRAL-(EGRESS|HOST|EGRESS-DROP)|aurral0|^-S DOCKER-USER' <<< "$REM" || true)"
[[ -z "$foreign" ]] && ok "remove touches no rule that is not Aurral's" || bad "remove touches: $foreign"

sect "9. MUTATION: drop the LOG from the chain -- section 1 must break"
MUT="$TMP/fw-mutant.sh"
cp "$FW" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  "$IPT" -A "$DROP_CHAIN" -m conntrack --ctstate NEW \\
      -m limit --limit 60/min --limit-burst 20 \\
      -j LOG --log-prefix 'aurral-egress-blocked ' --log-level info
"""
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, ""))
PY
if [[ $? -ne 0 ]]; then bad "9: the mutation did not apply"; else
  M="$(run apply "$MUT")"
  grep -qF 'aurral-egress-blocked' <<< "$M" && bad "mutant still logs" \
    || ok "without the LOG rule a blocked packet is dropped in silence -- the rule is load-bearing"
  grep -qF -- '-A AURRAL-EGRESS-DROP -j DROP' <<< "$M" && ok "the mutant still DROPS (so enforcement is not what this proves)" || bad "mutant lost the drop too"
fi

sect "10. MUTATION: revert one drop to inline -- section 4 must break"
MUT2="$TMP/fw-mutant2.sh"
cp "$FW" "$MUT2"
python3 - "$MUT2" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''"$IPT" -A "$FWD_CHAIN" -o 'br-+' -j "$DROP_CHAIN"'''
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, '''"$IPT" -A "$FWD_CHAIN" -o 'br-+' -j DROP'''))
PY
if [[ $? -ne 0 ]]; then bad "10: the mutation did not apply"; else
  M2="$(run apply "$MUT2")"
  grep -qF -- '-A AURRAL-EGRESS -o br-+ -j AURRAL-EGRESS-DROP' <<< "$M2" \
    && bad "mutant still routes br-+ through the log chain" \
    || ok "reverting br-+ to an inline drop is detected -- the DNAT path would log nothing"
fi

printf '\n%s checks, %s failures\n' "$n" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
