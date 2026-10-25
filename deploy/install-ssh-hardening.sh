#!/usr/bin/env bash
# Tightens sshd without touching how anyone logs in today.
#
#   sudo bash deploy/install-ssh-hardening.sh             no root login, no X11
#   sudo bash deploy/install-ssh-hardening.sh --keys-only  and no passwords
#
# --keys-only locks out every device without a key, so run it only once the
# phone has one. Existing sessions survive either way: sshd is reloaded, not
# restarted. Test from a second session before closing this one.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

CONF=/etc/ssh/sshd_config.d/10-pi-hardening.conf

{
  echo "# Written by deploy/install-ssh-hardening.sh. OpenSSH keeps the first"
  echo "# value it reads, so this sorts first among the drop-ins."
  echo "PermitRootLogin no"
  echo "X11Forwarding no"
  echo "MaxAuthTries 3"
  if [ "${1:-}" = "--keys-only" ]; then
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
  fi
} >"$CONF"
chmod 644 "$CONF"

sshd -t
systemctl reload ssh
sshd -T | grep -E '^(permitrootlogin|x11forwarding|maxauthtries|passwordauthentication|kbdinteractiveauthentication) '
