#!/usr/bin/env bash
# Jellyfin and Kiwix, and moves Vaultwarden and Uptime Kuma onto the same
# storage layout. Runs on the board.
#
# One idea, applied four times: an app has two halves, and they belong on
# different drives for different reasons.
#
#   APPS_DIR   the SSD. Everything the computer reads at random: settings,
#              databases, caches, artwork, indexes. Small, and the part where
#              speed is felt — a seek costs a spinning disk about 5ms against
#              an SSD's 0.1, and a database is thousands of seeks.
#   DATA_DIR   the 6TB. Everything you would recognise as a file: films and
#              .zim archives. Large, read start to finish, which is what a
#              spinning disk is actually good at.
#
# The cut is by how a file is read, not by whether it is called data. Calling a
# database "data" and putting it on the big disk is the mistake this layout was
# one revision away from making: Jellyfin's library index is 50MB and would
# have made the whole interface feel slow from the far side of a seek.
#
# Both are overridable, which is the point:
#
#     DATA_DIR=/srv/storage/media bash deploy/install-media.sh
#
# Nothing here uses a PersistentVolumeClaim. k3s' local-path provisioner puts
# volumes in /var/lib/rancher/k3s/storage/pvc-<uuid>_<ns>_<name>, and a
# directory named after a UUID inside a container runtime's internals cannot
# be found in Finder, cannot be backed up without knowing k3s, and cannot tell
# you what is eating the disk. Named directories on named drives do all three.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-$(id -un)}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

# The archive moved from /srv/archive to "/1) Archive". Both are accepted so
# this works whichever the board is carrying, rather than failing on a board
# that has not run deploy/setup-archive.sh since the rename.
if [ -z "${APPS_DIR:-}" ]; then
  for candidate in "/1) Archive" /srv/archive; do
    [ -d "$candidate" ] && { APPS_DIR="$candidate/Apps"; break; }
  done
fi
APPS_DIR="${APPS_DIR:-/1) Archive/Apps}"

# The 6TB, by its mount point rather than its device: a disk swapped for a
# bigger one at the same path should need no edit here.
DATA_DIR="${DATA_DIR:-/srv/storage}"
# Kiwix's .zim files go on HDD2 with the other archives, so the 6TB stays
# Jellyfin's alone. A board without HDD2 keeps them next to the films.
if [ -z "${WIKI_DIR:-}" ]; then
  WIKI_DIR="$DATA_DIR"
  mountpoint -q /srv/hdd2 2>/dev/null && WIKI_DIR=/srv/hdd2
fi
data_dir_for() { if [ "$1" = Kiwix ]; then echo "$WIKI_DIR"; else echo "$DATA_DIR"; fi; }

APPS=(Jellyfin Kiwix Vaultwarden Uptime)
# Two apps are entirely on the SSD and have no half on the 6TB.
#
# Uptime Kuma is a few megabytes of heartbeats, written constantly, which would
# keep the 6TB awake for nothing.
#
# Vaultwarden is a few megabytes of SQLite read at random, so the SSD is where
# it belonged anyway. It has to be off the 6TB for a second reason: qBittorrent
# mounts that whole disk at /data so a finished download can be hard-linked
# into place, and a torrent client with write access to a password vault is a
# bad trade for a convenience. k8s/vaultwarden.yaml moved its volume in #113
# and this list was not updated with it, so the folder went on being created
# and advertised on the 6TB — and the live vault went on sitting in it.
DATA_APPS=(Jellyfin Kiwix)
# Apps whose SSD folder needs a data/ subdirectory of its own, because their
# manifest mounts one with type: Directory and Kubernetes will not create it.
APPS_WITH_DATA_SUBDIR=(Uptime Vaultwarden)

if ! sudo systemctl is-active --quiet k3s; then
  echo "k3s is not running on this board. This installs into the cluster." >&2
  exit 1
fi

kube() { sudo k3s kubectl "$@"; }
# Refuses to install over a second copy of an app; see the file.
. "${REPO_ROOT}/deploy/lib/guard.sh"

if ! kube -n tailscale get secret operator-oauth >/dev/null 2>&1; then
  echo "The Tailscale operator is not installed — run 'make uptime' first." >&2
  echo "Jellyfin and Kiwix each want a tailnet name of their own, and the" >&2
  echo "operator is what hands those out." >&2
  exit 1
fi

# Say where everything is going before touching anything. The whole point of
# this layout is that you can answer "where is my data" without reading a
# manifest, and that starts with the install telling you.
echo "==> Layout"
printf '  %-14s %s\n' "apps  (SSD)" "$APPS_DIR"
printf '  %-14s %s\n' "data  (6TB)" "$DATA_DIR"
echo
for app in "${APPS[@]}"; do
  printf '  %-12s %s\n' "$app" "$APPS_DIR/$app"
  case " ${DATA_APPS[*]} " in
    *" $app "*) printf '  %-12s %s\n' "" "$(data_dir_for "$app")/$app" ;;
    *)          printf '  %-12s %s\n' "" "(nothing on the 6TB — it is small)" ;;
  esac
done
echo

# A missing DATA_DIR almost always means the 6TB is not mounted, and creating
# the directory anyway would silently write the media library onto the boot
# SSD until it filled. Refuse instead.
if [ ! -d "$DATA_DIR" ]; then
  echo "$DATA_DIR does not exist. Is the drive mounted? Check: findmnt $DATA_DIR" >&2
  exit 1
fi

# Existing is not the same as mounted. A mount point is a real directory on the
# boot disk when nothing is mounted on it, so "the folder is there" proves
# nothing — and creating the app folders inside an unmounted mount point is
# exactly how the whole media library ends up on the boot SSD, invisible, until
# the disk is mounted over the top of it.
if ! mountpoint -q "$DATA_DIR" 2>/dev/null; then
  echo >&2
  echo "  WARNING: $DATA_DIR is not a mount point." >&2
  echo "  Nothing is mounted there, so this is space on the boot disk." >&2
  echo "  If you meant the 6TB, stop now and check: findmnt $DATA_DIR" >&2
  echo >&2
  printf "  Continue anyway? [y/N] " >&2
  read -r reply
  case "$reply" in
    [yY]) echo "  Continuing on the boot disk." >&2 ;;
    *) echo "  Stopped. Nothing was changed." >&2; exit 1 ;;
  esac
fi

# The same guard for a separate wiki disk. No prompt: someone who passed
# WIKI_DIR named a specific disk, and an unmounted one is never what they meant.
if [ "$WIKI_DIR" != "$DATA_DIR" ] && ! mountpoint -q "$WIKI_DIR" 2>/dev/null; then
  echo "$WIKI_DIR is not a mount point. Is the drive mounted? Check: findmnt $WIKI_DIR" >&2
  exit 1
fi

echo "==> Creating the folders"
for app in "${APPS[@]}"; do sudo mkdir -p "$APPS_DIR/$app"; done
# These apps take ownership of everything inside their mount, so their data
# sits one level below the app folder and the note stays outside it.
for app in "${APPS_WITH_DATA_SUBDIR[@]}"; do sudo mkdir -p "$APPS_DIR/$app/data"; done
for app in "${DATA_APPS[@]}"; do sudo mkdir -p "$(data_dir_for "$app")/$app"; done
# Jellyfin's brain on the SSD, its films on the 6TB.
sudo mkdir -p "$APPS_DIR/Jellyfin/data" "$APPS_DIR/Jellyfin/cache" \
              "$DATA_DIR/Jellyfin/Media/Movies" "$DATA_DIR/Jellyfin/Media/Shows"
# Ownership, and the one non-obvious case.
#
# hostPath volumes are NOT chowned by Kubernetes. fsGroup is honoured for
# volume types that support ownership management and a raw hostPath is not one
# of them, so whatever these directories are created as is what the container
# gets. A directory left owned by root is a container that cannot write.
#
# Jellyfin and Kiwix run as the login user, so their folders are its own.
#
# Uptime Kuma is the case that would have broken. Its entrypoint drops to the
# image's `node` account through setpriv, which is uid 1000 in the node base
# image — the same number as the login user here, but by coincidence rather
# than agreement. It used to sit on a local-path volume, and that provisioner
# creates its directories world-writable, which is the only reason this was
# never a problem before. Its folder is under APPS_DIR and so is covered by the
# chown below; the write test after the rollout is what proves the coincidence
# held.
#
# Vaultwarden still runs as root and can write to anything, so its folder is
# deliberately left alone rather than given away to a user it does not use.
#
# Only this script's own app folders, never all of APPS_DIR. Other apps keep
# their state there too, and Immich's Postgres data must stay owned by uid 999:
# a recursive chown of APPS_DIR handed it to the login user under a running
# database, which crashed and came back unable to find its last checkpoint.
OWN_APP_DIRS=()
for app in "${APPS[@]}"; do OWN_APP_DIRS+=("$APPS_DIR/$app"); done
sudo chown "$OWNER_UID:$OWNER_GID" "$APPS_DIR"
sudo chown -R "$OWNER_UID:$OWNER_GID" \
  "${OWN_APP_DIRS[@]}" "$DATA_DIR/Jellyfin" "$WIKI_DIR/Kiwix"

# A note in each app's SSD folder, because a folder holding only a config file
# does not explain itself six months later.
for app in "${APPS[@]}"; do
  # Only the split apps get a second half. Writing the same note for all four
  # sent Uptime Kuma's to /srv/storage/Uptime, a path that has never existed.
  case " ${DATA_APPS[*]} " in
    *" $app "*) content="  Its content      $(data_dir_for "$app")/$app
                   the big files. Films and .zim archives." ;;
    *)          content="  Its content      is in this folder too. This app is small enough
                   to live entirely on the SSD, and has nothing on the 6TB." ;;
  esac
  sudo tee "$APPS_DIR/$app/WHERE-IS-MY-DATA.txt" >/dev/null <<NOTE
$app

  This folder      $APPS_DIR/$app
                   settings, database, cache. Small, fast, and the part
                   worth backing up.

$content

Written by deploy/install-media.sh. Change the split by re-running it with
APPS_DIR= or DATA_DIR= set.
NOTE
done
sudo chown -R "$OWNER_UID:$OWNER_GID" "${OWN_APP_DIRS[@]}"

# The vault, if it is still on the 6TB.
#
# #113 repointed Vaultwarden's volume at the SSD and nothing moved the database
# that was already on the 6TB, so the pod went on serving from the old path and
# the manifest and the board disagreed. Applying the manifest without this step
# would point a running vault at an empty directory, and Vaultwarden's answer to
# an empty directory is to build a fresh one and show you an empty account.
#
# Copy, never move: this is a password database. The original is left exactly
# where it is and the command to remove it is printed at the end, for you to run
# once you have logged in and seen your own passwords.
VW_OLD="$DATA_DIR/Vaultwarden"
VW_NEW="$APPS_DIR/Vaultwarden/data"
if [ -f "$VW_OLD/db.sqlite3" ] && [ ! -f "$VW_NEW/db.sqlite3" ]; then
  echo
  echo "==> Moving the vault off the 6TB"
  echo "    from  $VW_OLD"
  echo "    to    $VW_NEW"

  # SQLite in WAL mode keeps recent commits in db.sqlite3-wal, so a copy taken
  # while the pod is writing can be a database missing its newest entries. Stop
  # it first and wait for the pod to actually be gone, not merely asked to go.
  if kube -n pi get deployment vaultwarden >/dev/null 2>&1; then
    echo "    stopping vaultwarden"
    kube -n pi scale deployment/vaultwarden --replicas=0 >/dev/null
    kube -n pi wait --for=delete pod -l app=vaultwarden --timeout=120s >/dev/null 2>&1 || true
  fi

  sudo rsync -aHAX --info=stats2 "$VW_OLD/" "$VW_NEW/" | sed 's/^/    /'

  # Prove the copy is a database and not a file of the right length. Without
  # sqlite3 on the board, fall back to comparing what was copied.
  if command -v sqlite3 >/dev/null; then
    check=$(sudo sqlite3 "$VW_NEW/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 | head -1)
    if [ "$check" != "ok" ]; then
      echo "    integrity_check on the copy said: $check" >&2
      echo "    The original is untouched. Nothing was applied." >&2
      exit 1
    fi
    users=$(sudo sqlite3 "$VW_NEW/db.sqlite3" 'SELECT COUNT(*) FROM users;' 2>/dev/null || echo '?')
    ciphers=$(sudo sqlite3 "$VW_NEW/db.sqlite3" 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || echo '?')
    echo "    integrity_check ok — $users account(s), $ciphers item(s)"
  else
    old_n=$(sudo find "$VW_OLD" -type f | wc -l)
    new_n=$(sudo find "$VW_NEW" -type f | wc -l)
    [ "$old_n" = "$new_n" ] || { echo "    copied $new_n files of $old_n" >&2; exit 1; }
    echo "    $new_n files copied (sqlite3 not on this board, so no integrity check)"
  fi

  # rsync preserved the source's ownership. Vaultwarden runs as root and can
  # write regardless, but leaving a vault owned by whoever happened to own the
  # 6TB copy is not a state worth keeping.
  sudo chown -R 0:0 "$VW_NEW"
  sudo chmod 700 "$VW_NEW"
fi

echo "==> Applying manifests"
# The paths are substituted here rather than being fixed in the manifests,
# which is what makes them configurable. sed's delimiter is | because the
# values are paths and one of them contains a space and a bracket.
# Every tailnet machine by name, for Uptime Kuma's hostAliases: MagicDNS does
# not resolve inside a pod. See k8s/uptime-kuma.yaml.
HOST_ALIASES="$(sudo tailscale status --json 2>/dev/null | jq -c '
  [.Self, (.Peer // {} | .[])]
  | map(select((.DNSName // "") != "" and ((.TailscaleIPs // []) | length) > 0))
  | map({ip: .TailscaleIPs[0], hostnames: [.DNSName | rtrimstr(".")]})')" || HOST_ALIASES=""
case "$HOST_ALIASES" in
  ""|"[]") echo "Could not list tailnet machines from tailscaled. Is it up?" >&2; exit 1 ;;
esac

render() {
  sed -e "s|__APPS_DIR__|${APPS_DIR}|g" \
      -e "s|__DATA_DIR__|${DATA_DIR}|g" \
      -e "s|__WIKI_DIR__|${WIKI_DIR}|g" \
      -e "s|__HOST_ALIASES__|${HOST_ALIASES}|g" \
      -e "s|__UID__|${OWNER_UID}|g" \
      -e "s|__GID__|${OWNER_GID}|g" "$1"
}

for manifest in jellyfin kiwix vaultwarden uptime-kuma; do
  render "${REPO_ROOT}/k8s/${manifest}.yaml" | apply_guarded
done
# The GPU, when deploy/setup-gpu.sh has given k3s one. A no-op on a board
# without it.
. "${REPO_ROOT}/deploy/lib/jellyfin-gpu.sh"
jellyfin_gpu

# The old PVCs are deliberately left in place. Vaultwarden is empty and Kuma's
# heartbeat history is being started over, so neither is worth migrating — but
# deleting a volume in the same breath as repointing the thing that used it is
# how data goes missing. Remove them by hand once the pods are up and right.
echo
echo "==> The old volumes are still there, untouched:"
kube -n pi get pvc 2>/dev/null | sed 's/^/  /' || true
echo "  Remove when you are happy:  sudo k3s kubectl -n pi delete pvc vaultwarden uptime-kuma"

# Fires whether or not this run did the copying. A board where the migration
# already happened, or was half done by hand, still has a vault sitting on the
# torrent client's disk and should still be told so.
if [ -f "$VW_OLD/db.sqlite3" ]; then
  echo
  echo "==> A vault is still on the 6TB, untouched:"
  echo "  $VW_OLD"
  echo
  echo "  It holds db.sqlite3 and rsa_key.pem, and $DATA_DIR is the disk"
  echo "  qBittorrent mounts whole. Log in at the vault's tailnet address, see"
  echo "  your own passwords, then remove it:"
  echo
  echo "    sudo rm -rf \"$VW_OLD\""
fi

echo
echo "==> Waiting for the rollouts"
for app in jellyfin kiwix vaultwarden uptime-kuma; do
  kube -n pi rollout status "deployment/$app" --timeout=300s || {
    echo "  $app did not come up. Logs:" >&2
    kube -n pi logs "deployment/$app" --tail=30 2>&1 | sed 's/^/    /' >&2
  }
done

# Readiness proves the process answers, not that it can write where it was
# pointed — and a media server that cannot write its database will happily
# serve a login page while failing at the only thing it is for. Ask each
# container directly.
echo
echo "==> Can each app write to its data folder?"
# A third field names the uid the app really writes as, when that is not the
# user an exec lands as. Uptime Kuma's container starts as root with every
# capability but four dropped, then hands over to node (1000); root without
# DAC_OVERRIDE cannot write into node's folder, so asking as root reported a
# working app as broken.
write_test() { # deployment, path inside the container, [uid]
  if [ -n "${3:-}" ]; then
    kube -n pi exec "deployment/$1" -- setpriv --reuid="$3" --regid="$3" --clear-groups sh -c \
      'd=$1; t="$d/.write-test.$$"; touch "$t" 2>/dev/null && rm -f "$t"' sh "$2" >/dev/null 2>&1
  else
    kube -n pi exec "deployment/$1" -- sh -c \
      'd=$1; t="$d/.write-test.$$"; touch "$t" 2>/dev/null && rm -f "$t"' sh "$2" >/dev/null 2>&1
  fi
}
failed=0
for pair in "jellyfin /data" "kiwix /config" "vaultwarden /data" "uptime-kuma /app/data 1000"; do
  set -- $pair
  if write_test "$1" "$2" "${3:-}"; then
    printf '  ok    %-14s %s\n' "$1" "$2"
  else
    printf '  FAIL  %-14s %s  <- cannot write\n' "$1" "$2"
    failed=1
  fi
done
if [ "$failed" = 1 ]; then
  cat >&2 <<'FIXIT'

  A container that cannot write to its folder is an ownership mismatch: the
  directory on the board belongs to a different uid than the one inside the
  container. Find the uid it actually runs as, and hand it the folder:

    sudo k3s kubectl -n pi exec deployment/<app> -- id
    sudo chown -R <uid>:<gid> <the folder printed above>

FIXIT
fi

echo
echo "==> Addresses"
kube -n pi get ingress -o custom-columns=NAME:.metadata.name,HOST:.spec.tls[0].hosts[0] --no-headers 2>/dev/null |
  while read -r name host; do printf '  %-12s https://%s.%s\n' "$name" "$host" "<tailnet>.ts.net"; done

cat <<NEXT

Jellyfin
  Open it and run the setup wizard. Add a library pointing at /media/Movies
  and /media/Shows — those are ${DATA_DIR}/Jellyfin/Media/* from the board.
  Copy films in through the HDD-6TB folder in Finder.

  At home without Tailscale (a TV): http://$(hostname -I | awk '{print $1}'):8096
  — the house only; nothing outside can reach it.

  Without a GPU this machine direct-plays and does not meaningfully transcode.
  With one, run deploy/setup-gpu.sh (make gpu) and switch on NVENC in
  Dashboard > Playback > Transcoding; conversions then run on the card.

Kiwix
  Put a .zim from https://download.kiwix.org/zim/ into ${WIKI_DIR}/Kiwix. It
  appears within a couple of minutes once the file has finished copying; no
  restart. Removing a file takes it out the same way. The folder is the
  truth, and there is no index to keep in step with it.

Rollback:  sudo k3s kubectl -n pi delete -f ${REPO_ROOT}/k8s/jellyfin.yaml -f ${REPO_ROOT}/k8s/kiwix.yaml
NEXT
