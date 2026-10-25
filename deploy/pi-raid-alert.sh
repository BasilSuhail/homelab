#!/usr/bin/env bash
# Posts to Discord when an SSD drops out of homelab's mirror. Installed as
# /usr/local/bin/pi-raid-alert by deploy/ssd-mirror.sh.
#
#   pi-raid-alert EVENT /dev/mdX [/dev/sdXN]   mdadm's monitor (PROGRAM in mdadm.conf)
#   pi-raid-alert --boot                       pi-raid-check.service, once per boot
#
# A disk lost is loud (@everyone): the machine still runs, but on one disk with
# no second copy. A rebuild finishing is a plain message. Webhook:
# DISCORD_WEBHOOK in /etc/pi-report/env, the same one the daily report uses.
set -uo pipefail

ENV=/etc/pi-report/env
RUN=/run/pi-raid-alert
HOOK=$(sed -n 's/^DISCORD_WEBHOOK=//p' "$ENV" 2>/dev/null | head -1)
REPO="~/PI"

name_of() { mdadm --detail "$1" 2>/dev/null | sed -n 's/^ *Name : \([^ ]*:\)\{0,1\}\([^ ]*\).*/\2/p'; }
mount_of() { findmnt -nfo TARGET "$1" 2>/dev/null || echo "?"; }
disk_desc() { # partition -> "Samsung SSD 860 EVO 250GB 232.9G (sde)"
  local d; d=$(lsblk -dno PKNAME "$1" 2>/dev/null | head -1); d=${d:-$(basename "$1")}
  echo "$(lsblk -dno MODEL,SIZE "/dev/$d" 2>/dev/null | xargs) ($d)"
}
survivors() {
  mdadm --detail "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && /active sync/ { print $NF }' |
    while read -r p; do disk_desc "$p"; done | sort -u | paste -sd, - | sed 's/,/, /g'
}
recovering() { grep -Eq 'recover|resync' "/sys/block/$(basename "$(readlink -f "$1")")/md/sync_action" 2>/dev/null; }

post() { # text, loud (1/0)
  local text=$1 loud=$2 body
  [ -n "$HOOK" ] || { echo "pi-raid-alert: no DISCORD_WEBHOOK in $ENV; not posted" >&2; return 0; }
  body=$(LOUD=$loud TEXT=$text python3 -c '
import json, os
loud = os.environ["LOUD"] == "1"
text = ("@everyone " if loud else "") + os.environ["TEXT"]
print(json.dumps({"content": text[:1990],
                  "allowed_mentions": {"parse": ["everyone"] if loud else []}}))')
  # Retried in the background for five minutes: at boot the network may not
  # be up yet, and mdadm should not wait on Discord.
  setsid -f bash -c '
    for i in $(seq 30); do
      curl -sf -m 10 -H "Content-Type: application/json" -d "$1" "$2" >/dev/null && exit 0
      sleep 10
    done' _ "$body" "$HOOK" >/dev/null 2>&1
}

# One post per event and array per ten minutes: mdadm and the boot check can
# both see the same degraded array.
fresh() {
  mkdir -p "$RUN"
  [ -n "$(find "$RUN/quiet" -mmin -10 2>/dev/null)" ] && return 1
  local stamp="$RUN/$1"
  [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ] && return 1
  touch "$stamp"
}

lost() { # md, component (may be empty)
  local md=$1 part=${2:-} what
  what="SSD dropped out"
  [ -n "$part" ] && what="SSD dropped out: $(disk_desc "$part")"
  post "🚨 **homelab: $what**
Mirror **$(name_of "$md")** ($(mount_of "$md")) is down to one disk.
Still running on: $(survivors "$md")
Nothing has stopped, but there is no second copy until the disk is replaced.
Check: \`sudo bash $REPO/deploy/ssd-mirror.sh status\`
Replace: new SSD in, then \`sudo bash $REPO/deploy/ssd-mirror.sh add /dev/sdX --backup\`" 1
}

if [ "${1:-}" = --boot ]; then
  for md in /dev/md[0-9]*; do
    [ -b "$md" ] || continue
    deg=$(cat "/sys/block/$(basename "$md")/md/degraded" 2>/dev/null || echo 0)
    [ "$deg" -gt 0 ] || continue
    recovering "$md" && continue
    fresh "DegradedArray-$(basename "$md")" || continue
    post "🚨 **homelab booted with only one SSD**
Mirror **$(name_of "$md")** ($(mount_of "$md")) has $deg disk missing.
Running on: $(survivors "$md")
Check: \`sudo bash $REPO/deploy/ssd-mirror.sh status\`" 1
  done
  exit 0
fi

EVENT=${1:-} MD=${2:-} PART=${3:-}
case "$EVENT" in
  Fail|FailSpare)
    fresh "$EVENT-$(basename "$MD")" && lost "$MD" "$PART" ;;
  DeviceDisappeared)
    # The monitor reports this on every restart for names like /dev/md/md127
    # that udev never made; the array is still there as /dev/md127.
    [ -b "/dev/$(basename "$MD")" ] || { fresh "$EVENT-$(basename "$MD")" && lost "$MD" ""; } ;;
  DegradedArray)
    # Expected while a newly added disk copies in.
    recovering "$MD" || { fresh "$EVENT-$(basename "$MD")" && lost "$MD" ""; } ;;
  RebuildFinished)
    if [ "$(cat "/sys/block/$(basename "$(readlink -f "$MD")")/md/degraded" 2>/dev/null || echo 1)" = 0 ]; then
      post "✅ homelab: mirror **$(name_of "$MD")** ($(mount_of "$MD")) is complete, both SSDs in sync." 0
    fi ;;
  TestMessage)
    post "homelab SSD mirror alerts are on. **$(name_of "$MD")** is on: $(survivors "$MD")" 0 ;;
esac
exit 0
