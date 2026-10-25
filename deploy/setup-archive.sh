#!/usr/bin/env bash
# Creates the archive tree. Run on any board. Idempotent — safe to re-run.
#
# The 8TB is still blocked on 12V and does not need to block the archive with
# it. Both boards have hundreds of gigabytes free on their own SSD, which
# holds Wikipedia, the book library and a first laptop backup with room to
# spare. Nothing here assumes the disk underneath:
# every service is pointed at the path, never at a device, so when the 8TB is
# finally mounted at this path the services do not notice.
#
# Read the migration note this prints at the end before mounting that disk.
set -euo pipefail

ARCHIVE="${ARCHIVE:-/1) Archive}"
OLD_ARCHIVE="${OLD_ARCHIVE:-/srv/archive}"
OWNER="${OWNER:-$(id -un)}"
# Wikipedia alone is ~100GB; refuse to start somewhere that cannot hold it.
MIN_FREE_GB="${MIN_FREE_GB:-200}"

# $ARCHIVE does not exist yet, and nor may its parent if it was overridden.
probe="$ARCHIVE"
while [ ! -d "$probe" ]; do probe=$(dirname "$probe"); done
free_gb=$(df -BG --output=avail "$probe" | tail -1 | tr -dc '0-9')
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "Only ${free_gb}GB free where $ARCHIVE would live; wanted ${MIN_FREE_GB}GB." >&2
  exit 1
fi

# No subdirectories. The tree used to be seeded with backups/, documents/,
# photos/ and the rest, which is someone else deciding how you file things.
# This is your space; make the folders you actually want.
# The archive used to live at /srv/archive and be shown in the share through a
# bind mount named "1) Archive". A bind means the same files are reachable by
# two paths inside one drive, which is where every duplicate in the file views
# came from — and it needed mount propagation turned off to stay put, which in
# turn hid it from the console.
#
# It is a plain directory at the root of the disk now, named what it is called.
# Nothing binds it, nothing pins it, and both the share and the console see one
# folder because there is only one. A rename on the same filesystem: instant,
# atomic, and no byte of data moves.
if [ -d "$OLD_ARCHIVE" ] && [ ! -e "$ARCHIVE" ]; then
  echo "==> Moving $OLD_ARCHIVE -> $ARCHIVE"
  sudo mv "$OLD_ARCHIVE" "$ARCHIVE"
elif [ -d "$OLD_ARCHIVE" ] && [ -d "$ARCHIVE" ]; then
  # Both exist. Never merge them silently — say so and change nothing.
  if [ -z "$(ls -A "$OLD_ARCHIVE" 2>/dev/null)" ]; then
    sudo rmdir "$OLD_ARCHIVE" && echo "==> Removed the empty $OLD_ARCHIVE"
  else
    echo "Both $OLD_ARCHIVE and $ARCHIVE exist and hold files." >&2
    echo "Move what you want by hand, then re-run. Nothing was changed." >&2
    exit 1
  fi
fi

echo "==> Creating $ARCHIVE (${free_gb}GB free)"
sudo mkdir -p "$ARCHIVE"
# The top folder only. Recursive, this re-owned every app's data the first
# time it was re-run over a populated archive: Nextcloud's config passed from
# www-data to the login user and the web server could no longer write it.
# What an app keeps under Apps/ is owned by whoever that app runs as.
sudo chown "$OWNER:$(id -gn "$OWNER")" "$ARCHIVE"

# Boards set up before that decision still carry the seeded folders. Clear
# them out — but only the ones this script made, and only while they are
# empty, so anything that has since been filled is never at risk. rmdir
# refuses a non-empty directory, which is the whole safety mechanism here.
SEEDED=(backups books documents movies photos repos wikipedia)
removed=""
for d in "${SEEDED[@]}"; do
  if [ -d "$ARCHIVE/$d" ] && sudo rmdir "$ARCHIVE/$d" 2>/dev/null; then
    removed="$removed $d"
  fi
done
[ -n "$removed" ] && echo "==> Removed empty seeded folders:$removed"
# Group-writable and setgid, so anything added later inherits the group rather
# than depending on whichever daemon happened to write the file.
# Top folder only, for the reason above: recursive, it also made the vault
# backups world-readable and every database file executable.
sudo chmod 2775 "$ARCHIVE"

echo
df -h "$ARCHIVE" | sed 's/^/  /'

if mountpoint -q "$ARCHIVE"; then
  echo
  echo "==> $ARCHIVE is a mount point. The archive is on its own disk."
  exit 0
fi

device=$(findmnt -no SOURCE --target "$ARCHIVE")
cat <<NOTE

==> $ARCHIVE is on ${device}, the root filesystem — not a separate disk yet.

    When the 8TB arrives, do NOT simply mount it here. Mounting over a
    directory hides what is underneath: the files stay on ${device}, keep
    consuming it, and become invisible and unrecoverable without unmounting
    again. Instead:

      sudo mount /dev/sdX1 /mnt/new
      sudo rsync -aHAX --info=progress2 $ARCHIVE/ /mnt/new/
      sudo umount /mnt/new
      sudo mv $ARCHIVE $ARCHIVE.on-root       # keep until the copy is verified
      sudo mkdir -p $ARCHIVE
      # add the fstab line by UUID, then:
      sudo mount -a && ls $ARCHIVE
      # only once that looks right:
      sudo rm -rf $ARCHIVE.on-root

    The fstab line wants nofail, or a disconnected drive stops the board
    booting at all:

      UUID=<uuid>  $ARCHIVE  ext4  defaults,noatime,nofail  0  2
NOTE
