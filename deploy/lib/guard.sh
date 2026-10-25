# Sourced by the installers, which already define kube().
#
#   render k8s/app.yaml | apply_guarded
#
# kube apply -f -, after refusing a second copy of an app. Immich's database
# was corrupted three times by one: a stale Immich in another namespace
# (`pi1`) whose Postgres mounted the same folder as the live one. Postgres's
# lock file does not stop that — in a container both postmasters are PID 1,
# so each takes the other's lock for its own — and nothing else did either.
#
# Refused when a Deployment, StatefulSet or DaemonSet in ANOTHER namespace
#   - has the same name as one being installed, or
#   - mounts the same host folder.
# Same-namespace sharing is left alone: that is Nextcloud showing Immich's
# folder read-only, not a second Immich. /dev is not data (qBittorrent's
# /dev/net/tun), so it never counts.
apply_guarded() {
  local manifest new live clash
  manifest=$(cat)
  command -v jq >/dev/null || sudo apt-get install -y jq >/dev/null
  new=$(kube apply --dry-run=client -o json -f - <<<"$manifest")
  live=$(kube get deployments,statefulsets,daemonsets -A -o json)
  # From files, not --argjson: one argument caps at 128 KB, and a cluster-wide
  # listing passes that easily.
  clash=$(jq -rn --slurpfile new <(printf '%s' "$new") --slurpfile live <(printf '%s' "$live") '
    ($new[0]) as $new | ($live[0]) as $live
    | def items: if .kind == "List" then .items else [.] end;
    def workload: .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet";
    def paths: [.spec.template.spec.volumes[]? | .hostPath.path // empty
                | select(startswith("/dev/") | not)];
    ($new | items | map(select(workload))) as $mine
    | $mine[] as $m
    | ($m | paths) as $mp
    | $live.items[]
    | select(.metadata.namespace != $m.metadata.namespace)
    | (paths) as $tp
    | ($mp - ($mp - $tp)) as $shared
    | select(.metadata.name == $m.metadata.name or ($shared | length > 0))
    | "  \(.metadata.namespace)/\(.metadata.name) (\(.kind), \(.spec.replicas // "-") replicas)"
      + (if ($shared | length) > 0 then " mounts \($shared | join(", "))"
         else " has the same name" end)
      + " as \($m.metadata.namespace)/\($m.metadata.name)"')
  if [ -n "$clash" ]; then
    {
      echo
      echo "Refusing to install: another copy of this app is in the cluster."
      echo "$clash"
      echo
      echo "Two copies on one folder is what corrupted Immich's database. Check what"
      echo "the other copy holds, then remove it, for example:"
      echo "  sudo k3s kubectl -n <namespace> get deploy,statefulset,pvc"
      echo "  sudo k3s kubectl -n <namespace> delete deploy <name>"
      echo "and re-run. Nothing was changed."
    } >&2
    return 1
  fi
  kube apply -f - <<<"$manifest"
}
