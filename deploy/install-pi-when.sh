#!/usr/bin/env bash
# "What happened at 12:15?" Records the PC every minute (CPU, GPU, drives,
# Wi-Fi, pings, temperatures, app restarts) to /var/lib/pi-when on the OS
# drive, kept 14 days, and installs the lookup: sudo pi-when 12:15 nextcloud.
# Also keeps the journal on disk, so pi-paths and kernel lines survive a
# reboot. Idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/pi-when
UNIT=/etc/systemd/system/pi-when

echo "==> Recorder and lookup"
command -v ping >/dev/null || sudo apt-get install -y iputils-ping >/dev/null
sudo install -d /usr/local/lib/pi /var/lib/pi-when
sudo install -m 755 "$REPO_ROOT/deploy/pi-when.py" "$BIN"
sudo ln -sf "$BIN" /usr/local/bin/pi-when

echo "==> Journal kept on disk"
sudo install -d /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' | sudo tee /etc/systemd/journald.conf.d/pi-when.conf >/dev/null
if [ ! -d /var/log/journal ]; then
  sudo install -d /var/log/journal
  sudo systemd-tmpfiles --create --prefix /var/log/journal
  sudo systemctl restart systemd-journald
fi
sudo journalctl --disk-usage

sudo tee "$UNIT.service" >/dev/null <<UNIT
[Unit]
Description=One minute of PC readings, for pi-when
After=k3s.service

[Service]
Type=oneshot
ExecStart=$BIN record
Nice=10
UNIT

sudo tee "$UNIT.timer" >/dev/null <<UNIT
[Unit]
Description=Every minute: PC readings for pi-when

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pi-when.timer >/dev/null

echo "==> Two readings a minute apart"
sleep 70
sudo pi-when now --minutes 2
echo
echo "Ask:  sudo pi-when 12:15 nextcloud"
echo "      sudo pi-when \"yesterday 21:40\" jellyfin --who <name>"
