#!/usr/bin/env bash
# Runs the dashboard in k3s instead of under systemd. Issue #89.
#
# Runs on the board, like every other script in here. pi2 builds its own image
# with buildkit, which uses k3s' containerd as its worker — so the image is
# written straight into the namespace the kubelet reads. No registry, no tar,
# no second container runtime, and no other machine involved.
set -euo pipefail

SRC_DIR="${1:-$HOME/dashboard}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The kubelet resolves a bare `pi-console:tag` to this, so the image is built
# under the name it will be pulled by.
IMAGE=docker.io/library/pi-console
BUILDKIT_VERSION=v0.33.0
BUILDKIT_ADDR=unix:///run/buildkit/buildkitd.sock
CONTAINERD_SOCK=/run/k3s/containerd/containerd.sock

if [ ! -f "$SRC_DIR/Dockerfile" ]; then
  echo "No Dockerfile under $SRC_DIR — pass the source directory as the first argument." >&2
  exit 1
fi

if ! sudo systemctl is-active --quiet k3s; then
  echo "k3s is not running on this board. This script installs into the cluster;" >&2
  echo "use deploy/install-dashboard.sh for the systemd service instead." >&2
  exit 1
fi

if [ ! -S "$CONTAINERD_SOCK" ]; then
  echo "No containerd socket at ${CONTAINERD_SOCK} — is this a k3s server?" >&2
  exit 1
fi

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

echo "==> buildkit ${BUILDKIT_VERSION}"
# Only the daemon and the client are wanted; the rest of the tarball is the
# rootless helpers, which have nothing to do here.
if [ "$(buildctl --version 2>/dev/null | awk '{print $3}')" != "$BUILDKIT_VERSION" ]; then
  ARCH="$(dpkg --print-architecture)"
  TARBALL="buildkit-${BUILDKIT_VERSION}.linux-${ARCH}.tar.gz"
  # The tarball is 97MB and carries CNI plugins, qemu shims and a runc it does
  # not need here; only the daemon and the client are kept, 102MB installed.
  #
  # No --strip-components: the archive's only top-level entry is bin/, so the
  # two land at /usr/local/bin, which is where the unit below looks for them
  # and the only place on PATH. Stripping the component drops them in
  # /usr/local, where nothing finds them.
  TMP="$(mktemp -d)"
  curl -fsSL -o "${TMP}/bk.tgz" \
    "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/${TARBALL}"
  sudo tar -xzf "${TMP}/bk.tgz" -C /usr/local bin/buildkitd bin/buildctl
  rm -rf "$TMP"
fi
buildctl --version

echo "==> buildkitd"
# --oci-worker=false: without it buildkit brings its own snapshotter and builds
# into a store nothing else can see. The containerd worker writes into k3s'
# own containerd, in the k8s.io namespace the kubelet reads, which is the
# entire point of doing this on the board.
sudo tee /etc/systemd/system/buildkit.service >/dev/null <<UNIT
[Unit]
Description=BuildKit — builds the dashboard image into k3s' containerd
After=k3s.service
Requires=k3s.service

[Service]
Type=simple
ExecStart=/usr/local/bin/buildkitd \\
  --addr ${BUILDKIT_ADDR} \\
  --oci-worker=false \\
  --containerd-worker=true \\
  --containerd-worker-addr ${CONTAINERD_SOCK} \\
  --containerd-worker-namespace k8s.io
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
# Deliberately not enabled at boot. buildkitd is wanted for the length of a
# build and holds tens of MB the rest of the time; on these boards RAM is the
# scarce thing. Started here, stopped on the way out however this exits.
# buildkitd exits 1 on SIGTERM even after a clean build, so systemd marks it
# failed and the morning report lists it; reset-failed clears that.
sudo systemctl restart buildkit.service
trap 'sudo systemctl stop buildkit.service 2>/dev/null; sudo systemctl reset-failed buildkit.service 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  sudo buildctl --addr "$BUILDKIT_ADDR" debug workers >/dev/null 2>&1 && break
  sleep 1
done
sudo buildctl --addr "$BUILDKIT_ADDR" debug workers

# The tag is the commit, so applying the manifest is what triggers a rollout.
# A reused tag under imagePullPolicy: IfNotPresent would leave the old image in
# place and report success.
TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
git -C "$REPO_ROOT" diff --quiet HEAD || TAG="${TAG}-dirty$(date +%H%M%S)"

echo "==> Building ${IMAGE}:${TAG}"
sudo buildctl --addr "$BUILDKIT_ADDR" build \
  --frontend dockerfile.v0 \
  --local context="$SRC_DIR" \
  --local dockerfile="$SRC_DIR" \
  --output "type=image,name=${IMAGE}:${TAG}"

echo "==> Status tab feed"
# Who is using which app comes from the journal and Jellyfin, which only root
# on the PC can read. pi-when writes it to /run/pi-status every 30 seconds and
# the pod reads that directory (k8s/dashboard.yaml).
sudo install -d /usr/local/lib/pi
sudo install -m 755 "${REPO_ROOT}/deploy/pi-when.py" /usr/local/lib/pi/pi-when
sudo ln -sf /usr/local/lib/pi/pi-when /usr/local/bin/pi-when
sudo tee /etc/systemd/system/pi-status.service >/dev/null <<UNIT
[Unit]
Description=Status tab: who is using which app, what Jellyfin and Kiwix hold
After=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/pi/pi-when content
Nice=10
UNIT
sudo tee /etc/systemd/system/pi-status.timer >/dev/null <<UNIT
[Unit]
Description=Refresh the Status tab every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
# The refresh button: the pod writes /run/pi-console/refresh, the one thing it
# can write on the PC, and this runs a scan now: pi-paths, then the feed.
# /run is emptied at boot, so tmpfiles makes the directory, owned by the
# image's node user (1000).
echo "d /run/pi-console 0755 1000 1000 -" | sudo tee /etc/tmpfiles.d/pi-console.conf >/dev/null
sudo systemd-tmpfiles --create /etc/tmpfiles.d/pi-console.conf
sudo tee /etc/systemd/system/pi-status-now.path >/dev/null <<UNIT
[Unit]
Description=Scan who is using what when the console's refresh button asks

[Path]
PathModified=/run/pi-console/refresh

[Install]
WantedBy=paths.target
UNIT
sudo tee /etc/systemd/system/pi-status-now.service >/dev/null <<UNIT
[Unit]
Description=Status tab: scan now, for the refresh button

[Service]
Type=oneshot
ExecStart=/bin/systemctl start pi-paths.service
ExecStart=/bin/systemctl start pi-status.service
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now pi-status.timer pi-status-now.path >/dev/null
sudo systemctl start pi-status.service
sudo test -s /run/pi-status/status.json && echo "  /run/pi-status/status.json written" \
  || echo "  no status file yet: sudo journalctl -u pi-status -n 20"

echo "==> Cluster access for the node labels"
kube apply -f "${REPO_ROOT}/k8s/dashboard-node-reader.yaml"

echo "==> Manifests"
# The namespace and the secret go first: the Deployment mounts the secret, and
# a pod whose secret does not exist yet sits in CreateContainerConfigError
# until it does.
kube create namespace pi --dry-run=client -o yaml | kube apply -f - >/dev/null

# An install from before the OAuth client holds an API key instead (switch with
# deploy/dashboard-oauth.sh). Tailscale caps those at 90 days and will not tell
# a token its own expiry, so the date is recorded beside the key and the
# console reads it back.
# Without it the fleet simply empties one morning with nothing said.
#
# Not asked for. 90 days is both the maximum Tailscale allows and the default
# its form offers, so for a key made minutes ago it is right, and a prompt
# whose answer is almost always "yes, the default" is a keystroke for nothing.
# Set TS_EXPIRES to record a deliberately shorter key instead; the console also
# takes a correction afterwards, which the README spells out.
if [ -n "${TS_EXPIRES:-}" ]; then
  # Kept aside: the assignment below clears it on failure, and the complaint
  # should name what was actually passed.
  GIVEN_EXPIRY="$TS_EXPIRES"
  TS_EXPIRES="$(date -u -d "$GIVEN_EXPIRY" +%Y-%m-%d 2>/dev/null)" || {
    echo "TS_EXPIRES=${GIVEN_EXPIRY} is not a date this board recognises." >&2
    exit 1
  }
else
  TS_EXPIRES="$(date -u -d "+90 days" +%Y-%m-%d)"
fi

if ! kube -n pi get secret pi-console-tailscale >/dev/null 2>&1; then
  echo
  echo "  A pod has no tailscaled socket, so node discovery uses the Tailscale API,"
  echo "  through a read-only OAuth client that never expires. Make one at"
  echo "  https://login.tailscale.com/admin/settings/oauth (Devices: Core, Read only)."
  NO_RESTART=1 bash "${REPO_ROOT}/deploy/dashboard-oauth.sh"
elif kube -n pi get secret pi-console-tailscale -o jsonpath="{.data.oauth-id}" | grep -q .; then
  echo "  tailscale OAuth client present — nothing expires"
elif ! kube -n pi get secret pi-console-tailscale -o jsonpath="{.data.expires}" | grep -q .; then
  # A Secret written before the console could show an expiry. Ask for the date
  # alone rather than making someone mint a fresh key to record one.
  echo "  secret present but carries no expiry — the console cannot warn you yet"
  kube -n pi patch secret pi-console-tailscale --type merge \
    -p "{\"stringData\":{\"expires\":\"${TS_EXPIRES}\"}}" >/dev/null
  echo "  expiry recorded: ${TS_EXPIRES}"
else
  echo "  tailscale secret already present — leaving it alone"
  echo "  (replace it with: sudo k3s kubectl -n pi delete secret pi-console-tailscale, then re-run)"
fi

# The shim's token, from the file agent/install.sh made. Re-applied each run
# so the two cannot drift; the value never touches the command line.
if sudo test -s /etc/pi/agent-token; then
  sudo sed -n 's/^AGENT_TOKEN=//p' /etc/pi/agent-token \
    | kube -n pi create secret generic pi-console-agent --from-file=token=/dev/stdin \
        --dry-run=client -o yaml | kube apply -f - >/dev/null
  echo "  agent token copied into pi-console-agent"
else
  echo "  no /etc/pi/agent-token — run agent/install.sh first, or Files will be refused" >&2
fi

# Where sign-in keeps its passkeys and session key (server/lib/login.ts).
# Owned by the image's node user; nobody else needs to read it.
sudo install -d -m 700 -o 1000 -g 1000 "/1) Archive/Apps/Console"

sed "s/__TAG__/${TAG}/" "${REPO_ROOT}/k8s/dashboard.yaml" | apply_guarded

echo "==> Waiting for the rollout"
kube -n pi rollout status deployment/pi-console --timeout=180s

echo "==> Retiring the systemd unit"
# Both would answer on different ports, and the tailnet URL would follow
# whichever `tailscale serve` points at. Leaving it running is how a stale
# build ends up looking like the live one.
sudo systemctl disable --now pi-console.service 2>/dev/null || true
sudo tailscale serve reset
sudo tailscale serve --bg 80
# The reset above also drops the job bot's live view (noVNC on :6080), which browsers only
# allow clicks on over https: put it back on 8443. In its container it is a Service
# (k8s/applypilot.yaml); before that, a listener on the tailnet address.
LIVE_IP=$(kube -n applypilot get svc liveview -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
[ -n "$LIVE_IP" ] || LIVE_IP=$(ss -Hltn 'sport = :6080' | awk '{print $4}' | sed 's/:6080$//' | grep -m1 '^100\.' || true)
[ -n "$LIVE_IP" ] && sudo tailscale serve --bg --https=8443 "http://$LIVE_IP:6080" >/dev/null
sudo tailscale serve status

echo
echo "==> Probing through the ingress"
# Retried: the pod reports Ready a few seconds before the ingress routes to it,
# and a single attempt in that gap printed 503 after every good deploy.
code=000
for _ in $(seq 1 15); do
  # /healthz: everything else sends a request without a session to /login.
  code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://localhost/healthz || true)
  case "$code" in 2*|3*) break ;; esac
  sleep 2
done
echo "  localhost:80 -> HTTP $code"
case "$code" in
  2*|3*) ;;
  *) echo "  ingress did not answer — sudo k3s kubectl -n pi logs deploy/pi-console" ;;
esac
kube -n pi get pods -o wide

echo
echo "Rollback:            sudo k3s kubectl -n pi rollout undo deployment/pi-console"
echo "Back to systemd:     sudo k3s kubectl delete -f ${REPO_ROOT}/k8s/dashboard.yaml && make dashboard"
