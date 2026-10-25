#!/usr/bin/env bash
# Whether the console still takes the admin password, or only Face ID /
# Touch ID from devices already set up. The console reads this on every
# sign-in, so no restart.
#
#   sudo bash deploy/console-login.sh passkeys-only
#   sudo bash deploy/console-login.sh password-too
#   sudo bash deploy/console-login.sh            (shows the current state)
#
# Lost every device? password-too, sign in with the password, then set up
# Face ID / Touch ID again on the sign-in page.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

STATE="${APPS_DIR:-/1) Archive/Apps}/Console"
[ -d "$STATE" ] || { echo "no $STATE: run deploy/install-dashboard-k8s.sh first" >&2; exit 1; }

devices() {
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$STATE/passkeys.json" 2>/dev/null || echo 0
}

case "${1:-}" in
  passkeys-only)
    n=$(devices)
    [ "$n" -gt 0 ] || { echo "no device has Face ID / Touch ID set up yet; nothing changed" >&2; exit 1; }
    printf 'off\n' >"$STATE/password-login"
    ;;
  password-too)
    printf 'on\n' >"$STATE/password-login"
    ;;
  "") ;;
  *) echo "usage: $0 [passkeys-only|password-too]" >&2; exit 1 ;;
esac
chown 1000:1000 "$STATE/password-login" 2>/dev/null || true

mode=$(cat "$STATE/password-login" 2>/dev/null || echo on)
echo "Devices with Face ID / Touch ID: $(devices)"
[ "$mode" = off ] && echo "Password sign-in: off" || echo "Password sign-in: on"
