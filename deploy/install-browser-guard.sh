#!/usr/bin/env bash
# Keeps the job bot's browser off this machine's own services and the router.
#
#   sudo bash deploy/install-browser-guard.sh
#
# The bot's agent reads untrusted job pages and can run JavaScript in the
# page. Opened on http://127.0.0.1:9101 or the console, that JavaScript would
# be same-origin with a service that changes files, and the firewall cannot
# help: it is the same machine. A managed policy makes Chromium refuse those
# addresses outright. The bot never needs them: Playwright reaches the
# browser over CDP, which a URL blocklist does not touch.
#
# URLBlocklist takes hosts, not address ranges, so this machine's own
# addresses and the router's are read here rather than written into the repo.
# Re-run it if they change. A running browser reads policy only at start.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

hosts=(localhost 127.0.0.1 "[::1]" 0.0.0.0 "$(hostname)" ts.net cluster.local local fritz.box)
# IPv6 addresses go in brackets, or Chromium rejects them as patterns.
mapfile -t own < <(hostname -I | tr ' ' '\n' | grep -v '^$' | sed '/:/s/.*/[&]/')
gateway="$(ip -4 route show default | awk '{print $3; exit}')"
hosts+=("${own[@]}" ${gateway:+"$gateway"})

POLICY="$(printf '%s\n' "${hosts[@]}" | python3 -c '
import json, sys
print(json.dumps({"URLBlocklist": [h for h in sys.stdin.read().split() if h]}, indent=2))')"

# Chrome for Testing (what Playwright installs), Chromium, and Chrome each
# read their own directory.
for dir in /etc/opt/chrome_for_testing /etc/chromium /etc/opt/chrome; do
  install -d -m 755 "$dir/policies/managed"
  printf '%s\n' "$POLICY" >"$dir/policies/managed/pi-local-block.json"
  chmod 644 "$dir/policies/managed/pi-local-block.json"
done
echo "blocked: ${#hosts[@]} hosts (this machine, the tailnet, the router)"
echo "restart the live-view browser for it to apply:"
echo "  systemctl --user restart applypilot-home-browser"
