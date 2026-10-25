#!/usr/bin/env bash
# Builds and installs the Pi Console as a service on this node.
# Run on pi2. Idempotent — safe to re-run to deploy an update.
set -euo pipefail

APP_DIR="/opt/pi-console"
SRC_DIR="${1:-$HOME/dashboard}"
PORT="${PORT:-8080}"
NODE_MAJOR=22

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_READER="${REPO_ROOT}/k8s/dashboard-node-reader.yaml"
ENV_FILE="/etc/pi-console.env"
KUBE_CA="/etc/pi-console-k3s-ca.crt"

if [ ! -f "$SRC_DIR/package.json" ]; then
  echo "No package.json under $SRC_DIR — pass the source directory as the first argument." >&2
  exit 1
fi

echo "==> Node.js"
# Debian 13 ships Node 20; the build needs 22 or newer.
if ! command -v node >/dev/null || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt "$NODE_MAJOR" ]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
fi
node -v

echo "==> pnpm"
sudo npm install -g pnpm@10 --silent
pnpm -v

echo "==> Building in $SRC_DIR"
cd "$SRC_DIR"
pnpm install --frozen-lockfile --prod=false
pnpm run build

# The service and its directory were called tailnet-console before the rename.
# Carry the old install over rather than leaving a second copy running.
OLD_DIR="/opt/tailnet-console"
if [ -f /etc/systemd/system/tailnet-console.service ]; then
  echo "==> Retiring tailnet-console.service"
  sudo systemctl disable --now tailnet-console.service
  sudo rm -f /etc/systemd/system/tailnet-console.service
  sudo systemctl daemon-reload
fi
if [ -d "$OLD_DIR" ] && [ ! -d "$APP_DIR" ]; then
  echo "==> Moving $OLD_DIR to $APP_DIR"
  sudo mv "$OLD_DIR" "$APP_DIR"
fi

echo "==> Installing to $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo rsync -a --delete "$SRC_DIR/dist/" "$APP_DIR/dist/"
# apps.json ships with the rest of the build. It used to be seeded once and
# then left alone, to protect tiles edited on the node — but that also meant a
# tile added to the repo never arrived, which is how the OSINT News tile went
# missing after it was merged. The repo is the source of truth: edit
# dashboard/server/apps.json and deploy.
# node_modules is not needed: the client is bundled and the server imports
# nothing outside the standard library.

SERVICE_USER="${SERVICE_USER:-$(id -un)}"

echo "==> Checking ${SERVICE_USER} can reach tailscaled"
if ! sudo -u "$SERVICE_USER" tailscale status >/dev/null 2>&1; then
  echo "  ${SERVICE_USER} cannot query tailscaled." >&2
  echo "  Grant access with:  sudo tailscale set --operator=${SERVICE_USER}" >&2
  echo "  Node discovery will fail until then." >&2
fi

# The dashboard labels each card control-plane, worker or standalone. Without
# credentials for the cluster every node falls back to standalone, which is how
# pi2 — the board running the k3s server, and this script — described itself
# as standalone for as long as the dashboard has existed.
#
# Only the board running the server can do this, and only while k3s is up. Any
# other board keeps the fallback, which is the correct answer there.
# Every step is best effort and says so by returning non-zero: role labels are
# a nicety, deploying is not. `set -e` does not reach inside a function called
# on the left of `||`, so each step carries its own `|| return 1` rather than
# relying on it.
install_role_labels() {
  sudo k3s kubectl apply -f "$NODE_READER" || return 1

  # The token controller fills the Secret in a moment after it is created.
  local KUBE_TOKEN=""
  for _ in $(seq 1 15); do
    KUBE_TOKEN="$(sudo k3s kubectl -n kube-system get secret pi-console-node-reader \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [ -n "$KUBE_TOKEN" ] && break
    sleep 1
  done
  [ -n "$KUBE_TOKEN" ] || return 1

  # k3s keeps its CA under a root-only directory and the service does not run
  # as root. A CA certificate is public by nature, so a copy it can read is
  # the whole fix; 127.0.0.1 is in the API server's SANs, so no name is
  # needed and the request never leaves the board.
  sudo install -m 644 /var/lib/rancher/k3s/server/tls/server-ca.crt "$KUBE_CA" || return 1

  # Mode 600 and owned by root: systemd reads this before dropping to the
  # service user, so the token is never readable by the account running the
  # server, and never lands in the unit file.
  sudo install -m 600 -o root -g root /dev/null "$ENV_FILE" || return 1
  sudo tee "$ENV_FILE" >/dev/null <<ENVFILE || return 1
KUBE_API_SERVER=https://127.0.0.1:6443
KUBE_TOKEN=${KUBE_TOKEN}
NODE_EXTRA_CA_CERTS=${KUBE_CA}
ENVFILE
}

echo "==> Cluster role labels"
if [ ! -f "$NODE_READER" ]; then
  # The push-based fallback in docs/deploy.md copies this script on its own.
  # Skip rather than fail: role labels are a nicety, deploying is not.
  echo "  no ${NODE_READER##*/} beside this script — leaving role labels alone" >&2
elif command -v k3s >/dev/null && sudo systemctl is-active --quiet k3s; then
  if install_role_labels; then
    echo "  node-reader token installed (nodes get/list only)"
  else
    # A cluster that is up but unhappy must not take the dashboard down with
    # it. Drop any half-written credentials and fall back to standalone.
    echo "  cluster step failed — cards will read standalone." >&2
    sudo rm -f "$ENV_FILE"
  fi
else
  # Not a cluster server, or k3s is gone. Drop a stale token rather than leave
  # the service pointing at a cluster that is no longer there.
  echo "  no k3s server on this board — cards stay standalone"
  sudo rm -f "$ENV_FILE" "$KUBE_CA"
fi

echo
echo "==> Service on :${PORT} as ${SERVICE_USER}"
sudo tee /etc/systemd/system/pi-console.service >/dev/null <<UNIT
[Unit]
Description=Pi — fleet dashboard
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
Environment=PORT=${PORT}
Environment=NODE_ENV=production
# Cluster credentials, written above. Optional: absent on any board that is not
# running the k3s server, and the dashboard falls back to standalone labels.
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=$(command -v node) ${APP_DIR}/dist/server.js
Restart=always
RestartSec=5

# Discovery shells out to the tailscale CLI, which talks to the daemon over
# its local socket. Debian's tailscale package creates no group for that
# socket, so the service runs as the login user, who can already query it.
User=${SERVICE_USER}

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
MemoryMax=256M

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable pi-console.service
sudo systemctl restart pi-console.service

echo
echo "==> Waiting for the server to bind"
for _ in $(seq 1 15); do
  ss -tln | grep -q ":${PORT}\b" && break
  sleep 1
done

echo "==> Status"
systemctl is-active pi-console.service || true
ss -tln | grep ":${PORT}\b" || echo "port ${PORT} not bound"
echo
echo "==> Probing"
if NODES="$(curl -sf --max-time 20 "http://localhost:${PORT}/api/nodes")"; then
  echo "/api/nodes OK"
  case "$NODES" in
    *'"role":"control-plane"'*) echo "  cluster roles OK — a node reads control-plane" ;;
    *) echo "  every node reads standalone — right on a board with no k3s server" ;;
  esac
else
  echo "/api/nodes failed — check: sudo journalctl -u pi-console -n 30"
fi
echo
echo "Next: expose it on the tailnet with"
echo "  sudo tailscale serve --bg ${PORT}"
