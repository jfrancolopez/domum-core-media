#!/usr/bin/env bash
# Egress policy for the Aurral experiment.
#
# WHY THIS EXISTS. Aurral is given outbound internet access, and a NAT bridge
# cannot express "internet yes, private no": it reaches the LAN, the tailnet,
# the other Docker networks and every host port bound on 0.0.0.0 just as
# readily as it reaches the internet. On this host those are 22, 80, 443 and
# 111 (rpcbind). So the isolation is firewall-enforced, and this is the whole
# of it.
#
# WHAT IT TOUCHES. Two custom chains and four jump rules, every one of them
# scoped to the interface `aurral0` -- a bridge that exists only for this
# experiment. No production rule is read, moved, flushed or replaced, and no
# new firewall framework is introduced: DOCKER-USER is Docker's own documented
# hook, consulted before its own FORWARD rules and never flushed by it.
#
# Container -> other hosts is FORWARD, so DOCKER-USER covers it.
# Container -> THIS host is INPUT, which DOCKER-USER never sees -- hence the
# second chain. Missing that distinction is how a container keeps reaching
# sshd through a firewall that looks complete.
#
#   firewall.sh apply  [env-file]   install the policy (idempotent)
#   firewall.sh remove [env-file]   take it out again
#   firewall.sh show   [env-file]   print the live rules and their counters
#
# Apply BEFORE `up -d` and remove AFTER `down`: the rules match an interface
# name, which iptables accepts whether or not the interface exists yet, so
# the policy can be in place before anything can send a packet.
set -euo pipefail

BRIDGE=aurral0
FWD_CHAIN=AURRAL-EGRESS
IN_CHAIN=AURRAL-HOST
# Blocked whatever the operator lists, because none of these is a legitimate
# destination for an application and none of them is an RFC1918 or CGNAT
# literal (which this repository's identifier audit rejects in tracked files,
# so the private ranges come from the env file instead).
ALWAYS_BLOCK=(
  127.0.0.0/8        # loopback
  169.254.0.0/16     # link-local, and the cloud metadata address inside it
  224.0.0.0/4        # multicast
  240.0.0.0/4        # reserved
  0.0.0.0/8          # this network
  192.0.0.0/24       # IETF protocol assignments
  198.18.0.0/15      # benchmarking
)

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root (use sudo)."

ACTION="${1:-}"
ENV_FILE="${2:-/srv/data/experiments/aurral/aurral.env}"
case "$ACTION" in apply|remove|show) ;; *) die "usage: $0 {apply|remove|show} [env-file]" ;; esac

IPT="$(command -v iptables || echo /usr/sbin/iptables)"
IPT6="$(command -v ip6tables || echo /usr/sbin/ip6tables)"
[[ -x "$IPT" ]] || die "iptables not found"

# ---------------------------------------------------------------------------
# The ranges Aurral must not reach are infrastructure facts about THIS host,
# so they live in the untracked env file beside the addresses. A missing or
# empty list refuses: applying a policy whose block list is empty would open
# the LAN while reporting success.
# ---------------------------------------------------------------------------
read_block_cidrs() {
  [[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${AURRAL_BLOCK_CIDRS:?set AURRAL_BLOCK_CIDRS in $ENV_FILE (see aurral.env.example)}"
  : "${AURRAL_PROXY_IP:?set AURRAL_PROXY_IP in $ENV_FILE}"
  read -r -a BLOCK_CIDRS <<< "$AURRAL_BLOCK_CIDRS"
  [[ "${#BLOCK_CIDRS[@]}" -ge 4 ]] \
    || die "AURRAL_BLOCK_CIDRS lists ${#BLOCK_CIDRS[@]} range(s); the three RFC1918 ranges and the CGNAT range are the minimum"
  local c
  for c in "${BLOCK_CIDRS[@]}"; do
    [[ "$c" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "not a CIDR: $c"
  done
}

ipv6_forward_chain() {
  # Docker creates DOCKER-USER in ip6tables when ip6tables support is on. If
  # it is absent, fall back to FORWARD rather than skipping IPv6 silently.
  if "$IPT6" -S DOCKER-USER >/dev/null 2>&1; then printf 'DOCKER-USER'; else printf 'FORWARD'; fi
}

remove_policy() {
  local v6fwd; v6fwd="$(ipv6_forward_chain)"
  while "$IPT" -D DOCKER-USER -i "$BRIDGE" -j "$FWD_CHAIN" 2>/dev/null; do :; done
  while "$IPT" -D INPUT -i "$BRIDGE" -j "$IN_CHAIN" 2>/dev/null; do :; done
  "$IPT" -F "$FWD_CHAIN" 2>/dev/null || true
  "$IPT" -X "$FWD_CHAIN" 2>/dev/null || true
  "$IPT" -F "$IN_CHAIN" 2>/dev/null || true
  "$IPT" -X "$IN_CHAIN" 2>/dev/null || true
  while "$IPT6" -D "$v6fwd" -i "$BRIDGE" -j DROP 2>/dev/null; do :; done
  while "$IPT6" -D INPUT -i "$BRIDGE" -j DROP 2>/dev/null; do :; done
}

apply_policy() {
  read_block_cidrs
  remove_policy   # idempotent: a re-apply replaces, never stacks

  # -- container -> anywhere but this host -------------------------------
  "$IPT" -N "$FWD_CHAIN"
  # 1. traffic that stays on this bridge (Aurral <-> its proxy). It must come
  #    first: the bridge subnet is itself private, so a later range drop would
  #    otherwise cut the UI off from the application.
  "$IPT" -A "$FWD_CHAIN" -o "$BRIDGE" -j RETURN
  # 2. replies to connections somebody else opened. Without this, the proxy's
  #    answers to a LAN client are dropped by the LAN range below and the UI
  #    is unreachable from the one place it is meant to work. New connections
  #    the container itself opens have no conntrack entry, so they still fall
  #    through to the drops -- which is exactly "may not INITIATE".
  "$IPT" -A "$FWD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # 3. the proxy initiates nothing off this bridge. It is an nginx serving one
  #    static config; it resolves its single upstream through Docker's embedded
  #    resolver on the container's own loopback, which never crosses the
  #    bridge. So egress belongs to Aurral alone and the surface is one
  #    container rather than two. Replies to inbound requests are already
  #    RETURNed by rule 2 above, which is why this cannot break the UI.
  "$IPT" -A "$FWD_CHAIN" -s "$AURRAL_PROXY_IP" -j DROP
  # 4. by interface: the tailnet and the other Docker bridges, whatever they
  #    are addressed with. This catches a tailnet subnet router advertising
  #    ordinary public routes, which an address list cannot.
  "$IPT" -A "$FWD_CHAIN" -o tailscale0 -j DROP
  "$IPT" -A "$FWD_CHAIN" -o docker0 -j DROP
  "$IPT" -A "$FWD_CHAIN" -o 'br-+' -j DROP
  # 5. by address: the LAN, the CGNAT range, and the never-legitimate ranges.
  local c
  for c in "${BLOCK_CIDRS[@]}" "${ALWAYS_BLOCK[@]}"; do
    "$IPT" -A "$FWD_CHAIN" -d "$c" -j DROP
  done
  # 6. whatever survived is an external destination: log it once per
  #    connection, so "which services does Aurral actually contact" is
  #    answerable from the kernel log instead of guessed at. Rate-limited so
  #    a download burst cannot flood the journal; the limit is stated rather
  #    than hidden, because a dropped log line is a missed observation.
  "$IPT" -A "$FWD_CHAIN" -m conntrack --ctstate NEW \
      -m limit --limit 600/min --limit-burst 200 \
      -j LOG --log-prefix 'aurral-egress ' --log-level info
  "$IPT" -A "$FWD_CHAIN" -j RETURN
  "$IPT" -I DOCKER-USER 1 -i "$BRIDGE" -j "$FWD_CHAIN"

  # -- container -> THIS host --------------------------------------------
  # Everything, including the bridge gateway and the host's LAN and Tailscale
  # addresses: a packet to any local address arrives on INPUT from this
  # interface. DNS survives because the configured resolver is public, so it
  # is reached over the forward path above and never over INPUT.
  "$IPT" -N "$IN_CHAIN"
  "$IPT" -A "$IN_CHAIN" -m conntrack --ctstate NEW \
      -m limit --limit 60/min --limit-burst 20 \
      -j LOG --log-prefix 'aurral-host-blocked ' --log-level info
  "$IPT" -A "$IN_CHAIN" -j DROP
  "$IPT" -I INPUT 1 -i "$BRIDGE" -j "$IN_CHAIN"

  # -- IPv6 --------------------------------------------------------------
  # The network is created with enable_ipv6: false, so the container has no
  # global IPv6 address and cannot route anywhere over it. These two rules
  # are belt and braces, and they are what makes the claim testable rather
  # than argued.
  local v6fwd; v6fwd="$(ipv6_forward_chain)"
  "$IPT6" -I "$v6fwd" 1 -i "$BRIDGE" -j DROP
  "$IPT6" -I INPUT 1 -i "$BRIDGE" -j DROP

  note "policy applied on $BRIDGE"
  note "blocked ranges: ${BLOCK_CIDRS[*]} ${ALWAYS_BLOCK[*]}"
  note "IPv6 forward chain used: $v6fwd"
}

show_policy() {
  local v6fwd; v6fwd="$(ipv6_forward_chain)"
  local present=0
  printf '== jumps\n'
  "$IPT" -S DOCKER-USER 2>/dev/null | grep -F -- "-j $FWD_CHAIN" | sed 's/^/  v4 FORWARD /' || true
  "$IPT" -S INPUT 2>/dev/null | grep -F -- "-j $IN_CHAIN" | sed 's/^/  v4 INPUT   /' || true
  "$IPT6" -S "$v6fwd" 2>/dev/null | grep -F -- "-i $BRIDGE -j DROP" | sed "s/^/  v6 $v6fwd /" || true
  "$IPT6" -S INPUT 2>/dev/null | grep -F -- "-i $BRIDGE -j DROP" | sed 's/^/  v6 INPUT   /' || true
  printf '== %s (packet counters)\n' "$FWD_CHAIN"
  "$IPT" -L "$FWD_CHAIN" -v -n --line-numbers 2>/dev/null | sed 's/^/  /' || present=1
  printf '== %s (packet counters)\n' "$IN_CHAIN"
  "$IPT" -L "$IN_CHAIN" -v -n --line-numbers 2>/dev/null | sed 's/^/  /' || present=1
  [[ "$present" -eq 0 ]] || { printf 'the policy is NOT installed\n'; return 1; }
}

case "$ACTION" in
  apply)  apply_policy ;;
  remove) remove_policy; note "policy removed from $BRIDGE" ;;
  show)   show_policy ;;
esac
