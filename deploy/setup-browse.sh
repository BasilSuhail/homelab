#!/usr/bin/env bash
# Builds /srv/browse — one folder per drive. Nothing else at the top.
#
# This is "This PC" on Windows and the Locations list in Finder: a machine has
# drives, the drives are what you open, and anything that is not a drive has no
# business sitting beside them. Two disks in pi2 means two folders. Plug in a
# third and there are three. That is the whole model.
#
#   SSD-1TB      the disk, whole: "1) Archive" first, then the OS — bin, boot,
#                etc, and the rest of what a Linux install has. A disk that
#                hides its own /etc is a brochure, not a view.
#   HDD-6TB      the other disk.
#
# The archive is inside the disk that holds it, named so it sorts to the top of
# that disk's own listing — digits before letters. It is not a folder at the
# top level: the top level is drives.
#
# Bind mounts, not symlinks: Samba refuses to follow a symlink out of a share
# unless `wide links = yes`, and that option turns off a protection worth
# keeping. A bind mount is the same thing without the hole.
#
# One trap the shape has to defuse, learned the hard way: a mount under a bound
# root is invisible through the bind — the bind shows the directory underneath,
# not the filesystem mounted on it. So a second filesystem on the SAME disk
# (the boot partition) is bound again inside the disk's folder, at its real
# path. A filesystem on a DIFFERENT disk is deliberately not: /srv/storage on
# the SSD holds none of the SSD, the HDD has a folder of its own at the top,
# and the empty directory the SSD really has there is the truthful thing to
# show.
#
# Nothing here formats, partitions or writes to a disk. Idempotent: re-run it
# after mounting anything new and the tree is rebuilt to match.
set -euo pipefail

BROWSE="${BROWSE:-/srv/browse}"
MEDIA="${MEDIA:-/media}"
OWNER="${OWNER:-$(id -un)}"
FSTAB=/etc/fstab
MARK="# pi-browse"

# Mount points that are plumbing rather than a disk's contents: the OS's own
# pseudo-filesystems and container state. / is deliberately absent — the whole
# point of a per-disk tree is that the system's files sit under the disk they
# live on.
#
# /media is skipped here and picked up in a second pass below. A board's own
# partitions can turn up there as a duplicate mount, and those must not become
# a second folder for a disk that already has one; a plugged-in drive has no
# other mount, so the second pass finds it and nothing else.
#
# /boot/efi is firmware plumbing. On the SSD mirror it sits on a member disk
# of its own, and without this it became a top-level "drive" of 1G.
skip_re='^(/proc.*|/sys.*|/run.*|/dev.*|/boot/efi|/mnt/new|/var/lib/docker.*|/var/lib/kubelet.*|/var/lib/rancher.*|/snap.*)$'

# The physical disk a mounted source belongs to: sda2 -> sda. A source with no
# parent device names itself.
disk_of() {
  local parent md m
  # A mirror (deploy/ssd-mirror.sh) belongs to its main disk, the member that
  # is not write-mostly: the 250GB holds Debian and the apps, and the backup
  # SSD's half is the same files again, not something to browse twice.
  if [[ "$1" == /dev/md* ]]; then
    md=$(basename "$(readlink -f "$1")")
    for m in /sys/block/"$md"/md/dev-*; do
      [ -e "$m/state" ] || continue
      grep -q write_mostly "$m/state" && continue
      parent=$(lsblk -dno pkname "/dev/${m##*/dev-}" 2>/dev/null || true)
      [ -n "$parent" ] && { echo "$parent"; return; }
    done
    echo "$md"; return
  fi
  # -d: a mirror member partition would list the array under it as well.
  parent=$(lsblk -dno pkname "$1" 2>/dev/null || true)
  echo "${parent:-$(basename "$1")}"
}

# Size in bytes and the rotational flag for a disk, from the same sysfs files
# the agent reads. Empty when the disk cannot be named.
disk_facts() {
  local base="/sys/block/$1" sectors rotational device_path
  [ -r "$base/size" ] || return 0
  read -r sectors < "$base/size" || return 0
  rotational=1
  [ -r "$base/queue/rotational" ] && read -r rotational < "$base/queue/rotational" || true
  # USB-SATA bridges don't pass through the rotational flag; the kernel
  # defaults to 1 (spinning). If the device path walks through USB, assume SSD.
  if [ "$rotational" = 1 ]; then
    device_path=$(readlink -f "$base/device" 2>/dev/null || echo "")
    [[ "$device_path" == *usb* ]] && rotational=0
  fi
  echo "$((sectors * 512)) $rotational"
}

# Sold-as capacity, integer arithmetic: 0.98TB reads "1TB", 5.95TB reads
# "6TB", and a sub-TB disk snaps to the size the shelf sold it as, because
# "SSD 502GB" is noise and nobody has ever said it.
capacity_of() {
  local bytes=$1 tb gb c sold
  if (( bytes >= 950000000000 )); then
    tb=$(( bytes / 1000000000000 ))
    if (( bytes % 1000000000000 >= 500000000000 )); then tb=$(( tb + 1 )); fi
    echo "${tb}TB"
    return
  fi
  gb=$(( (bytes + 500000000) / 1000000000 ))
  # The nearest size within 8%: a 512GB disk is "512GB", not "500GB".
  sold="" best=""
  for c in 120 128 250 256 500 512 750 768; do
    if (( gb >= c * 92 / 100 && gb <= c * 108 / 100 )); then
      d=$(( gb > c ? gb - c : c - gb ))
      if [ -z "$best" ] || (( d < best )); then sold=$c; best=$d; fi
    fi
  done
  echo "${sold:-$gb}GB"
}

kind_of() { # $1 = rotational flag, $2 = device name
  if [ "$1" = 1 ]; then echo HDD
  elif [ "$1" = 0 ]; then echo SSD
  elif [[ "$2" == mmcblk* ]]; then echo "SD card"
  else echo disk
  fi
}

# "SSD 1TB" -> "SSD-1TB". Finder takes dashes over spaces without complaint.
name_for() { basename "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\+/-/g;s/^-//;s/-$//'; }

echo "==> Reading mounted filesystems"
# -n no headings, -r raw. SOURCE is the device; anything not under /dev
# is a pseudo-filesystem or a bind of a directory, and is not a disk.
#
# Raw output writes a space as \x20, so `read` cannot mis-split: a bind's
# SOURCE carries its folder too ("/dev/md126[/1) Archive]"), and with plain
# output that space cut it in two and the archive was never bound.
mapfile -t rows < <(findmnt -nro SOURCE,TARGET | sort -u)
unraw() { printf '%b' "$1"; }

declare -A disk_root=()   # disk -> its shallowest mount, the folder's contents
declare -A disk_depth=()  # depth of that mount, "/" being the shallowest
declare -A disk_label=()  # drives found only under /media, named by their label
mounts=()
media_rows=()
for row in "${rows[@]}"; do
  read -r source target <<<"$row"
  source=$(unraw "$source"); target=$(unraw "$target")
  [[ "$source" == /dev/* ]] || continue
  [[ "$target" == "$MEDIA"/* ]] && { media_rows+=("$row"); continue; }
  [[ "$target" =~ $skip_re ]] && continue
  [[ "$target" == "$BROWSE"/* ]] && continue
  disk=$(disk_of "${source%%[*}")   # a bind reads /dev/md126[/1) Archive]
  [ -z "$(disk_facts "$disk")" ] && continue   # loop/ram/zram: not a disk
  mounts+=("$target|$disk|${source%%[*}")
  # "/" is depth 0, so it wins over "/1) Archive" whatever order findmnt gives.
  depth=${target//[^\/]/}
  [ "$target" = / ] && depth=""
  if [ -z "${disk_root[$disk]:-}" ] || [ ${#depth} -lt ${disk_depth[$disk]} ]; then
    disk_root[$disk]=$target
    disk_depth[$disk]=${#depth}
  fi
done

# Second pass: a drive whose only mount is under /media is one somebody plugged
# in, and it gets a folder like any other drive. A disk already seen above is
# skipped — that mount is the OS turning up twice, not a new drive. The folder
# takes the drive's label, which is what the automount helper named the mount
# after and what is written on the disk itself.
for row in "${media_rows[@]}"; do
  read -r source target <<<"$row"
  source=$(unraw "$source"); target=$(unraw "$target")
  disk=$(disk_of "${source%%[*}")   # a bind reads /dev/md126[/1) Archive]
  [ -n "${disk_root[$disk]:-}" ] && continue   # the OS, mounted a second time
  [ -z "$(disk_facts "$disk")" ] && continue
  mounts+=("$target|$disk|${source%%[*}")
  disk_root[$disk]=$target
  disk_depth[$disk]=1
  disk_label[$disk]=$(basename "$target")
done

if [ ${#disk_root[@]} -eq 0 ]; then
  echo "No mounted disk to expose. Plug one in, or check: findmnt -l" >&2
  exit 1
fi

# Samba is the reason this script used to fail more often than it worked.
# smbd forks a process per connection and parks its working directory inside
# the share, so one Finder window left open on a Mac anywhere on the tailnet
# pins /srv/browse/<disk> and the rebuild aborts. "Close Finder windows and
# shells on it, then re-run" put that on the operator, every time, for a
# condition the script can simply resolve: the share is being rebuilt, so the
# thing serving it should not be running. Stopped here, started again on the
# way out — including on failure, which is what the trap is for.
SMB_UNITS=""
for unit in smbd nmbd; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then SMB_UNITS="$SMB_UNITS $unit"; fi
done
restore_samba() {
  [ -n "$SMB_UNITS" ] || return 0
  echo "==> Starting Samba again ($SMB_UNITS)"
  # shellcheck disable=SC2086
  sudo systemctl start $SMB_UNITS || true
}
if [ -n "$SMB_UNITS" ]; then
  echo "==> Stopping Samba while the tree is rebuilt ($SMB_UNITS)"
  echo "    Finder will reconnect on its own; open windows may blink."
  trap restore_samba EXIT
  # shellcheck disable=SC2086
  sudo systemctl stop $SMB_UNITS
fi

# Whatever still holds a mount after Samba is down, named. A generic "target is
# busy" sends you looking for a Finder window that is not the problem; a pid
# and a command name is something you can act on.
holders() {
  command -v fuser >/dev/null 2>&1 && sudo fuser -vm "$1" 2>&1 | sed 's/^/      /' && return 0
  command -v lsof  >/dev/null 2>&1 && sudo lsof "$1" 2>/dev/null | sed 's/^/      /' && return 0
  echo "      (install psmisc for fuser to see what is holding it)"
}

# The agent walks this tree to size it, and a scan in flight holds a directory
# open for as long as it runs. That is transient, unlike Samba, so it is worth
# waiting out rather than failing on.
unmount_tree() {
  local point="$1" try
  # Cut propagation first. The removable mirror is a slave of /media, but a
  # mirror re-created from fstab at boot is a shared peer of it, and
  # unmounting a peer unmounts the original — every plugged-in drive, ejected
  # by a script that only meant to rebuild a folder. Making it slave again is
  # a no-op when it already is.
  sudo mount --make-rslave "$point" 2>/dev/null || true
  for try in 1 2 3 4; do
    if sudo umount -R "$point" 2>/dev/null; then return 0; fi
    sleep 1
  done
  # Once more with the error showing. Four silent failures then a bare "target
  # is busy" tells you less than the kernel's own last word on it.
  sudo umount -R "$point"
}

echo "==> Clearing the old tree"
# Old fstab lines first, then unmount what they describe. umount -R walks the
# nested binds inside each folder. Deleting around a live mount is the one
# mistake this script must never make, so a folder that will not come free
# stops the run — but only after saying what is holding it.
sudo sed -i "\|$MARK|d" "$FSTAB"
sudo mkdir -p "$BROWSE"
for point in "$BROWSE"/*; do
  [ -e "$point" ] || continue
  if mountpoint -q "$point"; then
    unmount_tree "$point" || {
      echo "  $point will not unmount. Still holding it:" >&2
      holders "$point" >&2
      exit 1
    }
  fi
done

# Belt and braces before a recursive delete. If anything under here is still a
# mount, the delete would walk into the filesystem behind it — /media, and the
# drive someone has plugged into it. Nothing about rebuilding a folder tree is
# worth that risk, so stop instead.
if findmnt -rno TARGET | grep -q "^$BROWSE/"; then
  echo "  Something under $BROWSE is still mounted. Refusing to delete around it." >&2
  findmnt -rno TARGET | grep "^$BROWSE/" | sed 's/^/    /' >&2
  exit 1
fi
sudo find "$BROWSE" -mindepth 1 -delete

echo "==> Binding one folder per disk"
declare -A used_names=()
# fstab splits its fields on whitespace, so a path containing a space has to
# carry it as \040 or the line silently describes a different mount. "1)
# Archive" is exactly that case, and mount reads the escape back on boot.
fstab_escape() { printf '%s' "${1// /\\040}"; }

bind() { # source, destination
  sudo mount --bind "$1" "$2"
  # Cut propagation into the copy. systemd leaves / shared, so a bind of / joins
  # the same peer group and EVERY mount made under / afterwards is copied inside
  # it — which is why pi2 grew /srv/browse/SSD-1TB/srv/browse/HDD-6TB, and a
  # second "1) Archive" and "2) Plugged in" beside it. A drive's folder should
  # show that drive as it was when the tree was built, and nothing else.
  sudo mount --make-rprivate "$2"
  # The fstab line carries the same flag, or the boot-time bind is a shared
  # peer again and grows the copies back: homelab showed "1) Archive" inside
  # SSD-250GB as well as SSD-1TB after a reboot.
  printf '%s  %s  none  bind,rprivate,nofail  0  0  %s\n' \
    "$(fstab_escape "$1")" "$(fstab_escape "$2")" "$MARK" | sudo tee -a "$FSTAB" >/dev/null
}


# Disks in a stable order, oldest filesystem first. Two disks can share a
# name (two 6TB HDDs): the older keeps "HDD-6TB" and the newer is "HDD-6TB-2",
# on every boot. The array above has no order of its own, and device names
# (sdb, sdc) can swap between boots, so neither can decide which disk keeps
# the plain name. A filesystem with no creation date (not ext4) sorts last.
created_at() {
  local src t
  src=$(findmnt -nfo SOURCE --target "$1" 2>/dev/null | head -1)
  t=$(sudo tune2fs -l "$src" 2>/dev/null | sed -n 's/^Filesystem created: *//p')
  { [ -n "$t" ] && date -d "$t" +%s 2>/dev/null; } || echo 9999999999
}
mapfile -t ordered < <(
  for d in "${!disk_root[@]}"; do printf '%s %s\n' "$(created_at "${disk_root[$d]}")" "$d"; done |
    sort -k1,1n -k2,2 | awk '{print $2}'
)

declare -A disk_folder=()
for disk in "${ordered[@]}"; do
  read -r size rotational < <(disk_facts "$disk")
  # A drive somebody plugged in is known by what is written on it. "PHOTOS"
  # says more than "SSD-32GB", and it is the name they gave it.
  name=${disk_label[$disk]:-}
  [ -n "$name" ] || name=$(name_for "/$(kind_of "$rotational" "$disk") $(capacity_of "$size")")
  base=$name; n=2
  while [ -n "${used_names[$name]:-}" ]; do name="${base}-${n}"; n=$((n + 1)); done
  used_names[$name]=1
  disk_folder[$disk]=$name

  point="$BROWSE/$name"
  sudo mkdir -p "$point"
  bind "${disk_root[$disk]}" "$point"
  echo "  $name  <-  ${disk_root[$disk]}"

  # Same-disk filesystems beyond the root, bound inside at their real path so
  # the root bind does not shadow them. Cross-disk mounts stay out — see the
  # header for why showing the empty underlying directory is the honest view.
  # Shallowest first, and one path per filesystem: /1) Archive and /srv/ssd
  # are the same apps filesystem, so only "1) Archive" is bound, at the top.
  declare -A seen_dev=()
  while IFS='|' read -r target mdisk mdev; do
    [ "$mdisk" = "$disk" ] || continue
    [ "$target" = "${disk_root[$disk]}" ] && continue
    [ -n "${seen_dev[$mdev]:-}" ] && continue
    seen_dev[$mdev]=1
    nested="$point$target"
    sudo mkdir -p "$nested"
    bind "$target" "$nested"
    echo "  ${name}${target}  <-  $target"
  done < <(for m in "${mounts[@]}"; do t=${m%%|*}; d=${t//[^\/]/}; printf '%s %s\n' "${#d}" "$m"; done |
             sort -n -k1,1 | cut -d' ' -f2-)
  unset seen_dev
done

# Nothing here binds the archive. It is a plain directory at the root of the
# disk — "/1) Archive" — so it simply appears in the disk's own listing, first,
# because digits sort before letters. deploy/setup-archive.sh puts it there.
# A bind would mean the same files reachable by two paths inside one drive,
# which is where every duplicate in these views came from.

# Two mounts earlier versions left behind, both outside $BROWSE and so never
# touched by the teardown above: the "archives" pin at the root of the disk,
# and anything still bound under it. Unmounted only when findmnt confirms the
# path is a bind — a real directory with files in it is never touched.
for stale in "$BROWSE"/*/archives; do
  [ -e "$stale" ] || continue
  if mountpoint -q "$stale" 2>/dev/null; then
    if sudo umount -R "$stale" 2>/dev/null; then
      echo "  unmounted the old 'archives' pin at ${stale#"$BROWSE"/}"
    else
      echo "  old 'archives' pin at ${stale#"$BROWSE"/} is busy, leaving it" >&2
      continue
    fi
  fi
  sudo rmdir "$stale" 2>/dev/null && echo "  removed the old 'archives' directory"
done

sudo systemctl daemon-reload
sudo chown "$OWNER:$(id -gn "$OWNER")" "$BROWSE"
sudo chmod 0755 "$BROWSE"

echo
echo "==> $BROWSE"
printf '  %-20s %8s %8s  %s\n' NAME SIZE USED SOURCE
for point in "$BROWSE"/*; do
  [ -d "$point" ] || continue
  read -r size used _ < <(df -h --output=size,used "$point" | tail -1)
  printf '  %-20s %8s %8s  %s\n' "$(basename "$point")" "$size" "$used" \
    "$(findmnt -no SOURCE "$point" 2>/dev/null || echo '-')"
done
echo
echo "In Finder: the board's share, then the disk, then the path — the same"
echo "names the console's Files view uses."
