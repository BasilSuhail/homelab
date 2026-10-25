# Dashboard

Design and decisions for the console at `https://homelab.<tailnet>.ts.net`. It
began on the two Raspberry Pis; this is how it stands on the PC.

**What it is:** one page showing every machine on the tailnet — load, memory,
temperatures, power, fans, drives, GPU, processes — plus a launcher for the
self-hosted apps, a file browser, and who is using what. Activity Monitor for
the homelab, not for one box.

**Split:** frontend by the operator. Backend, agents and deployment here.

---

## The requirement that shapes everything

Machines get added and removed. The dashboard has to pick them up **without a
config edit or a redeploy**, which rules out a hardcoded node list.

**Tailscale is the source of truth.** Every machine worth watching is on the
tailnet, cluster member or not.

```
Tailscale API  →  device list
                    │
                    └─ probe each for an agent
                       answers → render its card
                       silent  → render offline
```

Cluster membership is a label, not a gate: `kubectl get nodes` decides whether
a node shows as `control-plane`, `worker`, or `standalone`. Today that is one
card that matters, homelab; the retired Pis read offline.

---

## The views

- **Fleet.** One card per node: CPU, memory, temperature, power, uptime. Phone
  first. Answers without tapping: up, hot, busy.
- **Node detail.** Per-core CPU, load, memory and swap, disks and their
  temperatures and busy time, the SSD mirror's halves, network, Wi-Fi signal,
  the GPU, voltages, the fans (click one for a slider: Auto, Off, or a speed),
  and the process table.
- **Apps.** Launcher tiles with a live health dot per service, and the
  qBittorrent power switch with the address its traffic leaves from.
- **Files / Storage.** Columns, biggest first, read-only except in a few
  places. See [storage.md](storage.md).
- **Status.** Who is using which app right now, Jellyfin and Kiwix totals, and
  the torrent switch. Under Watching over it, one line in two halves.
  **User data**: how many people, and who has an account in which app
  (Jellyfin and Immich by API key, Nextcloud by occ, Vaultwarden and Gitea
  from their SQLite read-only, the tailnet's people), joined by name;
  `/etc/pi-bot/people.json` (`{"name in an app": "person"}`) joins names that
  differ. **User activity history**: who is on now, or who was on
  last; clicked, it lists who used which app and when over the last 2 days
  (`pi-when content` keeps the log, `/var/lib/pi-when/activity.json`).
  Jellyfin's lines come from Jellyfin's own activity log (exact times, Funnel
  viewers included); the rest from pi-paths, filled from its journal the first
  time.

---

## Data contract

Frontend builds against this (`dashboard/shared/fleet.ts`). Backend guarantees it.

```ts
GET /api/nodes
[{
  id, name, tailscaleIp, online, lastSeen,
  role: "control-plane" | "worker" | "standalone",
  model, os, arch, kernel, uptimeSec,
  cpu:  { cores, usagePct, perCore: number[], loadAvg: [number,number,number] },
  mem:  { totalBytes, usedBytes, availableBytes, usedPct, swapTotalBytes, swapUsedBytes },
  temp: { cpuC, throttled } | null,
  power: { watts, rails } | null,
  disks: [{ mount, device, totalBytes, usedBytes, usedPct }],
  net:   [{ iface, rxBps, txBps }],
  hw: { cpuModel, cpuWatts, fans, volts, driveTemps, driveBusy, mirrors, gpu, wifi } | null,
  capabilities: ("power" | "throttle")[]
}]

GET  /api/nodes/:id/processes?limit=30
GET  /api/apps
GET  /api/status       who is using which app, from /run/pi-status/status.json (pi-when, every 30 s)
POST /api/refresh      the refresh button: asks the PC for a scan now (pi-status-now.path), waits for it
GET  /api/torrent      qBittorrent's state and its tunnel address; POST switches it
GET  /api/credentials  what the console holds and cannot renew itself
GET  /healthz          the one path open without signing in
```

Two rules the design has to respect:

1. **`capabilities` and nulls decide what renders.** A card must look right
   with tiles missing, not broken.
2. **`online: false` is normal, not an error.** A machine being off is an
   ordinary state and should not look like a failure.

---

## Where the numbers come from

Two agents on each machine, both installed by `agent/install.sh`.

| What | Source |
|---|---|
| CPU, load, memory, disks, network, processes | **Glances** (`glances -w`), JSON at `/api/4/all`, on port 61208, **loopback only** |
| CPU package power | RAPL energy counter; `agent/install.sh` adds a udev rule to make it readable |
| CPU, board and drive temperatures, voltages, fans | hwmon: `k10temp`, the it87 chip, `drivetemp`, `nvme` |
| Fan control | the shim writes the PWM; `pi-fans.service` holds the curve ([pc.md](pc.md#fans)) |
| GPU | `nvidia-smi` |
| SSD mirror | sysfs, `/sys/block/md*` |
| Wi-Fi signal | `/proc/net/wireless` |
| Files, thumbnails | the shim's file routes, which need `X-Agent-Token` |

The shim is `agent/pi-metrics.py`, `pi-metrics.service`, on port 9101.
`/metrics` and `/health` are open (Uptime Kuma reads them); everything that
reads or changes a file needs the token in `/etc/pi/agent-token`, which only
the console holds. On a Pi it also read power and throttling from `vcgencmd`,
which is why the `power` and `throttle` capabilities exist.

---

## Deployment

The console runs **in k3s on homelab**, `make dashboard-k8s` or
`deploy/install-dashboard-k8s.sh`. `k8s/dashboard.yaml`: Namespace,
ServiceAccount, ClusterRoleBinding, Deployment, Service, Ingress.
`k8s/qbittorrent.yaml` adds a Role that lets it scale that one Deployment and
nothing else.

Things about it that are not obvious:

- **No registry.** homelab builds the image with buildkit straight into k3s'
  containerd. `buildkitd` is not enabled at boot: it runs for the length of a
  build. The tag is the commit, because reusing a tag under
  `imagePullPolicy: IfNotPresent` leaves the old image in place and reports
  success.
- **`hostNetwork: true`.** Glances and the shim listen on the host, and Glances
  on loopback only. `dial.ts` rewrites this machine's own tailnet address to
  loopback, which with the host's network is how the pod reaches them.
- **Signing in.** Passkeys (Face ID / Touch ID) or the admin password, a
  session cookie for a day, `server/lib/login.ts`. Nothing but `/healthz` is
  served without one, so a missing password and no passkeys leave the console
  shut, not open. POSTs also need an `X-Pi-Console: 1` header. Passkeys and the
  session key live in `/1) Archive/Apps/Console`.
- **Node discovery** uses the Tailscale API through a read-only OAuth client
  (`deploy/dashboard-oauth.sh`), which never expires and can only read devices.
  The older 90-day API key still works; when one is set, the Fleet strip shows
  its expiry date, grey, then orange inside two weeks, then red.
- **Cluster credentials.** kubelet projects a token for the ServiceAccount, and
  `kube.ts` reads that when the environment carries nothing.

`make dashboard` still installs the old systemd unit as the way back. Not both.

---

## As built

| | |
|---|---|
| Server | `node:http`, no runtime dependencies |
| Client | Preact, built with Vite |
| Reachable at | `https://homelab.<tailnet>.ts.net`, tailnet only, real certificate, `tailscale serve` to Traefik on :80 |
| Runs as | k3s Deployment `pi-console` in namespace `pi` |
| Polling | 3s for the fleet, 15s for app health and qBittorrent |

## Decisions

- **Retention.** Live only. Sparklines keep a short in-memory buffer per node,
  lost on reload. History past a reboot would need a store on the server and
  has not been worth it.
- **Auth.** Tailnet-only was the whole of it until the security audit (issue
  #204): the console manages files, so it got a login. Details above and in
  [pc.md](pc.md#security).
- **Launcher.** `server/apps.json`, editable without a rebuild. It still lists
  the retired Pis' OSINT tiles, which read as down.
