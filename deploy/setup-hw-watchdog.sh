#!/usr/bin/env bash
# The board's hardware watchdog: if this board hangs, the chip reboots it.
# Runs on the board. Idempotent: re-running with the same timeout changes
# nothing.
#
# systemd, as PID 1, pats the SoC's watchdog timer every few seconds. If the
# kernel or systemd locks up, the patting stops, and once RuntimeWatchdogSec
# passes the chip resets the board — no person, no other board. Costs nothing:
# no daemon, no memory, a timer write every few seconds from a process that
# runs anyway.
#
# Why: pi2 went off the network on 2026-10-03 and stayed off for 16 hours
# until it was unplugged. Power, memory and heat were ruled out afterwards;
# a hang fits (#187).
#
# What it does not cover, so nobody expects it to:
#   - A board that has lost power, or shut itself down. Nothing is running to
#     reboot it; only cutting and restoring the power does that.
#   - A hang where the kernel and systemd still run — a wedged disk, a dead
#     network driver — because systemd keeps patting.
#
#   WATCHDOG_SEC=15 bash deploy/setup-hw-watchdog.sh
set -euo pipefail

# The Pi's watchdog counts to about 16 seconds at most; 15 is as long as it
# goes. A longer request would be cut down to what the hardware can do.
TIMEOUT="${WATCHDOG_SEC:-15}"
CONF=/etc/systemd/system.conf.d/pi-hw-watchdog.conf

if [ ! -e /dev/watchdog0 ]; then
  echo "No /dev/watchdog0 on this board, so there is nothing to arm." >&2
  echo "On a Pi it comes from the bcm2835_wdt driver: lsmod | grep wdt" >&2
  exit 1
fi

# RebootWatchdogSec: a reboot that itself hangs — a disk that will not
# unmount — is forced after two minutes, instead of waiting for a person.
want="[Manager]
RuntimeWatchdogSec=${TIMEOUT}s
RebootWatchdogSec=2min"

echo "==> Hardware watchdog"
if [ "$(cat "$CONF" 2>/dev/null)" = "$want" ]; then
  echo "  already set — nothing to change"
else
  sudo install -d /etc/systemd/system.conf.d
  printf '%s\n' "$want" | sudo tee "$CONF" >/dev/null
  # Re-executes PID 1 in place so it picks up system.conf; services keep
  # running. This is how systemd applies a Manager setting without a reboot.
  sudo systemctl daemon-reexec
  echo "  written to $CONF"
fi

# Read back what systemd is doing, not what the file asks for.
runtime=$(systemctl show -p RuntimeWatchdogUSec --value)
device=$(systemctl show -p WatchdogDevice --value 2>/dev/null || true)
printf '  %-14s %s\n' "reboots after" "${runtime:-unknown} without a pat" \
                      "on a stuck"    "reboot, after 2min" \
                      "device"        "${device:-/dev/watchdog0}"
if [ -z "$runtime" ] || [ "$runtime" = 0 ] || [ "$runtime" = infinity ]; then
  echo "  systemd is not using the watchdog. Check: journalctl -b _PID=1 | grep -i watchdog" >&2
  exit 1
fi
# The timer itself: which chip, the timeout it accepted, and the time left.
# Time left below the timeout means systemd is patting it. (Not the journal:
# systemd's wording varies, and a grep for "watchdog" catches the Jellyfin
# watchdog's service lines instead.)
sudo wdctl /dev/watchdog0 2>/dev/null | grep -E "^(Identity|Timeout|Timeleft):" | sed 's/^/  /' || true
