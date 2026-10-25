#!/usr/bin/env bash
# One Gitea backup, made when this is run. Never on a schedule: there is no
# timer for it, by decision (issue #201). Installed by deploy/install-gitea.sh.
#
#   sudo gitea-backup
#
# Gitea's own `gitea dump`: every repo, the database as SQL, app.ini,
# attachments and LFS, in one .tar.gz. It is written on the SSD first, checked,
# then moved to HDD2, so the copy lives on a different drive from Gitea itself.
# Nothing is deleted here; old backups are removed by hand.
#
# Restoring: https://docs.gitea.com/administration/backup-and-restore
set -euo pipefail

APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
HDD_MOUNT="${HDD_MOUNT:-/srv/hdd2}"
DIR="$APPS_DIR/Gitea"
# /var/lib/gitea/dumps inside the pod.
WORK="$DIR/dumps"
DEST="$HDD_MOUNT/Backups/Gitea"

kube() { k3s kubectl "$@"; }

[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo: sudo gitea-backup" >&2; exit 1; }
# Never write into an unmounted mount point: that directory is the boot SSD.
mountpoint -q "$HDD_MOUNT" || { echo "$HDD_MOUNT is not mounted, so no backup was made." >&2; exit 1; }
[ "$(kube -n pi get deploy gitea -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] || {
  echo "Gitea is not running, so no backup was made." >&2; exit 1; }

# The backup belongs to whoever owns Gitea's folder: the login user, so it can
# be copied over the Samba share.
owner=$(stat -c %u:%g "$DIR")
# Made when missing, never re-owned: install -d on an existing folder would
# also chown it, and Backups/ holds the vault's backups too.
for d in "$WORK" "$HDD_MOUNT/Backups" "$DEST"; do
  [ -d "$d" ] || install -d -m 750 -o "${owner%:*}" -g "${owner#*:}" "$d"
done

name="gitea-$(date +%F-%H%M).tar.gz"
rm -f "$WORK"/gitea-*.tar.gz
echo "==> Dumping (repos, database, settings)"
kube -n pi exec deploy/gitea -- gitea dump --quiet --skip-log --type tar.gz \
  --tempdir /var/lib/gitea/dumps --file "/var/lib/gitea/dumps/$name"

echo "==> Checking"
# Readable to the end, and holding the database and the settings: a dump
# missing either cannot be restored.
list=$(tar -tzf "$WORK/$name") || { echo "The dump is unreadable; it was removed." >&2; rm -f "$WORK/$name"; exit 1; }
for want in gitea-db.sql app.ini; do
  grep -q "$want\$" <<<"$list" || { echo "The dump has no $want; it was removed." >&2; rm -f "$WORK/$name"; exit 1; }
done
echo "  $(grep -c '' <<<"$list") files, database and settings included"

echo "==> Moving to HDD2"
# Copied under .part and renamed, so a half-written backup never carries a
# finished-looking name.
cp "$WORK/$name" "$DEST/$name.part"
chown "$owner" "$DEST/$name.part"
chmod 640 "$DEST/$name.part"
mv "$DEST/$name.part" "$DEST/$name"
rm -f "$WORK/$name"

echo
echo "  $DEST/$name  $(du -h "$DEST/$name" | cut -f1)"
echo "  $(ls -1 "$DEST"/gitea-*.tar.gz | wc -l) backups in $DEST, $(du -ch "$DEST"/gitea-*.tar.gz | tail -1 | cut -f1) together"
