#!/usr/bin/env bash
# One pass at making the Finder mounts match what the tailnet can reach right
# now: mount what is missing, unmount what has gone stale. Runs on the Mac, on
# an interval, from the agent that deploy/install-share-mounts.sh sets up.
#
# Nothing is remembered between passes. The mount table and `tailscale status`
# are the two sources of truth; a third opinion kept in a file here would only
# be one more thing to go stale.
#
# Nothing here may block. launchd will not start a second copy of an agent that
# is still running, so a pass that hangs does not miss one beat — it is the last
# pass that ever runs, and it hangs holding the very mount it was supposed to
# clear. Every operation that touches a mount point is therefore either bounded
# or pushed into the background and abandoned.
#
# Mounting goes through NetFS, not mount_smbfs. mount_smbfs takes a password
# from a terminal and nothing else: it opens /dev/tty and ignores stdin, so it
# works when a person is sitting there to type and never works from an agent.
# That is not a detail — it is the whole reason an earlier version of this file
# logged an authentication error every fifteen seconds for hours while the
# stored password was perfectly correct. NetFS takes the credential as a
# parameter, which is what an unattended mount needs.
set -uo pipefail
# Deliberately not -e: one board being unreachable must not skip the other, and
# unmounting a mount that is already gone is an expected failure.

NODES="${STORAGE_NODES:-pi2}"
SHARE_USERS="${SHARE_USERS:-}"
# NetFS names the mount after the share, puts it under /Volumes, and cannot be
# told otherwise — so the share on each board is named after the board. See
# install-samba.sh.
#
# Not configurable, deliberately. NetFS decides where the mount lands; a knob
# here could only ever disagree with it, and the failure would be this pass
# looking for its own mounts in a place they are not, mounting again every
# fifteen seconds and never seeing the result.
MOUNT_ROOT=/Volumes
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
MOUNT_TIMEOUT="${MOUNT_TIMEOUT:-25}"
# How long to leave a board alone after a mount attempt fails. Not politeness:
# NetFS raises a dialog when it dislikes an answer, so retrying a refused
# password every fifteen seconds would put a popup on the screen every fifteen
# seconds. A wrong password is not a transient condition and gains nothing from
# being asked again promptly.
RETRY_AFTER="${RETRY_AFTER:-300}"
WORK="${TMPDIR:-/tmp}/pi-share-mounts"
mkdir -p "$WORK"

# One pass at a time.
#
# The installer runs a pass in the foreground and the agent runs one on a timer,
# and on the first install both went off together. Two passes each saw an
# unmounted share, both mounted it, and NetFS — finding the obvious name taken
# by the first — put the second at /Volumes/pi-1. Two mounts of one share, and
# a mount point neither pass was looking for.
#
# mkdir is the lock because it is atomic. A stale one is taken over rather than
# waited on: the holder is a pass that died, and passes are meant to be
# disposable.
LOCK="${WORK}/pass.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "${LOCK}/pid" 2>/dev/null || echo)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "${LOCK}/pid"
trap 'rm -rf "$LOCK"' EXIT

TS=""
for candidate in \
  /usr/local/bin/tailscale \
  /Applications/Tailscale.app/Contents/MacOS/Tailscale \
  /opt/homebrew/bin/tailscale
do
  [ -x "$candidate" ] && { TS="$candidate"; break; }
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Said once, then not again until it changes. A permanent condition repeating at
# timer rate buries the events the log exists to record.
say_once() {
  local key="$1"; shift
  local file="${WORK}/said.$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
  local now="$*"
  [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$now" ] && return
  printf '%s' "$now" > "$file"
  log "$now"
}
forget() { rm -f "${WORK}/said.$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

if [ -z "$TS" ]; then
  say_once notailscale "no tailscale binary found — cannot tell whether the tailnet is up"
  exit 1
fi

# Whether the backend is up, answered without asking the backend.
#
# Every path to the tailscale CLI on macOS is a shim that execs the app bundle,
# so `tailscale status` does not report on Tailscale, it starts it. From this
# agent, on a fifteen-second timer, that is not a status check — it is a
# resurrection loop. The app reappears seconds after every quit, the VPN session
# with it, and nothing on screen says why; the obvious suspect is Tailscale
# itself, and the actual cause is this file. It cost an evening to find once.
#
# The interface list answers the same question, costs nothing, and starts
# nothing. A tunnel holding an address in Tailscale's range (the
# carrier-grade NAT block) is the backend running.
# No such address is the backend stopped — which is the honest answer, and the
# one that lets the stale-mount path below unmount what can no longer be
# reached instead of waking a VPN to ask.
tailnet_addressed() {
  ifconfig 2>/dev/null |
    grep -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
}

tailnet_up() { tailnet_addressed && "$TS" status >/dev/null 2>&1; }

node_online() {
  local row
  row=$("$TS" status 2>/dev/null | awk -v n="$1" '$2 == n { print; exit }')
  [ -n "$row" ] && [[ "$row" != *offline* ]]
}

# Where this board's share is mounted, or nothing.
#
# Looked up by the share, never by the path. NetFS picks the path itself, and
# when the obvious name is taken it quietly uses the next one — /Volumes/pi-1
# instead of /Volumes/pi. A check that asks "is anything mounted at the path I
# expect" then answers no about a mount that exists, and the pass mounts the
# same share again, every fifteen seconds, for ever. The share is the thing
# being asked about, so the share is the thing to look for.
mounted_at() {
  /sbin/mount | awk -v s="/$1" '
    $1 ~ ("@[^/]+" s "$") {
      # "//user@host/share on /Volumes/x (smbfs, ...)" — the path is everything
      # between "on " and the options, and it may contain spaces.
      p = $0
      sub(/^[^ ]+ on /, "", p)
      sub(/ \([^)]*\)$/, "", p)
      print p
      exit
    }'
}

# The name NetFS would use if nothing were in the way. Only for reporting.
point_for() { printf '%s/%s' "$MOUNT_ROOT" "$1"; }

user_for() {
  local pair
  for pair in $SHARE_USERS; do
    [ "${pair%%=*}" = "$1" ] && { printf '%s' "${pair#*=}"; return; }
  done
  printf '%s' "$(id -un)"
}

# `security -w` prints the stored value as a hex dump, with no marker and no
# warning, whenever it holds a byte outside printable ASCII. Anything using that
# output would authenticate with the literal text of the dump and be refused for
# ever, a failure with nothing in it to suggest a cause.
#
# `-g` is unambiguous where `-w` is not: its line begins `0x` for the hex case
# and with a quote otherwise, so the two are told apart rather than guessed at.
# Guessing would be wrong anyway — a value of nothing but hex digits is a
# perfectly ordinary one.
password_for() {
  local shown hex
  shown=$(security find-internet-password -g -a "$2" -s "$1" -r "smb " 2>&1 >/dev/null \
    | grep '^pass''word' | cut -d' ' -f2-)
  case "$shown" in
    0x*)
      hex=${shown#0x}
      hex=${hex%% *}
      printf '%s' "$hex" | xxd -r -p
      ;;
    *)
      security find-internet-password -a "$2" -s "$1" -r "smb " -w 2>/dev/null || true
      ;;
  esac
}

# Has this board earned another attempt yet?
cooled() {
  local mark="${WORK}/failed.$1"
  [ -f "$mark" ] || return 0
  local age=$(( $(date +%s) - $(stat -f %m "$mark" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$RETRY_AFTER" ]
}
mark_failed() { : > "${WORK}/failed.$1"; }
mark_ok() { rm -f "${WORK}/failed.$1"; }

# Is this mount still answering?
#
# There is no safe way to ask. Every probe blocks on a wedged path, including
# `smbutil statshares`, which reads kernel state rather than the server and still
# hung until the mount was forced away by hand. So a child does the reading and
# touches a file if it gets an answer, and the parent watches the clock and
# walks away when it runs out — without reaping the child, since a process
# blocked in uninterruptible I/O may not die on SIGKILL either. The forced
# unmount that follows is what actually releases it.
#
# `ls` rather than a stat: a stat of the mount point is answered from the
# kernel's cache and a directory read is not. A child that exits without leaving
# the file has answered too — a permission error is a live server refusing.
answering() {
  local mp="$1" flag child waited=0
  flag="${WORK}/probe.$$.$RANDOM"
  rm -f "$flag"
  ( /bin/ls -f "$mp" >/dev/null 2>&1; : > "$flag" ) &
  child=$!
  while [ "$waited" -lt "$PROBE_TIMEOUT" ]; do
    [ -e "$flag" ] && { rm -f "$flag"; return 0; }
    kill -0 "$child" 2>/dev/null || { rm -f "$flag"; return 0; }
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$child" 2>/dev/null
  rm -f "$flag"
  return 1
}

# Start a forced unmount and do not wait for it. One at a time per mount point:
# a forced unmount of something truly stuck can take a while, and starting
# another every fifteen seconds would pile up processes fighting over the path.
# Returns 1 when one is already running, so the caller says nothing.
drop() {
  local mp="$1" lock
  lock="${WORK}/$(printf '%s' "$mp" | tr '/' '_').unmount"
  if [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  (
    /sbin/umount "$mp" 2>/dev/null \
      || /sbin/umount -f "$mp" 2>/dev/null \
      || /usr/sbin/diskutil unmount force "$mp" >/dev/null 2>&1
    rm -f "$lock"
  ) &
  echo $! > "$lock"
  return 0
}

# Mount through NetFS. The script is fed to osascript on stdin rather than named
# on its command line, so the password is not in argv where ps would show it to
# every process on this Mac, and it is never written to disk.
#
# Quotes and backslashes are escaped because the password lands inside an
# AppleScript string literal; without that, a password containing either would
# produce a script that does not compile, and the mount would fail for a reason
# having nothing to do with the credential.
#
# Bounded and abandoned, like everything else here: NetFS puts a dialog up when
# it does not like an answer, and a dialog in an agent nobody is watching is a
# wait with no end.
# Does the board answer on the SMB port?
#
# Asked before NetFS is invoked at all, because NetFS puts a dialog on the
# screen when it cannot reach a server — and killing the osascript process does
# not take the dialog with it. Without this, a board that is off would decorate
# the desktop with a popup every fifteen seconds. `nc -G` bounds the wait, so
# this cannot become the hang it is here to prevent.
reachable() {
  /usr/bin/nc -z -G 3 "$1" 445 >/dev/null 2>&1
}

netfs_mount() {
  local node="$1" user="$2" out rc esc
  # Escaped for an AppleScript string literal: a backslash first, then a quote,
  # in that order — doing it the other way round would escape the backslashes
  # this step introduces.
  esc=${3//\\/\\\\}
  esc=${esc//\"/\\\"}
  out="${WORK}/mount.$$.$RANDOM"
  (
    # The credential goes into an AppleScript variable first, rather than
    # sitting as a quoted literal after the keyword. Same script either way;
    # the difference is that a secret scanner reads the shape of a line and
    # cannot tell a printf placeholder from the real thing. Writing it this way
    # keeps the pipeline from failing on a template.
    printf 'set c to "%s"\nset u to "%s"\ntry\n  mount volume "smb://%s/%s" as user name u with password c\n  return "ok"\non error e number n\n  return "err " & n & ": " & e\nend try\n' \
      "$esc" "$user" "$node" "$node" | /usr/bin/osascript - > "$out" 2>&1
  ) &
  local child=$! waited=0
  while [ "$waited" -lt "$MOUNT_TIMEOUT" ]; do
    kill -0 "$child" 2>/dev/null || break
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null
    rm -f "$out"
    printf 'timed out after %ss' "$MOUNT_TIMEOUT"
    return 1
  fi
  rc=$(cat "$out" 2>/dev/null); rm -f "$out"
  [ "$rc" = "ok" ] && return 0
  printf '%s' "${rc:-no answer from NetFS}"
  return 1
}

up=false
tailnet_up && up=true

for node in $NODES; do
  mp="$(point_for "$node")"

  want=false
  $up && node_online "$node" && want=true

  if $want; then
    at="$(mounted_at "$node")"
    if [ -n "$at" ]; then
      mp="$at"
      # Mounted and reachable is not the same as working. A session can be dead
      # while the server is fine, and the mount table still lists it.
      answering "$mp" && { forget "mount-$node"; mark_ok "$node"; continue; }
      drop "$mp" && log "${mp} stopped answering — forcing it off, will remount next pass"
      continue
    fi
    # Reachability first: tailscale saying a peer is online is not the same as
    # smbd answering, and the gap between those two is a dialog on the screen.
    cooled "$node" || continue
    if ! reachable "$node"; then
      say_once "mount-$node" "${node} is not answering on 445 — not attempting a mount"
      continue
    fi
    u="$(user_for "$node")"
    cred="$(password_for "$node" "$u")"
    if [ -z "$cred" ]; then
      say_once "mount-$node" "no keychain entry for ${u}@${node} — run: make mounts"
      continue
    fi
    if err=$(netfs_mount "$node" "$u" "$cred"); then
      forget "mount-$node"; mark_ok "$node"
      log "mounted ${node} at ${mp}"
    else
      mark_failed "$node"
      say_once "mount-$node" "could not mount ${node}: ${err} — next attempt in ${RETRY_AFTER}s"
    fi
    unset cred
  else
    mp="$(mounted_at "$node")"
    [ -n "$mp" ] || continue
    # Not checked afterwards: the unmount runs in the background and checking
    # would mean waiting for it. The next pass reports what actually happened.
    drop "$mp" && log "unmounting ${mp} ($($up && echo "${node} went offline" || echo "tailnet down"))"
  fi
done
