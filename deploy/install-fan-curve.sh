#!/usr/bin/env bash
# Temperature-driven fan control on the PC. Runs on the board. Idempotent.
#
# Needs the it87 driver for the board's IT8665E chip (the community DKMS build,
# loaded with ignore_resource_conflict=1) and k10temp for the CPU. The config
# is written once to /etc/pi-fans.json and then left alone, so thresholds can
# be tuned there and survive a re-run. Stopping the service, or any failure,
# hands every fan back to the BIOS curve.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/fan-curve
CONF=/etc/pi-fans.json
UNIT=/etc/systemd/system/pi-fans.service

if ! grep -qs '^it8' /sys/class/hwmon/hwmon*/name; then
  echo "No it87 fan chip. Install the it87 driver first; nothing was changed." >&2
  exit 1
fi

echo "==> Controller"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "$REPO_ROOT/deploy/fan-curve.py" "$BIN"

echo "==> Config"
# A config in an older shape is moved aside and replaced, since the controller
# would read it wrongly; one in the current shape is someone's tuning and stays.
if [ -f "$CONF" ] && grep -q '"version": 9' "$CONF"; then
  echo "  $CONF already present — leaving it alone"
else
  [ -f "$CONF" ] && sudo mv "$CONF" "$CONF.old" && echo "  older config kept as $CONF.old"
  "$BIN" --default-config | sudo tee "$CONF" >/dev/null
  echo "  written to $CONF"
fi

echo "==> Service"
sudo tee "$UNIT" >/dev/null <<UNIT
[Unit]
Description=Temperature-driven fan control
After=systemd-modules-load.service

[Service]
ExecStart=$BIN
# Runs after the process exits for any reason, a crash or a kill included, so
# the fans are never left at whatever duty the controller last wrote.
ExecStopPost=$BIN --release
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable pi-fans.service >/dev/null
sudo systemctl restart pi-fans.service

sleep 5
echo
echo "==> Now"
systemctl is-active pi-fans.service
sudo journalctl -u pi-fans --no-pager -n 5 -o cat
h=$(dirname "$(grep -ls '^it8' /sys/class/hwmon/hwmon*/name | head -1)")
for f in "$h"/fan[0-9]_input; do printf '  %s %s rpm\n' "$(basename "$f" _input)" "$(cat "$f")"; done
echo
echo "Release to the BIOS curve:  sudo systemctl stop pi-fans"
