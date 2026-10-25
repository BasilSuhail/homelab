#!/usr/bin/env bash
# Installs the node agents: Glances (general metrics) + pi-metrics (power, throttle).
# Idempotent. Safe to re-run.
set -euo pipefail

GLANCES_PORT=61208
SHIM_PORT=9101

# How often Glances refreshes everything it collects, in seconds.
#
# This is its background loop, not the request rate: it rebuilds every enabled
# plugin on this timer whether or not anyone is asking. On pi1 that means a
# 189-process list plus a Docker stats call for six containers.
#
# Do not oversell what this saves. Glances costs about 0.4% of one core on pi1,
# measured over a 50 second window against the board's own clock, which agrees
# with the 0.54% recorded in issue #1. The reason to do it is that the work is
# needless, not that the board is drowning in it.
#
# Five rather than the two it used to be. The console polls every three seconds
# and now holds its own answer for 2.5, so nothing downstream can tell the
# difference on the meters, and the collector does 60% less work to feed them.
GLANCES_INTERVAL="${GLANCES_INTERVAL:-5}"

# Plugins the console never reads, and which are not free to collect.
#
# `ip` does an outbound lookup of the public address. `ports` probes hosts on a
# timer. `sensors` enumerates every hwmon node. `programlist` re-aggregates the
# whole process list a second time, on top of the one that is already the most
# expensive thing here. `folders` walks directories. None of it reaches the
# dashboard: temperature comes from the pi-metrics shim reading sysfs directly,
# and disk figures come from `fs`.
#
# What is deliberately kept: cpu, percpu, load, mem, memswap, fs, network,
# system, uptime, processlist, containers, processcount, now.
GLANCES_DISABLED="alert,amps,diskio,folders,gpu,ip,ports,programlist,quicklook,sensors,wifi"

echo "==> Installing Glances"
sudo apt-get update -qq
sudo apt-get install -y glances

# Glances reads the Docker socket through the python docker library. Without
# it the containers plugin returns [] on a box that is running containers.
if command -v docker >/dev/null; then
  echo "==> Docker present — installing python3-docker for container stats"
  sudo apt-get install -y python3-docker
fi

echo "==> Glances as a service on :${GLANCES_PORT}"
# --disable-webui serves the REST API without Glances' own frontend.
write_glances_unit() {
  sudo tee /etc/systemd/system/glances.service >/dev/null <<UNIT
[Unit]
Description=Glances REST API for the fleet dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/glances -w --disable-webui --bind 127.0.0.1 --port ${GLANCES_PORT} -t ${GLANCES_INTERVAL} ${1}
Restart=always
RestartSec=5
MemoryMax=192M

[Install]
WantedBy=multi-user.target
UNIT
}

write_glances_unit "--disable-plugin ${GLANCES_DISABLED}"

# The console reads its own machine over loopback (dashboard/server/lib/dial.ts),
# so Glances has no reason to answer anyone else. It runs as root and lists
# every process.

echo "==> Token shared with the console"
# The shim's file routes need it; the console gets the same value as a k8s
# Secret from deploy/install-dashboard-k8s.sh. Made once and kept: replacing it
# means re-running both installers.
if ! sudo test -s /etc/pi/agent-token; then
  sudo install -d -m 755 /etc/pi
  sudo sh -c 'umask 077 && python3 -c "import secrets; print(\"AGENT_TOKEN=\" + secrets.token_hex(32))" > /etc/pi/agent-token'
  echo "  made /etc/pi/agent-token"
else
  echo "  /etc/pi/agent-token already present — keeping it"
fi

echo "==> Installing pi-metrics shim on :${SHIM_PORT}"
sudo install -m 755 "$(dirname "$0")/pi-metrics.py" /usr/local/bin/pi-metrics.py
sudo install -m 644 "$(dirname "$0")/pi-metrics.service" /etc/systemd/system/pi-metrics.service

# The unit ships with User=nobody so that nothing tracked in the repo names a
# person. The file browser has to read a home directory, which nobody cannot
# enter — it saw empty folders where the actual work is — so the login user is
# dropped in here. Deliberately not root: Docker's internal storage and other
# root-owned state stay unreadable, which is the point of picking this user.
SERVICE_USER="${SERVICE_USER:-$(id -un)}"
SERVICE_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
echo "==> Running the shim as ${SERVICE_USER}"
sudo mkdir -p /etc/systemd/system/pi-metrics.service.d
sudo tee /etc/systemd/system/pi-metrics.service.d/user.conf >/dev/null <<UNIT
[Service]
User=${SERVICE_USER}
Environment="BROWSE_ROOTS=system=/,home=${SERVICE_HOME},1) Archive=/1) Archive"
UNIT

# SATA drives report their temperature through the drivetemp module, which the
# kernel ships but does not load. Loaded now and at every boot; a kernel built
# without it leaves the drives without a temperature, and nothing else changes.
echo "==> Drive temperatures"
if sudo modprobe drivetemp 2>/dev/null; then
  echo drivetemp | sudo tee /etc/modules-load.d/drivetemp.conf >/dev/null
  echo "  drivetemp loaded, and set to load at boot"
else
  echo "  drivetemp is not available on this kernel — drives show no temperature"
fi

# CPU package power comes from the RAPL energy counter, which the kernel makes
# readable by root only (a side-channel fix, CVE-2020-8694). The shim is not
# root, so the counter is opened to every local user: on a box with one login,
# that user is the only one it opens it to. A udev rule rather than a one-off
# chmod, because the file is recreated each time the driver loads.
RAPL=/sys/class/powercap/intel-rapl:0
if [ -e "$RAPL/energy_uj" ]; then
  echo "==> CPU power"
  echo 'ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:0", RUN+="/bin/chmod 0444 /sys%p/energy_uj"' \
    | sudo tee /etc/udev/rules.d/99-pi-rapl.rules >/dev/null
  sudo udevadm control --reload
  sudo udevadm trigger --subsystem-match=powercap --action=add
  echo "  energy counter readable: $(stat -c %A "$RAPL/energy_uj")"
fi

sudo systemctl daemon-reload
sudo systemctl enable glances.service pi-metrics.service

# restart, not "enable --now": the Debian package may already have glances
# running under its own config (XML-RPC, not the REST API). enable --now sees
# it active and leaves the old process in place.
sudo systemctl restart glances.service pi-metrics.service

# The plugin names above are checked against `pluginslist` on a live board, but
# they are still flags this script cannot try before writing them. A version of
# Glances that rejects one would exit immediately, systemd would restart it into
# the same failure, and the board would sit there with no telemetry at all.
#
# So the flag is proved rather than assumed: if the API does not answer, the
# unit is rewritten without the plugin list and restarted. A board that ends up
# here is heavier than intended and says so, which is a great deal better than
# a fleet card that has gone blank.
echo "==> Checking Glances accepted its flags"
glances_answers() {
  for _ in $(seq 1 12); do
    curl -sf -o /dev/null "http://localhost:${GLANCES_PORT}/api/4/now" && return 0
    sleep 1
  done
  return 1
}

if glances_answers; then
  echo "  answering with ${GLANCES_DISABLED//,/ } disabled, refresh ${GLANCES_INTERVAL}s"
else
  echo "  no answer — retrying without --disable-plugin" >&2
  write_glances_unit ""
  sudo systemctl daemon-reload
  sudo systemctl restart glances.service
  if glances_answers; then
    echo "  answering with every plugin enabled. --disable-plugin was refused;" >&2
    echo "  this board is collecting more than it needs to." >&2
  else
    echo "  still no answer. Check: sudo journalctl -u glances -n 40" >&2
  fi
fi

echo
echo "==> Status"
systemctl is-active glances.service pi-metrics.service || true
echo
echo "==> Waiting for agents to bind"
for _ in $(seq 1 10); do
  if ss -tln | grep -qE ":(${GLANCES_PORT}|${SHIM_PORT})\b"; then break; fi
  sleep 1
done
echo
echo "==> Listening"
ss -tln | grep -E ":(${GLANCES_PORT}|${SHIM_PORT})\b" || echo "neither port bound"
echo
echo "==> Probing"
curl -sf "http://localhost:${SHIM_PORT}/metrics" | head -c 400 || echo "shim not answering yet"
echo
curl -sf "http://localhost:${GLANCES_PORT}/api/4/now" || echo "glances not answering yet"
echo
