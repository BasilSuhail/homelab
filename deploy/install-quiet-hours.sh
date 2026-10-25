#!/usr/bin/env bash
# Quiet hours: reschedule system maintenance out of midnight–6 AM, pause
# Immich's background jobs for those hours (the app stays up). Torrents are
# not touched: an overnight seeding limit also strangled downloads, because a
# download's own requests count against the upload limit.
#
# The apps have their own scheduling (Jellyfin's Scheduled Tasks, Immich's
# job settings) and those are configured in their own dashboards. This
# script handles the OS-level timers that the apps cannot see: apt updates,
# man-db rebuilds, and fstrim. All three default to times that regularly
# land in the middle of the night.
#
# Drop-in overrides rather than editing the packaged unit files, so an apt
# upgrade does not undo the change.
set -euo pipefail

echo "==> Rescheduling system maintenance to daytime"

for timer in apt-daily apt-daily-upgrade; do
  if systemctl list-unit-files "${timer}.timer" --no-pager --no-legend \
     2>/dev/null | grep -q .; then
    override="/etc/systemd/system/${timer}.timer.d"
    sudo mkdir -p "$override"
    sudo tee "$override/quiet-hours.conf" >/dev/null <<TIMERCONF
# Managed by deploy/install-quiet-hours.sh. Keep maintenance out of midnight–6 AM.
[Timer]
OnCalendar=
OnCalendar=*-*-* 07:00:00
RandomizedDelaySec=2h
TIMERCONF
    echo "  $timer → 07:00 ± 2h"
  fi
done

if systemctl list-unit-files man-db.timer --no-pager --no-legend \
   2>/dev/null | grep -q .; then
  override="/etc/systemd/system/man-db.timer.d"
  sudo mkdir -p "$override"
  sudo tee "$override/quiet-hours.conf" >/dev/null <<'TIMERCONF'
[Timer]
OnCalendar=
OnCalendar=Sun *-*-* 10:00:00
RandomizedDelaySec=2h
TIMERCONF
  echo "  man-db → Sunday 10:00 ± 2h"
fi

if systemctl list-unit-files fstrim.timer --no-pager --no-legend \
   2>/dev/null | grep -q .; then
  override="/etc/systemd/system/fstrim.timer.d"
  sudo mkdir -p "$override"
  sudo tee "$override/quiet-hours.conf" >/dev/null <<'TIMERCONF'
[Timer]
OnCalendar=
OnCalendar=Mon *-*-* 08:00:00
TIMERCONF
  echo "  fstrim → Monday 08:00"
fi

# Three more that Debian schedules around midnight and that the first version
# missed: a backup of the package database, log rotation, and the weekly ext4
# metadata check. Each is small, but "nothing automatic at night" means none.
for spec in "dpkg-db-backup|*-*-* 07:30:00|07:30" \
            "logrotate|*-*-* 07:30:00|07:30" \
            "e2scrub_all|Sun *-*-* 10:30:00|Sunday 10:30"; do
  IFS='|' read -r timer when label <<<"$spec"
  if systemctl list-unit-files "${timer}.timer" --no-pager --no-legend \
     2>/dev/null | grep -q .; then
    override="/etc/systemd/system/${timer}.timer.d"
    sudo mkdir -p "$override"
    printf '[Timer]\nOnCalendar=\nOnCalendar=%s\n' "$when" \
      | sudo tee "$override/quiet-hours.conf" >/dev/null
    echo "  $timer → $label"
  fi
done

# Two that are not on a clock at all, so moving OnCalendar is not enough.
# systemd-tmpfiles-clean runs a day after it last ran, and drifts to whatever
# hour the machine booted; fwupd-refresh adds a random delay of up to twelve
# hours. Each gets a fixed morning time and loses its relative schedule.
for spec in "systemd-tmpfiles-clean|07:30" "fwupd-refresh|10:00"; do
  IFS='|' read -r timer at <<<"$spec"
  if systemctl list-unit-files "${timer}.timer" --no-pager --no-legend \
     2>/dev/null | grep -q .; then
    override="/etc/systemd/system/${timer}.timer.d"
    sudo mkdir -p "$override"
    printf '[Timer]\nOnBootSec=\nOnUnitActiveSec=\nRandomizedDelaySec=0\nOnCalendar=\nOnCalendar=*-*-* %s:00\n' "$at" \
      | sudo tee "$override/quiet-hours.conf" >/dev/null
    echo "  $timer → $at"
  fi
done

sudo systemctl daemon-reload

# Clean up the old version's systemd units if they exist.
if systemctl list-unit-files pi-quiet-start.timer --no-pager --no-legend \
   2>/dev/null | grep -q .; then
  echo "==> Removing old quiet-hours timers"
  sudo systemctl disable --now pi-quiet-start.timer pi-quiet-end.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/pi-quiet-start.service \
             /etc/systemd/system/pi-quiet-start.timer \
             /etc/systemd/system/pi-quiet-end.service \
             /etc/systemd/system/pi-quiet-end.timer
  sudo rm -f /usr/local/lib/pi/quiet-hours
  sudo systemctl daemon-reload
fi

# Immich quiet overnight: no background jobs (thumbnails, transcodes, ML
# indexing, library scans, database dumps) and no phone uploads. The app itself
# stays up for browsing, and the queued work resumes at six. This goes through
# the API, so it needs a key; without one this part is skipped.
# The Immich pause stops every user uploading from midnight to six, so it is
# opt-in: the services are meant to be usable all night, and only background
# work moves to the morning. Ask for it with IMMICH_QUIET=1.
immich_quiet=false
if [ "${IMMICH_QUIET:-0}" != 1 ]; then
  echo "==> Immich uploads stay open all night (IMMICH_QUIET=1 to pause them)"
elif sudo k3s kubectl -n pi get deploy immich-server >/dev/null 2>&1; then
  if ! sudo test -s /etc/immich-api.key; then
    echo "==> Immich: no API key at /etc/immich-api.key — overnight pause skipped"
    echo "    Create one in Immich (Settings > API Keys), then:"
    echo "    sudo bash -c 'read -rsp \"key: \" k && echo \"\$k\" > /etc/immich-api.key && chmod 600 /etc/immich-api.key'"
  else
    echo "==> Immich jobs and uploads paused 00:00–06:00"
    sudo mkdir -p /usr/local/lib/pi
    sudo tee /usr/local/lib/pi/immich-quiet >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
# Managed by deploy/install-quiet-hours.sh.
# Pauses Immich's job queues and blocks uploads midnight–6 AM, and undoes
# both after. The app stays up for browsing. With no argument it decides from
# the clock, so a board that was off at midnight or six still lands in the
# right state; pass pause or resume to force one.
set -euo pipefail
QUIET_START=0
QUIET_END=6
KEY_FILE="${IMMICH_KEY_FILE:-/etc/immich-api.key}"
STATE="${IMMICH_QUIET_STATE:-/var/lib/immich-quiet/quotas.json}"

action="${1:-}"
if [ -z "$action" ]; then
  hour=$(date +%-H)
  if [ "$hour" -ge "$QUIET_START" ] && [ "$hour" -lt "$QUIET_END" ]; then
    action=pause
  else
    action=resume
  fi
fi
[ "$action" = pause ] && want=true || want=false

ip=$(k3s kubectl -n pi get svc immich -o jsonpath='{.spec.clusterIP}')
key=$(cat "$KEY_FILE")
api() { curl -sf -m 10 -H "x-api-key: $key" -H "Content-Type: application/json" "$@"; }
failed=0

# Uploads: each quota drops to what the user already stores, so any new upload
# is refused while browsing still works. The real quotas are saved only when no
# saved copy exists — a retry in the night must never save the lowered values
# over them, or they would come back at six as the new limits.
users=$(api "http://$ip/api/admin/users") || { echo "immich did not list its users"; exit 1; }
if [ "$action" = pause ]; then
  if [ ! -s "$STATE" ]; then
    mkdir -p "$(dirname "$STATE")"
    jq '[.[] | {id, quotaSizeInBytes}]' <<<"$users" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
  fi
  targets=$(jq -c '.[] | {id, q: (.quotaUsageInBytes // 0)}' <<<"$users")
elif [ -s "$STATE" ]; then
  targets=$(jq -c '.[] | {id, q: .quotaSizeInBytes}' "$STATE")
else
  targets=""
fi
while IFS= read -r t; do
  [ -n "$t" ] || continue
  id=$(jq -r .id <<<"$t")
  q=$(jq -c .q <<<"$t")
  got=$(api -X PUT -d "{\"quotaSizeInBytes\":$q}" "http://$ip/api/admin/users/$id" \
    | jq -c .quotaSizeInBytes) || got=error
  [ "$got" = "$q" ] || { echo "  user $id: expected quota $q, got $got"; failed=1; }
done <<<"$targets"
if [ "$action" = resume ] && [ "$failed" = 0 ]; then
  rm -f "$STATE"
fi

# Background jobs.
queues=$(api "http://$ip/api/jobs" | jq -r 'keys[]') || queues=""
[ -n "$queues" ] || { echo "immich did not list its job queues"; exit 1; }
for q in $queues; do
  got=$(api -X PUT -d "{\"command\":\"$action\",\"force\":false}" \
    "http://$ip/api/jobs/$q" | jq -r '.queueStatus.isPaused') || got=error
  [ "$got" = "$want" ] || { echo "  $q: expected isPaused=$want, got $got"; failed=1; }
done

echo "immich uploads and job queues: $action"
exit "$failed"
SCRIPT
    sudo chmod 755 /usr/local/lib/pi/immich-quiet

    # Restart=on-failure retries every five minutes while Immich is
    # unreachable; each retry re-reads the clock, so a pause that could not
    # land before six becomes a resume instead.
    sudo tee /etc/systemd/system/immich-quiet.service >/dev/null <<'UNIT'
[Unit]
Description=Pause Immich background jobs midnight–6 AM
After=k3s.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/lib/pi/immich-quiet
Restart=on-failure
RestartSec=5min
UNIT

    sudo tee /etc/systemd/system/immich-quiet.timer >/dev/null <<'UNIT'
[Unit]
Description=Pause Immich background jobs midnight–6 AM

[Timer]
OnCalendar=*-*-* 00:00:00
OnCalendar=*-*-* 06:00:00
OnBootSec=3min

[Install]
WantedBy=timers.target
UNIT

    sudo systemctl daemon-reload
    sudo systemctl enable --now immich-quiet.timer
    sudo systemctl start immich-quiet.service || true
    immich_quiet=true
  fi
fi

# Torrents are not part of quiet hours. Earlier versions of this script put an
# overnight limit into qBittorrent's own scheduler, which outlives the script,
# so it is switched off here, along with the slow mode if it is on right now.
# Sent to the Service's cluster IP from the board, the route the WebUI lets in
# without a login (see install-torrent.sh).
torrent_quiet="not part of quiet hours"
if sudo k3s kubectl -n pi get deploy qbittorrent >/dev/null 2>&1; then
  QIP=$(sudo k3s kubectl -n pi get svc qbittorrent -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  qb() { curl -sf -m 10 "$@"; }
  qb -X POST "http://$QIP/api/v2/app/setPreferences" \
     --data-urlencode 'json={"scheduler_enabled":false}' >/dev/null 2>&1 || true
  [ "$(qb "http://$QIP/api/v2/transfer/speedLimitsMode" 2>/dev/null || true)" = 1 ] &&
    { qb -X POST "http://$QIP/api/v2/transfer/toggleSpeedLimitsMode" >/dev/null 2>&1 || true; }
  sched=$(qb "http://$QIP/api/v2/app/preferences" 2>/dev/null | jq -r '.scheduler_enabled' 2>/dev/null || true)
  mode=$(qb "http://$QIP/api/v2/transfer/speedLimitsMode" 2>/dev/null || true)
  if [ "$sched" = false ] && [ "$mode" = 0 ]; then
    torrent_quiet="no limits day or night (old overnight schedule off)"
  else
    torrent_quiet="could not confirm the old overnight schedule is off (is qBittorrent running?). Re-run 'make quiet' while it is"
  fi
fi

echo
echo "==> Done"
echo "  apt-daily            07:00 ± 2h"
echo "  apt-daily-upgrade    07:00 ± 2h"
echo "  man-db               Sunday 10:00 ± 2h"
echo "  fstrim               Monday 08:00"
echo "  dpkg-db-backup       07:30"
echo "  logrotate            07:30"
echo "  e2scrub_all          Sunday 10:30"
echo "  tmpfiles-clean       07:30"
echo "  fwupd-refresh        10:00"
echo "  torrents             $torrent_quiet"
if [ "$immich_quiet" = true ]; then
  echo "  immich               jobs + uploads paused 00:00–06:00 (app stays up)"
fi
echo
echo "  The heavy app jobs (library scans, ML indexing) are configured"
echo "  inside each app's own dashboard, not here:"
echo "    Jellyfin   Dashboard > Scheduled Tasks > Scan Media Library"
echo "    Immich     Administration > Settings > Job Settings"
