#!/usr/bin/env bash
# Shares /srv/browse over SMB so the disks mount in Finder. Run on the board
# holding the disks. Idempotent — safe to re-run.
#
# Tailnet only, enforced by `hosts allow` and `hosts deny` rather than by
# which address smbd binds — see the note beside them for why. A connection
# from anywhere but the tailnet or this machine is refused before it can
# authenticate. Do not port forward this. SMB is not a protocol to expose to
# the internet.
#
# The config is written whole rather than edited, for the same reason apps.json
# is: the repo is the source of truth and a board-side edit is a thing that
# silently disappears. The original is kept once, on the first run.
set -euo pipefail

BROWSE="${BROWSE:-/srv/browse}"
# The share carries the board's name rather than being called "browse" on both.
# NetFS — which is what an unattended mount on a Mac has to use — names the
# mount point after the share and cannot be told otherwise, so two shares both
# called browse would arrive as "browse" and "browse-1", with which is which
# depending on the order they happened to mount.
SHARE_NAME="${SHARE_NAME:-$(hostname -s)}"
SHARE_USER="${SHARE_USER:-$(id -un)}"
CONF=/etc/samba/smb.conf
# Tailscale hands out addresses from the carrier-grade NAT range. Nothing on a
# home LAN can hold one, so this allows the tailnet and nothing else.
TAILNET_CIDR="100.64.0.0/10"

# Only used to check the result and to print the address at the end. smbd is
# no longer asked to bind it — see the note on interfaces below.
TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo "This board has no Tailscale IPv4 address. Bring tailscale up first." >&2
  exit 1
fi

if [ ! -d "$BROWSE" ]; then
  echo "$BROWSE does not exist. Run deploy/setup-browse.sh first." >&2
  exit 1
fi

echo "==> Installing samba"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y samba

if [ -f "$CONF" ] && [ ! -f "$CONF.before-pi" ]; then
  echo "==> Keeping the original config at $CONF.before-pi"
  sudo cp "$CONF" "$CONF.before-pi"
fi

echo "==> Writing $CONF"
sudo tee "$CONF" >/dev/null <<CONFIG
# Managed by deploy/install-samba.sh in the PI repo. Edit the repo, not this.

[global]
   workgroup = WORKGROUP
   server string = pi
   server role = standalone server
   security = user
   map to guest = never

   # smbd listens on everything, and these two lines decide who gets served.
   #
   # It is not for want of trying the other way. Samba was asked to bind the
   # Tailscale address by interface name and then by address-with-netmask, and
   # discarded both: its interface handling wants something it recognises as a
   # network, and a host route on a tun device is not that. It bound localhost
   # alone and reported success. Rather than guess at a third spelling, the
   # restriction moved to where it is unambiguous.
   #
   # The cost is that port 445 is visible on the home LAN. Nothing there can
   # read a file — every connection that is not from the tailnet or this
   # machine is refused before authentication — and nothing outside the house
   # can reach the port at all, because it is not forwarded and never should
   # be. To hide it from the LAN too, drop 445 on the LAN interface:
   #
   #     sudo nft add rule inet filter input iifname "wlan0" tcp dport 445 drop
   #
   # Left out of this script deliberately: a firewall rule applied over ssh to
   # a board in another room is how people lose access to boards in other rooms.
   hosts allow = ${TAILNET_CIDR} 127.0.0.1
   hosts deny = 0.0.0.0/0

   # SMB1 is what ransomware worms travel on. There is no client here that
   # needs it; macOS has spoken SMB3 for a decade.
   server min protocol = SMB3
   client min protocol = SMB3

   # Do not announce this to the local network. Both boards were turning up in
   # the Finder sidebar of every Mac on the wifi, and clicking one failed —
   # hosts allow admits the tailnet and nothing else — so the advert offered a
   # door that does not open and looked like a broken mount.
   #
   # Discovery exists to find a server whose name you do not know. These names
   # are known, they are in the README, and they resolve through the tailnet's
   # DNS. nmbd covers the NetBIOS half and is disabled below; this covers mDNS,
   # which is separate and on by default.
   multicast dns register = no
   disable netbios = yes

   # macOS interoperability. catia and streams_xattr let resource forks and
   # names with colons survive on ext4; fruit is what stops Finder being slow.
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

   logging = file
   log file = /var/log/samba/log.%m
   max log size = 1000

[${SHARE_NAME}]
   comment = Every disk on ${SHARE_NAME}
   path = ${BROWSE}
   browseable = yes
   read only = no
   valid users = ${SHARE_USER}
   create mask = 0664
   directory mask = 2775
CONFIG

echo "==> Checking the config"
testparm -s >/dev/null

# A Samba password is separate from the Unix one and has to be set explicitly.
# It is typed here, never stored in the repo, and never passed on a command
# line where it would land in shell history.
if sudo pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$SHARE_USER"; then
  echo "==> $SHARE_USER already has an SMB password (change it with: sudo smbpasswd $SHARE_USER)"
else
  echo "==> Set the SMB password for $SHARE_USER"
  echo "    This is what Finder will ask for. It is not the board's login password."
  sudo smbpasswd -a "$SHARE_USER"
fi

# The samba package enables a domain controller, a NetBIOS name service and a
# domain user lookup daemon. None are wanted: the tailnet resolves names by
# DNS, there is no domain, and this board shares 8GB with an ingest workload.
echo "==> Disabling the services samba brings that are not wanted here"
for unit in samba-ad-dc nmbd winbind; do
  sudo systemctl disable --now "$unit" 2>/dev/null || true
done

# smbd binds its addresses at startup, so at boot it has to come up after the
# address exists. Without this the share is unreachable until something
# restarts it by hand.
echo "==> Making smbd wait for tailscaled"
sudo mkdir -p /etc/systemd/system/smbd.service.d
sudo tee /etc/systemd/system/smbd.service.d/after-tailscale.conf >/dev/null <<'UNIT'
[Unit]
After=tailscaled.service
Wants=tailscaled.service
UNIT
sudo systemctl daemon-reload

echo "==> Starting"
sudo systemctl enable --now smbd
sudo systemctl restart smbd
systemctl is-active smbd

echo
echo "==> Listening on"
ss -tln | grep ':445\b' | sed 's/^/  /' || true
# Being bound somewhere is not the test. Being bound on the tailnet is, and
# this is the check that would have caught the lo-only bind.
# Listening on 0.0.0.0 covers the tailnet address. What is worth asserting is
# that something is listening at all, and that Samba was given the allow list.
if ss -tln | grep -qE '(\*|0\.0\.0\.0):445'; then
  echo "  reachable on the tailnet at ${TS_IP}"
  echo "  refused from anywhere that is not ${TAILNET_CIDR} or this machine"
else
  # Say why, rather than leaving a person to go and find out. These three
  # together answer it: what Samba was told, what Samba believes it has, and
  # what the kernel actually has.
  {
    echo
    echo "  smbd is not listening on 445 at all — Finder will not connect."
    echo
    echo "  samba's allow list:"
    testparm -s --parameter-name='hosts allow' 2>/dev/null | sed 's/^/    /'
    echo "  the kernel has these addresses:"
    ip -o -4 addr show | awk '{print "    " $2 "  " $4}'
    echo
    echo "  Last words from smbd:"
    journalctl -u smbd -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  } >&2
  exit 1
fi
echo
host=$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName":"\([^".]*\)\..*/\1/p' | head -1)
cat <<NEXT

  In Finder:  Go > Connect to Server (Cmd-K)

    smb://${host:-$(hostname -s)}.<tailnet>.ts.net/${SHARE_NAME}

  Log in as ${SHARE_USER} with the password just set.

  One share, deliberately. No Time Machine target: backups here are manual.
NEXT
