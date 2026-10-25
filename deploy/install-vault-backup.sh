#!/usr/bin/env bash
# Daily Vaultwarden backup: a copy on the SSD, then the same copy on HDD2.
# Runs on the board. Safe to re-run.
#
# Vaultwarden itself stays on the SSD. At 12:00 every day the database is
# copied with SQLite's online backup, which is consistent even while the app is
# writing, then checked with PRAGMA integrity_check. A copy that fails the
# check is never kept. The RSA keys, config.json, attachments and sends go with
# it: a database without the keys cannot decrypt anyone's session.
#
# Midday, not the middle of the night: quiet hours keep the disks idle from
# midnight to six.
set -euo pipefail

APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
BACKUP_MOUNT="${BACKUP_MOUNT:-/srv/hdd2}"
KEEP="${KEEP:-14}"

CONF=/etc/vault-backup.conf
SCRIPT=/usr/local/lib/pi/vault-backup
UNIT=vault-backup

for cmd in sqlite3 rsync; do
  command -v "$cmd" >/dev/null || sudo apt-get install -y "$cmd"
done

if [ ! -f "$APPS_DIR/Vaultwarden/data/db.sqlite3" ]; then
  echo "No vault database at $APPS_DIR/Vaultwarden/data. Is Vaultwarden installed?" >&2
  exit 1
fi

echo "==> Config"
# %q, because APPS_DIR contains a space and a bracket.
{
  echo "# Written by deploy/install-vault-backup.sh."
  printf 'DATA=%q\n' "$APPS_DIR/Vaultwarden/data"
  printf 'SSD=%q\n' "$APPS_DIR/Vaultwarden/backups"
  printf 'HDD_MOUNT=%q\n' "$BACKUP_MOUNT"
  printf 'HDD=%q\n' "$BACKUP_MOUNT/Backups/Vaultwarden"
  printf 'KEEP=%q\n' "$KEEP"
} | sudo tee "$CONF" >/dev/null
sudo chmod 600 "$CONF"

echo "==> Script"
sudo mkdir -p "$(dirname "$SCRIPT")"
sudo tee "$SCRIPT" >/dev/null <<'BACKUP'
#!/usr/bin/env bash
# Managed by deploy/install-vault-backup.sh.
set -euo pipefail
. /etc/vault-backup.conf

stamp=$(date +%F)
name="vaultwarden-$stamp"

# Keep the newest $KEEP dated folders in a directory, remove the rest.
prune() {
  ls -1d "$1"/vaultwarden-* 2>/dev/null | sort \
    | awk -v k="$KEEP" '{a[NR]=$0} END {for (i = 1; i <= NR - k; i++) print a[i]}' \
    | while IFS= read -r old; do rm -rf "$old"; done
}

[ -f "$DATA/db.sqlite3" ] || { echo "no vault database at $DATA"; exit 1; }

# Built under .tmp and renamed at the end, so a half-written backup never
# carries a finished-looking name.
mkdir -p "$SSD"
chmod 700 "$SSD"
tmp="$SSD/$name.tmp"
rm -rf "$tmp"
mkdir -p "$tmp"
sqlite3 "$DATA/db.sqlite3" ".backup '$tmp/db.sqlite3'"
# The copy inherits WAL mode; one self-contained file is what a restore wants.
sqlite3 "$tmp/db.sqlite3" 'PRAGMA journal_mode=DELETE;' >/dev/null
rm -f "$tmp/db.sqlite3-wal" "$tmp/db.sqlite3-shm"
check=$(sqlite3 "$tmp/db.sqlite3" 'PRAGMA integrity_check;' | head -1)
if [ "$check" != "ok" ]; then
  rm -rf "$tmp"
  echo "backup failed integrity_check: $check"
  exit 1
fi
for f in rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der config.json; do
  if [ -e "$DATA/$f" ]; then cp -a "$DATA/$f" "$tmp/"; fi
done
for d in attachments sends; do
  if [ -d "$DATA/$d" ]; then cp -a "$DATA/$d" "$tmp/"; fi
done
chmod -R go-rwx "$tmp"
rm -rf "${SSD:?}/$name"
mv "$tmp" "$SSD/$name"
prune "$SSD"
echo "ssd: $SSD/$name"

# Never write into an unmounted mount point: that directory is the boot SSD.
if ! mountpoint -q "$HDD_MOUNT"; then
  echo "$HDD_MOUNT is not mounted, HDD copy skipped"
  exit 1
fi
mkdir -p "$HDD"
chmod 700 "$HDD"
rsync -a --delete "$SSD/$name/" "$HDD/$name/"
prune "$HDD"
echo "hdd: $HDD/$name"
BACKUP
sudo chmod 755 "$SCRIPT"

echo "==> Timer"
sudo tee /etc/systemd/system/${UNIT}.service >/dev/null <<UNITFILE
[Unit]
Description=Vaultwarden backup to the SSD and HDD2

[Service]
Type=oneshot
ExecStart=$SCRIPT
UNITFILE

# Persistent: a board that was off at noon catches up when it boots.
sudo tee /etc/systemd/system/${UNIT}.timer >/dev/null <<UNITFILE
[Unit]
Description=Vaultwarden backup at 12:00

[Timer]
OnCalendar=*-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNITFILE

sudo systemctl daemon-reload
sudo systemctl enable --now ${UNIT}.timer >/dev/null

echo "==> First backup, now"
sudo "$SCRIPT"

echo
echo "==> Done"
echo "  vault        $APPS_DIR/Vaultwarden/data"
echo "  SSD copies   $APPS_DIR/Vaultwarden/backups  (last $KEEP days)"
echo "  HDD copies   $BACKUP_MOUNT/Backups/Vaultwarden  (last $KEEP days)"
echo "  schedule     daily at 12:00"
echo
echo "  Logs:     journalctl -u $UNIT --no-pager -n 20"
echo "  Run now:  sudo $SCRIPT"
