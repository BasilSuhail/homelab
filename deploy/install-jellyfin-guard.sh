#!/usr/bin/env bash
# The Jellyfin guard: switches Jellyfin's public access (Funnel) off and posts
# to Discord when strangers try to log in. Family on Tailscale are never
# affected. Runs on the board every minute. Idempotent.
#
# Needs the morning report installed first (make report): it posts through
# the same Discord webhook, in /etc/pi-report/env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/jellyfin-guard
UNIT=/etc/systemd/system/jellyfin-guard

if ! sudo grep -qs '^DISCORD_WEBHOOK=.\+' /etc/pi-report/env; then
  echo "No Discord webhook in /etc/pi-report/env. Run 'make report' first." >&2
  exit 1
fi

echo "==> Guard"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "$REPO_ROOT/deploy/jellyfin-guard.py" "$BIN"
if [ ! -f /etc/jellyfin-guard.env ]; then
  sudo tee /etc/jellyfin-guard.env >/dev/null <<'ENV'
# When to switch Jellyfin's public access off. Edit, then nothing to restart.
GUARD_UNKNOWN=2          # login tries with usernames that are not accounts, per hour
GUARD_FAILS=5            # failed logins of any kind...
GUARD_FAILS_MINUTES=15   # ...within this many minutes
ENV
  echo "  thresholds in /etc/jellyfin-guard.env"
fi

sudo tee "$UNIT.service" >/dev/null <<UNIT
[Unit]
Description=Jellyfin guard: public access off when strangers knock
After=k3s.service network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
UNIT
sudo tee "$UNIT.timer" >/dev/null <<UNIT
[Unit]
Description=Jellyfin guard, every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload

echo "==> First run: learns the devices already in use, posts nothing for them"
sudo "$BIN"
sudo systemctl enable --now jellyfin-guard.timer >/dev/null

echo
echo "==> Last 24 hours"
out=$(sudo "$BIN" --summary)
echo "${out:-  quiet: no failed logins, no new devices}" | sed 's/^/  /'
echo
echo "Log:        sudo journalctl -u jellyfin-guard --since today -o cat"
echo "Funnel on:  sudo k3s kubectl -n pi annotate ingress jellyfin tailscale.com/funnel=true"
echo "Funnel off: sudo k3s kubectl -n pi annotate ingress jellyfin tailscale.com/funnel-"
