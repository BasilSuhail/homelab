#!/usr/bin/env bash
# Immich in k3s, on its own tailnet name. Runs on the board.
#
# Needs the Tailscale operator, which deploy/install-uptime-kuma.sh installs.
#
# The same two-disk split every other app here uses:
#
#   APPS_DIR   the SSD. Postgres and the downloaded model weights — small,
#              read at random, and the half where speed is felt.
#   DATA_DIR   the 6TB. The photos and videos themselves — large, written
#              once, read start to finish.
#
# Both are overridable:
#
#     DATA_DIR=/srv/storage/photos bash deploy/install-immich.sh
#
# Safe to re-run. The database password is generated on the first run and
# never regenerated: rotating it after Postgres has initialised gives a
# server that cannot log into its own database, with an authentication error
# that reads like a bug.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

# The uid the official Postgres image drops to. The entrypoint would chown the
# directory itself on a first run, but only while it is still root, and only
# for a directory it created. Setting it here means a re-run onto an existing
# directory behaves the same as a first run.
PG_UID=999
PG_GID=999

# The archive moved from /srv/archive to "/1) Archive". Both are accepted so
# this works whichever the board is carrying.
if [ -z "${APPS_DIR:-}" ]; then
  for candidate in "/1) Archive" /srv/archive; do
    [ -d "$candidate" ] && { APPS_DIR="$candidate/Apps"; break; }
  done
fi
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"

# HDD2, by its mount point rather than its device. The library has lived at
# /srv/hdd2/Immich since the second 6TB went in, and it moved with that disk
# to the PC. Defaulting to /srv/storage pointed a migrated install at an empty
# folder, and Immich refused to start for want of its own folder markers.
DATA_DIR="${DATA_DIR:-/srv/hdd2}"

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

# The photos go on the 6TB, so refuse rather than silently write the library to
# the boot disk. `type: Directory` in the manifest would catch it too, but as a
# pod stuck in ContainerCreating rather than a sentence.
if ! mountpoint -q "$DATA_DIR"; then
  echo "$DATA_DIR is not a mount point." >&2
  echo "The photo library belongs on the 6TB. Mount it, or pass DATA_DIR=." >&2
  exit 1
fi

echo "==> Layout"
printf '  %-16s %s\n' "database (SSD)" "$APPS_DIR/Immich/db"
printf '  %-16s %s\n' "models   (SSD)" "$APPS_DIR/Immich/model-cache"
printf '  %-16s %s\n' "photos   (6TB)" "$DATA_DIR/Immich"

sudo mkdir -p "$APPS_DIR/Immich/db" "$APPS_DIR/Immich/model-cache" "$DATA_DIR/Immich"

# Postgres refuses to start on a data directory that is group- or
# world-readable, so this one is 700 and owned by the uid inside the container.
sudo chown -R "$PG_UID:$PG_GID" "$APPS_DIR/Immich/db"
sudo chmod 700 "$APPS_DIR/Immich/db"

# The other two belong to the login user: the photos so they are usable over
# Samba and in the console's file browser, the model cache so it is not a
# root-owned directory nobody can clear.
sudo chown "$OWNER_UID:$OWNER_GID" "$APPS_DIR/Immich" "$APPS_DIR/Immich/model-cache" "$DATA_DIR/Immich"

# Same note the other apps carry, for whoever finds the folder later and
# wonders which half of the app it is.
sudo tee "$APPS_DIR/Immich/WHERE-IS-MY-DATA.txt" >/dev/null <<NOTE
Immich keeps its two halves on two disks.

  This folder      $APPS_DIR/Immich
                   The Postgres database and the downloaded model weights.
                   Small, read at random, so it lives on the SSD.

  Your photos      $DATA_DIR/Immich
                   Everything you uploaded. Large, so it lives on the 6TB.

The photos are plain files. The database holds albums, faces and the search
index — losing it costs those, not the pictures.

Set by deploy/install-immich.sh. Both paths move with APPS_DIR= or DATA_DIR=.
NOTE

echo "==> Database password"
if kube -n pi get secret immich-db >/dev/null 2>&1; then
  echo "  already present — leaving it alone"
else
  # A-Za-z0-9 only. Immich's own example env says so, and a password with a
  # slash or an @ in it breaks the connection URL the server builds from it.
  #
  # python3 rather than the usual `tr -dc ... </dev/urandom | head -c 40`.
  # That idiom is a trap under `set -o pipefail`: head exits the moment it has
  # its 40 bytes, tr is still reading an endless file, and the closed pipe
  # kills tr with SIGPIPE. The pipeline then reports 141, `set -e` takes the
  # script down, and the message is `Error 141` at the exact point the install
  # looked like it was working. python3 is already required by
  # install-vaultwarden.sh and install-torrent.sh, and secrets.choice is the
  # right generator for this anyway.
  PASSWORD="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(40)))')"
  kube -n pi create secret generic immich-db --from-literal="password=${PASSWORD}" >/dev/null
  unset PASSWORD
  echo "  generated, 40 characters, stored only in the cluster"
fi

echo "==> Timezone"
# Read from the board rather than pinned in the repo. Without TZ the nightly
# tasks and both cron schedules run in UTC, so a 06:00 setting silently means
# something else. This is the only reason the ConfigMap exists.
TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[ -n "$TZ_NAME" ] || TZ_NAME="Etc/UTC"
kube -n pi create configmap immich-config --from-literal="TZ=${TZ_NAME}" \
  --dry-run=client -o yaml | kube apply -f - >/dev/null
echo "  TZ=${TZ_NAME}"

echo "==> Manifests"
# Substituted here rather than fixed in the manifest, which is what makes the
# paths configurable. sed's delimiter is | because the values are paths and
# one of them contains a space and a bracket.
sed -e "s|__APPS_DIR__|${APPS_DIR}|g" \
    -e "s|__DATA_DIR__|${DATA_DIR}|g" \
    "${REPO_ROOT}/k8s/immich.yaml" | apply_guarded

echo "==> Waiting for the database"
kube -n pi rollout status deployment/immich-postgres --timeout=300s

echo "==> Waiting for the rest"
kube -n pi rollout status deployment/immich-redis --timeout=180s
kube -n pi rollout status deployment/immich-machine-learning --timeout=600s
# Longest of the four on purpose: the first start runs every schema migration
# against an empty database, on four ARM cores.
kube -n pi rollout status deployment/immich-server --timeout=900s

echo "==> Waiting for its tailnet name"
HOST=""
for _ in $(seq 1 60); do
  HOST="$(kube -n pi get ingress photos -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$HOST" ] && break
  sleep 5
done

echo
if [ -n "$HOST" ]; then
  echo "  https://${HOST}"
else
  echo "  No hostname yet. It can take a few minutes on a first run." >&2
  echo "  Watch: sudo k3s kubectl -n pi get ingress photos -w" >&2
fi

cat <<'NEXT'

Next, in this order:

  1. Open the URL above. The first account you create is the admin, and
     Immich closes sign-up behind it on its own.

  2. Move the three schedules to the morning, where every automatic job on
     the machine runs. All are in Administration > Settings, and all default
     to midnight or 2am:

       Nightly Tasks     start time      00:00  ->  07:00
       Backup            database cron 0 02 * * *  ->  0 8 * * *
       External Library  scan cron     0 0 * * *  ->  0 9 * * *

     The backup is a scheduled database dump. Nothing else on these boards is
     backed up on a schedule, so it is a decision rather than a default. It
     dumps the database only — albums, faces and the search index, not the
     photos.

  3. Set the storage template, under Administration > Settings > Storage
     Template, so the library stays readable from outside Immich:

       {{y}}/{{MM}}/{{filename}}

     Without it the tree is nested by asset id, and the folder on the 6TB
     stops being something you can walk in Finder.

  4. Install the Immich app on the phone and point it at the URL above.
     Tailscale has to be up on the phone or it reaches nothing.

     Background App Refresh is optional. With it off, the app uploads
     everything new each time you open it, which is the reliable path anyway —
     iOS decides when background tasks run, and the app cannot ask.

  5. For an existing library, do not push it through the phone. From the Mac:

       npx @immich/cli upload --recursive /path/to/photos

     It asks for the server URL and an API key, which you make under Account
     Settings > API Keys. Originals are read, never moved or altered.

Machine learning is queued per upload, not continuous and not at search time.
A first bulk import will keep the CPU busy for as long as it takes and then
stop. Watch it under Administration > Jobs.

NEXT
echo "Rollback:  sudo k3s kubectl -n pi delete -f ${REPO_ROOT}/k8s/immich.yaml"
echo "           the photos and the database stay on disk, in the two folders above"
