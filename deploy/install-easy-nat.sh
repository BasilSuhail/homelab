#!/usr/bin/env bash
# Lets family devices outside the house reach the apps direct instead of
# through a slow Tailscale relay. Runs on the board. Idempotent.
#
# Each app is a Tailscale proxy in a pod, and pod traffic leaves through a NAT
# that changes the outside port per destination. pod-udp-nat.sh keeps the port
# for UDP, so each proxy looks to Tailscale like the host does. Before and
# after, this prints what Tailscale's own check says about the Cloud proxy:
# MappingVariesByDestIP should go from true to false.
#
#   UNDO=1 bash deploy/install-easy-nat.sh   removes it again
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/pod-udp-nat
UNIT=/etc/systemd/system/pi-easy-nat

netcheck() {
  local pod ns name
  pod=$(sudo k3s kubectl get pods -A -l tailscale.com/parent-resource=cloud \
        -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}')
  ns=${pod%%/*}; name=${pod#*/}
  sudo k3s kubectl -n "$ns" exec "$name" -c tailscale -- tailscale --socket=/tmp/tailscaled.sock netcheck 2>&1 \
    | grep -E 'MappingVariesByDestIP|IPv4:' | sed 's/^ */  /'
}

if [ "${UNDO:-}" = 1 ]; then
  sudo systemctl disable --now pi-easy-nat.timer 2>/dev/null || true
  sudo "$BIN" --undo || true
  sudo rm -f "$UNIT.service" "$UNIT.timer"
  sudo systemctl daemon-reload
  echo "Undone."
  exit 0
fi

echo "==> Cloud proxy before"
netcheck

echo "==> Rule"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "$REPO_ROOT/deploy/pod-udp-nat.sh" "$BIN"
sudo tee "$UNIT.service" >/dev/null <<UNIT
[Unit]
Description=Pod UDP keeps its source port (direct Tailscale paths for the apps)
After=k3s.service

[Service]
Type=oneshot
ExecStart=$BIN
UNIT
sudo tee "$UNIT.timer" >/dev/null <<UNIT
[Unit]
Description=Keep the pod UDP NAT rule in front of flannel's

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pi-easy-nat.timer >/dev/null
sudo "$BIN"

echo "==> Restarting the app proxies (about 20 seconds; uploads resume)"
# A running proxy keeps the outside port its open connections already have;
# only a fresh start picks up the rule. Their Tailscale identity is kept.
sudo k3s kubectl get pods -A -l tailscale.com/parent-resource \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
while read -r ns name; do
  sudo k3s kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null
done
sleep 5
sudo k3s kubectl wait pods -A -l tailscale.com/parent-resource --for=condition=Ready --timeout=180s >/dev/null || true
sleep 10

echo "==> Cloud proxy after"
netcheck
echo
echo "MappingVariesByDestIP: false means the apps now look like the PC itself."
echo "Whether a family device goes direct shows in:  sudo journalctl -u pi-paths --since -1h -o cat"
echo "Undo:  UNDO=1 bash ~/PI/deploy/install-easy-nat.sh"
