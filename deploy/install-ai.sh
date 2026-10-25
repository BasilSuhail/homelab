#!/usr/bin/env bash
# The local AI on the PC's GPU: builds llama.cpp's server for the card,
# downloads the model, runs it in the cluster, then asks it one question and
# reports the speed. Runs on the board. Idempotent: the image is built once per
# llama.cpp release and the model downloaded once. Plan: issue #200.
#
# Needs the GPU runtime (deploy/setup-gpu.sh) and buildkit (installed by
# deploy/install-dashboard-k8s.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
MODELS="$APPS_DIR/AI/models"
BUILDKIT_ADDR=unix:///run/buildkit/buildkitd.sock
IMAGE=docker.io/library/pi-ai
LLAMA_TAG=$(sed -n 's/^ARG LLAMA_TAG=//p' "$REPO_ROOT/ai/Dockerfile")

# Qwen3.5-4B at 4 bits: tool calling and a thinking mode built in, about 3GB.
# The checksum is the file's on Hugging Face; a mismatch is never used.
MODEL=Qwen_Qwen3.5-4B-Q4_K_M.gguf
MODEL_URL=https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/$MODEL
MODEL_SHA256=13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983

kube() { sudo k3s kubectl "$@"; }
free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc 0-9; }

echo "==> Checks"
kube get runtimeclass nvidia >/dev/null 2>&1 || { echo "No nvidia runtime in k3s. Run deploy/setup-gpu.sh first." >&2; exit 1; }
nvidia-smi -L
systemctl cat buildkit.service >/dev/null 2>&1 || { echo "No buildkit. Run deploy/install-dashboard-k8s.sh once first." >&2; exit 1; }
[ -d "$APPS_DIR" ] || { echo "No $APPS_DIR." >&2; exit 1; }

echo "==> Model"
sudo install -d -o "$OWNER" -g "$(id -g "$OWNER")" "$APPS_DIR/AI" "$MODELS"
if [ -f "$MODELS/$MODEL.ok" ] && [ -f "$MODELS/$MODEL" ]; then
  echo "  $MODEL already here and checked"
else
  [ "$(free_gb "$APPS_DIR")" -ge 5 ] || { echo "Less than 5GB free in $APPS_DIR." >&2; exit 1; }
  # A partial download resumes; it is checked before it gets its real name.
  curl -fL --retry 5 -C - -o "$MODELS/$MODEL.part" "$MODEL_URL"
  echo "$MODEL_SHA256  $MODELS/$MODEL.part" | sha256sum -c --quiet || {
    echo "Checksum mismatch; the download was removed." >&2; rm -f "$MODELS/$MODEL.part"; exit 1; }
  mv "$MODELS/$MODEL.part" "$MODELS/$MODEL"
  touch "$MODELS/$MODEL.ok"
  echo "  downloaded and checked"
fi

echo "==> Image ${IMAGE}:${LLAMA_TAG}"
if sudo k3s ctr -n k8s.io images ls -q | grep -qx "${IMAGE}:${LLAMA_TAG}"; then
  echo "  already built"
else
  # The CUDA build image is several GB while it exists.
  [ "$(free_gb /var/lib/rancher)" -ge 15 ] || { echo "Less than 15GB free for the build in /var/lib/rancher." >&2; exit 1; }
  echo "  compiling llama.cpp for the GPU: 15-30 minutes, the apps keep running"
  sudo systemctl restart buildkit.service
  # buildkitd exits 1 on SIGTERM even after a clean build; reset-failed keeps
  # it out of the morning report.
  trap 'sudo systemctl stop buildkit.service 2>/dev/null; sudo systemctl reset-failed buildkit.service 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do
    sudo buildctl --addr "$BUILDKIT_ADDR" debug workers >/dev/null 2>&1 && break
    sleep 1
  done
  sudo buildctl --addr "$BUILDKIT_ADDR" build \
    --frontend dockerfile.v0 \
    --local context="$REPO_ROOT/ai" \
    --local dockerfile="$REPO_ROOT/ai" \
    --output "type=image,name=${IMAGE}:${LLAMA_TAG}"
  # The build cache holds the CUDA toolkit image; the result does not need it.
  sudo buildctl --addr "$BUILDKIT_ADDR" prune --all >/dev/null
  echo "  built; build cache cleared"
fi

echo "==> Deploy"
sed -e "s|__APPS_DIR__|${APPS_DIR}|g" \
    -e "s|__MODEL__|${MODEL}|g" \
    -e "s|__TAG__|${LLAMA_TAG}|g" \
    -e "s|__UID__|$(id -u "$OWNER")|g" \
    -e "s|__GID__|$(id -g "$OWNER")|g" "$REPO_ROOT/k8s/ai.yaml" | kube apply -f -
kube -n pi rollout status deployment/ai --timeout=300s

echo "==> First question"
# The first answer includes loading the model onto the card.
reply=$(kube -n pi exec deploy/ai -- curl -s -m 300 localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"In one sentence: what does a degraded RAID1 array mean?"}],"max_tokens":200,"chat_template_kwargs":{"enable_thinking":false}}')
echo "$reply" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("  answer:", r["choices"][0]["message"]["content"].strip())
t = r.get("timings", {})
print("  speed:  %.1f tokens/s writing, %.0f tokens/s reading" % (t.get("predicted_per_second", 0), t.get("prompt_per_second", 0)))'
echo
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | sed 's/^/  GPU memory: /'
echo "  The model unloads after 10 idle minutes and reloads on the next question."
