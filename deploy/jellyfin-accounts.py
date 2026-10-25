#!/usr/bin/env python3
"""Jellyfin's own locks on its accounts, set the same way every time.

    sudo python3 deploy/jellyfin-accounts.py            show each account
    sudo python3 deploy/jellyfin-accounts.py --apply    set the locks below
    sudo python3 deploy/jellyfin-accounts.py --unlock NAME

With nothing set, Jellyfin never locks an account: its code only counts
wrong passwords when LoginAttemptsBeforeLockout has a value, and every
account here had none. On a login page that Funnel puts on the internet that
means unlimited guesses at a slow pace, below what jellyfin-guard watches for.

--apply sets:
  - 5 wrong passwords in a row disable a normal account, 3 an admin. A right
    password resets the count. A disabled account is switched back on here
    with --unlock, or by an admin in Dashboard > Users.
  - Admins may not sign in from the internet, only from home and the tailnet.
    That needs Jellyfin to see each visitor's real address, which
    deploy/install-jellyfin-edge.sh sets up (KnownProxies, LocalNetworkSubnets).
    Before that every visitor looks local, so this changes nothing yet.

Talks to Jellyfin's API with the key pi-when uses (JELLYFIN_API_KEY in
/etc/pi-bot/env). An API key still works while every admin is locked out,
which is what --unlock relies on. Stdlib only; the key is never printed.
"""
import json
import subprocess
import sys
import urllib.request

ENV = "/etc/pi-bot/env"
USER_LOCKOUT, ADMIN_LOCKOUT = 5, 3


def key():
    for line in open(ENV):
        if line.startswith("JELLYFIN_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit("no JELLYFIN_API_KEY in " + ENV)


def base():
    ip = subprocess.run(["k3s", "kubectl", "-n", "pi", "get", "svc", "jellyfin", "-o",
                         "jsonpath={.spec.clusterIP}"], capture_output=True, text=True, check=True).stdout
    return "http://%s" % ip.strip()


def api(path, body=None):
    req = urllib.request.Request(base() + path, method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": 'MediaBrowser Token="%s"' % KEY,
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = r.read()
        return json.loads(data) if data else None


def show(users):
    for u in users:
        p = u["Policy"]
        print("  %-24s %-6s lockout after %-5s from the internet: %-3s %s" % (
            u["Name"], "admin" if p["IsAdministrator"] else "user",
            p.get("LoginAttemptsBeforeLockout") if p.get("LoginAttemptsBeforeLockout", -1) > 0 else "never",
            "yes" if p["EnableRemoteAccess"] else "no", "(DISABLED)" if p["IsDisabled"] else ""))


def main():
    global KEY
    KEY = key()
    users = api("/Users")
    if "--apply" in sys.argv:
        for u in users:
            p = u["Policy"]
            admin = p["IsAdministrator"]
            p["LoginAttemptsBeforeLockout"] = ADMIN_LOCKOUT if admin else USER_LOCKOUT
            if admin:
                p["EnableRemoteAccess"] = False
            api("/Users/%s/Policy" % u["Id"], p)
        users = api("/Users")
    elif "--unlock" in sys.argv:
        name = sys.argv[sys.argv.index("--unlock") + 1]
        match = [u for u in users if u["Name"].lower() == name.lower()]
        if not match:
            sys.exit("no account called " + name)
        p = match[0]["Policy"]
        p["IsDisabled"] = False
        api("/Users/%s/Policy" % match[0]["Id"], p)
        users = api("/Users")
    show(users)


if __name__ == "__main__":
    main()
