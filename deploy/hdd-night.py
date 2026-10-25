#!/usr/bin/env python3
"""One night of hard-drive temperatures, to pick the bottom fan's start point.

In the closed case the drives sit around 35° doing nothing, so a fan rule at
35 runs nearly all the time. This measures what "normal" is. For the night,
the fan's drive trigger moves up to 42° (still a safe ceiling: the drives are
rated to 60°), so the fan does not hide the drives' own behaviour; the CPU
and GPU rules are untouched. At 12:00 the old setting comes back and a report
goes to Discord with a recommended start temperature.

  sudo python3 deploy/hdd-night.py start    record from now, trigger at 42° for the night
  sudo python3 deploy/hdd-night.py report   the report so far, printed
  sudo python3 deploy/hdd-night.py end      stop now: restore the setting, print and post the report

Hard drives only (rotational). Readings: /var/lib/pi-hdd/night.jsonl.
Stdlib only.
"""

import datetime
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

LOG = "/var/lib/pi-hdd/night.jsonl"
FANS_CONF = "/etc/pi-fans.json"
BACKUP = "/etc/pi-fans.json.before-night"
FANS_STATE = "/run/pi-fans.json"
REPORT_ENV = "/etc/pi-report/env"
BIN = "/usr/local/lib/pi/hdd-night"
UNITS = "/etc/systemd/system"
NIGHT_ON, NIGHT_OFF = 42, 40
CANDIDATES = range(35, 43)


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def drives():
    """[(block, model, °C)] for every spinning drive drivetemp can read."""
    out = []
    for h in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        if read(h + "/name") != "drivetemp":
            continue
        blocks = glob.glob(h + "/device/block/*")
        block = os.path.basename(blocks[0]) if blocks else None
        if not block or read(f"/sys/block/{block}/queue/rotational") != "1":
            continue
        raw = read(h + "/temp1_input")
        if raw is None:
            continue
        out.append((block, (read(h + "/device/model") or block).strip(), int(raw) / 1000))
    return out


def cpu_temp():
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        if read(h + "/name") in ("k10temp", "coretemp"):
            raw = read(h + "/temp1_input")
            return int(raw) / 1000 if raw else None
    return None


def bottom_fan():
    try:
        with open(FANS_STATE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        return None
    for fan in state.get("fans", {}).values():
        if fan.get("label", "").lower() == "intake bottom":
            return fan.get("duty")
    return None


def log():
    row = {"t": int(time.time()), "cpu": cpu_temp(), "bottom": bottom_fan(),
           "drives": {model: temp for _, model, temp in drives()}}
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(json.dumps(row) + "\n")


def rows():
    try:
        with open(LOG) as f:
            return [json.loads(l) for l in f if l.strip()]
    except OSError:
        return []


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def report():
    data = rows()
    if len(data) < 10:
        return "Not enough readings yet (%d). It records one a minute." % len(data)
    start = datetime.datetime.fromtimestamp(data[0]["t"]).strftime("%H:%M")
    end = datetime.datetime.fromtimestamp(data[-1]["t"]).strftime("%H:%M")
    lines = ["**Hard drives overnight** (%s–%s, %d readings, one a minute)" % (start, end, len(data)), ""]
    models = sorted({m for r in data for m in r["drives"]})
    hottest = []
    for m in models:
        temps = [r["drives"][m] for r in data if m in r["drives"]]
        hottest += temps
        lines.append("• %s: lowest %.0f°, normal %.0f°, 95%% of the time under %.0f°, peak %.0f°" % (
            m, min(temps), pct(temps, 50), pct(temps, 95), max(temps)))
    # Per minute, the hotter drive decides, as it does for the fan.
    per_min = [max(r["drives"].values()) for r in data if r["drives"]]
    lines += ["", "Minutes the bottom fan would have run, by start temperature:"]
    for c in CANDIDATES:
        n = sum(1 for t in per_min if t >= c)
        lines.append("• %d°: %d min (%d%% of the night)" % (c, n, round(100 * n / len(per_min))))
    # One degree above where the drives sit 95% of the time: the fan stays off
    # for normal, and starts the moment they run warmer than normal.
    rec = max(35, min(42, int(pct(per_min, 95)) + 1))
    lines += ["", "**Recommended start: %d°** (off again below %d°), one degree above where the drives sit "
              "95%% of the time." % (rec, rec - 2)]
    return "\n".join(lines)


def post(text):
    hook = None
    for line in (read(REPORT_ENV) or "").splitlines():
        if line.startswith("DISCORD_WEBHOOK="):
            hook = line.split("=", 1)[1].strip().strip('"')
    if not hook:
        return
    req = urllib.request.Request(hook, data=json.dumps({"content": text[:1900]}).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "hdd-night"})
    urllib.request.urlopen(req, timeout=20).read()


def set_drive_trigger(on, off):
    with open(FANS_CONF) as f:
        conf = json.load(f)
    conf["case"]["on"]["drive"], conf["case"]["off"]["drive"] = on, off
    tmp = FANS_CONF + ".tmp"
    with open(tmp, "w") as f:
        json.dump(conf, f, indent=2)
    os.replace(tmp, FANS_CONF)
    subprocess.run(["systemctl", "restart", "pi-fans"], check=False)


def unit(name, body):
    with open(os.path.join(UNITS, name), "w") as f:
        f.write(body)


def start():
    os.makedirs("/usr/local/lib/pi", exist_ok=True)
    shutil.copy(os.path.abspath(__file__), BIN)
    os.chmod(BIN, 0o755)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    open(LOG, "w").close()
    if not os.path.exists(BACKUP):
        shutil.copy(FANS_CONF, BACKUP)
    unit("pi-hdd-log.service", f"[Unit]\nDescription=Hard drive temperatures, one reading\n\n[Service]\nType=oneshot\nExecStart={BIN} log\n")
    unit("pi-hdd-log.timer", "[Unit]\nDescription=Hard drive temperatures, every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=5s\n\n[Install]\nWantedBy=timers.target\n")
    unit("pi-hdd-end.service", f"[Unit]\nDescription=End the hard drive night: restore the fan setting, post the report\n\n[Service]\nType=oneshot\nExecStart={BIN} end\n")
    unit("pi-hdd-end.timer", "[Unit]\nDescription=End the hard drive night at 12:00\n\n[Timer]\nOnCalendar=*-*-* 12:00:00\n\n[Install]\nWantedBy=timers.target\n")
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", "pi-hdd-log.timer", "pi-hdd-end.timer"], check=True)
    set_drive_trigger(NIGHT_ON, NIGHT_OFF)
    log()
    now = drives()
    print("Recording every minute until 12:00.")
    print("Bottom fan's drive trigger for tonight: %d° (off below %d°). CPU and GPU rules unchanged." % (NIGHT_ON, NIGHT_OFF))
    for _, model, t in now:
        print("  %-24s %.0f°" % (model, t))
    print("Report so far:  sudo python3 deploy/hdd-night.py report")
    print("Stop early:     sudo python3 deploy/hdd-night.py end")


def end():
    subprocess.run(["systemctl", "disable", "--now", "pi-hdd-log.timer", "pi-hdd-end.timer"], check=False)
    if os.path.exists(BACKUP):
        shutil.move(BACKUP, FANS_CONF)
        subprocess.run(["systemctl", "restart", "pi-fans"], check=False)
    text = report() + "\n\nThe bottom fan's drive trigger is back to its usual setting."
    print(text)
    post(text)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    if os.geteuid() != 0 and cmd != "report":
        sys.exit("run with sudo")
    {"start": start, "log": log, "report": lambda: print(report()), "end": end}.get(cmd, lambda: sys.exit("start, report or end"))()
