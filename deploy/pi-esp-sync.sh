#!/usr/bin/env bash
# Keeps every mirrored SSD's EFI partition the same as /boot/efi, so whichever
# disk the firmware starts from finds GRUB. Installed as
# /usr/local/bin/pi-esp-sync by deploy/ssd-mirror.sh; apt runs it after every
# package change, and pi-raid-check.service at boot.
#
# The EFI partition cannot be mirrored like the rest: the firmware reads it
# before Linux exists. So each disk has its own, and this copies them.
set -euo pipefail

ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

# EFI partitions on the disks that hold the mirror, and nowhere else.
mapfile -t esps < <(
  for slave in /sys/block/md*/slaves/*; do
    [ -e "$slave" ] || continue
    lsblk -dno PKNAME "/dev/$(basename "$slave")"
  done | sort -u | while read -r d; do
    lsblk -nrpo NAME,PARTTYPE "/dev/$d" | awk -v t="$ESP_TYPE" '$2 == t { print $1 }'
  done
)
[ ${#esps[@]} -gt 0 ] || exit 0

# The disk fstab names for /boot/efi may be the one that died; any other will do.
# Checked again after the first try: with nofail, mount answers 0 for a disk
# that is gone and mounts nothing.
if ! mountpoint -q /boot/efi; then
  mount /boot/efi 2>/dev/null || true
  mountpoint -q /boot/efi || mount "${esps[0]}" /boot/efi
fi
src=$(findmnt -nfo SOURCE /boot/efi)

for esp in "${esps[@]}"; do
  [ "$esp" = "$src" ] && continue
  tmp=$(mktemp -d)
  if mount "$esp" "$tmp"; then
    rsync -rt --delete /boot/efi/ "$tmp/"
    umount "$tmp"
  fi
  rmdir "$tmp"
done
