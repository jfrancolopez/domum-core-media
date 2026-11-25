#!/usr/bin/env bash
# A hostname the CLI reports must be the hostname Traefik actually routes.
#
# Why this suite exists. `domum-media doctor` lists "Configured hosts", and for
# uptime-kuma it printed `status.${DOMUM_DOMAIN}` while the compose label is
# Host(`status-media.${DOMUM_DOMAIN}`). Measured 2026-11-25, status-media had no
# DNS record at all -- Tailscale Split DNS sends the whole zone to the sibling
# host, which answered with its own address and served its own default
# certificate. The listing an operator would use to notice that was naming a
# hostname that does not exist, which is a report naming the wrong subject.
#
# The two spellings are in different files and nothing compared them, so this
# is the "a fact appears twice" shape: the CLI's copy drifted and the label's
# copy had a neighbour vouching for it.
set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
sect() { echo "== $* =="; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$REPO_ROOT/bin/domum-media"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Every hostname PREFIX the CLI hardcodes in its host listing, i.e. the ones of
# the form <prefix>.${DOMUM_DOMAIN}. A service whose hostname comes from a
# config variable (JELLYFIN_HOST and friends) is deliberately out of scope:
# there is no literal to compare, and the operator sets it.
#
# Comments are stripped first. A comment quoting the broken `status.` form is
# how this fix documents itself, and it must not be read as code.
cli_prefixes() {
  local src
  src="$(sed 's/#.*//' "$CLI")"
  grep -oE 'hosts\+=\("[a-z0-9_-]+\|[a-z0-9-]+\.\$\{DOMUM_DOMAIN' <<< "$src" \
    | sed -E 's/.*\|([a-z0-9-]+)\.\$\{DOMUM_DOMAIN/\1/' | sort -u
}

# Every hostname prefix any compose label routes.
label_prefixes() {
  grep -rhoE 'Host\(`[a-z0-9-]+\.\$\{DOMUM_DOMAIN\}`\)' "$REPO_ROOT/compose" 2>/dev/null \
    | sed -E 's/.*`([a-z0-9-]+)\.\$\{DOMUM_DOMAIN\}`.*/\1/' | sort -u
}

sect "1. both sides were actually extracted (this check cannot pass vacuously)"
cli_list="$(cli_prefixes)"
lab_list="$(label_prefixes)"
cli_n="$(grep -c . <<< "$cli_list" || true)"
lab_n="$(grep -c . <<< "$lab_list" || true)"
(( cli_n >= 2 )) || fail "1: extracted only $cli_n hardcoded CLI hostname(s); the pattern is stale"
(( lab_n >= 3 )) || fail "1: extracted only $lab_n compose label hostname(s); the pattern is stale"
echo "   CLI hardcodes : $(tr '\n' ' ' <<< "$cli_list")"
echo "   labels route  : $(tr '\n' ' ' <<< "$lab_list")"

sect "2. every hostname the CLI hardcodes is one a label actually routes"
missing=""
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  grep -qxF "$p" <<< "$lab_list" || missing+=" $p"
done <<< "$cli_list"
[[ -z "$missing" ]] && echo "   all agree" \
  || fail "2: the CLI reports hostname(s) no compose label routes:$missing"

sect "2b. the VARIABLE-routed hosts use the same variable on both sides"
# The other five routes are Host(`${JELLYFIN_HOST}`) and friends, and the CLI
# lists them through the same variable. That agreement is what keeps those five
# from drifting the way status-media did, so it is asserted rather than assumed.
cli_vars="$(sed 's/#.*//' "$CLI" \
  | grep -oE 'hosts\+=\("[a-z0-9_-]+\|\$\{[A-Z0-9_]+_HOST' \
  | sed -E 's/.*\$\{([A-Z0-9_]+_HOST)/\1/' | sort -u)"
lab_vars="$(grep -rhoE 'Host\(`\$\{[A-Z0-9_]+_HOST\}`\)' "$REPO_ROOT/compose" 2>/dev/null \
  | sed -E 's/.*\$\{([A-Z0-9_]+_HOST)\}.*/\1/' | sort -u)"
cv_n="$(grep -c . <<< "$cli_vars" || true)"
(( cv_n >= 5 )) || fail "2b: extracted only $cv_n variable-routed CLI host(s); the pattern is stale"
bad=""
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  grep -qxF "$v" <<< "$lab_vars" || bad+=" $v"
done <<< "$cli_vars"
[[ -z "$bad" ]] && echo "   all $cv_n agree: $(tr '\n' ' ' <<< "$cli_vars")" \
  || fail "2b: the CLI lists host variable(s) no compose label uses:$bad"

sect "3. the two known pairs are present, by name"
# Pinned explicitly so that a pattern which silently stopped matching cannot
# leave section 2 comparing an empty set against an empty set.
grep -qxF 'status-media' <<< "$cli_list" \
  || fail "3: the CLI no longer reports status-media for uptime-kuma"
grep -qxF 'status-media' <<< "$lab_list" \
  || fail "3: no compose label routes status-media"
grep -qxF 'photos' <<< "$cli_list" || fail "3: the CLI no longer reports photos"
grep -qxF 'photos' <<< "$lab_list" || fail "3: no compose label routes photos"

sect "4. NEGATIVE CONTROL: the historical 'status.' form must be caught"
# Without this, a clean verdict above is indistinguishable from a check that
# matches nothing.
cp "$CLI" "$TMP/cli.bad"
python3 - "$TMP/cli.bad" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'hosts+=("uptime-kuma|status-media.${DOMUM_DOMAIN:-}")'
assert s.count(old) == 1, "anchor matched %d times" % s.count(old)
open(p, "w").write(s.replace(old, 'hosts+=("uptime-kuma|status.${DOMUM_DOMAIN:-}")', 1))
PY
[ -s "$TMP/cli.bad" ] || fail "4: the mutation did not apply"
bad="$(CLI="$TMP/cli.bad" cli_prefixes)"
grep -qxF 'status' <<< "$bad" || fail "4: the extractor did not even see the bad form"
grep -qxF 'status' <<< "$lab_list" \
  && fail "4: 'status' is routed by a label, so this control proves nothing"
echo "   the regressed form extracts as 'status', which no label routes -> caught"

sect "5. bin/ was not written"
cmp -s "$CLI" "$REPO_ROOT/bin/domum-media" || fail "5: the CLI was modified"

echo "OK: route hostnames agree with the compose labels"
