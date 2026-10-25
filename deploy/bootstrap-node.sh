#!/usr/bin/env bash
# Gives a node its own read-only checkout of this repo, so deploys are a pull
# on the board rather than a push from the Mac.
#
# Run on the Mac:  bash deploy/bootstrap-node.sh homelab
# Idempotent — re-running verifies the key and the clone rather than replacing
# them. Needed once per node, and again only if the node is reimaged.
set -euo pipefail

NODE="${1:-}"
if [ -z "$NODE" ]; then
  echo "Usage: bash deploy/bootstrap-node.sh <node>   # e.g. homelab" >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-homelab}"
# The branch the node checks out: this checkout's own unless BRANCH is set.
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -vx HEAD || echo main)}"
KEY="~/.ssh/id_${REPO_DIR}_deploy"

# The slug comes from the remote rather than being written down here, so a
# fork or a rename needs no edit.
SLUG="$(git config --get remote.origin.url | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
[ -n "$SLUG" ] || { echo "No origin remote — run this from a checkout." >&2; exit 1; }

# One authenticated connection, reused by every ssh below, so the password is
# asked for once instead of three times.
SOCK="$(mktemp -u "/tmp/bootstrap-${NODE}-XXXXXX")"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=120s)
cleanup() { "${SSH[@]}" -O exit "$NODE" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Deploy key on ${NODE}"
PUBKEY="$("${SSH[@]}" "$NODE" "
  set -e
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  [ -f ${KEY} ] || ssh-keygen -t ed25519 -N '' -C '${NODE}-${REPO_DIR}-deploy' -f ${KEY} -q
  cat ${KEY}.pub
")"

echo "==> Registering it on ${SLUG} (read-only)"
TITLE="${NODE} — ${REPO_DIR} deploy (read-only)"
if gh repo deploy-key list --repo "$SLUG" | grep -qF "$TITLE"; then
  echo "    already registered"
else
  TMP="$(mktemp)"; printf '%s\n' "$PUBKEY" > "$TMP"
  gh repo deploy-key add "$TMP" --repo "$SLUG" --title "$TITLE"
  rm -f "$TMP"
fi

echo "==> Checkout at ~/${REPO_DIR} on ${NODE}"
"${SSH[@]}" "$NODE" "
  set -e
  # The key is bound to this repo alone, so it is selected by host alias
  # rather than becoming the default identity for all of GitHub.
  grep -q 'Host ${REPO_DIR}.github' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<CFG
Host ${REPO_DIR}.github
    HostName github.com
    User git
    IdentityFile ${KEY}
    IdentitiesOnly yes
CFG
  chmod 600 ~/.ssh/config
  ssh-keyscan -t ed25519 github.com 2>/dev/null | grep -qxFf - ~/.ssh/known_hosts 2>/dev/null \
    || ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
  if [ -d ~/${REPO_DIR}/.git ]; then
    git -C ~/${REPO_DIR} remote set-url origin ${REPO_DIR}.github:${SLUG}.git
    git -C ~/${REPO_DIR} fetch --quiet origin
    git -C ~/${REPO_DIR} checkout --quiet -B ${BRANCH} origin/${BRANCH}
    git -C ~/${REPO_DIR} reset --hard --quiet origin/${BRANCH}
  else
    git clone --quiet --branch ${BRANCH} ${REPO_DIR}.github:${SLUG}.git ~/${REPO_DIR}
  fi
  echo \"    \$(git -C ~/${REPO_DIR} log --oneline -1)\"
"

echo
echo "Done. Deploys to ${NODE} are now:  make dashboard"
