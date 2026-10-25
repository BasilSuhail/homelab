#!/usr/bin/env bash
# The Discord bot: type "status" in the server, get right now in a few lines
# (sudo pi-when status). Asks for the bot token the first time, and for
# optional extras: a Jellyfin API key (who is watching which film), an Immich
# API key (the dashboard's photo totals) and the channels it may answer in. Re-run to change them: an empty answer keeps
# what is there. Idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/usr/local/lib/pi/pi-bot
ENV=/etc/pi-bot/env
UNIT=/etc/systemd/system/pi-bot.service

echo "==> Bot and status"
python3 -c 'import websocket' 2>/dev/null || sudo apt-get install -y python3-websocket >/dev/null
sudo install -d /usr/local/lib/pi /etc/pi-bot
sudo install -m 755 "$REPO_ROOT/deploy/pi-bot.py" "$BIN"
# The AI channel's half (issue #200): the read-only checks the local AI may
# call, one of which lists Uptime Kuma's monitors.
sudo install -m 755 "$REPO_ROOT/deploy/pi-ask.py" /usr/local/lib/pi/pi-ask
sudo install -m 755 "$REPO_ROOT/deploy/kuma-list.py" /usr/local/lib/pi/kuma-list
# status is part of pi-when, so the bot needs a pi-when that has it.
sudo install -m 755 "$REPO_ROOT/deploy/pi-when.py" /usr/local/lib/pi/pi-when
sudo ln -sf /usr/local/lib/pi/pi-when /usr/local/bin/pi-when

echo "==> Settings in $ENV"
current() { sudo grep -s "^$1=" "$ENV" | cut -d= -f2- || true; }
ask() {
  local name=$1 prompt=$2 secret=${3:-} value
  if [ -n "$secret" ]; then read -rsp "$prompt" value; echo >&2; else read -rp "$prompt" value; fi
  [ -n "$value" ] || value=$(current "$name")
  printf '%s=%s\n' "$name" "$value"
}
TOKEN_NOW=$(current DISCORD_BOT_TOKEN)
[ -n "$TOKEN_NOW" ] && echo "  (Enter keeps what is set)"
umask 077
{
  ask DISCORD_BOT_TOKEN "  Discord bot token: " secret
  ask JELLYFIN_API_KEY "  Jellyfin API key (optional): " secret
  ask IMMICH_API_KEY "  Immich API key (optional, server statistics only): " secret
  ask DISCORD_CHANNELS "  Channel IDs to answer in, comma separated (optional, empty = any): "
  ask DISCORD_AI_CHANNEL "  Channel ID for the local AI, every message there goes to it (optional): "
} > /tmp/pi-bot.env
if ! grep -q '^DISCORD_BOT_TOKEN=.\+' /tmp/pi-bot.env; then
  rm -f /tmp/pi-bot.env
  echo "No token given. Nothing changed." >&2
  exit 1
fi
sudo install -m 600 -o root -g root /tmp/pi-bot.env "$ENV"
rm -f /tmp/pi-bot.env

echo "==> Its own user, and the only root it gets"
# The bot talks to Discord and to a language model, so it runs unprivileged.
# Root is for these fixed commands alone; pi-ask checks every --check again
# as root before running anything.
id pi-bot >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin pi-bot
SUDOERS=/etc/sudoers.d/pi-bot
printf '%s\n' \
  'pi-bot ALL=(root) NOPASSWD: /usr/local/lib/pi/pi-when status' \
  'pi-bot ALL=(root) NOPASSWD: /usr/local/lib/pi/pi-ask --check *' \
  'pi-bot ALL=(root) NOPASSWD: /usr/local/lib/pi/pi-ask --apps' \
  'pi-bot ALL=(root) NOPASSWD: /usr/local/lib/pi/pi-ask --ai-url' > /tmp/pi-bot.sudoers
sudo visudo -cqf /tmp/pi-bot.sudoers
sudo install -m 440 -o root -g root /tmp/pi-bot.sudoers "$SUDOERS"
rm -f /tmp/pi-bot.sudoers

echo "==> Service"
sudo tee "$UNIT" >/dev/null <<UNIT
[Unit]
Description=Discord bot: answers "status" with what the PC is doing
After=network-online.target k3s.service
Wants=network-online.target

[Service]
User=pi-bot
# Read by systemd as root, so the file stays root's alone.
EnvironmentFile=$ENV
ExecStart=/usr/bin/python3 $BIN
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable pi-bot.service >/dev/null
sudo systemctl restart pi-bot.service

echo "==> What it would answer now"
sudo pi-when status
echo
sleep 5
sudo journalctl -u pi-bot -n 5 --no-pager -o cat
echo
echo 'Type "status" in your Discord server. Logs: sudo journalctl -u pi-bot -f'
