#!/usr/bin/env bash
# ArchiveBox 0.9: a self-hosted internet archive. Runs on the PC.
#
# Feed it URLs — from the browser extension, the Add page, a bookmarks export
# or an RSS feed — and it saves full copies of everything it finds: HTML,
# screenshots, PDFs, media, WARC files, git repos.
#
# The split is the same as every other app here:
#
#   SSD        the index: a SQLite database, the config, logs and personas.
#              Small, read at random, and the part where speed is felt.
#   big drive  the archived content under archive/. Large, read in sequence.
#
# Re-runnable. An install still on 0.7 is set aside first (renamed, nothing
# deleted) and 0.9 starts a fresh collection.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

if [ -z "${APPS_DIR:-}" ]; then
  for candidate in "/1) Archive" /srv/archive; do
    [ -d "$candidate" ] && { APPS_DIR="$candidate/Apps"; break; }
  done
fi
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
DATA_DIR="${DATA_DIR:-/srv/storage}"
INDEX="$APPS_DIR/ArchiveBox"
CONTENT="$DATA_DIR/ArchiveBox/archive"

if ! sudo systemctl is-active --quiet k3s; then
  echo "k3s is not running here. This installs into the cluster." >&2
  exit 1
fi

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

if ! kube -n tailscale get secret operator-oauth >/dev/null 2>&1; then
  echo "The Tailscale operator is not installed — run 'make uptime' first." >&2
  exit 1
fi

if [ ! -d "$DATA_DIR" ]; then
  echo "$DATA_DIR does not exist. Is the drive mounted? Check: findmnt $DATA_DIR" >&2
  exit 1
fi

if ! mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo >&2
  echo "  WARNING: $DATA_DIR is not a mount point." >&2
  echo "  Nothing is mounted there, so this is space on the boot disk." >&2
  echo "  If you meant a data drive, stop now and check: findmnt $DATA_DIR" >&2
  echo >&2
  printf "  Continue anyway? [y/N] " >&2
  read -r reply
  case "$reply" in
    [yY]) echo "  Continuing on the boot disk." >&2 ;;
    *) echo "  Stopped. Nothing was changed." >&2; exit 1 ;;
  esac
fi

# 0.7 kept everything in one folder with the database symlinked to the SSD;
# 0.9 lays its files out differently and its upgrade moves them in place.
# With nothing in the 0.7 collection worth carrying over, a fresh start is
# simpler and safer: the old folders are renamed, not deleted.
if kube -n pi get deploy archivebox -o jsonpath='{..image}' 2>/dev/null | grep -q ':0\.7\.'; then
  STAMP="0.7-old-$(date +%Y%m%d-%H%M)"
  echo "==> Setting the 0.7 collection aside"
  kube -n pi scale deployment/archivebox --replicas=0 >/dev/null
  kube -n pi wait --for=delete pod -l app=archivebox --timeout=120s >/dev/null 2>&1 || true
  for d in "$INDEX" "$DATA_DIR/ArchiveBox"; do
    if [ -e "$d" ]; then
      sudo mv "$d" "$d.$STAMP"
      printf '  %s -> %s\n' "$d" "$d.$STAMP"
    fi
  done
  # Its admin password went with it; a new one is asked for below.
  kube -n pi delete configmap archivebox-config --ignore-not-found >/dev/null
  kube -n pi delete secret archivebox-admin --ignore-not-found >/dev/null
  echo "  Delete those once 0.9 is working; nothing reads them."
fi

echo "==> Layout"
printf '  %-14s %s\n' "index (SSD)" "$INDEX"
printf '  %-14s %s\n' "archive" "$CONTENT"

echo "==> Creating the folders"
sudo mkdir -p "$INDEX" "$CONTENT"
# Top folders only: a recursive chown would walk every archived file on each
# re-run. ArchiveBox's entrypoint keeps what it writes under the same owner.
sudo chown "$OWNER_UID:$OWNER_GID" "$INDEX" "$DATA_DIR/ArchiveBox" "$CONTENT"

sudo tee "$INDEX/WHERE-IS-MY-DATA.txt" >/dev/null <<NOTE
ArchiveBox

  This folder      $INDEX
                   the SQLite index, config, logs and personas (logged-in
                   browser profiles). Small and fast.

  Its content      $CONTENT
                   the archived pages, videos, PDFs and screenshots.

Written by deploy/install-archivebox.sh.
NOTE
sudo chown "$OWNER_UID:$OWNER_GID" "$INDEX/WHERE-IS-MY-DATA.txt"

echo "==> Admin account"
# Only the first init reads it, so it is only asked for before there is a
# collection. In a Secret rather than the manifest, so a re-apply cannot
# reset a password changed since.
if sudo test -e "$INDEX/index.sqlite3"; then
  echo "  collection exists — the admin account is already in it"
elif kube -n pi get secret archivebox-admin >/dev/null 2>&1; then
  echo "  already stored — first start will create it"
else
  printf '  Admin username for ArchiveBox: '
  read -r AB_USER
  printf '  Admin password: '
  IFS= read -rs AB_PASS; echo
  if [ -z "$AB_USER" ] || [ -z "$AB_PASS" ]; then
    echo "  Username or password is empty. Nothing was created." >&2
    exit 1
  fi
  kube -n pi create secret generic archivebox-admin \
    --from-literal=ADMIN_USERNAME="$AB_USER" --from-literal=ADMIN_PASSWORD="$AB_PASS" >/dev/null
  unset AB_PASS
  echo "  stored as secret/archivebox-admin"
fi

echo "==> Address"
# The name the Tailscale operator gave the ingress, read back rather than
# written into the repo. On a first install there is no ingress yet, so the
# tailnet's own suffix gives the same name.
HOST=$(kube -n pi get ingress archivebox -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [ -z "$HOST" ]; then
  SUFFIX=$(tailscale status --json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("MagicDNSSuffix",""))' || true)
  [ -n "$SUFFIX" ] && HOST="archivebox.$SUFFIX"
fi
if [ -z "$HOST" ]; then
  echo "  Could not work out the tailnet name. Is Tailscale up? (tailscale status)" >&2
  exit 1
fi
BASE_URL="https://$HOST"
echo "  $BASE_URL"

echo "==> Applying manifests"
render() {
  sed -e "s|__APPS_DIR__|${APPS_DIR}|g" \
      -e "s|__DATA_DIR__|${DATA_DIR}|g" \
      -e "s|__UID__|${OWNER_UID}|g" \
      -e "s|__GID__|${OWNER_GID}|g" \
      -e "s|__BASE_URL__|${BASE_URL}|g" "$1"
}
# The manifest's replicas: 1 also undoes the 0.7 step's scale to zero.
render "${REPO_ROOT}/k8s/archivebox.yaml" | apply_guarded

echo "==> Waiting for the rollout (first start creates the collection)"
kube -n pi rollout status deployment/archivebox --timeout=600s || {
  echo "  archivebox did not come up. Logs:" >&2
  kube -n pi logs deployment/archivebox --tail=40 2>&1 | sed 's/^/    /' >&2
  exit 1
}

# kubectl exec skips the image's entrypoint and arrives as root; this drops to
# the archivebox user the way the entrypoint does.
AS_ARCHIVEBOX="setpriv --reuid=archivebox --regid=archivebox --init-groups"

echo "==> Can it write to the archive drive?"
if kube -n pi exec deploy/archivebox -- $AS_ARCHIVEBOX sh -c \
    't="/data/archive/.write-test.$$"; touch "$t" && rm -f "$t"' >/dev/null 2>&1; then
  printf '  ok    %s\n' "$CONTENT"
else
  printf '  FAIL  %s  <- cannot write\n' "$CONTENT"
  echo "  Check: sudo k3s kubectl -n pi exec deploy/archivebox -- id archivebox; ls -ld \"$CONTENT\"" >&2
fi

echo "==> Version"
kube -n pi exec deploy/archivebox -- $AS_ARCHIVEBOX archivebox version 2>/dev/null | head -3 | sed 's/^/  /' || true

cat <<NEXT

ArchiveBox is up at ${BASE_URL}
Log in with the admin account. The browser extension's server URL is the same
address; on 0.9 it also takes an API key (Admin > API Keys > Generate).

From this machine, as the archivebox user:

  sudo k3s kubectl -n pi exec deploy/archivebox -- ${AS_ARCHIVEBOX} archivebox add 'https://example.com'

Rollback:  sudo k3s kubectl -n pi delete -f ${REPO_ROOT}/k8s/archivebox.yaml
NEXT
