#!/usr/bin/env bash
# Mirrors the two SSDs, so either one can die and homelab keeps running.
#
# Before: the 250GB SSD holds Debian, a second SSD holds "1) Archive". Lose
# either and the machine is down until someone rebuilds it.
#
# After: both SSDs carry the same three things, and Linux (mdadm RAID 1)
# writes every change to both at once:
#
#   p1  EFI       1G    each disk boots on its own; the firmware tries the
#                       next disk when one is dead
#   p2  root    100G    Debian, mirrored                       -> /
#   p3  apps    115G    "1) Archive", mirrored                 -> /srv/ssd
#   p4  swap     12G    one per disk, not mirrored
#   p5  spare   rest    only on a disk with room left over     -> /srv/spare
#
# The 250GB stays the main disk: reads come from it. The backup SSD's half is marked
# write-mostly, so it takes every write and stays an exact copy without doing
# the reading. A disk dropping out posts to Discord with @everyone, and so
# does a boot with only one disk left (pi-raid-alert).
#
# A mirror is not a backup. A deleted or corrupted file is deleted on both
# disks at once; this only covers a disk dying.
#
# Every path stays the same (/, /srv/ssd, /1) Archive), so no app changes.
#
#   sudo bash deploy/ssd-mirror.sh check            read-only: where things are, what is next
#   sudo bash deploy/ssd-mirror.sh consolidate      apps onto the 250GB; it runs everything alone
#   sudo bash deploy/ssd-mirror.sh stage1           build the mirror on the backup SSD, boot it once
#   sudo bash deploy/ssd-mirror.sh stage2           after that boot: add the 250GB, alerts on
#   sudo bash deploy/ssd-mirror.sh status           both disks, sync progress, boot entries
#   sudo bash deploy/ssd-mirror.sh add /dev/sdX [--backup]   a new or replacement SSD
#   sudo bash deploy/ssd-mirror.sh remove /dev/sdX           take an SSD out on purpose
#
# Consolidate first: the 250GB runs Debian and the apps on its own, and the
# backup SSD is unused. Stage 1 never touches the 250GB. Its reboot uses BootNext, a
# one-time boot: if the mirror does not come up, a power cycle lands back on
# the 250GB exactly as it was, apps included.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE=/etc/pi-ssd-mirror.env
# The apps on the 250GB between consolidate and stage 1: a folder on the root
# filesystem with /srv/ssd bound to it, so every path holds.
LOCAL=/srv/apps-local
NEW=/mnt/ssd-mirror
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
ESP_GB=1 ROOT_GB=100 APPS_GB=115 SWAP_GB=12
# A disk must hold p1-p4 and a little slack. The 250GB has 232.9GiB.
NEED_GIB=$((ESP_GB + ROOT_GB + APPS_GB + SWAP_GB + 1))
GIB=$((1024 * 1024 * 1024))

say() { echo "==> $*"; }
die() { echo "  $*" >&2; exit 1; }

# --- disks -------------------------------------------------------------------

# Mount sources come back as /dev/sdd2[/1) Archive] for a bind; the device is
# the part before the bracket.
src_of() { local s; s=$(findmnt -nfo SOURCE "$1" 2>/dev/null) || return 1; echo "${s%%[*}"; }
disk_of() { echo "/dev/$(lsblk -dno PKNAME "$1" | head -1)"; }
part_of() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "$1$2" ;; esac; }
size_of() { blockdev --getsize64 "$1"; }
uuid() { blkid -s UUID -o value "$1"; }
describe() { lsblk -dno MODEL,SIZE,TRAN "$1" | xargs; }

# sdX letters move between boots on this board; the by-id name does not.
by_id() {
  local l
  for l in /dev/disk/by-id/ata-* /dev/disk/by-id/nvme-*; do
    [ -e "$l" ] || continue
    case "$l" in *-part*) continue ;; esac
    [ "$(readlink -f "$l")" = "$1" ] && { echo "$l"; return 0; }
  done
  echo "$1"
}

# The array named root or apps, whatever number the kernel gave it.
md_dev() {
  local md
  for md in /dev/md[0-9]*; do
    [ -b "$md" ] || continue
    mdadm --detail "$md" 2>/dev/null | grep -Eq "^ *Name : ([^ ]*:)?$1( |$)" && { echo "$md"; return 0; }
  done
  return 1
}

# Every mount of any partition on a disk, deepest first, so binds come off
# before what they bind.
mounts_on() {
  local s t
  findmnt -rno SOURCE,TARGET | while read -r s t; do
    s=$(printf '%b' "$s"); s=${s%%[*}
    case "$s" in "$1"[0-9]*|"$1"p[0-9]*) printf '%b\n' "$t" ;; esac
  done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-
}

unmount_disk() {
  local m try
  for try in 1 2 3; do
    [ -z "$(mounts_on "$1")" ] && return 0
    while IFS= read -r m; do
      # Slave first: a peer of / passes its unmounts back up otherwise.
      mount --make-rslave "$m" 2>/dev/null || true
      umount "$m" 2>/dev/null || true
    done < <(mounts_on "$1")
    sleep 1
  done
  [ -z "$(mounts_on "$1")" ] && return 0
  echo "  Still mounted:" >&2
  mounts_on "$1" | sed 's/^/    /' >&2
  mounts_on "$1" | head -1 | xargs -d '\n' -r fuser -vm 2>&1 | sed 's/^/    /' >&2 || true
  return 1
}

# p1-p4 on every disk, p5 with whatever a bigger disk has left.
partition() {
  local disk=$1 p
  for p in $(lsblk -nrpo NAME,TYPE "$disk" | awk '$2 == "part" { print $1 }'); do
    mdadm --zero-superblock --force "$p" >/dev/null 2>&1 || true
    wipefs -aq "$p" || true
  done
  wipefs -aq "$disk"
  sgdisk --zap-all "$disk" >/dev/null
  sgdisk -n1:0:+${ESP_GB}G -t1:EF00 -c1:EFI \
         -n2:0:+${ROOT_GB}G -t2:FD00 -c2:mirror-root \
         -n3:0:+${APPS_GB}G -t3:FD00 -c3:mirror-apps \
         -n4:0:+${SWAP_GB}G -t4:8200 -c4:"$(swap_name "$disk")" "$disk" >/dev/null
  if [ $(( $(size_of "$disk") / GIB - NEED_GIB )) -gt 20 ]; then
    sgdisk -n5:0:0 -t5:8300 -c5:spare "$disk" >/dev/null
  fi
  partprobe "$disk"; udevadm settle
  for p in 1 2 3 4 5; do
    [ -b "$(part_of "$disk" $p)" ] || continue
    wipefs -aq "$(part_of "$disk" $p)" || true
  done
}

# Fstab lines are rewritten by mount point, keeping options and comments.
fstab_set() { # file, mount point, UUID
  local f=$1 tmp; tmp=$(mktemp)
  awk -v m="$2" -v u="UUID=$3" '
    $1 !~ /^#/ && NF >= 3 && $2 == m { $1 = u; if (m == "/boot/efi" && $4 !~ /nofail/) $4 = $4 ",nofail" }
    { print }' "$f" > "$tmp"
  install -m 644 "$tmp" "$f"; rm -f "$tmp"
}

# Swap lines whose partition is gone: a disk taken out, or the 250GB's old one.
prune_swap() {
  local tmp; tmp=$(mktemp)
  awk '$1 !~ /^#/ && $3 == "swap" && $1 ~ /^UUID=/ {
         if (system("test -e /dev/disk/by-uuid/" substr($1, 6)) != 0) next }
       { print }' /etc/fstab > "$tmp"
  install -m 644 "$tmp" /etc/fstab; rm -f "$tmp"
}

boot_entry() { # label -> Boot#### number
  efibootmgr | sed -n "s/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} $1\([[:space:]].*\)\{0,1\}$/\1/p" | tail -1
}

add_boot_entry() { # disk -> prints the new Boot#### number
  local disk=$1 label n loader='\EFI\debian\grubx64.efi' tmp
  label="homelab mirror $(lsblk -dno SERIAL "$disk" | xargs)"
  while n=$(boot_entry "$label") && [ -n "$n" ]; do efibootmgr -q -b "$n" -B; done
  tmp=$(mktemp -d); mount "$(part_of "$disk" 1)" "$tmp"
  [ -f "$tmp/EFI/debian/shimx64.efi" ] && loader='\EFI\debian\shimx64.efi'
  umount "$tmp"; rmdir "$tmp"
  # -c puts the new entry first; callers set the order they want after.
  efibootmgr -q -c -d "$disk" -p 1 -L "$label" -l "$loader"
  boot_entry "$label"
}

# Each disk's swap gets its own name. Two partitions both called "swap" make
# /dev/disk/by-label/swap point at two devices, and systemd logs "Swap
# appeared twice ... refusing" on every boot.
swap_name() { local s; s=$(lsblk -dno SERIAL "$1" | xargs); echo "swap-${s: -8}"; }

write_mostly() { # md, partition
  echo writemostly > "/sys/block/$(basename "$(readlink -f "$1")")/md/dev-$(basename "$2")/state"
}

# --- shared by consolidate and stage 1 ---------------------------------------

# Stopping the apps for a copy: every host timer first (jellyfin-guard opens
# jellyfin.db every minute, enough to fail the copy check), then k3s and its
# containers, then Samba. start_apps undoes it.
TIMERS=""
stop_apps() {
  local i
  TIMERS=$(systemctl list-units --type=timer --state=active --no-legend --plain | awk '{ print $1 }' | xargs)
  # shellcheck disable=SC2086
  [ -z "$TIMERS" ] || systemctl stop $TIMERS
  for i in $(seq 30); do
    systemctl list-units --type=service --state=activating --no-legend --plain | grep -q . || break
    sleep 1
  done
  systemctl stop k3s
  # Stopping k3s leaves its containers running, by design. Its own teardown
  # kills them and lifts their mounts.
  [ -x /usr/local/bin/k3s-killall.sh ] || die "k3s-killall.sh is missing; cannot stop the containers."
  /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
  for i in $(seq 30); do pgrep -f containerd-shim >/dev/null || break; sleep 1; done
  if pgrep -f containerd-shim >/dev/null; then
    pgrep -af containerd-shim | head -5 | sed 's/^/    /' >&2
    die "Containers are still running."
  fi
  systemctl stop smbd nmbd 2>/dev/null || true
  echo "  apps, timers and Samba stopped"
}
start_apps() {
  # shellcheck disable=SC2086
  systemctl start smbd nmbd k3s $TIMERS 2>/dev/null || true
}

# Two passes (the second catches anything that moved during the first), then
# a dry run that must come back empty.
copy_tree() { # from, to
  rsync -aAXH --numeric-ids --delete --info=progress2 "$1/" "$2/"
  rsync -aAXH --numeric-ids --delete "$1/" "$2/"
  local diff
  diff=$(rsync -aAXHn --numeric-ids --delete --itemize-changes "$1/" "$2/")
  if [ -n "$diff" ]; then
    echo "  Still changing under the copy:" >&2
    echo "$diff" | head -20 | sed 's/^/    /' >&2
    return 1
  fi
  echo "  copy matches"
}

# The whole fstab line for a mount point, replaced.
fstab_line() { # file, mount point, new line
  local tmp; tmp=$(mktemp)
  awk -v m="$2" -v l="$3" '$1 !~ /^#/ && NF >= 3 && $2 == m { print l; next } { print }' "$1" > "$tmp"
  install -m 644 "$tmp" "$1"; rm -f "$tmp"
}

who_is_on() { command -v pi-when >/dev/null || return 0; say "Who is using it"; pi-when now || true; }

# --- check -------------------------------------------------------------------

check() {
  local root_src apps_src main
  root_src=$(src_of /) || die "Cannot read the root mount."
  apps_src=$(src_of /srv/ssd) || apps_src="(not mounted)"
  say "Now"
  printf '  %-10s %-12s %s\n' / "$root_src" "$(describe "$(disk_of "$root_src")")"
  printf '  %-10s %-12s %s\n' /srv/ssd "$apps_src" "$(describe "$(disk_of "$apps_src" 2>/dev/null)" 2>/dev/null)"
  case "$root_src" in /dev/md*)
    if grep -q '\[2/2\]' /proc/mdstat; then echo "  Next: nothing, both SSDs are in the mirror"
    else echo "  Next: sudo bash deploy/ssd-mirror.sh stage2"; fi
    return ;;
  esac
  main=$(disk_of "$root_src")
  say "Space on $main"
  printf '  %-22s %4s GiB used\n' "Debian (/)" $(( $(df -B1 --output=used / | tail -1) / GIB ))
  printf '  %-22s %4s GiB used\n' "apps (/srv/ssd)" $(( $(df -B1 --output=used /srv/ssd | tail -1) / GIB ))
  printf '  %-22s %4s GiB free\n' "on /" $(( $(df -B1 --output=avail / | tail -1) / GIB ))
  if [ "$(disk_of "$apps_src")" = "$main" ]; then
    echo "  The apps run from the 250GB. Next: sudo bash deploy/ssd-mirror.sh stage1"
  else
    echo "  The apps run from $(describe "$(disk_of "$apps_src")"). Next: sudo bash deploy/ssd-mirror.sh consolidate"
  fi
}

# --- consolidate -------------------------------------------------------------

# Moves the apps onto the 250GB, so it runs everything on its own and the other
# SSD is free to become the mirror. That SSD is unmounted, not erased: its copy of
# the apps stays as it was until stage 1.
consolidate() {
  ROOT_SRC=$(src_of /) || die "Cannot read the root mount."
  case "$ROOT_SRC" in /dev/md*) die "Root is already on the mirror." ;; esac
  APPS_SRC=$(src_of /srv/ssd) || die "/srv/ssd is not mounted."
  MAIN=$(disk_of "$ROOT_SRC")
  BACKUP=$(disk_of "$APPS_SRC")
  if [ "$BACKUP" = "$MAIN" ]; then
    echo "  The apps already run from $MAIN ($(describe "$MAIN")). Next: stage1"; return 0
  fi
  local apps_used root_free
  apps_used=$(df -B1 --output=used /srv/ssd | tail -1)
  root_free=$(df -B1 --output=avail / | tail -1)

  who_is_on
  say "Moving the apps"
  printf '  %-6s %s\n' from "$BACKUP  $(describe "$BACKUP")  (/srv/ssd, $((apps_used / GIB)) GiB)"
  printf '  %-6s %s\n' to "$MAIN  $(describe "$MAIN")  ($LOCAL, $((root_free / GIB)) GiB free)"
  [ "$root_free" -gt $(( apps_used + 20 * GIB )) ] || die "Not enough room on the 250GB."
  echo "  The other SSD is unmounted afterwards, not erased. Apps are down for about 10 minutes."
  printf '  Type MOVE to start: '
  read -r reply
  [ "$reply" = MOVE ] || die "Stopped. Nothing was changed."

  # The first attempt staged a copy on the 6TB. Only a copy; the other SSD still
  # holds the originals.
  if [ -d /srv/storage/.ssd-mirror-stage ]; then
    say "Deleting the old staging copy on the 6TB"
    rm -rf /srv/storage/.ssd-mirror-stage
  fi

  say "Stopping the apps"
  FSTAB_BAK=""
  trap 'echo "  Stopped. Putting everything back as it was." >&2
        if [ -n "$FSTAB_BAK" ]; then
          install -m 644 "$FSTAB_BAK" /etc/fstab; systemctl daemon-reload
          umount "/1) Archive" /srv/ssd 2>/dev/null || true
        fi
        mount -a 2>/dev/null || true; start_apps' EXIT
  stop_apps

  say "Copying the apps to $LOCAL"
  mkdir -p "$LOCAL"
  copy_tree /srv/ssd "$LOCAL" || die "The copy does not match. Nothing was changed."

  say "/srv/ssd now comes from the 250GB"
  FSTAB_BAK=/etc/fstab.pi-ssd-mirror.bak
  cp /etc/fstab "$FSTAB_BAK"
  unmount_disk "$BACKUP" || die "Could not unmount the other SSD."
  fstab_line /etc/fstab /srv/ssd "$LOCAL /srv/ssd none bind,nofail 0 0"
  systemctl daemon-reload
  mount -a
  [ "$(disk_of "$(src_of /srv/ssd)")" = "$MAIN" ] || die "/srv/ssd did not come up from the 250GB."
  [ -d "/1) Archive/Apps" ] || die "/1) Archive is empty after the switch."
  printf 'MAIN_ID=%s\nBACKUP_ID=%s\n' "$(by_id "$MAIN")" "$(by_id "$BACKUP")" > "$STATE"

  trap - EXIT
  say "Starting the apps"
  start_apps
  cat <<NEXT

Done. The 250GB now runs Debian and the apps on its own; the other SSD is not used.
Give the apps a few minutes, check they all work (dashboard, Jellyfin,
Nextcloud, Immich), then build the mirror:

  sudo bash $REPO_ROOT/deploy/ssd-mirror.sh stage1

To undo instead: sudo cp $FSTAB_BAK /etc/fstab, then reboot.
NEXT
}

# --- stage 1 -----------------------------------------------------------------

stage1() {
  ROOT_SRC=$(src_of /) || die "Cannot read the root mount."
  case "$ROOT_SRC" in /dev/md*) die "Root is already on the mirror. Next: sudo bash deploy/ssd-mirror.sh stage2" ;; esac
  MAIN=$(disk_of "$ROOT_SRC")
  [ "$(disk_of "$(src_of /srv/ssd)")" = "$MAIN" ] && [ -r "$STATE" ] ||
    die "The apps are not on the 250GB yet. First: sudo bash deploy/ssd-mirror.sh consolidate"
  # shellcheck disable=SC1090
  . "$STATE"
  BACKUP=$(readlink -f "$BACKUP_ID")
  [ -b "$BACKUP" ] && [ "$BACKUP" != "$MAIN" ] || die "The backup SSD ($BACKUP_ID) is not here."
  # Unused since consolidate, but an automount may have picked it up.
  unmount_disk "$BACKUP" || die "Could not unmount $BACKUP."
  # A failed run leaves a half-built mirror on the backup SSD; it is erased again
  # below. An array on any other disk is not this script's to touch.
  local md slave leftover=""
  for md in /sys/block/md[0-9]*; do
    [ -e "$md" ] || continue
    for slave in "$md"/slaves/*; do
      [ "/dev/$(lsblk -dno PKNAME "/dev/$(basename "$slave")")" = "$BACKUP" ] ||
        die "$(basename "$md") uses $(basename "$slave"), not the backup SSD. Not touching it."
    done
    leftover="$leftover /dev/$(basename "$md")"
  done
  [ -d /sys/firmware/efi ] || die "Not booted in UEFI mode."
  [ $(( $(size_of "$BACKUP") / GIB )) -ge $NEED_GIB ] || die "$BACKUP is smaller than ${NEED_GIB}GiB."
  local apps_used root_used
  apps_used=$(du -sb "$LOCAL" | cut -f1)
  root_used=$(( $(df -B1 --output=used / | tail -1) - apps_used ))
  [ "$root_used" -lt $(( (ROOT_GB - 10) * GIB )) ] || die "Debian is too big for ${ROOT_GB}GiB."
  [ "$apps_used" -lt $(( (APPS_GB - 10) * GIB )) ] || die "The apps are too big for ${APPS_GB}GiB."

  who_is_on
  say "Building the mirror"
  printf '  %-7s %s\n' erase "$BACKUP  $(describe "$BACKUP")"
  printf '  %-7s %s\n' copy "Debian $((root_used / GIB)) GiB, apps $((apps_used / GIB)) GiB, from the 250GB"
  echo "  The 250GB is not touched. Apps are down until the reboot."
  printf '  Type WIPE to erase %s (%s): ' "$BACKUP" "$(describe "$BACKUP")"
  read -r reply
  [ "$reply" = WIPE ] || die "Stopped. Nothing was changed."

  say "Tools"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q mdadm gdisk dosfstools efibootmgr rsync >/dev/null

  say "Stopping the apps"
  trap 'echo "  Stopped. The 250GB is untouched; starting the apps again." >&2
        umount -R "$NEW" 2>/dev/null || true; start_apps' EXIT
  stop_apps

  say "Laying out $BACKUP"
  # The share's SSD-250GB folder is a bind of / that still joins its mounts
  # (its fstab line predates the rprivate fix), so anything mounted under
  # /mnt shows up in there as a linked copy, and unmounting a linked copy
  # unmounts the original. An earlier run lost /sys/firmware/efi/efivars
  # that way. Each folder is its own mount; /srv/browse itself is not one.
  for m in /srv/browse/*; do
    mountpoint -q "$m" && mount --make-rprivate "$m"
  done
  umount -R "$NEW" 2>/dev/null || true
  if [ -n "$leftover" ]; then
    for md in $leftover; do
      while IFS= read -r t; do umount -R "$t" 2>/dev/null || umount -Rl "$t" 2>/dev/null || true; done < <(
        findmnt -rno SOURCE,TARGET | while read -r src t; do
          src=$(printf '%b' "$src")
          [ "${src%%[*}" = "$md" ] && printf '%b\n' "$t"
        done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
    done
    # shellcheck disable=SC2086
    mdadm --stop $leftover >/dev/null || die "Could not stop the last run's mirror: cat /proc/mdstat"
    echo "  cleared the last run's half-built mirror"
  fi
  partition "$BACKUP"
  mdadm --create /dev/md/root --name=root --level=1 --metadata=1.2 --bitmap=internal \
    --raid-devices=2 --run "$(part_of "$BACKUP" 2)" missing <<<y
  mdadm --create /dev/md/apps --name=apps --level=1 --metadata=1.2 --bitmap=internal \
    --raid-devices=2 --run "$(part_of "$BACKUP" 3)" missing <<<y
  udevadm settle
  MD_ROOT=$(md_dev root); MD_APPS=$(md_dev apps)
  mkfs.ext4 -q -F -L root "$MD_ROOT"
  mkfs.ext4 -q -F -L apps -m 1 "$MD_APPS"
  mkfs.vfat -F 32 -n EFI "$(part_of "$BACKUP" 1)" >/dev/null
  mkswap -q -L "$(swap_name "$BACKUP")" "$(part_of "$BACKUP" 4)"
  SPARE=""
  if [ -b "$(part_of "$BACKUP" 5)" ]; then
    SPARE=$(part_of "$BACKUP" 5)
    mkfs.ext4 -q -F -L spare "$SPARE"
  fi

  say "Copying Debian"
  mkdir -p "$NEW"
  # Private before anything goes under it: the /dev, /proc, /sys and /run
  # binds below must not leave copies anywhere else.
  mount --bind "$NEW" "$NEW" && mount --make-private "$NEW"
  mount "$MD_ROOT" "$NEW"
  # -x stays on the root filesystem, but a bind of a folder on it is the same
  # filesystem and rsync walks straight in: /srv/ssd and /1) Archive are binds
  # of the apps folder, /srv/browse/SSD-250GB of / itself. Each would copy the
  # apps again (the first run filled 100G that way). Their mount points are
  # kept empty; the apps folder goes to its own mirror below.
  local excludes=(--exclude="$LOCAL" --exclude="$NEW/*" --exclude='/lost+found')
  local t
  while IFS= read -r t; do
    [ "$t" = / ] || excludes+=(--exclude="$t/*")
  done < <(findmnt -rno TARGET,SOURCE | while read -r t src; do
             src=$(printf '%b' "$src")
             [ "${src%%[*}" = "$ROOT_SRC" ] && printf '%b\n' "$t"
           done)
  rsync -aAXHx --numeric-ids --info=progress2 "${excludes[@]}" / "$NEW/"
  mkdir -p "$NEW/boot/efi"
  mount "$(part_of "$BACKUP" 1)" "$NEW/boot/efi"
  rsync -rt /boot/efi/ "$NEW/boot/efi/"

  say "Copying the apps"
  mkdir -p "$NEW/srv/ssd"
  mount "$MD_APPS" "$NEW/srv/ssd"
  copy_tree "$LOCAL" "$NEW/srv/ssd" || die "The apps on the mirror do not match."

  say "Pointing the copy at the mirror"
  fstab_set "$NEW/etc/fstab" / "$(uuid "$MD_ROOT")"
  fstab_set "$NEW/etc/fstab" /boot/efi "$(uuid "$(part_of "$BACKUP" 1)")"
  fstab_line "$NEW/etc/fstab" /srv/ssd "UUID=$(uuid "$MD_APPS") /srv/ssd ext4 defaults,noatime,nofail 0 2"
  # The 250GB's swap goes; this disk's own comes in.
  sed -i '/^[^#].*[[:space:]]swap[[:space:]]/d' "$NEW/etc/fstab"
  echo "UUID=$(uuid "$(part_of "$BACKUP" 4)") none swap sw,nofail 0 0" >> "$NEW/etc/fstab"
  if [ -n "$SPARE" ]; then
    mkdir -p "$NEW/srv/spare"
    echo "UUID=$(uuid "$SPARE") /srv/spare ext4 defaults,noatime,nofail 0 2" >> "$NEW/etc/fstab"
  fi
  for conf in /etc/mdadm/mdadm.conf "$NEW/etc/mdadm/mdadm.conf"; do
    sed -i '/^ARRAY /d' "$conf"
    mdadm --detail --brief "$MD_ROOT" "$MD_APPS" >> "$conf"
  done
  # A kernel or initramfs that cannot find its root reboots after 10 seconds
  # instead of waiting at a prompt nobody can see. BootNext is spent by then,
  # so that reboot lands on the 250GB.
  grep -q 'panic=' "$NEW/etc/default/grub" ||
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 panic=10"/' "$NEW/etc/default/grub"
  cp "$STATE" "$NEW$STATE"

  say "Making it bootable"
  for d in dev proc sys run; do mount --rbind "/$d" "$NEW/$d"; mount --make-rslave "$NEW/$d"; done
  chroot "$NEW" update-initramfs -u -k all
  chroot "$NEW" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=debian --no-nvram --force-extra-removable
  chroot "$NEW" update-grub 2>&1 | sed 's/^/  /'
  grep -q "$(uuid "$MD_ROOT")" "$NEW/boot/grub/grub.cfg" || die "grub.cfg does not boot the mirror."
  # The whole listing first: grep -q would stop reading at the first match,
  # and the listing tool calls the broken pipe a failure.
  local listing
  listing=$(lsinitramfs "$(ls -1 "$NEW"/boot/initrd.img-* | sort -V | tail -1)")
  grep -q 'sbin/mdadm' <<<"$listing" || die "The initramfs has no mdadm in it; it could not find the mirror."
  grep -q 'mdadm.conf' <<<"$listing" || die "The initramfs has no mdadm.conf; it would not know the mirror."
  umount -R "$NEW"

  say "Boot entry"
  mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  ORDER=$(efibootmgr | sed -n 's/^BootOrder: //p')
  ENTRY=$(add_boot_entry "$BACKUP")
  [ -n "$ENTRY" ] || die "Could not create the boot entry."
  # Usual order back, the mirror last, and the mirror once via BootNext.
  efibootmgr -q -o "${ORDER:+$ORDER,}$ENTRY"
  efibootmgr -q -n "$ENTRY"
  echo "  Boot$ENTRY  $(describe "$BACKUP")  -- next boot only"

  trap - EXIT
  cat <<NEXT

Stage 1 done. The apps stay stopped until the reboot, so nothing changes on
the 250GB that the mirror would miss. Reboot now:

  sudo reboot

Give it 3 minutes, SSH back in, then:

  sudo bash $REPO_ROOT/deploy/ssd-mirror.sh status

It should say root is on the mirror. If homelab has not come back after 5
minutes, switch it off at the power button and on again: it boots the 250GB
exactly as it was, apps included. Nothing is lost either way.
NEXT
}

# --- add / stage 2 -----------------------------------------------------------

# Lays out a disk, joins it to both mirrors, copies the EFI partition and gives
# it a boot entry. Prints the entry number last.
add_disk() { # disk, role (main|backup)
  local disk=$1 role=$2 md p tmp
  MD_ROOT=$(md_dev root) || die "No mirror named root."
  MD_APPS=$(md_dev apps) || die "No mirror named apps."
  [ $(( $(size_of "$disk") / GIB )) -ge $NEED_GIB ] || die "$disk is smaller than ${NEED_GIB}GiB."
  [ -z "$(mounts_on "$disk")" ] || die "$disk has mounted partitions: $(mounts_on "$disk" | xargs)"
  grep -qw "$(basename "$disk")[0-9p]*" /proc/mdstat && die "$disk is already in a mirror."

  partition "$disk"
  mdadm --add "$MD_ROOT" "$(part_of "$disk" 2)" >/dev/null
  mdadm --add "$MD_APPS" "$(part_of "$disk" 3)" >/dev/null
  if [ "$role" = backup ]; then
    write_mostly "$MD_ROOT" "$(part_of "$disk" 2)"
    write_mostly "$MD_APPS" "$(part_of "$disk" 3)"
  fi

  mkfs.vfat -F 32 -n EFI "$(part_of "$disk" 1)" >/dev/null
  mountpoint -q /boot/efi || mount /boot/efi
  tmp=$(mktemp -d); mount "$(part_of "$disk" 1)" "$tmp"
  rsync -rt --delete /boot/efi/ "$tmp/"
  umount "$tmp"; rmdir "$tmp"

  mkswap -q -L "$(swap_name "$disk")" "$(part_of "$disk" 4)"
  echo "UUID=$(blkid -s UUID -o value "$(part_of "$disk" 4)") none swap sw,nofail 0 0" >> /etc/fstab
  swapon "$(part_of "$disk" 4)" || true
  p=$(part_of "$disk" 5)
  if [ -b "$p" ]; then
    mkfs.ext4 -q -F -L spare "$p"
    if ! awk '$1 !~ /^#/ && $2 == "/srv/spare"' /etc/fstab | grep -q .; then
      mkdir -p /srv/spare
      echo "UUID=$(blkid -s UUID -o value "$p") /srv/spare ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
      systemctl daemon-reload; mount /srv/spare || true
    fi
  fi

  add_boot_entry "$disk"
}

# Main disk first, the rest of the mirror next, anything else after. Entries
# for EFI partitions that no longer exist (the 250GB's old one) are deleted.
boot_order() { # first entry, second entry
  local n uuid order="$1${2:+,$2}"
  while read -r n uuid; do
    [ -e "/dev/disk/by-partuuid/$uuid" ] || { efibootmgr -q -b "$n" -B; echo "  removed stale Boot$n"; }
  # The firmware may store the path upper-cased (\EFI\DEBIAN\).
  done < <(efibootmgr -v | sed -n 's/^Boot\([0-9A-F]\{4\}\).*HD([0-9]*,GPT,\([0-9a-fA-F-]*\),.*File(\\EFI\\[Dd][Ee][Bb][Ii][Aa][Nn]\\.*/\1 \2/p')
  for n in $(efibootmgr | sed -n 's/^BootOrder: //p' | tr ',' ' '); do
    case ",$order," in *",$n,"*) ;; *) efibootmgr | grep -q "^Boot$n" && order="$order,$n" ;; esac
  done
  efibootmgr -q -o "$order"
}

install_alerts() {
  say "Alerts"
  install -m 755 "$REPO_ROOT/deploy/pi-raid-alert.sh" /usr/local/bin/pi-raid-alert
  install -m 755 "$REPO_ROOT/deploy/pi-esp-sync.sh" /usr/local/bin/pi-esp-sync
  local conf=/etc/mdadm/mdadm.conf
  sed -i '/^PROGRAM /d' "$conf"
  echo "PROGRAM /usr/local/bin/pi-raid-alert" >> "$conf"
  cat > /etc/systemd/system/pi-raid-check.service <<'UNIT'
[Unit]
Description=Post to Discord if homelab booted with an SSD missing from the mirror
Wants=network-online.target
After=network-online.target mdmonitor.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pi-esp-sync
ExecStart=/usr/local/bin/pi-raid-alert --boot

[Install]
WantedBy=multi-user.target
UNIT
  # Any package change can touch GRUB or the kernel; every disk's EFI
  # partition gets the result, not only the mounted one.
  echo 'DPkg::Post-Invoke { "/usr/local/bin/pi-esp-sync || true"; };' > /etc/apt/apt.conf.d/99-pi-esp-sync
  systemctl daemon-reload
  systemctl enable pi-raid-check.service >/dev/null 2>&1
  systemctl restart mdmonitor.service 2>/dev/null || systemctl start mdmonitor.service 2>/dev/null || true
  printf '  %-14s %s\n' mdmonitor "$(systemctl is-active mdmonitor.service 2>/dev/null || true)"
  /usr/local/bin/pi-raid-alert TestMessage "$(md_dev root)" && echo "  test message sent to Discord"
}

stage2() {
  ROOT_SRC=$(src_of /)
  case "$ROOT_SRC" in /dev/md*) ;; *)
    die "Root is on $ROOT_SRC, not the mirror. Stage 1's boot did not take; paste: sudo bash deploy/ssd-mirror.sh status" ;;
  esac
  [ -r "$STATE" ] || die "$STATE is missing; it names the two disks."
  # shellcheck disable=SC1090
  . "$STATE"
  MAIN=$(readlink -f "$MAIN_ID"); BACKUP=$(readlink -f "$BACKUP_ID")
  [ -b "$MAIN" ] || die "The 250GB ($MAIN_ID) is not here."
  [ "$(disk_of "$ROOT_SRC")" != "$MAIN" ] || die "Root runs from $MAIN; it cannot be the disk being erased."
  if grep -qw "$(basename "$MAIN")[0-9]*" /proc/mdstat; then
    echo "  $MAIN is already in the mirror. Showing status."; status; return
  fi

  local p
  for p in $(lsblk -nrpo NAME,TYPE "$MAIN" | awk '$2 == "part" { print $1 }'); do swapoff "$p" 2>/dev/null || true; done
  unmount_disk "$MAIN" || die "Could not free $MAIN."

  say "Disks"
  printf '  %-8s %-10s %s\n' main "$MAIN" "$(describe "$MAIN")  -- erased now, joins the mirror"
  printf '  %-8s %-10s %s\n' backup "$BACKUP" "$(describe "$BACKUP")  -- running, kept"
  printf '  Type WIPE to erase %s (%s): ' "$MAIN" "$(describe "$MAIN")"
  read -r reply
  [ "$reply" = WIPE ] || die "Stopped. Nothing was changed."

  # The mirror becomes the normal boot now, so a reboot mid-way still lands
  # on it rather than on the 250GB's old system.
  local backup_entry main_entry
  backup_entry=$(boot_entry "homelab mirror $(lsblk -dno SERIAL "$BACKUP" | xargs)")
  [ -n "$backup_entry" ] && boot_order "$backup_entry"

  say "Laying out $MAIN and joining it to the mirror"
  main_entry=$(add_disk "$MAIN" main | tail -1)
  prune_swap

  say "$(describe "$BACKUP") as the backup half (write-mostly)"
  write_mostly "$(md_dev root)" "$(part_of "$BACKUP" 2)"
  write_mostly "$(md_dev apps)" "$(part_of "$BACKUP" 3)"

  say "Boot order"
  boot_order "$main_entry" "$backup_entry"
  efibootmgr | grep -E '^Boot(Order|[0-9A-F]{4}\*? homelab)' | sed 's/^/  /'

  install_alerts
  update-initramfs -u >/dev/null 2>&1 || true
  systemctl daemon-reload
  echo
  status
  cat <<NEXT

Stage 2 done. The 250GB is copying itself from the backup SSD (the % above); the
machine is fully usable while it does. Then:

  sudo bash $REPO_ROOT/deploy/setup-browse.sh
NEXT
}

add_cmd() {
  local disk=${1:-} role=main entry
  [ -b "$disk" ] || die "Usage: ssd-mirror.sh add /dev/sdX [--backup]"
  [ "${2:-}" = --backup ] && role=backup
  disk=$(readlink -f "$disk")
  say "Adding $disk ($(describe "$disk")) as $role"
  printf '  Type WIPE to erase it: '
  read -r reply
  [ "$reply" = WIPE ] || die "Stopped. Nothing was changed."
  prune_swap
  entry=$(add_disk "$disk" "$role" | tail -1)
  # A main disk boots first; a backup boots second.
  if [ "$role" = main ]; then
    boot_order "$entry"
    sed -i "s|^MAIN_ID=.*|MAIN_ID=$(by_id "$disk")|" "$STATE" 2>/dev/null || true
  else
    boot_order "$(efibootmgr | sed -n 's/^BootOrder: \([0-9A-F]\{4\}\).*/\1/p')" "$entry"
    sed -i "s|^BACKUP_ID=.*|BACKUP_ID=$(by_id "$disk")|" "$STATE" 2>/dev/null || true
  fi
  update-initramfs -u >/dev/null 2>&1 || true
  status
}

remove_cmd() {
  local disk=${1:-} md p label n
  [ -b "$disk" ] || die "Usage: ssd-mirror.sh remove /dev/sdX"
  disk=$(readlink -f "$disk")
  for md in $(md_dev root) $(md_dev apps); do
    [ "$(mdadm --detail "$md" | sed -n 's/^ *Active Devices : //p')" -ge 2 ] ||
      die "$(basename "$md") has only one disk left; removing it would stop homelab."
  done
  say "Taking $disk ($(describe "$disk")) out of the mirror"
  printf '  The other SSD carries on alone until a new one is added. Type REMOVE: '
  read -r reply
  [ "$reply" = REMOVE ] || die "Stopped. Nothing was changed."
  # Planned, so no @everyone for the next ten minutes.
  mkdir -p /run/pi-raid-alert && touch /run/pi-raid-alert/quiet
  for md in $(md_dev root) $(md_dev apps); do
    for p in $(lsblk -nrpo NAME "$disk" | tail -n +2); do
      if mdadm --detail "$md" | grep -q "$p\$"; then
        mdadm "$md" --fail "$p" --remove "$p" >/dev/null
        mdadm --zero-superblock "$p" 2>/dev/null || true
        echo "  $p left $(basename "$md")"
      fi
    done
  done
  for p in $(lsblk -nrpo NAME "$disk" | tail -n +2); do swapoff "$p" 2>/dev/null || true; done
  if [ "$(disk_of "$(src_of /boot/efi 2>/dev/null || echo /dev/null)" 2>/dev/null)" = "$disk" ]; then
    umount /boot/efi
  fi
  unmount_disk "$disk" || true
  # Point /boot/efi at a disk that stays; pi-esp-sync mounts one if needed.
  /usr/local/bin/pi-esp-sync || true
  p=$(src_of /boot/efi 2>/dev/null) && fstab_set /etc/fstab /boot/efi "$(blkid -s UUID -o value "$p")"
  label="homelab mirror $(lsblk -dno SERIAL "$disk" | xargs)"
  while n=$(boot_entry "$label") && [ -n "$n" ]; do efibootmgr -q -b "$n" -B; echo "  removed Boot$n"; done
  echo "  Power off, swap the disk, power on, then: sudo bash deploy/ssd-mirror.sh add /dev/sdX --backup"
}

# --- status ------------------------------------------------------------------

status() {
  say "Mounts"
  for m in / /srv/ssd /boot/efi /srv/spare; do
    printf '  %-10s %s\n' "$m" "$(src_of "$m" 2>/dev/null || echo '(not mounted)')"
  done
  say "Mirrors"
  local md name found=0
  for md in /dev/md[0-9]*; do
    [ -b "$md" ] || continue
    found=1
    name=$(mdadm --detail "$md" | sed -n 's/^ *Name : \([^ ]*:\)\{0,1\}\([^ ]*\).*/\2/p')
    printf '  %-5s %-9s %s\n' "$name" "$(basename "$md")" "$(mdadm --detail "$md" | sed -n 's/^ *State : //p')"
    mdadm --detail "$md" | awk '$NF ~ /^\/dev\// && $1 ~ /^[0-9]+$/ {
        s = ""; for (i = 5; i < NF; i++) s = s $i " "; print $NF, s }' |
      while read -r p role; do
        printf '        %-10s %-28s %s\n' "$p" "$role" "$(describe "$(disk_of "$p")")"
      done
    sed -n "/^$(basename "$md") /,/^$/p" /proc/mdstat | grep -o '\(recovery\|resync\) *=.*' | sed 's/^/        /' || true
  done
  [ "$found" -eq 1 ] || echo "  none"
  say "Swap"
  swapon --show=NAME,SIZE --noheadings | sed 's/^/  /'
  say "Boot"
  efibootmgr | grep -E '^Boot(Next|Order|[0-9A-F]{4})' | sed 's/^/  /'
}

case "${1:-}" in
  check) check ;;
  consolidate) consolidate ;;
  stage1) stage1 ;;
  stage2) stage2 ;;
  status) status ;;
  add) shift; add_cmd "$@" ;;
  remove) shift; remove_cmd "$@" ;;
  *) sed -n '/^#   sudo/p' "$0" | sed 's/^# *//'; exit 1 ;;
esac
