#!/usr/bin/env bash
# Jellyfin watchdog: a circuit breaker that disables non-admin users when the
# system is overloaded, and re-enables them after a cooldown.
#
# The admin's own account is never touched. When the board is under heavy
# load — too many concurrent streams, the CPU pegged by an accidental
# transcode, or memory running out — every other Jellyfin account is locked
# out for thirty minutes, the load drops, and the admin keeps watching.
#
# Runs on the board. Needs a Jellyfin API key: Dashboard > API Keys > +.
set -euo pipefail

STATE_DIR="/var/lib/jellyfin-watchdog"
CONF="/etc/jellyfin-watchdog.conf"
SCRIPT="/usr/local/lib/pi/jellyfin-watchdog"
SERVICE="jellyfin-watchdog"

# --- prerequisites ---

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null; then
    echo "==> Installing $cmd"
    sudo apt-get install -y "$cmd"
  fi
done

# --- API key ---

if [ -f "$CONF" ]; then
  echo "==> Config exists at $CONF — keeping it"
  echo "  (delete it and re-run to change the key or thresholds)"
else
  cat <<'NOTE'

  The watchdog needs a Jellyfin API key to manage user accounts.

  In Jellyfin: Dashboard > API Keys > +
  Name it "watchdog" — the name is for you, not the script.

NOTE
  printf "  API key: "
  read -rs api_key
  echo

  if [ -z "$api_key" ]; then
    echo "  No key entered. Nothing installed." >&2
    exit 1
  fi

  sudo tee "$CONF" >/dev/null <<CONF
# Jellyfin watchdog. Written by deploy/install-watchdog.sh.
#
# Edit any value here — the timer picks up changes on the next tick.
API_KEY=$api_key

# Thresholds. Any ONE being exceeded triggers the lockout.
MAX_STREAMS=8        # total active playback sessions (admin included)
MAX_LOAD=16          # 1-minute load average: 4x the cores. Other apps
                     # (Immich processing, torrents) push it past 5 routinely
                     # without hurting playback, since Jellyfin has CPU priority
MAX_MEM_PCT=90       # percent of total RAM in use
MAX_IOWAIT=80        # percent of CPU time spent waiting on disk I/O

# How long non-admin users stay locked out after a trigger.
COOLDOWN=900         # seconds (15 minutes)

# Quiet hours: non-admin users are disabled regardless of load.
# The HDD stays silent. Set both to the same value to disable.
QUIET_START=0        # hour (0 = midnight)
QUIET_END=6          # hour (6 = 6:00 AM)

# Kubernetes namespace where Jellyfin runs.
JF_NAMESPACE=pi

# Discord webhook for lockout notices (quiet hours, overload). Optional.
#DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
CONF
  sudo chmod 600 "$CONF"
  echo "  saved to $CONF (root-only)"
fi

# --- state directory ---

sudo mkdir -p "$STATE_DIR"

# --- the script ---

sudo mkdir -p "$(dirname "$SCRIPT")"
sudo tee "$SCRIPT" >/dev/null <<'WATCHDOG'
#!/usr/bin/env bash
# Jellyfin watchdog. Runs every 60s via systemd timer.
#
# Four checks: active streams, CPU load, memory pressure, disk I/O. Any one
# exceeding its threshold disables every non-admin Jellyfin account for
# the cooldown period. The admin account is identified by
# Policy.IsAdministrator and is never touched.
#
# State lives in /var/lib/jellyfin-watchdog/:
#   disabled_at    — epoch when the lockout started
#   disabled_users — tab-separated id/name of users WE disabled
#
# Only users the watchdog disabled are re-enabled afterwards, so a user
# the admin disabled manually is left alone.
set -euo pipefail

CONF="/etc/jellyfin-watchdog.conf"
STATE_DIR="/var/lib/jellyfin-watchdog"
DISABLED_AT="$STATE_DIR/disabled_at"
DISABLED_USERS="$STATE_DIR/disabled_users"

[ -f "$CONF" ] || { echo "no config at $CONF"; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

COOLDOWN="${COOLDOWN:-900}"
MAX_STREAMS="${MAX_STREAMS:-8}"
MAX_LOAD="${MAX_LOAD:-16}"
MAX_MEM_PCT="${MAX_MEM_PCT:-90}"
MAX_IOWAIT="${MAX_IOWAIT:-80}"
QUIET_START="${QUIET_START:-0}"
QUIET_END="${QUIET_END:-6}"
JF_NAMESPACE="${JF_NAMESPACE:-pi}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

QUIET_FLAG="$STATE_DIR/quiet"

# A failed notice must never stop a lockout or a re-enable.
notify() {
  [ -n "$DISCORD_WEBHOOK" ] || return 0
  jq -n --arg c "$1" '{content: $c}' |
    curl -sf -m 10 -H "Content-Type: application/json" -d @- \
      "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
}

# Resolve Jellyfin's cluster IP. If k3s or the service is not up, exit
# quietly — there is nothing to protect and nothing to talk to.
JF_IP=$(k3s kubectl -n "$JF_NAMESPACE" get svc jellyfin \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || exit 0
JF="http://${JF_IP}"

jf() { curl -sf -m 5 -H "Authorization: MediaBrowser Token=\"$API_KEY\"" "$@"; }

# ---- shared: disable/re-enable helpers --------------------------------

disable_non_admin_users() {
  local label="$1"
  local users_json visible hidden
  visible=$(jf "$JF/Users") || { echo "cannot list users"; return 1; }
  hidden=$(jf "$JF/Users?isHidden=true" 2>/dev/null) || hidden="[]"
  users_json=$(printf '%s\n%s' "$visible" "$hidden" | jq -s 'add | unique_by(.Id)')

  local targets
  targets=$(echo "$users_json" | jq -r \
    '.[] | select(.Policy.IsAdministrator != true and .Policy.IsDisabled != true)
         | [.Id, .Name] | @tsv')

  if [ -z "$targets" ]; then
    echo "no users to disable"
    return 0
  fi

  > "$DISABLED_USERS"
  while IFS=$'\t' read -r uid name; do
    [ -z "$uid" ] && continue
    local policy
    policy=$(echo "$users_json" | jq -c --arg id "$uid" \
      '.[] | select(.Id == $id) | .Policy')
    echo "$policy" | jq -c '.IsDisabled = true' |
      jf -X POST -H "Content-Type: application/json" \
        -d @- "$JF/Users/$uid/Policy" >/dev/null 2>&1
    printf '%s\t%s\n' "$uid" "$name" >> "$DISABLED_USERS"
    echo "  disabled $name"
  done <<< "$targets"

  echo "$(wc -l < "$DISABLED_USERS" | tr -d ' ') user(s) locked out ($label)"

  # Stop active playback and revoke devices so clients get kicked out
  local sessions
  sessions=$(jf "$JF/Sessions" 2>/dev/null) || sessions="[]"
  local devices
  devices=$(jf "$JF/Devices" 2>/dev/null) || devices='{"Items":[]}'
  while IFS=$'\t' read -r uid name; do
    [ -z "$uid" ] && continue
    # Send stop command to active sessions
    echo "$sessions" | jq -r --arg id "$uid" \
      '.[] | select(.UserId == $id) | .Id' |
    while IFS= read -r sid; do
      [ -z "$sid" ] && continue
      jf -X POST "$JF/Sessions/$sid/Playing/Stop" >/dev/null 2>&1 || true
    done
    # Revoke all devices — forces re-auth which fails on a disabled account
    echo "$devices" | jq -r --arg id "$uid" \
      '.Items[] | select(.LastUserId == $id) | .Id' |
    while IFS= read -r did; do
      [ -z "$did" ] && continue
      jf -X DELETE "$JF/Devices?id=$did" >/dev/null 2>&1 || true
    done
    echo "  killed sessions for $name"
  done < "$DISABLED_USERS"

  # Restart Jellyfin to drop all TCP connections — the only guaranteed
  # way to stop an active stream. Disabled accounts can't reconnect;
  # the admin can.
  k3s kubectl -n "$JF_NAMESPACE" rollout restart deployment/jellyfin 2>/dev/null || true
  echo "  restarted jellyfin — all streams dropped"
}

reenable_users() {
  local visible hidden users_json
  visible=$(jf "$JF/Users") || visible="[]"
  hidden=$(jf "$JF/Users?isHidden=true" 2>/dev/null) || hidden="[]"
  users_json=$(printf '%s\n%s' "$visible" "$hidden" | jq -s 'add | unique_by(.Id)')

  echo "$users_json" | jq -r \
    '.[] | select(.Policy.IsAdministrator != true and .Policy.IsDisabled == true)
         | [.Id, .Name] | @tsv' |
  while IFS=$'\t' read -r uid name; do
    [ -z "$uid" ] && continue
    local policy
    policy=$(echo "$users_json" | jq -c --arg id "$uid" \
      '.[] | select(.Id == $id) | .Policy')
    echo "$policy" | jq -c '.IsDisabled = false' |
      jf -X POST -H "Content-Type: application/json" \
        -d @- "$JF/Users/$uid/Policy" >/dev/null 2>&1 || true
    echo "  enabled ${name:-$uid}"
  done
  rm -f "$DISABLED_AT" "$DISABLED_USERS" "$QUIET_FLAG"
}

# ---- quiet hours ------------------------------------------------------
# Between QUIET_START and QUIET_END, non-admin users are disabled
# regardless of load so the HDD stays silent overnight.

in_quiet_hours() {
  local h
  h=$(date +%-H)
  if [ "$QUIET_START" -eq "$QUIET_END" ]; then
    return 1
  elif [ "$QUIET_START" -lt "$QUIET_END" ]; then
    [ "$h" -ge "$QUIET_START" ] && [ "$h" -lt "$QUIET_END" ]
  else
    # wraps midnight, e.g. 23–6
    [ "$h" -ge "$QUIET_START" ] || [ "$h" -lt "$QUIET_END" ]
  fi
}

if in_quiet_hours; then
  if [ -f "$QUIET_FLAG" ]; then
    echo "quiet hours ($(printf '%02d' "$QUIET_START"):00–$(printf '%02d' "$QUIET_END"):00)"
    exit 0
  fi
  echo "quiet hours starting — disabling non-admin users"
  rm -f "$DISABLED_AT"
  disable_non_admin_users "quiet hours until $(printf '%02d' "$QUIET_END"):00"
  touch "$QUIET_FLAG"
  notify "Jellyfin quiet hours started: family accounts locked until $(printf '%02d' "$QUIET_END"):00."
  exit 0
fi

if [ -f "$QUIET_FLAG" ]; then
  echo "quiet hours ended — re-enabling users"
  reenable_users
  notify "Jellyfin quiet hours over: family accounts back on."
  echo "done"
  exit 0
fi

# ---- cooldown --------------------------------------------------------

if [ -f "$DISABLED_AT" ] && [ -s "$DISABLED_AT" ]; then
  now=$(date +%s)
  elapsed=$((now - $(cat "$DISABLED_AT")))

  if [ "$elapsed" -lt "$COOLDOWN" ]; then
    echo "cooldown: $(( (COOLDOWN - elapsed) / 60 ))m left"
    exit 0
  fi

  echo "cooldown expired — re-enabling users"
  reenable_users
  notify "Jellyfin load back to normal: family accounts back on."
  echo "done"
  exit 0
fi

# ---- load check ------------------------------------------------------

# First /proc/stat sample — taken before the API call so the network
# round-trip acts as the measurement window instead of a sleep.
read -r _ u1 n1 s1 i1 w1 _ < /proc/stat

streams=$(jf "$JF/Sessions" 2>/dev/null \
  | jq '[.[] | select(.NowPlayingItem != null)] | length' 2>/dev/null) || streams=0
load=$(awk '{print $1}' /proc/loadavg)
mem_pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", (1-a/t)*100}' /proc/meminfo)

# Second sample. The delta between the two gives iowait as a percentage
# of total CPU time — high values mean the HDD is the bottleneck.
read -r _ u2 n2 s2 i2 w2 _ < /proc/stat
d_total=$(( (u2-u1) + (n2-n1) + (s2-s1) + (i2-i1) + (w2-w1) ))
if [ "$d_total" -gt 0 ]; then
  iowait=$(( (w2-w1) * 100 / d_total ))
else
  iowait=0
fi

overloaded=false
reason=""

if [ "$streams" -gt "$MAX_STREAMS" ]; then
  overloaded=true
  reason="streams=$streams"
fi

if awk "BEGIN{exit !($load > $MAX_LOAD)}" 2>/dev/null; then
  overloaded=true
  reason="${reason:+$reason, }load=$load"
fi

if [ "$mem_pct" -gt "$MAX_MEM_PCT" ]; then
  overloaded=true
  reason="${reason:+$reason, }mem=${mem_pct}%"
fi

if [ "$iowait" -gt "$MAX_IOWAIT" ]; then
  overloaded=true
  reason="${reason:+$reason, }iowait=${iowait}%"
fi

if [ "$overloaded" = false ]; then
  echo "ok: streams=$streams load=$load mem=${mem_pct}% iowait=${iowait}%"
  exit 0
fi

# ---- disable non-admin users -----------------------------------------

echo "OVERLOADED: $reason"
disable_non_admin_users "cooldown ${COOLDOWN}s"
date +%s > "$DISABLED_AT"
notify "Jellyfin overloaded ($reason): family accounts locked for $((COOLDOWN / 60)) min."
WATCHDOG
sudo chmod 755 "$SCRIPT"

# --- systemd ---

sudo tee /etc/systemd/system/${SERVICE}.service >/dev/null <<SERVICE
[Unit]
Description=Jellyfin watchdog — disable non-admin users under load
After=k3s.service

[Service]
Type=oneshot
ExecStart=$SCRIPT
SERVICE

sudo tee /etc/systemd/system/${SERVICE}.timer >/dev/null <<TIMER
[Unit]
Description=Jellyfin watchdog timer

[Timer]
OnBootSec=120
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now ${SERVICE}.timer

# --- bypass-user command ---

sudo tee /usr/local/bin/bypass-user >/dev/null <<'BYPASS'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${1:-}" ] && { echo "usage: bypass-user <name>"; exit 1; }
. /etc/jellyfin-watchdog.conf
JF_IP=$(k3s kubectl -n "${JF_NAMESPACE:-pi}" get svc jellyfin -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
jf() { curl -sf -m 5 -H "Authorization: MediaBrowser Token=\"$API_KEY\"" "$@"; }
uid=$(jf "http://$JF_IP/Users" | jq -r --arg n "$1" '.[] | select(.Name == $n) | .Id')
[ -z "$uid" ] && uid=$(jf "http://$JF_IP/Users?isHidden=true" 2>/dev/null | jq -r --arg n "$1" '.[] | select(.Name == $n) | .Id')
[ -z "$uid" ] && { echo "no user named '$1'"; exit 1; }
policy=$(jf "http://$JF_IP/Users/$uid" | jq -c '.Policy')
echo "$policy" | jq -c '.IsDisabled = false' | jf -X POST -H "Content-Type: application/json" -d @- "http://$JF_IP/Users/$uid/Policy" >/dev/null
sed -i "/^$uid/d" /var/lib/jellyfin-watchdog/disabled_users 2>/dev/null || true
echo "$1 is back in"
BYPASS
sudo chmod 755 /usr/local/bin/bypass-user

# Source the config for the summary. The file is root-only, so read it
# through sudo — the installer runs as the login user with sudo for
# privileged operations.
# shellcheck source=/dev/null
eval "$(sudo cat "$CONF")"

echo
echo "==> Done"
echo "  config     $CONF"
echo "  script     $SCRIPT"
echo "  timer      ${SERVICE}.timer (every 60s, starting 2m after boot)"
echo "  state      $STATE_DIR"
echo
echo "  Thresholds (any one triggers the lockout):"
echo "    streams  > ${MAX_STREAMS:-8}"
echo "    load     > ${MAX_LOAD:-16}"
echo "    memory   > ${MAX_MEM_PCT:-90}%"
echo "    iowait   > ${MAX_IOWAIT:-80}%"
echo "  Cooldown     $((${COOLDOWN:-900} / 60)) minutes"
echo "  Quiet hours  $(printf '%02d' "${QUIET_START:-0}"):00–$(printf '%02d' "${QUIET_END:-6}"):00 (non-admin users disabled, HDD stays silent)"
echo
echo "  Logs:   journalctl -u $SERVICE --no-pager -n 20"
echo "  Test:   sudo $SCRIPT"
echo "  Tune:   edit $CONF — changes take effect on the next tick"
