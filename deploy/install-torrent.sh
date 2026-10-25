#!/usr/bin/env bash
# qBittorrent behind AirVPN, on its own tailnet name. Runs on the board.
#
# `ssh -t`, because this asks for the WireGuard keys.
#
# Nothing here is written to the repository. The three values AirVPN's Config
# Generator produces are read from the terminal, put straight into a Kubernetes
# Secret, and never echoed — the same treatment the Tailscale OAuth client
# gets in install-uptime-kuma.sh.
#
# The deployment is installed stopped. This is the one workload meant to be off
# unless something is downloading, and the console's power switch is what turns
# it on: k8s/qbittorrent.yaml carries a Role letting the console set this one
# deployment's replica count and nothing else in the cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"
SECRET=qbittorrent-vpn

if [ -z "${APPS_DIR:-}" ]; then
  for candidate in "/1) Archive" /srv/archive; do
    [ -d "$candidate" ] && { APPS_DIR="$candidate/Apps"; break; }
  done
fi
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"
DATA_DIR="${DATA_DIR:-/srv/storage}"
# Where the tunnel comes out. gluetun chooses a server from AirVPN's whole list
# unless told otherwise — the keys are account-wide and every server takes them
# — so without this an exit anywhere on earth is a fair draw. Nearby is faster
# for the same reason a shorter cable is.
VPN_COUNTRIES="${VPN_COUNTRIES:-Netherlands,Germany,Belgium}"

if ! sudo systemctl is-active --quiet k3s; then
  echo "k3s is not running on this board. This installs into the cluster." >&2
  exit 1
fi

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

if ! kube -n tailscale get secret operator-oauth >/dev/null 2>&1; then
  echo "The Tailscale operator is not installed — run 'make uptime' first." >&2
  exit 1
fi

# /dev/net/tun is what WireGuard needs and the most likely thing to be missing.
# Checked before anything is created, because the failure otherwise appears as
# a pod stuck in ContainerCreating with the reason three commands away.
if [ ! -c /dev/net/tun ]; then
  echo "/dev/net/tun does not exist on this board, and WireGuard needs it." >&2
  echo "  sudo modprobe tun && echo tun | sudo tee -a /etc/modules" >&2
  exit 1
fi

if ! mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo "  WARNING: $DATA_DIR is not a mount point — downloads would land on the boot disk." >&2
  printf "  Continue anyway? [y/N] " >&2
  read -r reply
  case "$reply" in [yY]) ;; *) echo "  Stopped." >&2; exit 1 ;; esac
fi

# The networks that may bypass the tunnel: the cluster's own, and nothing else.
# Read from the live cluster because k3s' 10.42/10.43 defaults are only
# defaults, and a wrong value here does not fail loudly — it presents as a
# healthy pod whose web interface never loads.
#
# Pod ranges come from the nodes themselves, one per node, which is exact. The
# service range has no API of its own, so it is taken from the width of the
# kubernetes service's own address: that address is inside it by definition.
echo "==> Cluster networks"
# `|| true` on both, because the point of the check below is to explain the
# failure. Without it set -e ends the run inside the pipeline and the
# explanation never prints.
POD_CIDRS=$(kube get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | grep . | paste -sd, - || true)
SVC_IP=$(kube -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$POD_CIDRS" ] || [ -z "$SVC_IP" ]; then
  echo "Could not read the cluster's networks. Without them the web interface" >&2
  echo "would be unreachable behind the killswitch, so nothing was applied." >&2
  exit 1
fi
SVC_CIDR=$(echo "$SVC_IP" | awk -F. '{print $1"."$2".0.0/16"}')
CLUSTER_CIDRS="${POD_CIDRS},${SVC_CIDR}"
# This machine's own address on each pod network (the bridge, .1): where the
# console and the board's scripts appear from when they call the WebUI.
WEBUI_BYPASS=$(python3 -c 'import ipaddress,sys; print(",".join(f"{ipaddress.ip_network(c)[1]}/32" for c in sys.argv[1].split(",") if c))' "$POD_CIDRS")
printf '  %-16s %s\n' "exit through" "$VPN_COUNTRIES"
printf '  %-16s %s\n' "may bypass" "$CLUSTER_CIDRS"
printf '  %-16s %s\n' "everything else" "goes through AirVPN or nowhere"
echo

echo "==> Layout"
printf '  %-16s %s\n' "settings (SSD)" "$APPS_DIR/qBittorrent"
printf '  %-16s %s\n' "downloads (6TB)" "$DATA_DIR"
echo
echo "  The whole 6TB is mounted, not one folder inside it. A finished download"
echo "  is hard-linked into place rather than copied, and a hard link cannot"
echo "  cross a mount boundary — two mounts would mean a second full copy of"
echo "  every file that is still seeding."
echo

echo "==> Folders"
sudo mkdir -p "$APPS_DIR/qBittorrent" "$DATA_DIR/Downloads"
sudo chown -R "$OWNER_UID:$OWNER_GID" "$APPS_DIR/qBittorrent" "$DATA_DIR/Downloads"

# The image's own default save path is /downloads, which is not mounted here —
# left alone, every download would land in the container's writable layer,
# disappear on the next restart, and fill the boot disk on the way. Seeded once
# so the first torrent added goes somewhere real.
#
# Only when absent. qBittorrent rewrites this file constantly and owns it after
# the first start; re-running this script must not stamp on settings changed
# since.
QBT_CONF="$APPS_DIR/qBittorrent/qBittorrent/qBittorrent.conf"
if [ ! -f "$QBT_CONF" ]; then
  echo "==> Seeding qBittorrent's save paths"
  sudo mkdir -p "$(dirname "$QBT_CONF")"
  # Incomplete files stay on the 6TB rather than the SSD. Finishing a download
  # is then a rename within one filesystem — instant, and no second copy —
  # where a fast staging area on the other disk would mean writing every byte
  # twice and reading it once more.
  sudo tee "$QBT_CONF" >/dev/null <<CONF
[BitTorrent]
Session\\DefaultSavePath=/data/Downloads
Session\\TempPathEnabled=true
Session\\TempPath=/data/Downloads/.incomplete
CONF
  sudo chown -R "$OWNER_UID:$OWNER_GID" "$APPS_DIR/qBittorrent"
  printf '  %-16s %s\n' "finished" "$DATA_DIR/Downloads"
  printf '  %-16s %s\n' "in progress" "$DATA_DIR/Downloads/.incomplete"
  echo "  Both on the 6TB, so finishing a download is a rename and not a copy."
else
  echo "==> qBittorrent already has settings — leaving them alone"
fi

# No password, for the same reason the console has none.
#
# Reaching this at all means being on the tailnet: no port is open, the name
# resolves nowhere else, and the certificate is issued to a machine only an
# authenticated device can route to. Tailscale has already answered "who is
# this" before qBittorrent is asked. A second password on top of that is not a
# second lock — it is the same lock, and one nobody can open, because
# qBittorrent generates its own at every start and voids it on the next.
#
# The whitelist is the cluster's own networks, which is where the ingress proxy
# sits and the only place a request can arrive from. Nothing outside the
# cluster can present those addresses.
#
# Applied whether or not the config was just written: a board set up before
# this existed is holding a generated password nobody knows.
# Three settings qBittorrent cannot work without here, and cannot be told from
# its own interface because two of them are why the interface is useless.
#
#   Port=<reserved>      Listen on the port AirVPN forwards. It was picking a
#                        random one — 32522 — so the forwarded port pointed at
#                        nothing and the client reported itself firewalled.
#
#   AuthSubnetWhitelist  No login for this machine itself (its address on
#                        the pod network), so the console and quiet hours can
#                        use the API. Everyone else logs in. It used to be the
#                        whole cluster network, which includes the tailnet
#                        proxy pods, so the web page had no password at all.
#                        The login is set by deploy/set-admin-password.sh.
echo "==> qBittorrent settings"
# The port AirVPN forwards, taken from the secret it was stored in. Prompted
# for if it is missing: an earlier install could store the keys without it, and
# a client listening on a port nobody forwards is a client no peer can reach.
FWD_PORT=$(kube -n pi get secret "$SECRET" -o jsonpath='{.data.forwardedPort}' 2>/dev/null | base64 -d 2>/dev/null || true)

# The address WireGuard gives this client, which is the address tun0 will have
# once gluetun is up. AirVPN issues it per key, so it is stable across
# reconnects and belongs in the same secret the key came from. Stored as a
# comma-separated list of an IPv4 and an IPv6 address, each with its prefix
# length. Only the IPv4 part is wanted, without the mask.
TUN_ADDR=$(kube -n pi get secret "$SECRET" -o jsonpath='{.data.addresses}' 2>/dev/null |
  base64 -d 2>/dev/null | tr ',' '\n' | sed -n 's#^ *\([0-9][0-9.]*\)/.*#\1#p' | head -1 || true)

# qBittorrent rewrites this file when it exits, so an edit made while it runs is
# discarded on the way out. Stopped, edited, then put back the way it was found.
WAS=$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [ "${WAS:-0}" != "0" ]; then
  kube -n pi scale deployment/qbittorrent --replicas=0 >/dev/null
  kube -n pi wait --for=delete pod -l app=qbittorrent --timeout=90s >/dev/null 2>&1 || true
fi

# python3 rather than sed: the keys contain backslashes and the values contain
# slashes, and nested sed escaping through a heredoc produced a doubled
# backslash and keys qBittorrent does not recognise. Line-based, with no
# regular expression near a value — a backslash in a re.sub replacement is an
# escape too, which cost one more attempt.
sudo python3 - "$QBT_CONF" "$WEBUI_BYPASS" <<'EDIT'
import sys

path, cidrs = sys.argv[1], sys.argv[2]

lines = open(path).read().splitlines()

# qBittorrent 5.3 moved these out of [Preferences], as WebUI\Key, into their
# own [WebUI] section. Write whichever layout the file already has.
def place(key):
    return ("WebUI", key) if "[WebUI]" in lines else ("Preferences", "WebUI\\" + key)

want = [(*place("AuthSubnetWhitelistEnabled"), "true"),
        (*place("AuthSubnetWhitelist"), cidrs)]

for section, key, value in want:
    lines = [l for l in lines if not l.startswith(key + "=")]
    header = "[" + section + "]"
    if header in lines:
        lines.insert(lines.index(header) + 1, key + "=" + value)
    else:
        lines += ["", header, key + "=" + value]

open(path, "w").write("\n".join(lines) + "\n")
EDIT
sudo chown "$OWNER_UID:$OWNER_GID" "$QBT_CONF"
printf '  %-16s %s\n' "no login from" "$WEBUI_BYPASS"
if [ "${WAS:-0}" != "0" ]; then
  kube -n pi scale deployment/qbittorrent --replicas="$WAS" >/dev/null
fi

echo "==> AirVPN credentials"
if kube -n pi get secret "$SECRET" >/dev/null 2>&1; then
  echo "  already present — leaving them alone"
  echo "  (replace with: sudo k3s kubectl -n pi delete secret ${SECRET}, then re-run)"
else
  cat <<'NOTE'

  From AirVPN's Client Area > Config Generator, choose WireGuard and a server,
  then read these three values off the generated config. Eddie is not involved
  and does not need to be running: this is a separate device on the same
  subscription, and it will use one of your plan's connection slots.

    PrivateKey    the [Interface] PrivateKey
    PresharedKey  the [Peer] PresharedKey
    Address       the [Interface] Address, both values, comma separated

  And the port you reserved under Client Area > Ports. Traffic only reaches
  the client on a port AirVPN is forwarding; without one it can download but
  seeds poorly.

  Nothing typed here is echoed, and none of it is written to this board's disk
  outside the cluster's own secret store.

NOTE
  printf '  WireGuard private key: '
  IFS= read -rs WG_KEY; echo
  printf '  WireGuard preshared key: '
  IFS= read -rs WG_PSK; echo
  printf '  WireGuard addresses: '
  IFS= read -r WG_ADDR
  printf '  Forwarded port: '
  IFS= read -r WG_PORT

  for pair in "private key:$WG_KEY" "preshared key:$WG_PSK" "addresses:$WG_ADDR" "port:$WG_PORT"; do
    if [ -z "${pair#*:}" ]; then
      echo "  The ${pair%%:*} is empty. Nothing was created." >&2
      exit 1
    fi
  done

  kube -n pi create secret generic "$SECRET" \
    --from-literal=privateKey="$WG_KEY" \
    --from-literal=presharedKey="$WG_PSK" \
    --from-literal=addresses="$WG_ADDR" \
    --from-literal=forwardedPort="$WG_PORT" >/dev/null
  unset WG_KEY WG_PSK WG_ADDR WG_PORT
  echo "  stored in the cluster as secret/$SECRET"
fi

echo "==> Applying manifests"
render() {
  sed -e "s|__APPS_DIR__|${APPS_DIR}|g" -e "s|__DATA_DIR__|${DATA_DIR}|g" \
      -e "s|__UID__|${OWNER_UID}|g" -e "s|__GID__|${OWNER_GID}|g" \
      -e "s|__CLUSTER_CIDRS__|${CLUSTER_CIDRS}|g" \
      -e "s|__VPN_COUNTRIES__|${VPN_COUNTRIES}|g" "$1"
}
# The manifest says replicas: 0 because that is right on a first install. On a
# re-run it would stop a download in progress, so whatever the deployment is
# set to now is put back afterwards.
WAS=$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
render "${REPO_ROOT}/k8s/qbittorrent.yaml" | apply_guarded
if [ -n "$WAS" ] && [ "$WAS" != "0" ]; then
  kube -n pi scale deployment/qbittorrent --replicas="$WAS" >/dev/null
  echo "  it was running, so it has been left running"
fi

# The generated password, fished out of the log rather than left for someone to
# go looking for. qBittorrent 5 ships no default: it makes one per start and
# prints it once, so a restart invalidates whatever was written down last time.
# Only worth showing while the client is actually running.
if [ "$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" != "0" ]; then
  echo
  echo "==> Web interface login"
  kube -n pi rollout status deployment/qbittorrent --timeout=120s >/dev/null 2>&1 || true
  QBT_PW=$(kube -n pi logs deploy/qbittorrent -c qbittorrent --tail=200 2>/dev/null |
    sed -n 's/.*temporary password is provided for this session: *//p' | tail -1 || true)
  if [ -n "$QBT_PW" ]; then
    printf '  %-12s %s\n' "username" "admin"
    printf '  %-12s %s\n' "password" "$QBT_PW"
    echo "  Generated for this run and void on the next restart. Set your own in"
    echo "  Options > Web UI."
  else
    echo "  No temporary password in the log, which means a permanent one is set."
  fi
fi

# The rest is applied through qBittorrent's own API rather than its config
# file, because the file route quietly failed: the port was written to a key
# the client reads at startup and then overwrites on exit, and the value never
# survived. The API is what qBittorrent's own settings page uses, it applies
# immediately, and it answers whether it worked.
#
# Sent from the board to the Service's cluster IP. That traffic arrives from the
# cluster network, which the WebUI's AuthSubnetWhitelist lets in without a
# login. Two routes that do not work: localhost inside the pod is not on that
# list and answers 403, and a cluster DNS name does not resolve in the pod,
# because gluetun owns its DNS. The earlier localhost call used curl without
# -f, so the 403 still exited 0 and this reported settings it never applied;
# the settings are now read back and compared.
if [ "$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" != "0" ]; then
  echo "==> Peer settings"
  kube -n pi rollout status deployment/qbittorrent --timeout=180s >/dev/null 2>&1 || true

  if [ -z "$FWD_PORT" ]; then
    echo "  No forwarded port stored. Reserve one under AirVPN's Client Area >" >&2
    echo "  Ports and re-run; until then peers cannot reach this client and it" >&2
    echo "  will report itself firewalled." >&2
  fi

  # UPnP is off because there is nothing here to ask. UPnP negotiates a port
  # with a router on the local network; this client's only route out is a
  # tunnel, and the port on the far end of it was reserved by hand in AirVPN's
  # control panel. Left on, it retries forever against a gateway that will
  # never answer.
  # Bind to the tunnel address rather than to every interface.
  #
  # "every interface" is what qBittorrent does by default, and it enumerates
  # them once, at startup. Anything that delays tun0 past that moment — a slow
  # WireGuard handshake, a probe that passed early, a gluetun reconnect — leaves
  # the client bound to eth0 and loopback and nothing else. It then sends every
  # tracker announce, DHT query and peer connection out of eth0, where the
  # killswitch drops them. Names still resolve, so nothing reports an error: the
  # client just sits there, firewalled, DHT at zero, magnets on "retrieving
  # metadata" until you give up.
  #
  # Named by address and not by device. libtorrent accepted "tun0" and then
  # never finished binding to it — it logged the attempt and no success, and the
  # client went from firewalled to disconnected. The address binds first time.
  #
  # This is also the stricter setting of the two. A socket on the tunnel address
  # cannot send a packet down eth0 whatever the routing table says, so the
  # killswitch stops being the only thing standing between this client and the
  # board's own connection.
  if [ -z "$TUN_ADDR" ]; then
    echo "  No WireGuard address stored in the secret, so the client is left" >&2
    echo "  bound to every interface. It works while the tunnel wins the race" >&2
    echo "  at startup and stops dead when it does not." >&2
  fi
  PREFS="{\"upnp\":false${FWD_PORT:+,\"listen_port\":$FWD_PORT},\"random_port\":false${TUN_ADDR:+,\"current_network_interface\":\"tun0\",\"current_interface_address\":\"$TUN_ADDR\"}}"
  command -v jq >/dev/null || sudo apt-get install -y jq >/dev/null
  QIP=$(kube -n pi get svc qbittorrent -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST \
           "http://$QIP/api/v2/app/setPreferences" --data-urlencode "json=$PREFS" || true)
  applied=false
  if [ "$code" = 200 ]; then
    got=$(curl -s -m 10 "http://$QIP/api/v2/app/preferences" || true)
    applied=true
    [ "$(jq -r '.upnp' <<<"$got" 2>/dev/null)" = false ] || applied=false
    if [ -n "$FWD_PORT" ] && [ "$(jq -r '.listen_port' <<<"$got" 2>/dev/null)" != "$FWD_PORT" ]; then
      applied=false
    fi
    if [ -n "$TUN_ADDR" ] && [ "$(jq -r '.current_interface_address' <<<"$got" 2>/dev/null)" != "$TUN_ADDR" ]; then
      applied=false
    fi
  fi
  if [ "$applied" = true ]; then
    printf '  %-16s %s\n' "listening on" "${TUN_ADDR:-every interface}:${FWD_PORT:-unchanged}"
    printf '  %-16s %s\n' "upnp" "off — nothing on a tunnel to negotiate with"
  else
    echo "  qBittorrent did not take these settings (HTTP ${code:-no answer})." >&2
    echo "  It may still be starting; re-run this in a minute." >&2
  fi
fi

# Said from the deployment as it now is: a re-run leaves a running client
# running, and the summary must not then report it stopped.
if [ "$(kube -n pi get deploy qbittorrent -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)" != "0" ]; then
  STATE=running
  POWER="It is running. The qBittorrent tile in the console's Apps tab has a power
switch to stop it."
else
  STATE=stopped
  POWER="Start it from the console's Apps tab — the qBittorrent tile has a power
switch."
fi

cat <<NEXT

==> Installed, and ${STATE}.

${POWER} The VPN comes up first and the client cannot send a packet until it
has, because they share one network namespace and gluetun owns the routing.
Stopping puts both away and gives the memory back.

Before downloading anything, prove the tunnel is up. With it running:

  sudo k3s kubectl -n pi exec deploy/qbittorrent -c gluetun -- \\
    wget -qO- https://ipinfo.io/ip

That address should be AirVPN's, not yours. If it is yours, stop immediately
and check the secret.

Downloads land in ${DATA_DIR}/Downloads, which is HDD-6TB/Downloads in Finder.
The add-torrent form shows that path and lets you change it per torrent —
anywhere under /data, which is the whole 6TB. Categories are worth setting up
once (Options > Downloads, then a category per destination) so a film goes
straight to ${DATA_DIR}/Jellyfin/Media/Movies without retyping it.

The port you reserved goes in Options > Connection > Listening Port.

There is no login. Tailscale has already established who you are before
qBittorrent is asked, and a second password on top of that is the same lock
twice — one of which nobody can open, since qBittorrent generates its own at
every start and voids it on the next.

Rollback:  sudo k3s kubectl -n pi delete -f ${REPO_ROOT}/k8s/qbittorrent.yaml
NEXT
