#!/usr/bin/env bash
# The dashboard reads the device list with a read-only Tailscale OAuth client
# instead of an API key. An API key lasts 90 days and carries its owner's full
# admin rights; this client never expires and can only read devices.
#
# Make it first: https://login.tailscale.com/admin/settings/oauth
#   Generate OAuth client > Devices: Core, Read only > Generate.
# Then run this on the PC and paste the client ID and secret when asked.
# Run install-dashboard-k8s.sh first if the dashboard predates OAuth support.
#
# Swaps the Secret, restarts the dashboard and checks it can list devices.
# The old API key is removed only once that works. Revoke it afterwards on
# https://login.tailscale.com/admin/settings/keys
set -euo pipefail

kube() { sudo k3s kubectl "$@"; }
SECRET=pi-console-tailscale

printf '  OAuth client ID: '
IFS= read -r ID
# Prompt printed separately rather than passed to read -p: the secret scanner
# reads a prompt string next to a variable as a credential in the source.
printf '  OAuth client secret (not shown): '
IFS= read -rs SEC
echo
[ -n "$ID" ] && [ -n "$SEC" ] || { echo "  Both are needed — stopping." >&2; exit 1; }

echo "==> Checking the client with Tailscale"
TOKEN=$(curl -fsS https://api.tailscale.com/api/v2/oauth/token \
  --data-urlencode "client_id=$ID" --data-urlencode "client_secret=$SEC" \
  -d grant_type=client_credentials | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || true
[ -n "$TOKEN" ] || { echo "  Tailscale refused that ID and secret — nothing changed." >&2; exit 1; }
COUNT=$(curl -fsS -H "Authorization: Bearer $TOKEN" https://api.tailscale.com/api/v2/tailnet/-/devices \
  | grep -o '"nodeId"' | wc -l) || COUNT=0
unset TOKEN
[ "$COUNT" -gt 0 ] || { echo "  The client cannot read devices. Give it Devices: Core, Read." >&2; exit 1; }
echo "  ok: it can see $COUNT devices"

echo "==> Secret"
if kube -n pi get secret "$SECRET" >/dev/null 2>&1; then
  kube -n pi patch secret "$SECRET" --type merge \
    -p "{\"stringData\":{\"oauth-id\":\"$ID\",\"oauth-secret\":\"$SEC\"}}" >/dev/null
else
  kube -n pi create secret generic "$SECRET" \
    --from-literal=oauth-id="$ID" --from-literal=oauth-secret="$SEC" >/dev/null
fi
unset SEC
[ "${NO_RESTART:-}" = 1 ] && exit 0

echo "==> Restarting the dashboard"
kube -n pi rollout restart deployment/pi-console >/dev/null
kube -n pi rollout status deployment/pi-console --timeout=180s
IP=$(kube -n pi get svc pi-console -o jsonpath='{.spec.clusterIP}')
for _ in 1 2 3 4 5 6; do
  NODES=$(curl -fsS "http://$IP/api/nodes" 2>/dev/null | grep -o '"tailscaleIp"' | wc -l) || NODES=0
  [ "$NODES" -gt 0 ] && break
  sleep 5
done
if [ "$NODES" -gt 0 ]; then
  echo "  ok: the dashboard lists $NODES boards through the OAuth client"
  kube -n pi patch secret "$SECRET" --type json \
    -p '[{"op":"remove","path":"/data/api-key"},{"op":"remove","path":"/data/expires"}]' >/dev/null 2>&1 || true
  echo "  old API key removed from the PC. Revoke it too: https://login.tailscale.com/admin/settings/keys"
else
  echo "  The dashboard lists no boards yet; the old key is kept. Logs:" >&2
  echo "  sudo k3s kubectl -n pi logs deploy/pi-console --tail=30" >&2
  exit 1
fi
