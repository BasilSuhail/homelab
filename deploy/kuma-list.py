#!/usr/bin/env python3
"""Every Uptime Kuma monitor and its last result, read from Kuma's database.

Read-only: the database is opened with mode=ro, so this is safe while Kuma
runs. The monitor list is not kept in this repository (see
install-uptime-kuma.sh); this is how it is checked from SSH.

  sudo python3 deploy/kuma-list.py [path/to/kuma.db]
"""
import sqlite3
import sys
import urllib.parse
from datetime import datetime

DB = sys.argv[1] if len(sys.argv) > 1 else "/1) Archive/Apps/Uptime/data/kuma.db"
STATUS = {0: "DOWN", 1: "up", 2: "pending", 3: "maint"}

con = sqlite3.connect(f"file:{urllib.parse.quote(DB)}?mode=ro", uri=True)
rows = con.execute(
    """
    select m.id, m.name, m.type, coalesce(m.url, m.hostname, ''), coalesce(m.keyword, ''), m.active,
           h.status, h.time, h.msg
    from monitor m
    left join heartbeat h on h.id = (
        select id from heartbeat where monitor_id = m.id order by time desc limit 1)
    order by m.id
    """
).fetchall()

for mid, name, kind, target, keyword, active, status, time, msg in rows:
    state = "paused" if not active else STATUS.get(status, "none")
    when = ""
    if time:
        try:
            when = datetime.fromisoformat(str(time)).strftime("%d %b %H:%M")
        except ValueError:
            when = str(time)
    print(f"{mid:>3}  {state:<7} {name}")
    print(f"       {kind}  {target}" + (f"  [keyword: {keyword}]" if keyword else ""))
    if state not in ("up", "paused") and msg:
        print(f"       last: {when}  {msg[:120]}")
print(f"\n{len(rows)} monitors")
