#!/usr/bin/env bash
# The morning report: what went wrong on the PC in the last 24 hours, posted to
# Discord at 08:00, and nothing posted on a quiet day. Runs on the board.
# Idempotent: the webhook and the to-do list are written once, then left alone.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/daily-report
CONF=/etc/pi-report
UNIT=/etc/systemd/system/pi-report
KUMA_DIR="${KUMA_DIR:-/1) Archive/Apps/Uptime}"

echo "==> Report"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "$REPO_ROOT/deploy/daily-report.py" "$BIN"
sudo install -d -m 700 "$CONF"

echo "==> Discord"
if sudo grep -qs '^DISCORD_WEBHOOK=.\+' "$CONF/env"; then
  echo "  webhook already set in $CONF/env"
else
  # Uptime Kuma already posts to Discord; its webhook is the one to reuse.
  hook=$(sudo find "$KUMA_DIR" -maxdepth 2 -name kuma.db -print -quit 2>/dev/null | while read -r db; do
    sudo python3 - "$db" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for (cfg,) in db.execute("select config from notification"):
    url = (json.loads(cfg or "{}") or {}).get("discordWebhookUrl")
    if url:
        print(url)
        break
PY
  done)
  if [ -n "$hook" ]; then
    echo "  using the webhook Uptime Kuma posts to"
  else
    read -rsp "  Discord webhook URL (Server settings > Integrations > Webhooks): " hook; echo
  fi
  [ -n "$hook" ] || { echo "No webhook; nothing installed." >&2; exit 1; }
  printf 'DISCORD_WEBHOOK=%s\n' "$hook" | sudo tee "$CONF/env" >/dev/null
  sudo chmod 600 "$CONF/env"
fi

echo "==> To-do list (shown in the Monday report)"
if sudo test -f "$CONF/todo.txt"; then
  echo "  $CONF/todo.txt already present — leaving it alone"
else
  sudo tee "$CONF/todo.txt" >/dev/null <<'TODO'
# One line per item. Delete a line when it is done; lines starting with # are skipped.
Delete the old app volumes once happy: sudo k3s kubectl -n pi delete pvc vaultwarden uptime-kuma
Delete the paused Uptime Kuma monitors for the old Pi (Glances, Shim)
Mac: delete ~/Downloads/AirVPN and ~/Downloads/AirVPN.7z
Torrent client is off: keep it or remove it
After OSINT has moved: delete the Pi backups (pi1-full.tgz, pi1-backup.tgz) from the laptop
Jellyfin: one family account still cannot have video converted (Dashboard > Users)
Renew the dashboard's Tailscale API key before 2027-01-05
Fans: GPU fan on its header, CPU fan allowed to stop at idle
Pi inside the PC as the outside watcher (issue 196)
TODO
  echo "  written to $CONF/todo.txt"
fi

echo "==> Timer"
sudo tee "$UNIT.service" >/dev/null <<UNIT
[Unit]
Description=Morning report to Discord
After=k3s.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
Nice=10
UNIT

sudo tee "$UNIT.timer" >/dev/null <<UNIT
[Unit]
Description=Morning report to Discord, 08:00

[Timer]
OnCalendar=*-*-* 08:00:00
# A morning the PC was off still gets its report, at the next boot.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pi-report.timer >/dev/null

echo "==> First report, posted now so you can see it arrive (takes up to a minute)"
sudo "$BIN" --always
echo
echo "Next: $(systemctl show pi-report.timer -p NextElapseUSecRealtime --value)"
echo "Preview without posting:  sudo $BIN --dry --always"
echo "To-do list:               sudo nano $CONF/todo.txt"
