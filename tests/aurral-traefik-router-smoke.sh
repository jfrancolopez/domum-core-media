#!/usr/bin/env bash
# The Aurral Traefik router template must render, must match the pattern every
# production router uses, and must not carry an infrastructure literal.
#
# The load-bearing check is section 3: render_traefik_dynamic() renders with an
# envsubst ALLOWLIST and then DIES on any surviving '${VAR}'. So a template that
# uses a variable the allowlist does not name does not merely render oddly -- it
# breaks `apply` and `converge`. That is checked for EVERY template, derived
# rather than hardcoded, so a future one is covered too.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYN="$ROOT/compose/proxy/traefik/dynamic"
CLI="$ROOT/bin/domum-media"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); printf '  ok    %s\n' "$*"; }
bad()  { n=$((n+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
sect() { printf '\n== %s\n' "$*"; }

command -v envsubst >/dev/null 2>&1 || { echo "SKIP: envsubst not available"; exit 0; }

TPL="$DYN/aurral.yml.tmpl"
[[ -f "$TPL" ]] || { echo "FAIL: $TPL is missing"; exit 1; }

sect "1. the template carries NO infrastructure literal"
# tests/identifier-audit.py enforces this repo-wide; asserted here too because
# this file's whole reason for being a template is to keep the LAN address out.
body="$(sed 's/#.*//' "$TPL")"
if grep -qE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$body"; then
  bad "a dotted-quad address appears in the template: $(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$body" | head -1)"
else
  ok "no dotted-quad address -- the upstream is a variable"
fi
grep -qF '${DOMUM_LAN_IP}' <<< "$body" && ok 'the upstream uses ${DOMUM_LAN_IP}' || bad 'the upstream does not use ${DOMUM_LAN_IP}'
grep -qF '${DOMUM_DOMAIN}' <<< "$body" && ok 'the host rule uses ${DOMUM_DOMAIN}' || bad 'the host rule does not use ${DOMUM_DOMAIN}'

sect "2. it matches the pattern every production router uses"
grep -qE 'certResolver:\s*cf' <<< "$body" && ok "certResolver: cf (DNS-01 via Cloudflare, as all seven services use)" || bad "certResolver is not cf"
grep -qE '^\s*-\s*websecure\s*$' <<< "$body" && ok "entryPoint websecure" || bad "entryPoint is not websecure"
grep -qE '^\s*-\s*securityHeaders\s*$' <<< "$body" && ok "securityHeaders middleware, as the others have" || bad "securityHeaders middleware missing"
grep -qE 'rule:.*Host\(`aurral\.' <<< "$body" && ok "routes Host(\`aurral.<domain>\`)" || bad "the host rule is not aurral.<domain>"
# It must NOT try to reach Aurral by container/service name: that would require
# joining domum-proxy, which takes the proxy outside the firewall's -i aurral0
# scope and voids rule 3.
grep -qE 'url:.*(aurral-experiment|aurral-proxy|host\.docker\.internal)' <<< "$body" \
  && bad "the upstream names a container or host.docker.internal -- see the comment in the template" \
  || ok "the upstream is an address:port, so no production network is joined"

sect "3. the envsubst ALLOWLIST covers every variable EVERY template uses"
allow="$(grep -oE "envsubst '[^']*'" "$CLI" | head -1 || true)"
[[ -n "$allow" ]] && ok "found the allowlist: $allow" || bad "could not find the envsubst allowlist in $CLI"
missing=0
for t in "$DYN"/*.tmpl; do
  used="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$t" | sort -u || true)"
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if grep -qF "$v" <<< "$allow"; then
      ok "$(basename "$t"): $v is in the allowlist"
    else
      bad "$(basename "$t"): $v is NOT in the allowlist -- render_traefik_dynamic would DIE and break apply"
      missing=1
    fi
  done <<< "$used"
done
(( missing == 0 )) && ok "every template variable is allowlisted" || true

sect "4. it renders with no surviving placeholder"
rendered="$(DOMUM_DOMAIN=example.test DOMUM_LAN_IP=203.0.113.9 \
  envsubst '${TRAEFIK_DASHBOARD_HOST} ${DOMUM_DOMAIN} ${DOMUM_LAN_IP}' < "$TPL")"
printf '%s' "$rendered" > "$TMP/aurral.yml"
if grep -qE '\$\{[A-Z_][A-Z0-9_]*\}' <<< "$rendered"; then
  bad "a placeholder survived: $(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' <<< "$rendered" | head -1)"
else
  ok "no placeholder survived (render_traefik_dynamic would accept it)"
fi
grep -qF 'Host(`aurral.example.test`)' <<< "$rendered" && ok "the host rule rendered" || bad "the host rule did not render"
grep -qF 'http://203.0.113.9:3001' <<< "$rendered" && ok "the upstream rendered with the port" || bad "the upstream did not render"

sect "5. the rendered YAML is valid and says what Traefik needs"
python3 -I - "$TMP/aurral.yml" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("  SKIP  PyYAML not installed; structure not parsed")
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
r = d["http"]["routers"]["aurral"]
s = d["http"]["services"]["aurral"]["loadBalancer"]["servers"]
assert r["service"] == "aurral", r
assert r["tls"]["certResolver"] == "cf", r
assert r["entryPoints"] == ["websecure"], r
assert s[0]["url"].endswith(":3001"), s
print("  ok    parsed: router -> service 'aurral', certResolver cf, 1 upstream on :3001")
PY

sect "6. the RENDERED file must be gitignored, or it blocks the deploy script"
( cd "$ROOT" && git check-ignore -q compose/proxy/traefik/dynamic/aurral.yml ) \
  && ok "rendered aurral.yml is ignored (the deploy gate aborts on untracked drift)" \
  || bad "rendered aurral.yml is NOT ignored -- it would abort the deployment script"
( cd "$ROOT" && git check-ignore -q compose/proxy/traefik/dynamic/aurral.yml.tmpl ) \
  && bad "the TEMPLATE is ignored -- it must be tracked and reviewed" \
  || ok "the template itself is tracked"

sect "7. MUTATION: drop DOMUM_LAN_IP from the allowlist -- section 3 must break"
MUT="$TMP/cli-mutant"
cp "$CLI" "$MUT"
python3 - "$MUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "envsubst '${TRAEFIK_DASHBOARD_HOST} ${DOMUM_DOMAIN} ${DOMUM_LAN_IP}'"
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, "envsubst '${TRAEFIK_DASHBOARD_HOST} ${DOMUM_DOMAIN}'", 1))
PY
if [[ $? -ne 0 ]]; then bad "7: the mutation did not apply"; else
  mallow="$(grep -oE "envsubst '[^']*'" "$MUT" | head -1 || true)"
  grep -qF '${DOMUM_LAN_IP}' <<< "$mallow" \
    && bad "the mutant still allowlists DOMUM_LAN_IP" \
    || ok "the mutant drops it, so section 3 would fail -- the allowlist check bites"
  mrender="$(DOMUM_DOMAIN=example.test DOMUM_LAN_IP=203.0.113.9 eval "${mallow} < '$TPL'")"
  grep -qF '${DOMUM_LAN_IP}' <<< "$mrender" \
    && ok "and the placeholder survives rendering, which render_traefik_dynamic treats as fatal" \
    || bad "the mutant rendered cleanly, so the allowlist is not what resolves the upstream"
fi

printf '\n%s checks, %s failures\n' "$n" "$fails"
[[ "$fails" -eq 0 ]] || exit 1
