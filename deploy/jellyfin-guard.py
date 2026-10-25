#!/usr/bin/env python3
"""Switches Jellyfin's public door (Tailscale Funnel) off when strangers knock.

With Funnel on, Jellyfin's login page is on the internet. Family use it; bots
find it. Every minute this reads Jellyfin's server log for denied logins, and
switches Funnel off, posting to Discord, when:

  someone tries usernames that are not Jellyfin accounts   (GUARD_UNKNOWN, 2 an hour)
  or there are many failed logins in a short time          (GUARD_FAILS, 5 in 15 minutes)

Only Funnel goes off: family on Tailscale keep watching as before. A login
from a device an account has never used is posted too, without switching
anything off, since it may be family on a new phone.

  --summary   the last 24 hours as lines, for the morning report
  --dry       say what would happen; change nothing, post nothing

Reads the server log through kubectl, and jellyfin.db read-only for the
accounts and the devices they sign in from. Config: /etc/pi-report/env (the Discord webhook
the morning report uses), optional /etc/jellyfin-guard.env. State:
/var/lib/jellyfin-guard/state.json. Stdlib only.
"""

import datetime
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request

STATE = os.environ.get("GUARD_STATE", "/var/lib/jellyfin-guard/state.json")
REPORT_ENV = os.environ.get("REPORT_ENV", "/etc/pi-report/env")
GUARD_ENV = os.environ.get("GUARD_ENV", "/etc/jellyfin-guard.env")
APPS_DIR = os.environ.get("APPS_DIR", "/1) Archive/Apps")
KUBECTL = ["k3s", "kubectl", "-n", "pi"]
DENIED = re.compile(r"Authentication request for (.+?) has been denied")
INGRESS = "jellyfin"
FUNNEL = "tailscale.com/funnel"


def env_file(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    # A note after the value: "5   # failed logins".
                    if " #" in v:
                        v = v.split(" #", 1)[0]
                    out[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return out


CONF = {**env_file(GUARD_ENV), **os.environ}
UNKNOWN_PER_HOUR = int(CONF.get("GUARD_UNKNOWN", 2))
FAILS = int(CONF.get("GUARD_FAILS", 5))
FAILS_MIN = int(CONF.get("GUARD_FAILS_MINUTES", 15))


def db_path():
    if CONF.get("JELLYFIN_DB"):
        return CONF["JELLYFIN_DB"]
    hits = glob.glob(os.path.join(APPS_DIR, "Jellyfin", "**", "jellyfin.db"), recursive=True)
    if not hits:
        sys.exit("jellyfin.db not found under %s/Jellyfin" % APPS_DIR)
    return hits[0]


def utc(minutes_ago):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)
    return t.strftime("%Y-%m-%d %H:%M:%S")


def after(name, word):
    """'Failed login try from bob' -> 'bob'; '+' is how some apps send spaces."""
    i = name.rfind(word)
    return (name[i + len(word):] if i >= 0 else name).strip().replace("+", " ")


class Log:
    def __init__(self, path):
        self.db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=10)
        self.users = {u.lower() for (u,) in self.db.execute("select Username from Users")}

    def rows(self, kind, since):
        return self.db.execute(
            "select Id, Name, coalesce(UserId, ''), DateCreated from ActivityLogs "
            "where Type = ? and replace(DateCreated, 'T', ' ') >= ? order by Id", (kind, since)).fetchall()

    def failures(self, since_ts):
        """[(username, known)] for failed logins since a Unix time.

        From Jellyfin's server log, not the activity log: the activity log
        leaves out tries with usernames that are not accounts, which is
        exactly what a stranger sends."""
        since = datetime.datetime.fromtimestamp(since_ts, datetime.timezone.utc)
        out = subprocess.run(KUBECTL + ["logs", "deploy/jellyfin", "--since-time=" + since.strftime("%Y-%m-%dT%H:%M:%SZ")],
                             capture_output=True, text=True, timeout=60).stdout
        return [(who, who.lower() in self.users) for who in DENIED.findall(out)]

    def sessions(self, since):
        """[(id, username, device, time)] for 'X is online from Y' entries."""
        out = []
        for rid, name, _, at in self.rows("SessionStarted", since):
            if " is online from " in name:
                who, dev = name.split(" is online from ", 1)
                out.append((rid, who.strip(), dev.strip().replace("+", " "), at))
        return out


def funnel_on():
    out = subprocess.run(KUBECTL + ["get", "ingress", INGRESS, "-o", "json"],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        return False
    return json.loads(out.stdout)["metadata"].get("annotations", {}).get(FUNNEL) == "true"


def funnel_off():
    subprocess.run(KUBECTL + ["annotate", "ingress", INGRESS, FUNNEL + "-"],
                   capture_output=True, text=True, timeout=30)


def post(text):
    hook = env_file(REPORT_ENV).get("DISCORD_WEBHOOK")
    if not hook:
        print("no DISCORD_WEBHOOK in %s; not posted" % REPORT_ENV, file=sys.stderr)
        return
    req = urllib.request.Request(hook, data=json.dumps({"content": text[:1900]}).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "jellyfin-guard"})
    urllib.request.urlopen(req, timeout=20).read()


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def check(dry):
    log, state = Log(db_path()), load()
    first = "devices" not in state
    devices = set(state.get("devices", []))
    seen_first = state.get("first_seen", {})
    msgs = []

    # Devices: the first run learns what is there, later runs report new ones.
    now = utc(0)
    for rid, who, dev, at in log.sessions(state.get("sessions_since", "0000")):
        key = "%s|%s" % (who.lower(), dev.lower())
        if key not in devices:
            devices.add(key)
            if not first:
                seen_first[key] = at
                msgs.append("New device: **%s** signed in from **%s** (first time for this account)" % (who, dev))
    state["sessions_since"] = now

    # Strangers: only counted since Funnel last went off, so switching it back
    # on is not undone at once by the knocks that switched it off.
    now_ts = time.time()
    floor = state.get("off_ts", 0)
    unknown = [w for w, k in log.failures(max(now_ts - 3600, floor)) if not k]
    fails = log.failures(max(now_ts - FAILS_MIN * 60, floor))
    reason = None
    if len(unknown) >= UNKNOWN_PER_HOUR:
        reason = "%d login tries with usernames that are not accounts in the last hour (%s)" % (
            len(unknown), ", ".join(sorted(set(unknown)))[:200])
    elif len(fails) >= FAILS:
        reason = "%d failed logins in %d minutes (%s)" % (
            len(fails), FAILS_MIN, ", ".join(sorted({w for w, _ in fails}))[:200])

    if reason and funnel_on():
        if dry:
            print("would switch Funnel off: " + reason)
        else:
            funnel_off()
            state["off_ts"] = now_ts
            state.setdefault("events", []).append([int(time.time()), reason])
            msgs.insert(0, ("🔒 **Jellyfin's public access is OFF.** %s.\nFamily on Tailscale are not affected. "
                            "Back on, from homelab:\n`sudo k3s kubectl -n pi annotate ingress jellyfin "
                            "tailscale.com/funnel=true`") % reason)

    state["devices"] = sorted(devices)
    state["first_seen"] = seen_first
    state["events"] = [e for e in state.get("events", []) if e[0] > time.time() - 7 * 86400]
    for m in msgs:
        print(m)
        if not dry:
            post("**Jellyfin guard**\n" + m)
    if not dry:
        save(state)


def summary():
    """Lines for the morning report: quiet when the day was quiet."""
    log, state = Log(db_path()), load()
    lines = []
    fails = log.failures(time.time() - 86400)
    if fails:
        by = {}
        for who, known in fails:
            by.setdefault((who, known), 0)
            by[(who, known)] += 1
        parts = ["%s%s ×%d" % (w, "" if k else " (not an account)", n) for (w, k), n in sorted(by.items())]
        lines.append("%d failed logins: %s" % (len(fails), ", ".join(parts)[:300]))
    since = utc(24 * 60)
    new = [k for k, at in state.get("first_seen", {}).items() if at >= since]
    if new:
        lines.append("New devices: " + ", ".join(k.replace("|", " on ") for k in new)[:300])
    for at, reason in state.get("events", []):
        if at > time.time() - 86400:
            lines.append("Public access switched off at %s: %s" % (
                datetime.datetime.fromtimestamp(at).strftime("%H:%M"), reason))
    lines.append("Public access (Funnel): %s" % ("on" if funnel_on() else "off"))
    if len(lines) == 1:
        return []
    return lines


if __name__ == "__main__":
    if "--summary" in sys.argv:
        print("\n".join(summary()))
    else:
        check("--dry" in sys.argv)
