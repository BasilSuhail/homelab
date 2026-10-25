#!/usr/bin/env bash
# Vaultwarden in k3s, on its own tailnet name. Runs on the board.
#
# Needs the Tailscale operator, which deploy/install-uptime-kuma.sh installs.
# Safe to re-run: the config is written once and left alone afterwards, so a
# redeploy cannot reopen registration after it has been closed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=vaultwarden-config

if ! sudo systemctl is-active --quiet k3s; then
  echo "k3s is not running on this board. This installs into the cluster." >&2
  exit 1
fi

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

if ! kube get ingressclass tailscale >/dev/null 2>&1; then
  echo "No tailscale IngressClass. Run 'make uptime' first, which installs the" >&2
  echo "operator this needs to put a service on the tailnet." >&2
  exit 1
fi

echo "==> Config"
if kube -n pi get configmap "$CONFIG" >/dev/null 2>&1; then
  echo "  already present — leaving it alone"
  echo "  registration is currently: $(kube -n pi get configmap "$CONFIG" -o jsonpath='{.data.SIGNUPS_ALLOWED}')"
else
  # Read from the board rather than written into the repo, so the tailnet name
  # lives in one place. DOMAIN has to match the URL a browser actually uses:
  # Bitwarden clients check it, and WebAuthn refuses to register against a
  # mismatch.
  # Parsed rather than matched. tailscaled pretty-prints its JSON, so a
  # pattern expecting `"key":"value"` misses the space after the colon and
  # silently yields nothing.
  TAILNET="$(sudo tailscale status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("MagicDNSSuffix") or "")' 2>/dev/null)"
  [ -n "$TAILNET" ] || {
    echo "  Could not read the tailnet name from tailscaled. Is it up?" >&2
    exit 1
  }

  # Registration is open for the first visit and closed immediately after, by
  # the command printed at the end. Open is the only way to create the first
  # account without also standing up the admin panel and a token to guard it.
  kube -n pi create configmap "$CONFIG" \
    --from-literal="DOMAIN=https://vault.${TAILNET}" \
    --from-literal="SIGNUPS_ALLOWED=true" >/dev/null
  echo "  created, registration open for the first account"
fi

echo "==> Manifests"
# The manifest's hostPaths carry __APPS_DIR__, filled here the same way
# deploy/install-media.sh does. Applied raw, the pod would mount a path that
# does not exist and the running vault would be replaced by one that cannot start.
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
sed -e "s|__APPS_DIR__|${APPS_DIR}|g" "${REPO_ROOT}/k8s/vaultwarden.yaml" | apply_guarded
kube -n pi rollout status deployment/vaultwarden --timeout=300s

echo "==> Waiting for its tailnet name"
HOST=""
for _ in $(seq 1 60); do
  HOST="$(kube -n pi get ingress vault -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$HOST" ] && break
  sleep 5
done

echo
if [ -n "$HOST" ]; then
  echo "  https://${HOST}"
else
  echo "  No hostname yet. It can take a few minutes on a first run." >&2
  echo "  Watch: sudo k3s kubectl -n pi get ingress vault -w" >&2
fi

cat <<'NEXT'

Next, in this order:

  1. Open the URL above and create your account. Use a strong, different
     master password: this vault is not the one you already have.

  2. Import the copy. In Bitwarden, Tools > Export vault, format .json.
     Then here, Tools > Import data, "Bitwarden (json)". Delete the export
     file afterwards, it is plain text.

  3. Close registration, so nobody else can make an account:

       sudo k3s kubectl -n pi patch configmap vaultwarden-config \
         --type merge -p '{"data":{"SIGNUPS_ALLOWED":"false"}}'
       sudo k3s kubectl -n pi rollout restart deployment/vaultwarden

Attachments do not come across in a JSON export, and neither do Sends or
password history. Everything else, including TOTP codes, does.

NEXT
echo "Rollback:  sudo k3s kubectl delete -f ${REPO_ROOT}/k8s/vaultwarden.yaml"
