#!/usr/bin/env bash
# What the PCIe port and the SATA HAT are actually doing on this board.
#
# Reports only. It never edits /boot/firmware/config.txt, and that is the whole
# design: a wrong line there stops a Pi 5 booting, and this board has no
# monitor attached to read the panic on. So it prints the line to add and
# leaves the decision, and the reboot, to a person.
#
# The HAT moved from pi1 to pi2 and has never been checked in its new slot.
# With nothing plugged into it the expected answer is a SATA controller on the
# bus holding no disks — that still proves the port is on and the HAT is seated,
# which is everything worth knowing before a drive and a 12V supply arrive.
set -euo pipefail

CONFIG=/boot/firmware/config.txt
say() { printf '%s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }

section "Board"
if [ -r /proc/device-tree/model ]; then
  # The file is NUL-terminated, which shows up as a stray byte without the tr.
  say "  $(tr -d '\0' </proc/device-tree/model)"
else
  say "  unknown — /proc/device-tree/model is not readable"
fi

section "PCIe port"
# The Pi 5's PCIe port is off unless config.txt turns it on. Everything below
# depends on this, so it is checked before anything is looked for on the bus.
if [ ! -r "$CONFIG" ]; then
  say "  cannot read $CONFIG — is this a Pi?"
  PORT=unknown
elif grep -Eq '^[[:space:]]*dtparam=pciex1([[:space:]]|=|$)' "$CONFIG"; then
  say "  enabled — dtparam=pciex1 is set"
  PORT=on
  if grep -Eq '^[[:space:]]*dtparam=pciex1_gen=3' "$CONFIG"; then
    say "  running at Gen 3, which is faster than the Pi 5 is validated for"
  fi
else
  say "  NOT enabled — nothing on the HAT can appear until it is"
  PORT=off
fi

section "On the bus"
if ! command -v lspci >/dev/null 2>&1; then
  say "  lspci is missing: sudo apt-get install -y pciutils"
elif ! lspci >/dev/null 2>&1; then
  say "  lspci found nothing at all"
else
  # Class 0106 is "SATA controller", which is what the HAT presents however it
  # is branded. Matching the class rather than a vendor string means a HAT with
  # a different chip on it still reports correctly.
  CONTROLLERS=$(lspci -d '::0106' 2>/dev/null || true)
  if [ -n "$CONTROLLERS" ]; then
    say "$CONTROLLERS" | sed 's/^/  /'
  else
    say "  no SATA controller — the HAT is not seated, or the port is off"
    lspci 2>/dev/null | sed 's/^/  (bus) /' || true
  fi
fi

section "Is the controller actually switched on"
# The check that would have saved an hour. A PCIe device can sit on the bus
# with its config space answering perfectly — right vendor, right class, link
# trained, power state D0 — while its COMMAND register reads 0x0000, meaning
# memory decoding and bus mastering are both off. Every MMIO register then
# reads back 0xffffffff, so the AHCI driver sees nothing, no port can detect a
# disk, and a drive that is plainly spinning stays invisible.
#
# That is what a hot-plug transient did here: connecting a powered drive
# glitched the PCIe link, the kernel recovered it, and the controller came back
# unconfigured. Bit 1 is the one that matters. A healthy device reads 0x0406.
for dev in /sys/bus/pci/devices/*; do
  [ -r "$dev/class" ] || continue
  case "$(cat "$dev/class" 2>/dev/null)" in
    0x0106*) ;;
    *) continue ;;
  esac
  cmd=$(od -An -tx2 -j4 -N2 "$dev/config" 2>/dev/null | tr -d ' ')
  say "  $(basename "$dev")  COMMAND=0x${cmd:-????}"
  if [ -n "$cmd" ] && [ $(( 0x$cmd & 2 )) -eq 0 ]; then
    say "    memory decoding is OFF — the driver cannot reach this controller."
    say "    Nothing plugged into it can ever be detected in this state."
    say "    Reboot the board, or as root:"
    say "      echo 1 > $dev/remove && echo 1 > /sys/bus/pci/rescan"
  else
    say "    memory decoding on — the driver can reach it"
  fi
done

section "SATA ports"
# The controller creates one ata_link per port whether or not anything is
# plugged into it, and an empty port reports its speed as <unknown>. So this is
# the line that answers "did the drive come up" — it changes to 3.0 or 6.0 Gbps
# the moment a disk is seen, without anything having to be mounted.
if [ -d /sys/class/ata_link ]; then
  for link in /sys/class/ata_link/link*; do
    [ -e "$link" ] || continue
    spd=$(cat "$link/sata_spd" 2>/dev/null || echo '?')
    case "$spd" in
      "<unknown>"|"") say "  $(basename "$link")  empty" ;;
      *)             say "  $(basename "$link")  $spd" ;;
    esac
  done
else
  say "  no ata_link nodes — the AHCI driver has not bound to anything"
fi

section "Disks"
# -d lists whole devices without their partitions, which is the level a "what
# is attached" question is asked at.
lsblk -d -o NAME,SIZE,TRAN,MODEL 2>/dev/null | sed 's/^/  /' || say "  lsblk failed"

section "What to do"
case "$PORT" in
  off)
    say "  The port is off. Add this line to $CONFIG, then reboot:"
    say
    say "      dtparam=pciex1"
    say
    say "  Back the file up first, and keep a way to read the SD card on the Mac:"
    say "      sudo cp $CONFIG $CONFIG.bak"
    say
    say "  Re-run this afterwards. A controller with no disks is the right answer"
    say "  until something is actually plugged into the HAT."
    ;;
  on)
    say "  Port is on. If a SATA controller is listed above, the HAT is seated"
    say "  and working, and a disk plugged into it will appear under Disks."
    say
    say "  None of this says anything about the 12V supply. The controller is"
    say "  powered from the PCIe connector, so it enumerates perfectly with the"
    say "  barrel jack unplugged. The 12V only ever reaches the drive."
    say "  Test it with a multimeter on a SATA power connector before trusting"
    say "  a disk to it: black probe on a ground pin, red on a 12V pin, expect"
    say "  11.4 to 12.6 V. Check the barrel is centre-positive first."
    ;;
  *)
    say "  Could not determine the port state, so nothing is recommended."
    ;;
esac
