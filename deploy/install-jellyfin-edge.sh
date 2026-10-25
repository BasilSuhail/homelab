#!/usr/bin/env bash
# Puts the bouncer (k8s/jellyfin-edge.yaml) between Jellyfin's tailnet name,
# Funnel included, and Jellyfin, and has Jellyfin tell visitors apart.
#
#   bash deploy/install-jellyfin-edge.sh      (as the owner; FORCE=1 to skip the viewer check)
#
# 1. The bouncer: admin-only changes refused from the internet, a few sign-in
#    attempts a minute per address.
# 2. Jellyfin trusts the forwarded address from the pod network only, and
#    counts home, the tailnet and the pods as local, everything else as the
#    internet. Its network.xml is copied aside first. Jellyfin restarts once.
# 3. Jellyfin's tailnet name (and Funnel) now goes to the bouncer.
# 4. Account locks: deploy/jellyfin-accounts.py --apply (admins: home and
#    tailnet only).
#
# The TV at home (jellyfin-lan, port 8096) does not go through the bouncer.
# Back as before: point the Ingress at `jellyfin` again (the patch below with
# that name), and copy network.xml.pre-edge-* back over network.xml.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "run as the owner, without sudo" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kube() { sudo k3s kubectl "$@"; }
NETWORK_XML="${APPS_DIR:-/1) Archive/Apps}/Jellyfin/network.xml"

echo "==> Nobody watching"
NOW=$(sudo pi-when now 2>/dev/null | sed -n '/Using an app right now/,/^==/p')
if [ -z "${FORCE:-}" ] && grep -q " on Jellyfin" <<<"$NOW"; then
  echo "  someone is on Jellyfin; it restarts once. Try later, or FORCE=1" >&2
  grep " on Jellyfin" <<<"$NOW" >&2
  exit 1
fi
echo "  ok"

echo "==> Addresses on this machine"
POD_CIDR=$(kube get nodes -o jsonpath='{.items[0].spec.podCIDR}')
# The home network: the route of the interface the default route uses.
DEV=$(ip -4 route show default | awk '{print $5; exit}')
LAN=$(ip -4 -o route show dev "$DEV" scope link | awk '{print $1; exit}')
# The tailnet: Tailscale's whole range, from this machine's own address.
TAILNET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1] + "/10", strict=False))' \
  "$(tailscale ip -4 | head -1)")
echo "  pods $POD_CIDR, home $LAN, tailnet $TAILNET"

echo "==> Bouncer"
SUM=$(sed "s|__POD_CIDR__|$POD_CIDR|" "$REPO_ROOT/k8s/jellyfin-edge.yaml" | sha256sum | cut -c1-12)
sed -e "s|__POD_CIDR__|$POD_CIDR|" -e "s|__CONFIG_SUM__|$SUM|" "$REPO_ROOT/k8s/jellyfin-edge.yaml" \
  | kube apply -f -
kube -n pi rollout status deployment/jellyfin-edge --timeout=120s

echo "==> Jellyfin: who is local, whose forwarded address counts"
sudo test -f "$NETWORK_XML" || { echo "  no $NETWORK_XML" >&2; exit 1; }
sudo cp -p "$NETWORK_XML" "$NETWORK_XML.pre-edge-$(date +%Y%m%d-%H%M%S)"
sudo python3 - "$NETWORK_XML" "$POD_CIDR" "$LAN" "$TAILNET" <<'EDIT'
import sys
import xml.etree.ElementTree as ET

path, pods, lan, tailnet = sys.argv[1:]
# Keep the prefixes Jellyfin wrote.
ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")
ET.register_namespace("xsd", "http://www.w3.org/2001/XMLSchema")
tree = ET.parse(path)
root = tree.getroot()

def strings(tag, values):
    el = root.find(tag)
    if el is None:
        el = ET.SubElement(root, tag)
    el.clear()
    el.tail = el.tail or "\n  "
    for v in values:
        s = ET.SubElement(el, "string")
        s.text = v

# The proxies in front of it, both on the pod network: Tailscale's, then the bouncer.
strings("KnownProxies", [pods])
# Local: the pods (the TV's route arrives from here too), home, and the tailnet.
strings("LocalNetworkSubnets", [pods, lan, tailnet])
ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
EDIT
sudo grep -A4 -E "<(KnownProxies|LocalNetworkSubnets)>" "$NETWORK_XML" | sed 's/^/  /'
kube -n pi rollout restart deployment/jellyfin >/dev/null
kube -n pi rollout status deployment/jellyfin --timeout=300s

echo "==> Tailnet name and Funnel to the bouncer"
kube -n pi patch ingress jellyfin --type merge \
  -p '{"spec":{"defaultBackend":{"service":{"name":"jellyfin-edge","port":{"name":"http"}}}}}'
# The operator rewrites the proxy's serve config, but the running proxy kept
# the old route; a restart (about 20 seconds) makes it read the new one.
PROXY=$(kube -n tailscale get sts -o name | grep '/ts-jellyfin-' | head -1)
kube -n tailscale rollout restart "$PROXY" >/dev/null
kube -n tailscale rollout status "$PROXY" --timeout=180s
for _ in $(seq 1 30); do
  kube -n tailscale exec "${PROXY#statefulset.apps/}-0" -- tailscale serve status 2>/dev/null \
    | grep -q "$(kube -n pi get svc jellyfin-edge -o jsonpath='{.spec.clusterIP}')" && break
  sleep 3
done
kube -n tailscale exec "${PROXY#statefulset.apps/}-0" -- tailscale serve status | grep proxy | sed 's/^/  /'

echo "==> Account locks"
sudo python3 "$REPO_ROOT/deploy/jellyfin-accounts.py" --apply

echo
echo "Watch the door:  sudo k3s kubectl -n pi logs -f deploy/jellyfin-edge"
echo "                 (internet=1 is Funnel; 403 refused, 429 too many sign-ins)"
