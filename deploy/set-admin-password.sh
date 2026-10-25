#!/usr/bin/env bash
# One admin password for the three tools that have none of their own:
# the console, the browser live view, and qBittorrent's web page.
#
#   sudo bash deploy/set-admin-password.sh
#
# Asks for it twice and never prints it. Run it again to change it.
#
#   console      any user name, this password
#   live view    this password, first 8 characters only (VNC's own limit)
#   qBittorrent  its existing user name (admin if none), this password
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

kube() { k3s kubectl "$@"; }
OWNER="${SUDO_USER:-homelab}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
OWNER_UID="$(id -u "$OWNER")"
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
QBT_CONF="$APPS_DIR/qBittorrent/qBittorrent/qBittorrent.conf"

read -rsp "Admin password (new, 12+ characters) > " PW; echo
read -rsp "Same again > " PW2; echo
[ "$PW" = "$PW2" ] || { echo "they differ; nothing changed" >&2; exit 1; }
[ "${#PW}" -ge 12 ] || { echo "at least 12 characters; nothing changed" >&2; exit 1; }
unset PW2

echo "==> Console"
printf '%s' "$PW" | kube -n pi create secret generic pi-console-login \
  --from-file=password=/dev/stdin --dry-run=client -o yaml | kube apply -f - >/dev/null
kube -n pi rollout restart deployment/pi-console >/dev/null
kube -n pi rollout status deployment/pi-console --timeout=180s >/dev/null
echo "  set"

echo "==> Live view"
# x11vnc only takes the password on its command line, so it sits in argv for
# the moment it takes to write the file. The file is the owner's alone.
as_owner() { sudo -u "$OWNER" XDG_RUNTIME_DIR="/run/user/$OWNER_UID" "$@"; }
as_owner install -d -m 700 "$OWNER_HOME/.vnc"
as_owner x11vnc -storepasswd "$PW" "$OWNER_HOME/.vnc/passwd" >/dev/null 2>&1
chmod 600 "$OWNER_HOME/.vnc/passwd"
if kube -n applypilot get deployment applypilot >/dev/null 2>&1; then
  # In the bot's container (k8s/applypilot.yaml): the file goes into its
  # Secret, and once the mounted copy has changed, VNC alone restarts. The pod
  # does not, so a running round carries on.
  kube -n applypilot create secret generic applypilot-vnc --from-file="passwd=$OWNER_HOME/.vnc/passwd" \
    --dry-run=client -o yaml | kube apply -f - >/dev/null
  want=$(md5sum <"$OWNER_HOME/.vnc/passwd")
  # Secrets reach a running pod within a minute or two.
  for _ in $(seq 1 60); do
    got=$(kube -n applypilot exec deploy/applypilot -- sh -c 'md5sum </etc/applypilot/vnc/passwd' 2>/dev/null || true)
    [ "$got" = "$want" ] && break
    sleep 3
  done
  kube -n applypilot exec deploy/applypilot -- services restart vnc >/dev/null
  echo "  set (first 8 characters)"
else
DROPIN="$OWNER_HOME/.config/systemd/user/applypilot-vnc.service.d"
as_owner install -d -m 755 "$DROPIN"
# The unit's own command, with -nopw swapped for the password file.
as_owner tee "$DROPIN/password.conf" >/dev/null <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/x11vnc -display :99 -localhost -rfbport 5900 -forever -shared -rfbauth %h/.vnc/passwd -quiet
UNIT
as_owner systemctl --user daemon-reload
as_owner systemctl --user restart applypilot-vnc
echo "  set (first 8 characters)"
fi

echo "==> qBittorrent"
if [ -f "$QBT_CONF" ]; then
  # It rewrites its config on exit, so it is stopped for the edit and put back.
  WAS=$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  if [ "${WAS:-0}" != "0" ]; then
    kube -n pi scale deployment/qbittorrent --replicas=0 >/dev/null
    kube -n pi wait --for=delete pod -l app=qbittorrent --timeout=90s >/dev/null 2>&1 || true
  fi
  # No login only for this machine itself, its .1 on each pod network, as in
  # deploy/install-torrent.sh. The tailnet arrives through proxy pods and
  # must log in.
  PODS=$(kube get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{","}{end}')
  BYPASS=$(python3 -c 'import ipaddress,sys; print(",".join(f"{ipaddress.ip_network(c)[1]}/32" for c in sys.argv[1].split(",") if c))' "$PODS")
  # qBittorrent's own format: PBKDF2-HMAC-SHA512, 100000 rounds, 16-byte salt.
  PW="$PW" python3 - "$QBT_CONF" "$BYPASS" <<'EDIT'
import base64, hashlib, os, sys

path, bypass = sys.argv[1], sys.argv[2]
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", os.environ["PW"].encode(), salt, 100000, 64)
value = '"@ByteArray(%s:%s)"' % (base64.b64encode(salt).decode(), base64.b64encode(key).decode())
lines = open(path).read().splitlines()
# qBittorrent 5.3 moved these out of [Preferences], as WebUI\Key, into their
# own [WebUI] section. Write whichever layout the file already has.
header, prefix = ("[WebUI]", "") if "[WebUI]" in lines else ("[Preferences]", "WebUI\\")
want = [(prefix + "Password_PBKDF2", value),
        (prefix + "AuthSubnetWhitelistEnabled", "true"), (prefix + "AuthSubnetWhitelist", bypass)]

# The user name is the owner's to choose; only a config without one gets admin.
if not any(l.startswith(prefix + "Username=") for l in lines):
    want.insert(0, (prefix + "Username", "admin"))
for k, v in want:
    lines = [l for l in lines if not l.startswith(k + "=")]
    if header in lines:
        lines.insert(lines.index(header) + 1, k + "=" + v)
    else:
        lines += ["", header, k + "=" + v]
open(path, "w").write("\n".join(lines) + "\n")
EDIT
  if [ "${WAS:-0}" != "0" ]; then
    kube -n pi scale deployment/qbittorrent --replicas="$WAS" >/dev/null
  fi
  echo "  set (user $(sed -n 's/^\(WebUI\\\)\{0,1\}Username=//p' "$QBT_CONF")); no login only from $BYPASS"
else
  echo "  no qBittorrent config at $QBT_CONF; skipped"
fi
unset PW

echo
echo "Done. Each asks for the password on its next visit."
