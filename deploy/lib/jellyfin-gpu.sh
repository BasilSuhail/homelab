# Sourced, not run. Gives Jellyfin the NVIDIA card when this machine has one
# and the container runtime for it (deploy/setup-gpu.sh), and does nothing
# otherwise, so the same install works on a board without a GPU.
#
# The NVIDIA runtime hands a container the card when NVIDIA_VISIBLE_DEVICES
# says so; `video` is what NVENC and NVDEC need, `utility` brings nvidia-smi
# in for checking. A patch rather than a field in k8s/jellyfin.yaml, because
# runtimeClassName naming a runtime that does not exist stops the pod
# starting at all.
jellyfin_gpu() {
  if sudo k3s kubectl get runtimeclass nvidia >/dev/null 2>&1 \
     && [ -x /usr/bin/nvidia-container-runtime ] && command -v nvidia-smi >/dev/null; then
    sudo k3s kubectl -n pi patch deployment jellyfin --type strategic -p '{
      "spec": {"template": {"spec": {
        "runtimeClassName": "nvidia",
        "containers": [{"name": "jellyfin", "env": [
          {"name": "NVIDIA_VISIBLE_DEVICES", "value": "all"},
          {"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "compute,video,utility"}
        ]}]
      }}}}' >/dev/null
    echo "  jellyfin: GPU attached for hardware transcoding"
  fi
}
