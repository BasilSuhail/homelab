#!/usr/bin/env bash
# Where the dashboard is running, and how it is doing.
#
# The board can hold it either way: `make dashboard` installs a systemd unit,
# `make dashboard-k8s` runs it as a Deployment and retires that unit. Neither
# target records which one ran last, and asking the wrong one is how a healthy
# dashboard reads as down. So ask the board.
#
#   status   name which of the two holds it, and its state
#   logs     recent output from whichever one holds it
#
# Reporting both is not a fallthrough case. It means two servers are answering
# on different ports and the tailnet URL is showing whichever `tailscale serve`
# points at, which is the stale-build trap install-dashboard-k8s.sh avoids.
set -uo pipefail

MODE="${1:-status}"
NS=pi
DEPLOY=pi-console
UNIT=pi-console.service

# k3s keeps its kubeconfig root-only, so the cluster half needs sudo. This runs
# from `make check` over a non-interactive ssh with no terminal to type into,
# so -n is mandatory: without it sudo blocks on a prompt nobody can answer.
kube()       { sudo -n k3s kubectl -n "$NS" "$@" 2>/dev/null; }
# systemctl and journalctl answer for a unit without privileges.
in_systemd() { systemctl is-enabled --quiet "$UNIT" 2>/dev/null; }

# Three states, not two. "Could not ask" reported as "not installed" would turn
# a password prompt into a false alarm about a dashboard that is running fine.
if ! sudo -n true 2>/dev/null; then
  K8S=unknown
elif kube get deploy "$DEPLOY" >/dev/null 2>&1; then
  K8S=yes
else
  K8S=no
fi

case "$MODE" in
  status)
    if [ "$K8S" = yes ]; then
      # readyReplicas is absent, not zero, while no pod is ready — which is
      # the state this command exists to report. Asked for separately so an
      # empty field becomes 0 rather than swallowing the numerator.
      ready="$(kube get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}')"
      want="$(kube get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
      echo "dashboard: k3s Deployment, ${ready:-0}/${want:-1} ready"
    fi
    if in_systemd; then
      echo "dashboard: systemd unit, $(systemctl is-active "$UNIT")"
    fi

    if [ "$K8S" = yes ] && in_systemd; then
      echo "dashboard: WARNING — both are live. Retire one, or the URL and the" \
           "logs disagree about which build you are looking at."
    elif [ "$K8S" = unknown ]; then
      echo "dashboard: k3s not asked — sudo wants a password over this ssh." \
           "Any systemd line above is still accurate."
    elif [ "$K8S" = no ] && ! in_systemd; then
      echo "dashboard: neither a Deployment nor an enabled unit — not installed"
    fi
    ;;

  logs)
    [ "$K8S" = yes ] && kube logs "deploy/$DEPLOY" --tail=40
    in_systemd && journalctl -u "$UNIT" -n 40 --no-pager
    [ "$K8S" = unknown ] && echo "k3s not asked — sudo wants a password over this ssh." >&2
    [ "$K8S" = no ] && ! in_systemd && echo "dashboard: not installed by either route"
    ;;

  *)
    echo "usage: ${0##*/} [status|logs]" >&2
    exit 2
    ;;
esac

exit 0
