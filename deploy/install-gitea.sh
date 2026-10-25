#!/usr/bin/env bash
# Gitea in k3s, on its own tailnet name, plus the manual backup command.
# Runs on the PC. Issue #201.
#
# Needs the Tailscale operator, which deploy/install-uptime-kuma.sh installs.
# Safe to re-run: the secret key is made once, the admin account only when
# there is none, and the folders are never re-owned once they exist.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
# The repos go on HDD2 with the other apps' data.
DATA_DIR="${DATA_DIR:-/srv/hdd2}"
DIR="$APPS_DIR/Gitea"
REPOS="$DATA_DIR/Gitea"

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

echo "==> Checks"
sudo systemctl is-active --quiet k3s || { echo "k3s is not running on this PC." >&2; exit 1; }
kube get ingressclass tailscale >/dev/null 2>&1 || {
  echo "No tailscale IngressClass. Run 'make uptime' first, which installs the operator." >&2; exit 1; }
[ -d "$APPS_DIR" ] || { echo "No $APPS_DIR." >&2; exit 1; }
# Never make the folder in an unmounted mount point: that is the boot SSD.
mountpoint -q "$DATA_DIR" || { echo "$DATA_DIR is not mounted." >&2; exit 1; }
# Parsed rather than matched: tailscaled pretty-prints its JSON.
TAILNET="$(sudo tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null)"
[ -n "$TAILNET" ] || { echo "Could not read the tailnet name from tailscaled. Is it up?" >&2; exit 1; }

echo "==> Folders"
# Made, not re-owned: install -d on an existing folder would also chown it.
for d in "$DIR" "$DIR/config" "$DIR/dumps" "$REPOS"; do
  [ -d "$d" ] || sudo install -d -m 750 -o "$OWNER" -g "$(id -g "$OWNER")" "$d"
done
echo "  app and database: $DIR"
echo "  repos:            $REPOS"

echo "==> Secret key"
if kube -n pi get secret gitea-secret >/dev/null 2>&1; then
  echo "  already present, leaving it alone"
else
  # Changing it later breaks every stored two-factor secret, so it is made
  # once and never rewritten.
  kube -n pi create secret generic gitea-secret \
    --from-literal="SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)" >/dev/null
  echo "  created"
fi

echo "==> Manifests"
sed -e "s|__APPS_DIR__|${APPS_DIR}|g" \
    -e "s|__DATA_DIR__|${DATA_DIR}|g" \
    -e "s|__TAILNET__|${TAILNET}|g" \
    -e "s|__UID__|$(id -u "$OWNER")|g" \
    -e "s|__GID__|$(id -g "$OWNER")|g" "${REPO_ROOT}/k8s/gitea.yaml" | apply_guarded
kube -n pi rollout status deployment/gitea --timeout=300s || {
  echo "  gitea did not come up. Logs:" >&2
  kube -n pi logs deployment/gitea --tail=40 2>&1 | sed 's/^/    /' >&2
  exit 1
}

echo "==> Admin account"
# One header line, then one line per admin.
if [ "$(kube -n pi exec deploy/gitea -- gitea admin user list --admin 2>/dev/null | wc -l)" -gt 1 ]; then
  echo "  an admin already exists, leaving accounts alone"
elif [ -t 0 ]; then
  read -r -p "  Admin username for Gitea: " ADMIN_USER
  read -r -p "  Admin email (Gitea needs one; it sends nothing): " ADMIN_EMAIL
  # A random password, shown once, changed at the first sign-in.
  kube -n pi exec deploy/gitea -- gitea admin user create --admin \
    --username "$ADMIN_USER" --email "$ADMIN_EMAIL" \
    --random-password --must-change-password | sed 's/^/  /'
else
  echo "  no terminal to ask on; make it later with:" >&2
  echo "  sudo k3s kubectl -n pi exec deploy/gitea -- gitea admin user create --admin --username NAME --email EMAIL --random-password --must-change-password" >&2
fi

echo "==> Backup command"
sudo install -d /usr/local/lib/pi
sudo install -m 755 "${REPO_ROOT}/deploy/gitea-backup.sh" /usr/local/lib/pi/gitea-backup
sudo ln -sf /usr/local/lib/pi/gitea-backup /usr/local/bin/gitea-backup
echo "  sudo gitea-backup"

echo "==> Waiting for its tailnet name"
HOST=""
for _ in $(seq 1 60); do
  HOST="$(kube -n pi get ingress git -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$HOST" ] && break
  sleep 5
done
echo
if [ -n "$HOST" ]; then
  echo "  https://${HOST}"
else
  echo "  No hostname yet. It can take a few minutes on a first run." >&2
  echo "  Watch: sudo k3s kubectl -n pi get ingress git -w" >&2
fi

cat <<NEXT

Next:

  1. Sign in with the password above and set your own.

  2. Uptime Kuma: Add New Monitor
       Type     HTTP(s) - Keyword
       Name     Gitea
       URL      http://gitea.pi.svc.cluster.local:3000/api/healthz
       Keyword  pass
     and tick the Discord notification.

  3. A backup, whenever you want one:  sudo gitea-backup

Rollback:  sudo k3s kubectl -n pi delete deploy/gitea svc/gitea ingress/git
NEXT
