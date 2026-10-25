#!/usr/bin/env bash
# Keeps one NAT rule in place: UDP leaving a pod keeps its source port.
#
# Flannel masquerades pod traffic with --random-fully, so a pod's UDP socket
# gets a different outside port for every destination. To Tailscale that is a
# "hard" NAT (MappingVariesByDestIP), and the app proxies, which are pods, can
# then only reach a device behind another strict NAT through a DERP relay. A
# plain MASQUERADE ahead of flannel's rule keeps the port, so each proxy looks
# like the host itself: one outside port for everyone, which NAT traversal can
# work with. TCP and pod-to-pod traffic are untouched.
#
# Idempotent; run at boot and every few minutes, since a k3s restart can put
# flannel's rule back in front. `--undo` removes the rule.
set -euo pipefail

# The cluster's pod range, as flannel was given it; the node's own slice of it
# is enough on a single node.
CIDR="${CLUSTER_CIDR:-$(sed -n 's/^FLANNEL_NETWORK=//p' /run/flannel/subnet.env 2>/dev/null)}"
[ -n "$CIDR" ] || CIDR=$(k3s kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)
[ -n "$CIDR" ] || { echo "pod address range not found; k3s not running yet?" >&2; exit 1; }
TAG=pi-easy-nat
RULE=(-s "$CIDR" ! -d "$CIDR" -p udp -m comment --comment "$TAG" -j MASQUERADE)

# k3s writes its rules through whichever iptables backend the host uses; use
# the one that can see flannel's chain.
IPT=""
for cand in iptables iptables-nft iptables-legacy; do
  if command -v "$cand" >/dev/null && "$cand" -t nat -S FLANNEL-POSTRTG >/dev/null 2>&1; then
    IPT=$cand; break
  fi
done
[ -n "$IPT" ] || { echo "flannel's NAT chain not found; k3s not running yet?" >&2; exit 1; }

if [ "${1:-}" = "--undo" ]; then
  while "$IPT" -t nat -D POSTROUTING "${RULE[@]}" 2>/dev/null; do :; done
  echo "removed"
  exit 0
fi

# Position of our rule and of flannel's jump in POSTROUTING (1-based).
pos() { "$IPT" -t nat -S POSTROUTING | grep -v '^-P' | grep -n -- "$1" | head -1 | cut -d: -f1; }
ours=$(pos "$TAG" || true)
flannel=$(pos "FLANNEL-POSTRTG" || true)

if [ -n "$ours" ] && { [ -z "$flannel" ] || [ "$ours" -lt "$flannel" ]; }; then
  exit 0
fi
[ -n "$ours" ] && "$IPT" -t nat -D POSTROUTING "${RULE[@]}"
"$IPT" -t nat -I POSTROUTING 1 "${RULE[@]}"
echo "rule in place ($IPT, $CIDR)"
