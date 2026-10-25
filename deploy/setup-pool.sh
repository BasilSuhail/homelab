#!/usr/bin/env bash
# Pools the data disks behind one path with mergerfs. Runs on the board.
# Idempotent: re-running with the same disks changes nothing.
#
# Apps point at the pool, never at a disk. Adding a disk later means adding a
# branch here and re-running; no app is reconfigured, and the pool moves to
# another machine as it is. Files stay plain files on each disk's own ext4 —
# pull a disk out and its half of the pool is still readable on its own.
#
# HDD1 (/srv/storage) is deliberately not a branch: qBittorrent hard-links
# finished downloads into Jellyfin's library, and a hard link cannot cross
# disks, which mergerfs would otherwise let it try.
#
#   POOL_BRANCHES=/srv/hdd2:/srv/hdd3 bash deploy/setup-pool.sh
set -euo pipefail

POOL_DIR="${POOL_DIR:-/srv/pool}"
BRANCHES="${POOL_BRANCHES:-/srv/hdd2}"
MARK="# pi-pool: managed by deploy/setup-pool.sh"

command -v mergerfs >/dev/null || sudo apt-get install -y mergerfs

# Every branch must be a mounted disk. An unmounted mount point is an empty
# directory on the boot SSD, and pooling it would put family files there.
IFS=: read -ra dirs <<<"$BRANCHES"
for d in "${dirs[@]}"; do
  if ! mountpoint -q "$d"; then
    echo "$d is not a mount point. Mount the disk first: findmnt $d" >&2
    exit 1
  fi
done

# mfs: new files go to the branch with the most free space. minfreespace keeps
# 50G back on each disk; moveonenospc retries on another branch if one fills
# mid-write. nofail: the board still boots with a disk missing, and the apps
# on the pool stop at ContainerCreating rather than writing to the SSD.
requires=""
for d in "${dirs[@]}"; do requires+=",x-systemd.requires-mounts-for=$d"; done
line="$BRANCHES $POOL_DIR fuse.mergerfs defaults,allow_other,category.create=mfs,moveonenospc=true,minfreespace=50G,fsname=pool,nofail${requires} 0 0"

echo "==> Pool"
printf '  %-10s %s\n' "path" "$POOL_DIR" "disks" "${BRANCHES//:/, }"

if grep -qxF -- "$line" /etc/fstab && mountpoint -q "$POOL_DIR"; then
  echo "  already set up and mounted — nothing to change"
else
  if mountpoint -q "$POOL_DIR"; then
    echo "  $POOL_DIR is mounted with different disks. Stop the apps using it" >&2
    echo "  (e.g. make cloud's Nextcloud), then: sudo umount $POOL_DIR, and re-run." >&2
    exit 1
  fi
  # One marked line per pool, replaced in place; the old fstab is kept.
  sudo cp /etc/fstab /etc/fstab.pi-pool.bak
  tmp=$(mktemp)
  awk -v p="$POOL_DIR" -v m="$MARK" '$0 != m && $2 != p' /etc/fstab > "$tmp"
  printf '%s\n%s\n' "$MARK" "$line" >> "$tmp"
  sudo install -m 644 "$tmp" /etc/fstab
  rm -f "$tmp"
  sudo mkdir -p "$POOL_DIR"
  sudo systemctl daemon-reload
  sudo mount "$POOL_DIR"
  echo "  mounted (fstab backup: /etc/fstab.pi-pool.bak)"
fi

echo
df -h "$POOL_DIR" | sed 's/^/  /'
echo
echo "  Anything already on the disks shows through the pool as well:"
echo "  /srv/hdd2/Immich is also $POOL_DIR/Immich. Existing apps keep their"
echo "  /srv/hdd2 paths; new ones (Nextcloud) use $POOL_DIR."
