#!/usr/bin/env bash
# Installs the home-network firewall (deploy/firewall.nft) with an automatic
# undo, because this machine has no screen: a wrong rule would otherwise mean
# no way back in.
#
#   sudo bash deploy/install-firewall.sh          load it; undone in 3 minutes
#   sudo bash deploy/install-firewall.sh --keep   keep it, and load it at boot
#   sudo bash deploy/install-firewall.sh --off    remove it now
#
# Between the first two, open a new SSH session over Tailscale. If it works,
# --keep. If it does not, wait: the undo timer deletes the table on its own.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES=/etc/pi/firewall.nft
UNIT=/etc/systemd/system/pi-firewall.service
UNDO=pi-firewall-undo
UNDO_AFTER=180

case "${1:-}" in
  --keep)
    nft list table inet pi-fw >/dev/null 2>&1 || { echo "the firewall is not loaded; run without --keep first" >&2; exit 1; }
    systemctl stop "${UNDO}.timer" 2>/dev/null || true
    systemctl enable pi-firewall.service >/dev/null
    echo "kept. pi-firewall.service loads it at every boot."
    exit 0
    ;;
  --off)
    systemctl stop "${UNDO}.timer" 2>/dev/null || true
    systemctl disable pi-firewall.service 2>/dev/null || true
    nft delete table inet pi-fw 2>/dev/null || true
    echo "removed. The home network reaches everything again."
    exit 0
    ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

echo "==> Rules"
install -d -m 755 /etc/pi
install -m 644 "${REPO_ROOT}/deploy/firewall.nft" "$RULES"
nft -c -f "$RULES"
echo "  syntax checked"

echo "==> Unit"
cat >"$UNIT" <<UNITFILE
[Unit]
Description=Home-network firewall: Jellyfin only, everything else tailnet-only
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${RULES}
ExecStop=/usr/sbin/nft delete table inet pi-fw

[Install]
WantedBy=multi-user.target
UNITFILE
systemctl daemon-reload

echo "==> Undo in ${UNDO_AFTER}s unless kept"
systemctl stop "${UNDO}.timer" 2>/dev/null || true
systemctl reset-failed "${UNDO}.service" 2>/dev/null || true
systemd-run --quiet --unit="$UNDO" --on-active="$UNDO_AFTER" /usr/sbin/nft delete table inet pi-fw

echo "==> Loading"
nft -f "$RULES"
nft list chain inet pi-fw home | sed -n '/home {/,/}/p' | sed 's/^/  /'

echo
echo "Now open a new SSH session over Tailscale. If it works:"
echo "  sudo bash deploy/install-firewall.sh --keep"
echo "If it does not, wait ${UNDO_AFTER}s and the rules remove themselves."
