#!/usr/bin/env bash
# The admin's own files are a folder on HDD2 ("Admin Storage"), reached until
# now only through the whole-disk /HDD2 view. Nextcloud never counts external
# storage, so the admin showed "0 B used" with hundreds of GB in that folder.
#
# This mounts that folder over the admin's Nextcloud home (data/<admin>/files)
# in both containers, so it is the admin's Personal files: counted, searched,
# and listed at the top of All files. Nothing is copied or moved; Finder and
# Samba keep using the same folder. Whatever was in the old, empty home stays
# on disk underneath and comes back if this is undone.
#
# Called by install-nextcloud.sh; safe to run on its own and to re-run.
#   ADMIN_HOME_DIR   the folder (default: "$HDD2_DIR/Admin Storage"); skipped
#                    when it does not exist
#   UNDO=1           take the mount out again
set -euo pipefail

HDD2_DIR="${HDD2_DIR:-/srv/hdd2}"
POOL_DIR="${POOL_DIR:-/srv/pool}"
ADMIN_HOME_DIR="${ADMIN_HOME_DIR:-$HDD2_DIR/Admin Storage}"
VOL=admin-home

kube() { sudo k3s kubectl "$@"; }
occ() { kube -n pi exec deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "nice php /var/www/html/occ $*"; }
command -v jq >/dev/null || sudo apt-get install -y jq >/dev/null

ADMIN_USER="$(kube -n pi get secret nextcloud-admin -o jsonpath='{.data.username}' | base64 -d)"
HOME_IN_POD="/var/www/html/data/$ADMIN_USER/files"
deploy_json() { kube -n pi get deployment nextcloud -o json; }

if [ "${UNDO:-}" = 1 ]; then
  deploy_json | jq --arg v "$VOL" '
    del(.status) | del(.metadata.resourceVersion)
    | .spec.template.spec.volumes |= map(select(.name != $v))
    | .spec.template.spec.containers |= map(.volumeMounts |= map(select(.name != $v)))' \
    | kube replace -f - >/dev/null
  kube -n pi rollout status deployment/nextcloud --timeout=600s
  occ files:scan --path="$ADMIN_USER/files" >/dev/null 2>&1 || true
  echo "Undone: the admin's Personal files are the old Nextcloud home again."
  exit 0
fi

if [ ! -d "$ADMIN_HOME_DIR" ]; then
  echo "  admin home       $ADMIN_HOME_DIR does not exist; skipped"
  exit 0
fi

current=$(deploy_json | jq -r --arg v "$VOL" '.spec.template.spec.volumes[] | select(.name == $v) | .hostPath.path')
if [ "$current" = "$ADMIN_HOME_DIR" ]; then
  echo "  admin home       already $ADMIN_HOME_DIR"
  exit 0
fi

# The mount point must exist in the data folder, owned as Nextcloud expects;
# runc would otherwise create it as root.
data=$(deploy_json | jq -r '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.path')
old="${data:-$POOL_DIR/Nextcloud/data}/$ADMIN_USER/files"
sudo install -d -o 33 -g 33 "$old"
n=$(sudo find "$old" -mindepth 1 -maxdepth 1 | wc -l)
[ "$n" -eq 0 ] || echo "  note: $n item(s) in the old home stay on disk, hidden while this is in place"

patch=$(jq -n --arg v "$VOL" --arg host "$ADMIN_HOME_DIR" --arg pod "$HOME_IN_POD" '
  {spec: {template: {spec: {
    volumes: [{name: $v, hostPath: {path: $host, type: "Directory"}}],
    containers: [
      {name: "nextcloud", volumeMounts: [{name: $v, mountPath: $pod}]},
      {name: "cron",      volumeMounts: [{name: $v, mountPath: $pod}]}
    ]}}}}')
kube -n pi patch deployment nextcloud --type strategic -p "$patch" >/dev/null
echo "  admin home       $ADMIN_HOME_DIR is now ${ADMIN_USER}'s Personal files"
kube -n pi rollout status deployment/nextcloud --timeout=600s

# Count it. The scan reads names and sizes only, and also counts the three
# disk views below the home, so their sizes stop showing Pending.
echo "  counting it (several minutes for a few hundred GB)"
occ files:scan --path="$ADMIN_USER/files" 2>&1 | grep -E '^\| [0-9]' | tail -1 \
  | awk -F'|' '{gsub(/ /,""); print "  scanned          " $2 " folders, " $3 " files"}'
