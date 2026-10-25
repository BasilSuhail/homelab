#!/usr/bin/env bash
# A watcher for how family devices reach the apps: direct, or through a slow
# Tailscale relay. Runs on the board every minute and writes to the journal
# only while a device is using an app. Idempotent; changes nothing else.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/tailnet-paths
UNIT=/etc/systemd/system/pi-paths

echo "==> Watcher"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "$REPO_ROOT/deploy/tailnet-paths.py" "$BIN"

sudo tee "$UNIT.service" >/dev/null <<UNIT
[Unit]
Description=How family devices reach the apps: direct or relay
After=k3s.service

[Service]
Type=oneshot
ExecStart=$BIN
Nice=10
UNIT

sudo tee "$UNIT.timer" >/dev/null <<UNIT
[Unit]
Description=Every minute: how family devices reach the apps

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pi-paths.timer >/dev/null

echo "==> Now (two readings 15 seconds apart; empty when nobody is using an app)"
sudo "$BIN"
sleep 15
sudo "$BIN"
echo
echo "Read it:  sudo journalctl -u pi-paths --since today -o short"
echo "RELAY <city> = through a relay, slow.  direct = straight to the house."
