#!/usr/bin/env python3
"""Records how each family device reaches the apps, whenever one is in use.

Every app is its own Tailscale proxy. A device either talks to it directly,
or through a Tailscale relay server (DERP), which is slow enough to make video
stutter and uploads crawl. Which one happens can only be seen while the device
is actually using the app, so this runs every minute and writes one line per
device in use: the path, and how fast data is moving each way.

Read it with:  journalctl -u pi-paths --since today -o short

Stdlib only. Changes nothing; counters from the last run are kept in
/run/pi-paths.json to turn byte totals into a speed.
"""

import ipaddress
import json
import os
import socket
import subprocess
import time

STATE = os.environ.get("PATHS_STATE", "/run/pi-paths.json")
KUBECTL = ["k3s", "kubectl"]
SOCKET = "/tmp/tailscaled.sock"
# Below this a device is only keeping the connection alive, not using the app.
IDLE_MBIT = 0.05


def run(args, timeout=20):
    out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "exit %d" % out.returncode)
    return out.stdout


def proxies():
    """(app, namespace, pod) for every running app proxy."""
    pods = json.loads(run(KUBECTL + ["get", "pods", "-A", "-l", "tailscale.com/parent-resource", "-o", "json"]))
    for p in pods["items"]:
        if p["status"].get("phase") == "Running":
            m = p["metadata"]
            yield m["labels"]["tailscale.com/parent-resource"], m["namespace"], m["name"]


def status(ns, pod):
    return json.loads(run(KUBECTL + ["-n", ns, "exec", pod, "-c", "tailscale", "--",
                                     "tailscale", "--socket=" + SOCKET, "status", "--json"]))


def path(peer):
    addr = peer.get("CurAddr") or ""
    if addr:
        host = addr.rsplit(":", 1)[0].strip("[]")
        try:
            home = ipaddress.ip_address(host).is_private
        except ValueError:
            home = False
        return ("direct, at home" if home else "direct") + " " + addr
    if peer.get("PeerRelay"):
        return "peer relay " + peer["PeerRelay"]
    return "RELAY " + (peer.get("Relay") or "?")


def main():
    try:
        with open(STATE) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}
    now = time.time()
    me = socket.gethostname()
    seen = {}

    for app, ns, pod in proxies():
        try:
            st = status(ns, pod)
        except (RuntimeError, subprocess.SubprocessError, ValueError) as err:
            print("%s: no status (%s)" % (app, err), flush=True)
            continue
        users = st.get("User") or {}
        for peer in (st.get("Peer") or {}).values():
            if peer.get("Tags") or peer.get("HostName") == me:
                continue
            key = "%s/%s" % (app, peer.get("ID") or peer.get("PublicKey"))
            rx, tx = peer.get("RxBytes", 0), peer.get("TxBytes", 0)
            seen[key] = {"rx": rx, "tx": tx, "at": now}
            old = prev.get(key)
            if not old or now <= old["at"] or rx < old["rx"] or tx < old["tx"]:
                continue
            dt = now - old["at"]
            to_them = (tx - old["tx"]) * 8 / dt / 1e6
            from_them = (rx - old["rx"]) * 8 / dt / 1e6
            if max(to_them, from_them) < IDLE_MBIT:
                continue
            user = users.get(str(peer.get("UserID"))) or {}
            who = user.get("DisplayName") or user.get("LoginName") or "?"
            print("%-10s %-28s %-40s to them %5.1f Mbit/s  from them %5.1f Mbit/s" % (
                app, "%s / %s" % (who, peer.get("HostName", "?")), path(peer), to_them, from_them), flush=True)

    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(seen, f)
    os.replace(tmp, STATE)


if __name__ == "__main__":
    main()
