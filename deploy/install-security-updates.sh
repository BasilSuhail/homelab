#!/usr/bin/env bash
# Debian security updates, applied on their own every morning.
#
#   sudo bash deploy/install-security-updates.sh
#
# Security pocket only. Debian 13's default also takes point-release updates
# from the main archive, so the list is cleared and set to security alone.
# Tailscale's own repository is
# left out on purpose, since upgrading it restarts tailscaled and drops every
# tailnet connection. Never reboots: a new kernel waits for a reboot chosen by
# hand, because this machine has no screen.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

cat >/etc/apt/apt.conf.d/52pi-unattended <<'CONF'
// Written by deploy/install-security-updates.sh.
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
CONF

# apt-daily-upgrade.timer already fires at 06:00 plus up to an hour: morning,
# which is where automatic jobs belong here.
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null

unattended-upgrade --dry-run 2>&1 | grep -E "Allowed origins|Packages that will be upgraded|No packages found" || true
systemctl list-timers apt-daily-upgrade.timer --no-pager | sed -n 2p
