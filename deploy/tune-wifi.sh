#!/usr/bin/env bash
# Stop the wifi radio going to sleep between packets. Runs on the board.
#
# Measured, not guessed. Streaming a film off pi2 stutters a few times an
# hour while every other number says the board is idle: CPU under 6%, load
# under 0.7, 48 C, never throttled, Jellyfin itself under 0.5% of one core.
# Sampling the link every five seconds for ten minutes found the cause:
#
#   116 pings, zero lost
#   median 6.6ms, p90 7.8ms, p99 13.3ms
#   one outlier at 101ms
#
# That shape is specific. A congested link drops packets and this one dropped
# none. A loaded board raises latency gradually and this one did not. A single
# large spike with everything around it clean is the radio not being there for
# a moment, which is what power saving does: the chip sleeps between beacons
# and the first packet after a sleep waits for it to wake.
#
# It matters here and not on a laptop because the board is a server. Nothing
# it serves is ever the thing that woke the radio up.
#
# NetworkManager is the owner of the setting on Debian 13, so the drop-in
# below is the durable half and survives reboots and reconnections. `iw` is
# the immediate half, because the drop-in only takes effect the next time the
# connection comes up and nobody wants to reboot a board to stop a stutter.
set -euo pipefail

IFACE="${IFACE:-wlan0}"
CONF=/etc/NetworkManager/conf.d/wifi-powersave-off.conf

if [ ! -d /sys/class/net/"$IFACE" ]; then
  echo "no such interface: $IFACE" >&2
  echo "Wired boards do not need this. Interfaces here:" >&2
  ls /sys/class/net | sed 's/^/  /' >&2
  exit 1
fi

echo "==> Before"
/usr/sbin/iw dev "$IFACE" get power_save 2>/dev/null | sed 's/^/  /' || echo "  iw could not read it"

# 2 is NetworkManager's "disable". 3 is enable, 0 is "use the default", and the
# default is on — so leaving this unset is not neutral.
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
  echo "==> Durable: $CONF"
  sudo mkdir -p "$(dirname "$CONF")"
  sudo tee "$CONF" >/dev/null <<'NOTE'
# Written by deploy/tune-wifi.sh. Power saving parks the wifi radio between
# beacons, which costs a server latency for a benefit only a battery wants.
[connection]
wifi.powersave = 2
NOTE
  sudo systemctl reload NetworkManager
else
  # No NetworkManager. A one-shot unit at boot is the equivalent, and ordering
  # it after the interface exists is the part that is easy to get wrong.
  echo "==> NetworkManager not in charge — installing a boot-time unit instead"
  sudo tee /etc/systemd/system/wifi-powersave-off.service >/dev/null <<UNIT
[Unit]
Description=Disable wifi power saving on ${IFACE}
After=sys-subsystem-net-devices-${IFACE}.device
BindsTo=sys-subsystem-net-devices-${IFACE}.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iw dev ${IFACE} set power_save off

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now wifi-powersave-off.service
fi

# Immediate, either way. The drop-in applies on the next connect and the unit
# applies on the next boot; this is what makes the change true right now.
echo "==> Now"
sudo iw dev "$IFACE" set power_save off
/usr/sbin/iw dev "$IFACE" get power_save | sed 's/^/  /'

echo
echo "Want: 'Power save: off'. If it still says on, NetworkManager reapplied it"
echo "and the drop-in above is not being read — check: nmcli -f 802-11-wireless-powersave con show --active"
