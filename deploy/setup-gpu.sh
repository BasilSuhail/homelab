#!/usr/bin/env bash
# Lets k3s hand the NVIDIA card to a container, and gives it to Jellyfin for
# hardware transcoding. Runs on the board. Idempotent.
#
# Needs the NVIDIA driver already working on the host (nvidia-smi answers).
# Installs NVIDIA's container toolkit from NVIDIA's own repository, then
# restarts k3s, which finds the runtime at start and defines the `nvidia`
# RuntimeClass by itself. Running pods carry on through the restart.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kube() { sudo k3s kubectl "$@"; }
. "${REPO_ROOT}/deploy/lib/jellyfin-gpu.sh"

if ! nvidia-smi -L >/dev/null 2>&1; then
  echo "nvidia-smi does not answer: install the NVIDIA driver first (docs/pc.md)." >&2
  exit 1
fi

echo "==> NVIDIA container toolkit"
if [ -x /usr/bin/nvidia-container-runtime ]; then
  echo "  already installed"
else
  KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --yes -o "$KEYRING"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-container-toolkit >/dev/null
  echo "  installed"
fi

echo "==> k3s picks up the runtime"
if ! sudo grep -qs nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml; then
  sudo systemctl restart k3s
  for _ in $(seq 1 60); do kube get nodes >/dev/null 2>&1 && break; sleep 2; done
fi
sudo grep -qs nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
  && echo "  containerd has the nvidia runtime" \
  || { echo "  k3s did not register the nvidia runtime" >&2; exit 1; }
for _ in $(seq 1 30); do kube get runtimeclass nvidia >/dev/null 2>&1 && break; sleep 2; done
kube get runtimeclass nvidia >/dev/null && echo "  RuntimeClass nvidia present"

echo "==> A throwaway pod sees the card"
kube -n pi delete pod gpu-test --ignore-not-found >/dev/null
kube -n pi run gpu-test --restart=Never --image=docker.io/library/debian:trixie-slim \
  --overrides='{"spec":{"runtimeClassName":"nvidia"}}' \
  --env NVIDIA_VISIBLE_DEVICES=all --env NVIDIA_DRIVER_CAPABILITIES=utility \
  -- nvidia-smi -L >/dev/null
for _ in $(seq 1 60); do
  phase=$(kube -n pi get pod gpu-test -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 2
done
kube -n pi logs gpu-test 2>&1 | sed 's/^/  /'
kube -n pi delete pod gpu-test --ignore-not-found >/dev/null
[ "$phase" = Succeeded ] || { echo "  the test pod could not use the GPU" >&2; exit 1; }

echo "==> Jellyfin"
jellyfin_gpu
kube -n pi rollout status deployment/jellyfin --timeout=300s
kube -n pi exec deploy/jellyfin -- nvidia-smi -L 2>&1 | sed 's/^/  inside jellyfin: /'

cat <<'NOTE'

Now switch it on in Jellyfin: Dashboard > Playback > Transcoding.
  Hardware acceleration           NVIDIA NVENC
  Enable hardware decoding for    H264, HEVC, MPEG2, VC1, VP8, VP9,
                                  HEVC 10bit, VP9 10bit   (not AV1: this card cannot)
  Enable hardware encoding        on
  Allow encoding in HEVC format   off   (browsers need H.264)
  Enable tone mapping             on    (HDR films on SDR screens)
Save at the bottom. Rollback: Hardware acceleration back to None.
NOTE
