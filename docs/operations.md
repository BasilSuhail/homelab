# Running it

How the PC is laid out and run day to day: the disks, deploying, and the
services. The story and the overview are in the [README](../README.md).

Issue and PR numbers in these docs (#198 and so on) point at the private repo
this snapshot was taken from; they will not open here.

## The disks

Two rules, and everything else follows from them.

**A drive is a folder.** Open the PC's share and you see its drives, named for
what they are. Nothing that is not a drive sits beside them.

```
homelab/
├── SSD-250GB/          Debian and "1) Archive": every app's settings and databases
├── SSD-512GB/          the mirror's spare space, gone with the failed T-Force
├── HDD-6TB/            HDD1: Jellyfin's media, downloads
├── HDD-6TB-2/          HDD2: Nextcloud, Immich, Gitea's repos, ArchiveBox, Kiwix, backups
└── HDD-1TB/            HDD3: the old NTFS disk, kept as it was
```

**The split is by how a file is read, not by what it is called.** Anything read
at random — settings, databases, caches, artwork — lives on the SSD under
`/1) Archive/Apps/<App>`. Anything you would recognise as a file — films,
photos, `.zim` archives, downloads — lives on a hard drive, mostly HDD2 at
`/srv/hdd2/<App>`. A database is called data and behaves like an app: on a
spinning disk it makes the whole interface feel slow.

`1) Archive` is a directory, not a mount or a shortcut. It sorts first because
digits sort before letters. Which drive holds what, and the SSD mirror:
[`pc.md`](pc.md#disks).

## Deploying

On homelab, in its own shell (SSH from the Mac or the phone):

```bash
cd ~/homelab && git pull
```

```bash
sudo pi-when now
```

Then the script for what changed, for example
`bash deploy/install-dashboard-k8s.sh ~/homelab/dashboard`. `pi-when now` says who is
using which app; if someone is watching or uploading on the app being touched,
wait.

The `make` targets do the same from the Mac: each one SSHes to homelab, takes its
checkout to the branch the Mac is on, and runs the script.

```bash
make dashboard-k8s          # the console, as a k3s Deployment
make agents                 # if agent/ changed
make check                  # services up, console answering
```

`make dashboard` still installs the old systemd unit and is kept as the way
back. Do not run both. `make` lists the rest. The security scripts (firewall,
updates, SSH, logins) have no `make` target; they are listed in
[`pc.md`](pc.md#security).

Details and troubleshooting: [`deploy.md`](deploy.md).

## The services

Each on its own tailnet name with a real certificate, all reachable from a
phone with Tailscale on. They are tiles in the console's Apps tab.

| | | |
|---|---|---|
| Console | `homelab.<tailnet>.ts.net` | the PC, the files, the launcher. `make dashboard-k8s` |
| Uptime | `uptime.<tailnet>.ts.net` | `make uptime` |
| Vault | `vault.<tailnet>.ts.net` | `make vault` |
| Nextcloud | `cloud.<tailnet>.ts.net` | `make cloud` |
| Jellyfin | `jellyfin.<tailnet>.ts.net` | `make media`. Also on the internet (Funnel) and on the home network for the TV, port 8096 |
| Kiwix | `kiwix.<tailnet>.ts.net` | `make media` |
| Photos | `photos.<tailnet>.ts.net` | `make photos` |
| qBittorrent | `torrent.<tailnet>.ts.net` | `make torrent` — off by default |
| ArchiveBox | `archivebox.<tailnet>.ts.net` | `make archivebox` |
| Gitea | `git.<tailnet>.ts.net` | `make gitea` |
| Local AI | Discord | `make ai`, answers in its own channel through `pi-bot` |

<details>
<summary><strong>Storage — one-time setup</strong></summary>

Already done on homelab. On a fresh install, from the Mac, in order:

```bash
make bootstrap NODE=homelab
```

```bash
make agents
```

```bash
make archive
```

```bash
make automount
```

```bash
make pool
```

```bash
make browse
```

Then the services, once the Tailscale operator exists — `make uptime` installs
it and everything after that reuses it:

```bash
make uptime
```

```bash
make vault
```

```bash
make media
```

The agent's file routes need the token in `/etc/pi/agent-token`, which only
the console holds. Without it they answer 401. To check them on homelab:

```bash
T=$(sudo sed -n 's/^AGENT_TOKEN=//p' /etc/pi/agent-token)
```

```bash
curl -s -H "X-Agent-Token: $T" localhost:9101/files
```

</details>

<details>
<summary><strong>Storage — mounting the disks in Finder</strong></summary>

Optional. The PC first, then the Mac.

```bash
make samba NODE=homelab
```

```bash
make mounts
```

`make mounts` asks for the SMB password once, stores it in the login
keychain, reads it back and refuses to continue if what comes back is not what
you typed. Nothing needs `sudo`. You do not run it again on this Mac unless you
change the SMB password.

After that the share appears in Finder as `homelab` whenever Tailscale is up, and
unmounts when it goes down — across reboots, sleep and dropped wifi, with
nothing to click.

By hand instead, ⌘K in Finder:

```
smb://homelab/homelab
```

Watch what the agent is doing:

```bash
tail -f ~/Library/Logs/pi.share-mounts.log
```

</details>

<details>
<summary><strong>Storage — day to day</strong></summary>

Drag files from Finder onto a column in the console to upload them. Right-click
anything for the same actions the bar offers.

After plugging a drive in, nothing — `make automount` handles it. Only if a
drive was mounted by hand:

```bash
make browse
```

What each does: [`storage.md`](storage.md).

</details>

<details>
<summary><strong>Console — signing in, and the Tailscale client</strong></summary>

**Signing in.** Face ID / Touch ID (passkeys), or the admin password as a
backup. One password covers the console and qBittorrent; set
or change it on homelab:

```bash
sudo bash deploy/set-admin-password.sh
```

`sudo bash deploy/console-login.sh passkeys-only` turns the password off,
`password-too` back on. Lost every device: `password-too`, sign in with the
password, set up Face ID again on the sign-in page.

**Which machines exist.** A pod has no tailscaled socket, so the console asks
Tailscale's web API, through a read-only OAuth client (Devices: Core, read
only). It never expires and can only read devices. Set up or replaced with:

```bash
bash deploy/dashboard-oauth.sh
```

It asks for the client ID and secret, swaps the `pi-console-tailscale`
Secret, restarts the console and checks it can list devices. Neither value is
echoed or written to disk. Make the client at Tailscale's admin page, Settings,
OAuth clients.

The older 90-day API key still works if set, and the Fleet strip then shows
its expiry date. With the OAuth client there is nothing to renew.

</details>

<details>
<summary><strong>Uptime Kuma — alerts when something dies</strong></summary>

```bash
make uptime
```

Puts Uptime Kuma 2.x on homelab at its own tailnet name,
`https://uptime.<tailnet>.ts.net`, so it does not have to share the console's
URL. 21 monitors today: the drives, the apps, the PC's ping, SSH and Samba,
DNS and the internet.

**Once, in the Tailscale admin console, before the first run.** The operator
registers machines on your tailnet, so it needs its own credentials:

1. Access Controls: add tag owners for `tag:k8s-operator` and `tag:k8s`.
2. Settings, then OAuth clients, then Generate. Give it **write** scope on
   Devices Core and on Auth Keys, tagged `tag:k8s-operator`.

`make uptime` asks for the client ID and secret once and puts them straight
into a Secret. Neither is echoed and neither lands on the PC's disk. Do not
revoke that client: every app drops off the tailnet with it.

**Once, in Discord, for alerts.** Uptime Kuma can show red on a page, but it
cannot reach you without somewhere to send to:

1. Pick or make a channel for alerts.
2. Gear icon next to the channel, then Integrations, then Webhooks.
3. New Webhook, name it, then Copy Webhook URL.

**Then, in Uptime Kuma itself.** The first visit asks you to create an admin
account. After that, Settings, then Notifications, then Setup Notification,
choose Discord, paste the URL, hit Test, and tick Default enabled so new
monitors use it without being asked.

The webhook is a credential and belongs only in Kuma's own settings. It never
goes in this repo.

**Adding monitors.** Kuma 2.x has no Settings > Backup page, so there is no
JSON import or export: Add New Monitor, or Clone on an existing one. Every
monitor lives in `/1) Archive/Apps/Uptime/data/kuma.db`; read them over SSH
with `sudo python3 deploy/kuma-list.py`.

**Worth monitoring**: the console's `/healthz` and the shim's `/metrics` on
9101, both open without a login. Glances on 61208 answers only on homelab itself
now (`--bind 127.0.0.1`), so Kuma cannot reach it; the shim's file routes need
the console's token.

</details>

<details>
<summary><strong>Vaultwarden — a copy of the password vault</strong></summary>

```bash
make vault
```

Needs `make uptime` first, which installs the Tailscale operator this uses to
get a name of its own. Lands at `https://vault.<tailnet>.ts.net`.

**What this is, and is not.** Bitwarden's own service stays the source of
truth and is not touched. This holds a copy, imported once and left alone.
Nothing syncs between them, so the copy drifts the moment a password changes
in one and not the other.

A Bitwarden client points at one server at a time, so the two do not fight:
keep the browser extension and desktop app on bitwarden.com as they are, and
use Vaultwarden through its own web page.

**After the deploy, in this order:**

1. Open the URL and create an account. Use a different master password: this
   is not the vault you already have.
2. In Bitwarden, Tools, Export vault, format `.json`. Here, Tools, Import
   data, "Bitwarden (json)". Delete the export afterwards, it is plain text.
3. Close registration:

```bash
sudo k3s kubectl -n pi patch configmap vaultwarden-config --type merge -p '{"data":{"SIGNUPS_ALLOWED":"false"}}'
```

```bash
sudo k3s kubectl -n pi rollout restart deployment/vaultwarden
```

**What a JSON export leaves behind:** file attachments, Sends, and password
history. Everything else, TOTP codes included, comes across.

**Where it lives.** `1) Archive/Apps/Vaultwarden/` on the SSD mirror — visible
in Finder, copyable like anything else.

**Backed up daily**, the one scheduled backup here by choice:

```bash
make vault-backup
```

At 12:00 the database is copied with SQLite's online backup, checked with
`PRAGMA integrity_check`, and kept with the RSA keys, config and attachments,
first on the SSD and then on HDD2. A copy that fails the check is never kept.

</details>

<details>
<summary><strong>qBittorrent — downloads, behind AirVPN</strong></summary>

```bash
make torrent
```

Installs **stopped**. Two containers in one pod sharing one network namespace:
gluetun brings up WireGuard and owns the routing, qBittorrent has no network of
its own. That shared namespace is the whole point — the client cannot be
configured around the VPN, cannot fall back to the PC's connection, and
cannot send a packet before the tunnel exists, because there is no other route
for it to take.

It is also why the VPN is not separately switchable. A toggle that could leave
the client running with the tunnel down is the exact failure this shape makes
impossible, so the two start and stop together.

**Nothing here touches the PC's networking.** The WireGuard interface lives
in the pod's namespace; the PC's routing table, and tailscaled with it, are in a
different one and never see it. A VPN installed on the PC itself would take
the default route and drop Tailscale — the console, the shares and SSH with it.

**Before the first run**, from AirVPN's Client Area:

1. Config Generator, choose WireGuard and a server. You need the `[Interface]`
   PrivateKey, the `[Peer]` PresharedKey, and the `[Interface]` Address.
2. Ports, and reserve one. Traffic only reaches the client on a port AirVPN is
   forwarding; without one it downloads but seeds poorly.

`make torrent` asks for those four and puts them straight into a Secret.
Nothing is echoed and nothing lands on the PC's disk. Eddie is not involved
— this is a separate device on the same subscription and uses one of the plan's
connection slots.

**Turning it on.** The console's Apps tab, the qBittorrent tile, the power
switch on it. Works from a phone; there is no terminal step. The tile shows
the address traffic is actually leaving from, read from gluetun rather than
inferred from the pod being up — "running" and "protected" are different
claims and only the second one matters.

`make torrent-on` and `make torrent-off` do the same from a terminal. They exist
so the button stays optional: the console's permission to press it is a single
RoleBinding, and deleting it leaves both commands working.

**What the button can do, and cannot.** The console has been read-only against
the cluster until this. The grant is a `Role` in one namespace, on
`deployments/scale`, for one deployment by name. The subresource is the part
doing the work: write access to a *deployment* would let a compromised console
add a privileged container with the host filesystem mounted and take the PC,
while `scale` accepts one integer and refuses everything else.

**Where downloads go.** `/data/Downloads` in the client, which is
`HDD-6TB/Downloads` in Finder. The add-torrent form shows that path and lets
you change it per torrent — anywhere under `/data`, which is the whole of
HDD1.
Incomplete files sit beside the finished ones rather than staging on the SSD,
so completing a download is a rename inside one filesystem and never a copy.

The whole 6TB is mounted for the same reason: a finished download is
hard-linked into place, and a hard link cannot cross a mount boundary. Two
mounts would mean a 40GB film costing 80GB for as long as it kept seeding.

**Login.** The web page uses the admin password shared with the console, and keeps qBittorrent's existing user name (`admin` if none).
Set or change it on homelab:

```bash
sudo bash deploy/set-admin-password.sh
```

Only homelab itself skips the login; the tailnet arrives through proxy pods and
must sign in. qBittorrent 5.3 moved these settings into a `[WebUI]` section of their own, and both
scripts write whichever layout the config already has.

</details>

<details>
<summary><strong>Photos — Immich, and the phone backing itself up</strong></summary>

```bash
make photos
```

Immich on homelab at `https://photos.<tailnet>.ts.net`. A timeline, albums,
natural-language search, faces, and a phone app that uploads to it. Machine
learning runs on the CPU; the GPU belongs to Jellyfin and the local AI.

**Four containers**, which is three more than anything else here runs:

| | |
|---|---|
| server | the API, the web interface, the job workers |
| machine-learning | CLIP for search and the face model, on the CPU |
| postgres | the library index and the vector search index |
| valkey | the job queue |

It has its own Postgres. Immich needs the VectorChord extension compiled in,
which is the thing that makes "a photo of a bicycle" a query rather than a
wish.

**Where it lives.** The usual split. `1) Archive/Apps/Immich/` on the SSD holds
the database and the downloaded model weights, both read at random. The photos
go to `/srv/hdd2/Immich` on HDD2.

**Machine learning runs on upload, not on a timer and not when you search.**

```
Upload → Metadata → Storage Template → Thumbnails
                                         ├→ Smart Search → Duplicate Detection
                                         ├→ Face Detection → Facial Recognition
                                         ├→ OCR
                                         └→ Video Transcoding
```

The queue drains and the workers sleep. Searching for a face or a phrase is a
database lookup against work already done, so it costs the same at 5000 photos
as at 500. The one expensive moment is the first bulk import.

**After the deploy, in this order:**

1. Open the URL. The first account created is the admin, and sign-up closes
   behind it automatically.
2. Move the schedules off the middle of the night, under Administration,
   Settings. Nightly Tasks start time `00:00` to `06:00`, and External Library
   scan `0 0 * * *` to `0 6 * * *`. The installer sets `TZ` from the PC's own
   clock, without which both would mean UTC.
3. Keep the Backup database dump on, moved to `0 6 * * *`. It is enabled by
   default at 2am; the dumps are one of the two scheduled backups here by
   choice, with Vaultwarden's.
4. Set the storage template to `{{y}}/{{MM}}/{{filename}}`, so the tree on the
   hard drive stays something you can walk in Finder.
5. Install the app and point it at the URL. Tailscale has to be up on the phone.

**Background App Refresh is optional.** With it off, the app uploads everything
new each time you open it. That path is the reliable one regardless: on iOS the
system decides when a background task runs, and the app cannot ask.

**Do not push an existing library through the phone.** From the Mac:

```bash
npx @immich/cli upload --recursive /path/to/photos
```

It wants the server URL and an API key from Account Settings. Originals are read,
never moved or altered.

**Immich owns its data layout**, which cuts against the rule that no app here
owns the data. The storage template above keeps the tree readable, and existing
photos can be added as an external library, which Immich reads and never moves.
Losing the database costs albums, faces and search — not the pictures.

**It is capped on both axes, so it cannot take the PC.** Every container has
a kernel-enforced ceiling, not a promise:

| | CPU | memory |
|---|---|---|
| server | 1500m | 4Gi |
| machine-learning | 1000m | 3Gi |
| postgres | 500m | 2Gi |
| valkey | 100m | 256Mi |
| **total** | **3100m of 12000m** | **9.25Gi of 24GB** |

Postgres went from 1Gi to 2Gi: its 512MB `shared_buffers` and the `/dev/shm`
volume both count against the limit, and at 1Gi the 3.3.5 upgrade's
migrations were killed halfway.

Nearly nine threads and about 14GB stay out of Immich's reach whatever it
does, which is what k3s, the console, Jellyfin, Nextcloud and the rest keep
running on. Indexing is a batch job that would otherwise take every core for
as long as the queue lasts; capped at one, it takes longer and nothing else
notices. That single number is the knob to turn if a first import is too
slow.

Disk is not capped here and has no cgroup equivalent. The lever is Immich's own
per-user storage quota under Administration, Users.

**One open upstream bug worth knowing about.** `immich-app/immich#26162`: the
api process grows until its memory limit kills it, at 95-97% of whatever that
limit is, and raising the limit only makes it take longer. It correlates with
large libraries and a phone backing up. The manifest caps the server at 4Gi
deliberately, so the failure is one container restarting in seconds rather than
the PC going down — which is what happens to the people hitting this under
Docker Compose. Watch for `immich-server` collecting restarts with `OOMKilled`
on an idle PC.

**Backups.** Immich's own database dumps, daily at 06:00 (step 3 above). The
photos themselves are not backed up on a schedule, by choice: copies are made
by hand.

</details>

<details>
<summary><strong>ArchiveBox — a self-hosted internet archive</strong></summary>

```bash
make archivebox
```

ArchiveBox 0.9 at `https://archivebox.<tailnet>.ts.net`. Feed it URLs —
from the browser extension, one at a time, a bookmarks export, or an RSS
feed — and it saves full copies: HTML snapshots, PDFs, screenshots, media,
git repos. It uses wget, yt-dlp, and a headless Chrome under the hood.

The same SSD/data-drive split, as two mounts: `/data` (the SQLite index,
config, logs and personas) on the SSD, `/data/archive` (the saved content)
on the data drive.

`make archivebox` asks for an admin username and password before the first
start. It needs `make uptime` first for the Tailscale operator. Run over a
0.7 install, it renames the old folders aside and starts a fresh collection.

</details>

<details>
<summary><strong>Gitea — self-hosted Git</strong></summary>

```bash
make gitea
```

Gitea at `https://git.<tailnet>.ts.net`, issue #201. Clone and push over
HTTPS with your password or an access token; there is no SSH, because the
tailnet proxy carries HTTP only. Registration is closed: `make gitea` asks for
the admin's username and email once and prints a one-time password. More
accounts come from Site Administration.

The same split as the other apps, all owned by the login user: the app, its
SQLite database and `app.ini` in `1) Archive/Apps/Gitea` on the SSD mirror;
the repos, LFS and attachments in `/srv/hdd2/Gitea` on HDD2.

**Backups are manual.** `sudo gitea-backup` runs Gitea's own `gitea dump`
(repos, database, settings, attachments) into one `.tar.gz`, checks it holds
the database and the settings, and moves it to `/srv/hdd2/Backups/Gitea`.
There is no timer, and nothing is deleted automatically. The Status tab shows
the repo count, their size, and how long ago the last backup was. Restoring
follows [Gitea's guide](https://docs.gitea.com/administration/backup-and-restore).

</details>

<details>
<summary><strong>Nextcloud — the family's files</strong></summary>

```bash
make pool
```

```bash
make cloud
```

Nextcloud at `https://cloud.<tailnet>.ts.net`, with per-person storage
limits. Its code, config and Postgres are on the SSD; everyone's files are on
`/srv/pool`, a mergerfs pool of the data disks, so a disk added later is one
more branch and no app changes. HDD1 is deliberately not in the pool:
qBittorrent hard-links finished downloads into Jellyfin's library there, and
a hard link cannot cross disks.

The admin also sees every drive, under the same names as in Finder:
`HDD-6TB`, `HDD-6TB-2`, `SSD-250GB` (the `1) Archive` folder), `SSD-512GB`,
and `HDD-1TB`, read-only since that disk is kept as it was. The others are
writable except the app folders, which are read-only so a wrong drag cannot
break an app. The `Apps` folder is hidden from the pod, since it holds every
other app's database and secrets. Impersonate is on: the admin can open a
family account from the Users page to sort out its files.

</details>

<details>
<summary><strong>Jellyfin — the one app on the internet</strong></summary>

Jellyfin is on Tailscale Funnel, for family whose connection makes Tailscale
itself too slow. The TV at home uses port 8096 on the home network, the one
port the firewall leaves open there.

Funnel and the tailnet name go through a bouncer first, `k8s/jellyfin-edge.yaml`
(`deploy/install-jellyfin-edge.sh`). From the internet it refuses admin-only
changes and allows 5 sign-ins at once per address, then one every 10 seconds.
Who knocks:

```bash
sudo k3s kubectl -n pi logs deploy/jellyfin-edge
```

Accounts lock after 5 wrong passwords (the admin after 3), and the admin signs
in from home or the tailnet only:

```bash
sudo python3 deploy/jellyfin-accounts.py --apply
```

```bash
sudo python3 deploy/jellyfin-accounts.py --unlock NAME
```

`make guard` adds `jellyfin-guard`: Funnel goes off, with a Discord post, when
someone tries names that are not accounts or fails many logins in a short
time. Family on Tailscale keep watching.

**Not installed: `make watchdog`.** The Pi-era circuit breaker disabled every
non-admin account overnight and under load. Services here work at any hour, so
it stays off; the target is kept only as history.

How it was built and tested: [`docs/build-log.md`](build-log.md#jellyfins-door-to-the-internet).

</details>

<details>
<summary><strong>Local AI — on the GPU, in Discord</strong></summary>

```bash
make ai
```

llama.cpp built for the GTX 1050 Ti, with Qwen3.5-4B (about 3GB of the card's
4GB), unloaded after ten idle minutes. It shares the card with Jellyfin. It
answers in its own Discord channel through `pi-bot`, read-only. Issue #200;
details in [`pc.md`](pc.md#drivers).

</details>

<details>
<summary><strong>Quiet hours — keeping maintenance out of the night</strong></summary>

```bash
make quiet
```

Moves the PC's maintenance timers out of midnight–6 AM. Users are never
restricted; only automatic jobs move.

| | moved to |
|---|---|
| `apt-daily` | 07:00 + up to 2h |
| `apt-daily-upgrade` (security updates) | 07:00 + up to 2h |
| `man-db` | Sunday 10:00 + up to 2h |
| `fstrim` | Monday 08:00 |

App schedules (Jellyfin's Scheduled Tasks, Immich's jobs) are set in each
app. `IMMICH_QUIET=1 make quiet` would also pause Immich's jobs and uploads
overnight; it is off, because it stops everyone uploading.

</details>

## Status

All of it runs on homelab under k3s, behind Tailscale, with the console as a
Deployment behind Traefik. Uptime Kuma posts to Discord, and a report at 08:00
(`make report`) lists what went wrong in the last day.

The SSD mirror is degraded: the T-Force 512GB failed on 2026-10-16 and homelab
runs on the Samsung alone until a new backup half goes in
([`pc.md`](pc.md#ssd-mirror)).

Backups are made by hand, by decision. The exceptions are Vaultwarden's daily
copy and Immich's database dumps; Gitea's are `sudo gitea-backup`, by hand.
