#!/usr/bin/env bash
# Makes a plugged-in drive mount itself. Run on any board. Idempotent.
#
# Plugging a disk in should be the whole job — USB, SATA, whatever the kernel
# recognises. Without this it takes an ssh session, a mount, an fstab line and
# a re-run of setup-browse.sh, which is four steps too many for "I attached a
# drive".
#
# A udev rule hands each new partition to systemd-mount, which mounts it under
# /media and unmounts it again when the device goes away. That is how a desktop
# Linux behaves; nothing here is exotic. /media is already in the agent's
# writable roots, so the drive arrives browsable and writable with no config.
#
# The partitions the board boots from are excluded explicitly, by device and by
# PARTUUID. The first version of this rule trusted systemd-mount to skip
# devices already in fstab, and that trust was wrong: fstab names them by
# PARTUUID while the rule hands systemd-mount a /dev node, and both boards
# ended up with their own root and boot filesystems mounted under /media —
# writable, through the console's file browser, one stray delete from an
# unbootable board.
set -euo pipefail

RULE=/etc/udev/rules.d/99-pi-automount.rules
HELPER=/usr/local/lib/pi/mount-media
MEDIA=/media

# Who owns a filesystem that cannot say. Resolved here, at install time, and
# baked into the helper: udev runs it as root with no login and no way to ask.
OWNER="${OWNER:-$(id -un)}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

# The device behind a path, as exactly one line.
#
# findmnt answers with a row per mount, and a path can carry more than one: a
# systemd automount unit and the real filesystem stack at the same target, the
# former reporting its source as "systemd-1" rather than a device. Every use
# here assumed a single line and a device. Neither held, and the failure was
# quiet in both directions — the exclusion list below became a multi-line
# string udev cannot parse, so it excluded nothing, and the cleanup further
# down compared against it and matched nothing. The first row naming a device
# is the answer to the question actually being asked.
device_at() { findmnt -no SOURCE "$@" 2>/dev/null | grep -m1 '^/dev/' || true; }

# Everything udev will ever see the boot partitions as, resolved from the live
# mounts so the rule works on any board however it boots. Deduplicated: the
# same device can back more than one of these paths, and repeating an exclusion
# makes the rule longer without making it stricter.
self_excludes=""
self_sources=""
for mountpoint in / /boot/firmware; do
  src=$(device_at "$mountpoint")
  case " $self_sources " in
    *" $src "*) src="" ;;   # already excluded by an earlier mount point
  esac
  if [ -n "$src" ]; then
    self_excludes="$self_excludes ENV{DEVNAME}!=\"$src\""
    self_sources="$self_sources $src"
  fi
  partuuid=$(findmnt -no PARTUUID "$mountpoint" 2>/dev/null | grep -m1 . || true)
  case "$partuuid" in
    ''|-) ;;  # not every filesystem has one; the DEVNAME match still guards
    *)
      case "$self_excludes" in
        *"\"$partuuid\""*) ;;
        *) self_excludes="$self_excludes ENV{ID_PART_ENTRY_UUID}!=\"$partuuid\"" ;;
      esac
      ;;
  esac
done
# A board whose root could not be named still gets a rule that parses, matching
# nothing, rather than one udev rejects outright.
[ -n "$self_excludes" ] || self_excludes='ENV{DEVNAME}=="__no_such_node__"'

echo "==> Ensuring $MEDIA exists"
sudo mkdir -p "$MEDIA"

# A USB stick is usually not ext4. exFAT is what anything over 32GB is sold
# formatted as, NTFS is what a drive that has seen Windows carries, and a board
# without those drivers mounts neither — the rule fires, the mount fails, and
# nothing says why. Installed here so "plug it in and read it" holds for the
# filesystems people actually turn up with. Best-effort: a board with no
# network keeps the drivers it already has rather than failing the whole run.
echo "==> Filesystem drivers for the disks people actually plug in"
missing=""
for pkg in exfatprogs ntfs-3g; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
  echo "  installing:$missing"
  sudo apt-get update -qq && sudo apt-get install -y -qq $missing || \
    echo "  could not install$missing — exFAT or NTFS sticks may not mount" >&2
else
  echo "  exfatprogs, ntfs-3g: already installed"
fi

echo "==> Writing $HELPER"
# The rule used to build the mount point inline, as /media/$env{ID_FS_LABEL},
# and that expression is wrong in three ways that all end in a drive you
# plugged in and cannot read:
#
#   no label      the path becomes "/media/" — the directory itself, not a
#                 mount point under it. The note this script prints claimed a
#                 device-name fallback that the rule never had.
#   a space       udev splits RUN arguments on whitespace, so "MY STICK"
#                 hands systemd-mount two arguments and mounts neither.
#   vfat/exfat    no Unix ownership of their own, so they mount root-owned and
#   /ntfs         read-only to everyone else. Readable at the console, not
#                 through Samba, and never writable — which is exactly the
#                 case "copy from the stick" runs into.
#
# A helper reads the device itself rather than being handed a guess, so the
# label never has to survive a round trip through udev's argument splitting.
sudo mkdir -p "$(dirname "$HELPER")"
sudo tee "$HELPER" >/dev/null <<HELPER_BODY
#!/usr/bin/env bash
# Managed by deploy/setup-automount.sh in the PI repo. Edit the repo, not this.
#
# Mount one just-plugged partition under /media, named and owned so that the
# console, Samba and a shell all see the same readable, writable drive.
set -eu

# udev runs this with a minimal environment. Naming the tools by absolute path
# would mean guessing between /sbin and /usr/sbin, which differ across images;
# setting PATH once covers both and keeps the calls below readable.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

[ \$# -eq 1 ] || { echo "usage: \$(basename "\$0") /dev/sdXN" >&2; exit 2; }
dev="\$1"
[ -b "\$dev" ] || exit 0

# One value at a time, quoted into a variable. blkid can emit the lot as shell
# assignments with -o export, and eval'ing that is the obvious shortcut — but a
# label is text written on a disk somebody handed you, and eval would run it.
fstype=\$(blkid -o value -s TYPE "\$dev" 2>/dev/null || true)
label=\$(blkid -o value -s LABEL "\$dev" 2>/dev/null || true)
uuid=\$(blkid -o value -s UUID "\$dev" 2>/dev/null || true)

# A mount point is one path segment. Slashes, control characters and a leading
# dot are the ways a label breaks that — a dot because Finder and ls would then
# hide the drive. Spaces come off first so " .photos" reduces the same as
# ".photos", and a label that is nothing but punctuation reduces to nothing at
# all, which is where the device name takes over: the fallback the note under
# this script has always promised and the rule never had.
name=\$(printf '%s' "\$label" | tr -d '[:cntrl:]' | tr '/' '-' |
  sed 's/^ *//; s/ *\$//; s/^[.-]*//; s/ *\$//')
[ -n "\$name" ] || name=\$(basename "\$dev")

# Two sticks both labelled "USB" would otherwise fight over one directory. The
# second one takes its UUID's first block, which is stable across replugs.
point="${MEDIA}/\$name"
if [ -e "\$point" ] && ! findmnt -no SOURCE "\$point" 2>/dev/null | grep -qx "\$dev"; then
  if mountpoint -q "\$point" 2>/dev/null; then
    name="\$name-\${uuid%%-*}"
    point="${MEDIA}/\$name"
  fi
fi

# Filesystems with no ownership of their own are given it at mount time. Every
# other filesystem carries its own and must not be overridden — forcing uid on
# ext4 would hide the real owners of every file on the disk.
opts="noatime"
case "\$fstype" in
  vfat|msdos)  opts="\$opts,uid=${OWNER_UID},gid=${OWNER_GID},umask=0002,flush,iocharset=utf8,shortname=mixed" ;;
  exfat)       opts="\$opts,uid=${OWNER_UID},gid=${OWNER_GID},umask=0002" ;;
  ntfs|ntfs3)  opts="\$opts,uid=${OWNER_UID},gid=${OWNER_GID},umask=0002,windows_names" ;;
esac

# Removable media mounts for real, at once. --automount=yes would defer it to
# first access, and a deferred mount is invisible to everything that looks
# without opening: the Finder share's mirror of /media, a df, a directory
# listing. A stick you have to poke twice before it appears is the problem
# this script exists to remove.
#
# Fixed disks keep the deferred mount. They are the case --automount was for:
# a sleeping 6TB should not spin up because something indexed a directory.
removable=0
parent=\$(lsblk -no pkname "\$dev" 2>/dev/null | head -1)
[ -n "\$parent" ] && [ -r "/sys/block/\$parent/removable" ] && \\
  read -r removable < "/sys/block/\$parent/removable" || true
if [ "\${ID_BUS:-}" = usb ]; then removable=1; fi

# --fsck=no on both. systemd-mount checks a filesystem before mounting it by
# default, and the check runs in repair mode: an exFAT SSD plugged into pi2
# came back with 352 entries deleted or renamed, without anyone asking (#191).
# A drive plugged in to be read is not written to. A disk that needs checking
# is checked by a person, on purpose.
mkdir -p "\$point"
if [ "\$removable" = 1 ]; then
  exec systemd-mount --no-block --collect --fsck=no -o "\$opts" "\$dev" "\$point"
else
  exec systemd-mount --no-block --automount=yes --collect --fsck=no -o "\$opts" "\$dev" "\$point"
fi
HELPER_BODY
sudo chmod 0755 "$HELPER"

echo "==> Writing $RULE (excluding$self_sources from automount)"
# ENV{ID_FS_USAGE}=="filesystem" skips swap, raid members and empty devices.
sudo tee "$RULE" >/dev/null <<RULE_BODY
# Managed by deploy/setup-automount.sh in the PI repo. Edit the repo, not this.
#
# Hand any newly attached filesystem to ${HELPER}, which names it, gives it an
# owner and mounts it under /media. Removal is by device node rather than by
# path, so a drive still unmounts cleanly when its label is one the helper had
# to change. The partitions this board boots from are excluded by device and
# by PARTUUID — see setup-automount.sh for why trusting fstab did not work.

ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", \\
  ENV{DEVTYPE}=="partition", ENV{ID_BUS}!="", ${self_excludes} \\
  RUN{program}+="${HELPER} \$devnode"

ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", \\
  ENV{DEVTYPE}=="partition", ENV{ID_BUS}!="", \\
  RUN{program}+="/usr/bin/systemd-umount \$devnode"
RULE_BODY

echo "==> Reloading udev"
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block --action=add

# An older version of this rule mounted the board's own partitions under /media,
# and those mounts outlive the rule that made them. Take them down here so a
# re-run leaves the board as intended, without waiting for a reboot. Touching
# the directory first trips systemd's automount into mounting the real
# filesystem, which is the thing findmnt has to see to recognise it.
#
# Two things this got wrong, and both showed up on a real board:
#
#   -T answers for the filesystem CONTAINING a path, not the one mounted at
#   it. An empty leftover directory under /media therefore reported the root
#   filesystem, matched the exclusion list, and the script tried to unmount
#   something that was never mounted — "umount: /media/bootfs: not mounted"
#   under set -e, which ended the run. Whether the path is itself a mount
#   point is the actual question, and mountpoint answers it.
#
#   The unmount was the last command of its branch, so a drive that would not
#   come free killed the run too. This is opportunistic tidying of an old
#   mistake; it should report what it could not do and carry on.
if [ -n "$self_sources" ]; then
  for point in "$MEDIA"/*; do
    [ -d "$point" ] || continue
    ls "$point" >/dev/null 2>&1 || true
    mountpoint -q "$point" 2>/dev/null || continue
    src=$(device_at --mountpoint "$point")
    [ -n "$src" ] || continue
    case " $self_sources " in
      *" $src "*)
        if sudo systemd-umount "$point" 2>/dev/null || sudo umount "$point" 2>/dev/null; then
          sudo rmdir "$point" 2>/dev/null || true
          echo "==> Unmounted $point — it was $src, the operating system"
        else
          echo "  $point is $src, the operating system, and will not unmount." >&2
          echo "  It is excluded from now on; a reboot will clear it." >&2
        fi
        ;;
    esac
  done
fi

echo
echo "==> Mounted under $MEDIA"
if [ -n "$(ls -A "$MEDIA" 2>/dev/null)" ]; then
  for point in "$MEDIA"/*; do
    [ -d "$point" ] || continue
    printf '  %-24s %s\n' "$(basename "$point")" \
      "$(findmnt -no SOURCE,SIZE "$point" 2>/dev/null | grep -m1 '^/dev/' || echo 'not mounted')"
  done
else
  echo "  nothing yet — plug a drive in and it appears here"
fi

cat <<'NOTE'

  A drive without a filesystem label mounts under its device name instead —
  "sda1" rather than "photos" — so label one if you would rather read the name
  than decode it:

      sudo e2label /dev/sdX1 photos          ext4
      sudo exfatlabel /dev/sdX1 photos       exFAT
      sudo fatlabel /dev/sdX1 PHOTOS         FAT32

  Removable drives mount the moment they are plugged in and appear under
  "2) Plugged in" in the share, and as a disk of their own in the console.
  Fixed disks still mount on first access, so a sleeping drive is not spun up
  just because something listed a directory.

  This does not touch the disks the board already had. Those stay in fstab and
  stay where they are.
NOTE
