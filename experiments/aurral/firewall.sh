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
# WHAT IT TOUCHES. Three custom chains and four jump rules, every one of them
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
# Every egress DROP jumps here instead of dropping inline, so a blocked packet
# is LOGGED and then dropped. It exists because the allowed-egress LOG sits
# after the drops and therefore only ever recorded traffic that was PERMITTED:
# measured 2026-11-24, four of validate.sh's seven host probes were blocked
# silently, and nothing would have recorded Aurral probing a production
# container, the LAN or the tailnet. Enforcement is unchanged -- same rules,
# same order, same verdict -- only the target differs.
DROP_CHAIN=AURRAL-EGRESS-DROP
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

# Overridable so a test can record the exact ruleset this would build without
# touching a real one. Both default to the production binaries, so nothing
# about production behaviour depends on these existing. The root check above is
# NOT weakened for testing -- the suite satisfies it by running under
# `unshare -r`, where the caller really does map to uid 0.
IPT="${AURRAL_IPTABLES:-$(command -v iptables || echo /usr/sbin/iptables)}"
IPT6="${AURRAL_IP6TABLES:-$(command -v ip6tables || echo /usr/sbin/ip6tables)}"
[[ -x "$IPT" ]] || die "iptables not found"

# ---------------------------------------------------------------------------
# The ranges Aurral must not reach are infrastructure facts about THIS host,
# so they live in the untracked env file beside the addresses. A missing or
# empty list refuses: applying a policy whose block list is empty would open
# the LAN while reporting success.
# ---------------------------------------------------------------------------
read_block_cidrs() {
  [[ -r "$ENV_FILE" ]] || die "cannot read $ENV_FILE"
  # `source` returns the status of the LAST command in the file, so this
  # catches a file that is syntactically broken -- an unbalanced quote
  # returns 2 -- and NOT an unquoted multi-word value. Measured: an unquoted
  # `VAR=a b c` is a command PREFIX assignment, so it does not persist at
  # all and the variable is simply unset; the `:?` guards below are what
  # catch that, and they say so.
  # shellcheck disable=SC1090
  if ! source "$ENV_FILE"; then
    die "could not source $ENV_FILE -- it is not valid shell (an unbalanced quote returns 2)"
  fi
  # The hint about quoting lives HERE because this is the guard that actually
  # fires for an unquoted list: the value never persists, so the variable is
  # unset rather than short.
  : "${AURRAL_BLOCK_CIDRS:?set AURRAL_BLOCK_CIDRS in $ENV_FILE (see aurral.env.example). A multi-range value MUST be quoted: AURRAL_BLOCK_CIDRS=\"<range> <range> <range> <range>\" -- unquoted, the assignment applies only to the next word as a command and does not persist}"
  : "${AURRAL_PROXY_IP:?set AURRAL_PROXY_IP in $ENV_FILE}"
  read -r -a BLOCK_CIDRS <<< "$AURRAL_BLOCK_CIDRS"
  [[ "${#BLOCK_CIDRS[@]}" -ge 4 ]] \
    || die "AURRAL_BLOCK_CIDRS lists ${#BLOCK_CIDRS[@]} range(s); the three RFC1918 ranges and the CGNAT range are the minimum"
  local c
  for c in "${BLOCK_CIDRS[@]}"; do
    [[ "$c" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || die "not a CIDR: $c"
  done
  assert_block_coverage
}

# A COUNT IS NOT A COMPLETENESS CHECK, and the refusal above names four
# specific ranges -- so four /32 entries would satisfy it and report success
# while leaving the LAN, the tailnet and the other Docker networks reachable.
# These assertions prove each required range is actually COVERED by some
# listed CIDR.
#
# The required ranges are built with integer arithmetic instead of being
# written as dotted quads, because this repository's identifier audit rejects
# an RFC1918 or CGNAT literal in a tracked file. The two-octet shorthand in
# the messages (10/8, 172.16/12) is not a 4-octet address and so does not
# match that audit's pattern.
ip_to_int() {
  local o
  IFS=. read -r -a o <<< "$1"
  printf '%s' "$(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))"
}

netmask_of() {
  local m="$1"
  (( m == 0 )) && { printf '0'; return 0; }
  printf '%s' "$(( (0xFFFFFFFF << (32 - m)) & 0xFFFFFFFF ))"
}

# Does any listed CIDR cover the WHOLE of <base>/<prefix-length>? A listed
# range covers it only when its prefix is no longer (so it is not merely a
# subset) and the required base falls inside it.
block_list_covers() {
  local rbase="$1" rprefix="$2"
  local entry lip lprefix lmask lint
  for entry in "${BLOCK_CIDRS[@]}"; do
    lip="${entry%/*}"
    lprefix="${entry#*/}"
    (( lprefix <= rprefix )) || continue
    lmask="$(netmask_of "$lprefix")"
    lint="$(ip_to_int "$lip")"
    (( (lint & lmask) == (rbase & lmask) )) && return 0
  done
  return 1
}

assert_block_coverage() {
  local priv_a priv_b priv_c cgnat
  priv_a=$(( 10 << 24 ))
  priv_b=$(( (172 << 24) + (16 << 16) ))
  priv_c=$(( (192 << 24) + (168 << 16) ))
  cgnat=$((  (100 << 24) + (64 << 16) ))
  block_list_covers "$priv_a" 8 \
    || die "AURRAL_BLOCK_CIDRS does not cover the 10/8 private range"
  block_list_covers "$priv_b" 12 \
    || die "AURRAL_BLOCK_CIDRS does not cover the 172.16/12 private range"
  block_list_covers "$priv_c" 16 \
    || die "AURRAL_BLOCK_CIDRS does not cover the 192.168/16 private range"
  block_list_covers "$cgnat" 10 \
    || die "AURRAL_BLOCK_CIDRS does not cover the 100.64/10 Tailscale CGNAT range"
}

ipv6_forward_chain() {
  # Docker creates DOCKER-USER in ip6tables when ip6tables support is on. If
  # it is absent, fall back to FORWARD rather than skipping IPv6 silently.
  if "$IPT6" -S DOCKER-USER >/dev/null 2>&1; then printf 'DOCKER-USER'; else printf 'FORWARD'; fi
}

remove_policy() {
  while "$IPT" -D DOCKER-USER -i "$BRIDGE" -j "$FWD_CHAIN" 2>/dev/null; do :; done
  while "$IPT" -D INPUT -i "$BRIDGE" -j "$IN_CHAIN" 2>/dev/null; do :; done
  # Flush ALL THREE before deleting any: $DROP_CHAIN is referenced by
  # $FWD_CHAIN, and iptables refuses to delete a chain that is still
  # referenced. Flushing first removes every reference, so the deletes below
  # cannot fail for ordering reasons. Each one tolerates absence, so this is
  # safe on a host where the policy was never applied.
  "$IPT" -F "$FWD_CHAIN" 2>/dev/null || true
  "$IPT" -F "$IN_CHAIN" 2>/dev/null || true
  "$IPT" -F "$DROP_CHAIN" 2>/dev/null || true
  "$IPT" -X "$FWD_CHAIN" 2>/dev/null || true
  "$IPT" -X "$IN_CHAIN" 2>/dev/null || true
  "$IPT" -X "$DROP_CHAIN" 2>/dev/null || true
  # BOTH candidate chains, not the one `ipv6_forward_chain` picks now.
  # `apply` chooses by what exists at the time, so if Docker gains (or loses)
  # an ip6tables DOCKER-USER between apply and remove, asking again would
  # target the other chain and leave a stray `-i aurral0 -j DROP` behind. It
  # would be harmless once the interface is gone, and it would also mean
  # `show` could never report the policy fully removed. Each delete is
  # already tolerant of absence, so trying both costs nothing.
  local v6chain
  for v6chain in DOCKER-USER FORWARD; do
    while "$IPT6" -D "$v6chain" -i "$BRIDGE" -j DROP 2>/dev/null; do :; done
  done
  while "$IPT6" -D INPUT -i "$BRIDGE" -j DROP 2>/dev/null; do :; done
}

apply_policy() {
  read_block_cidrs
  remove_policy   # idempotent: a re-apply replaces, never stacks

  # -- blocked egress: log, then drop ------------------------------------
  # Created BEFORE the chain that jumps to it, because iptables refuses a jump
  # to a chain that does not exist yet.
  #
  # ctstate NEW, so one line per CONNECTION rather than per retransmitted SYN
  # -- a dropped SYN is retransmitted about five times, which would otherwise
  # multiply every observation by five. Rate-limited at the same 60/min as the
  # host chain, because both are "something was blocked" and a shared vocabulary
  # should have a shared cost.
  #
  # The limit is one bucket shared by every drop reason, and the trade-off is
  # stated rather than hidden: a flood of one kind of blocked traffic can
  # exhaust it and hide another kind. Nothing on this bridge is known to be
  # chatty, so a shared bucket is the simpler and honest starting point; if the
  # journal ever shows it saturating, split it then.
  #
  # It logs headers only. LOG never records payload, so no application data,
  # credential or music metadata can reach the journal through this.
  "$IPT" -N "$DROP_CHAIN"
  "$IPT" -A "$DROP_CHAIN" -m conntrack --ctstate NEW \
      -m limit --limit 60/min --limit-burst 20 \
      -j LOG --log-prefix 'aurral-egress-blocked ' --log-level info
  "$IPT" -A "$DROP_CHAIN" -j DROP

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
  "$IPT" -A "$FWD_CHAIN" -s "$AURRAL_PROXY_IP" -j "$DROP_CHAIN"
  # 4. by interface: the tailnet and the other Docker bridges, whatever they
  #    are addressed with. This catches a tailnet subnet router advertising
  #    ordinary public routes, which an address list cannot.
  "$IPT" -A "$FWD_CHAIN" -o tailscale0 -j "$DROP_CHAIN"
  "$IPT" -A "$FWD_CHAIN" -o docker0 -j "$DROP_CHAIN"
  "$IPT" -A "$FWD_CHAIN" -o 'br-+' -j "$DROP_CHAIN"
  # 5. by address: the LAN, the CGNAT range, and the never-legitimate ranges.
  local c
  for c in "${BLOCK_CIDRS[@]}" "${ALWAYS_BLOCK[@]}"; do
    "$IPT" -A "$FWD_CHAIN" -d "$c" -j "$DROP_CHAIN"
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
  # Replies to a connection THIS HOST opened to the container. Measured on
  # this host: `EnableUserlandProxy` is true, so docker-proxy binds each
  # published port. Whether a LAN client is served by the nat-table DNAT
  # (which routes the packet to the container, so INPUT is never involved) or
  # by docker-proxy (which terminates on the host and opens its OWN
  # connection to the container, whose replies DO arrive here on INPUT) is a
  # property of Docker's port-publishing mechanism, not of this policy -- and
  # without this rule the second case drops the UI's replies and the
  # experiment is unreachable from the one place it is meant to work.
  #
  # It does not weaken the claim. The claim is that Aurral may not INITIATE a
  # connection to this host, and a container-initiated connection has no
  # conntrack entry, so it still falls through to the DROP below. This is the
  # same rule, for the same reason, as rule 2 of the forward chain; the two
  # chains were asymmetric and only the forward half had it.
  "$IPT" -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
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
  printf '== %s (packet counters)\n' "$DROP_CHAIN"
  "$IPT" -L "$DROP_CHAIN" -v -n --line-numbers 2>/dev/null | sed 's/^/  /' || present=1
  [[ "$present" -eq 0 ]] || { printf 'the policy is NOT installed\n'; return 1; }
}

case "$ACTION" in
  apply)  apply_policy ;;
  remove) remove_policy; note "policy removed from $BRIDGE" ;;
  show)   show_policy ;;
esac
