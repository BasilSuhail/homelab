# The PC

One x86 desktop, homelab, replaced both boards. Everything pi2 ran under k3s
runs on it now, and pi1's OSINT stack moves over next. Both Pis are retired.

This page is the machine as built. Where it differs from the plan it replaced,
the plan was wrong.

---

## Hardware

| | | |
|---|---|---|
| Board | ASUS ROG STRIX B350-F GAMING | BIOS 6232, UEFI |
| CPU | AMD Ryzen 5 1600 | 6 cores, 12 threads. **No integrated graphics** |
| RAM | 24 GB | four sticks: 8 + 8 + 4 + 4 |
| GPU | NVIDIA GeForce GTX 1050 Ti, 4 GB | stays in: the CPU has no display output of its own |
| PSU | Corsair CX600M | 600 W. No data link, so nothing can read its draw |
| Wi-Fi | Intel AX210 on a PCIe card | `wlp7s0`, in-kernel `iwlwifi`. The only network: no cable reaches the PC |
| Screen | none | homelab runs headless. Everything is done over SSH |

---

## Disks

| Drive | Model | Holds | Mount |
|---|---|---|---|
| SSD1, 250 GB | Samsung 860 EVO | Debian and `1) Archive` (every app's settings, databases and backups), the main half of the mirror | `/` and `/srv/ssd`, bound to `/1) Archive` |
| SSD2, 512 GB | T-Force Vulcan Z | **failed 2026-10-16, out of the PC** (see below). Was the mirror's backup half and `/srv/spare` | — |
| HDD1, 6 TB | Seagate ST6000VX009 | Jellyfin, downloads | `/srv/storage` |
| HDD2, 6 TB | WD Purple WD64PURZ | Nextcloud, Immich, Gitea's repos, backups, ArchiveBox, Kiwix | `/srv/hdd2`, under the `/srv/pool` mergerfs pool |
| HDD3, 1 TB | WD Blue WD10EZEX | old NTFS disk, kept as it was | `/srv/hdd1` |

All are mounted by UUID with `nofail`. The `sdX` letters move between boots on
this board, so nothing may refer to a disk by them; the mirror script names
disks by `/dev/disk/by-id`.

`1) Archive` started on pi2's old 1TB root SSD and moved onto the 250GB when
the mirror was built. Its fstab line still binds `/srv/ssd/1) Archive` to
`/1) Archive`, which is where every install script looks, so no app needed a
path changed. The 1TB SSD left the PC and is now an exFAT backup drive.

### SSD mirror

`deploy/ssd-mirror.sh` turns the two SSDs into a mirror (mdadm RAID 1): each
carries an EFI partition, root (100G, `/`), apps (115G, `/srv/ssd`) and its own
swap, and every write lands on both. Either SSD can die and homelab keeps running;
the firmware boots whichever is left. The 250GB is the main disk and the
512GB's half is write-mostly, so reads stay on the 250GB. The 512GB's leftover
~249G is `/srv/spare`, not mirrored, and shows in Finder as `SSD-512GB`.

**Degraded since 2026-10-16.** The T-Force dropped out mid-run at 07:04 and
never came back: the SATA port reports `link down` on both ports, both data
cables and both power plugs, all of which work for the Samsung. On a USB
adapter it showed up once, then disconnected by itself within a minute, and it
runs hot while idle. It is failing, not mis-cabled, and is going back under
warranty. homelab runs on the Samsung alone until a new backup half goes in with
`ssd-mirror.sh add <disk> --backup`; the planned replacement is the Crucial
1TB. `/srv/spare` and the `SSD-512GB` share went with it.

A disk dropping out, or a boot with one missing, posts to Discord with
@everyone (`pi-raid-alert`, from mdadm's monitor and `pi-raid-check.service`).
`pi-esp-sync` copies `/boot/efi` to every SSD's EFI partition after each apt
run, since the firmware reads those before Linux and they cannot be mirrored.

Replacing an SSD:
`ssd-mirror.sh remove /dev/sdX`, power off, swap, power on,
`ssd-mirror.sh add /dev/sdY --backup`. `ssd-mirror.sh status` shows both
halves, the copy progress and the boot order. A mirror is not a backup: a
deleted file is gone from both.

---

## BIOS

Set once, with a screen, and not to be revisited:

- **Advanced → AMD CBS → CPU Common Options → Power Supply Idle Control → Typical Current Idle.**
  First-generation Ryzen can freeze when idle without it.
- **Restore AC Power Loss → Power On.**
- **Wait For 'F1' If Error → Disabled.** A headless machine cannot press F1.
- **Secure Boot: off.** `mokutil --sb-state` confirms it over SSH. The NVIDIA
  and it87 modules are self-signed by DKMS, which only works with it off.

---

## OS

Debian 13 (trixie), amd64. The login user is `homelab`, with passwordless `sudo`
because the `make` targets run `sudo` without a terminal. That stays, by
decision (issue #204, item 7): nothing that reads untrusted content runs as
`homelab`. The job bot is in its own container (below) and the Discord bot is
its own user, `pi-bot`.

The installer put GNOME on despite the task being unticked. Its login screen
suspended the machine after twenty idle minutes, which looked like crashes.
It is disabled, not removed (removal takes NetworkManager with it, and that is
the Wi-Fi):

```
sudo systemctl disable --now gdm3
sudo systemctl set-default multi-user.target
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Wi-Fi power saving is off (`IFACE=wlp7s0 bash deploy/tune-wifi.sh`; `make wifi`
does not pass the interface through).

---

## Security

From the October 2026 audit, issue #204. None of these has a `make` target;
each is a script in `deploy/`, run with `sudo` on homelab, and safe to re-run.

| | What | Script |
|---|---|---|
| Firewall | The home network reaches Jellyfin (8096) and nothing else: plus ping, DHCP and Tailscale's direct path (UDP 41641). One nftables chain at prerouting, before k3s' DNAT, so it covers pods' hostPorts and NodePorts too. Only `en*`/`wl*` are filtered; the tailnet, pods and loopback pass. `pi-firewall.service` loads it at boot | `install-firewall.sh` loads it with a 3-minute undo; open a new SSH session, then `--keep`. `--off` removes it. Rules: `firewall.nft` |
| Updates | Debian's security pocket only, every morning (`apt-daily-upgrade`, 07:00 plus up to two hours after `make quiet`). Tailscale's repository is left out, since upgrading it drops every tailnet connection. Never reboots; a new kernel waits for a reboot by hand | `install-security-updates.sh` |
| SSH | Drop-in `/etc/ssh/sshd_config.d/10-pi-hardening.conf`: no root login, no X11, 3 tries. `--keys-only` also turns passwords off. sshd is reloaded, so open sessions survive | `install-ssh-hardening.sh` |
| Console | Passkey (Face ID / Touch ID) or the admin password; `/healthz` is the only open path. `passkeys-only` / `password-too` | `console-login.sh` |
| Admin password | One password for the console, the live view (first 8 characters, VNC's limit) and qBittorrent. Asked twice, never printed | `set-admin-password.sh` |
| File agent | The shim's file and fan routes need `X-Agent-Token`; the token is `/etc/pi/agent-token`, root-only, made by `agent/install.sh`, copied into the console's `pi-console-agent` Secret by `install-dashboard-k8s.sh`. `/metrics` stays open for Kuma. Glances listens on loopback only | `agent/install.sh` |
| Discord bot | Its own user, `pi-bot`; root only through fixed `sudo` calls | `install-pi-bot.sh` |
| Job bot's browser | In the container: a managed policy (`applypilot/chrome-policy.json`) refuses `file://`, loopback, `ts.net`, `cluster.local` and the router, and the network policy refuses every non-public range. On the host, `install-browser-guard.sh` writes the same block with this machine's own addresses; re-run it if they change | image, `install-browser-guard.sh` |
| Jellyfin on the internet | Bouncer, account locks, admin from home or the tailnet only: see [build-log](build-log.md#jellyfins-door-to-the-internet) | `install-jellyfin-edge.sh`, `jellyfin-accounts.py` |

Images updated in the audit are pinned by digest as well as tag (Jellyfin,
Nextcloud, Vaultwarden, Kiwix, qBittorrent, Uptime Kuma), so a re-run installs
exactly what was tested. Gitea, Immich, ArchiveBox and gluetun are by tag only.

---

## Drivers

| Driver | For | How |
|---|---|---|
| `nvidia-driver` 550 | GPU stats, NVENC | `contrib non-free` added in `/etc/apt/sources.list.d/nonfree.list`, then `apt install linux-headers-amd64 nvidia-driver nvidia-smi` and a reboot |
| it87, community DKMS build | fans | `github.com/frankcrawford/it87`, `sudo ./dkms-install.sh`. The board's IT8665E chip has no in-kernel driver. Loaded with `options it87 ignore_resource_conflict=1` and listed in `/etc/modules-load.d/it87.conf`. No kernel boot option needed |
| `drivetemp` | drive temperatures | loaded by `agent/install.sh` |
| RAPL energy counter | CPU package power | root-only by default; `agent/install.sh` adds a udev rule that makes it readable |

The GTX 1050 Ti reports no power draw (`N/A`), and its fan cannot go below
45%: both are set in the card's firmware.

`make gpu` installs NVIDIA's container toolkit, restarts k3s so it registers
the `nvidia` RuntimeClass, and gives the card to Jellyfin for NVENC/NVDEC.
Hardware acceleration is then switched on in Jellyfin's own Transcoding page.
The card decodes H.264, HEVC (8 and 10-bit), VP9 and older formats, and
encodes H.264 and HEVC; it has no AV1.

`make ai` puts a small local model on the same card (issue #200,
`k8s/ai.yaml`): llama.cpp built for CUDA 12.4 and `sm_61`, Qwen3.5-4B, about
3GB of the 4GB, unloaded after ten idle minutes. It shares the card with
Jellyfin through the same runtime, with no device plugin, so neither holds it.
It answers in its own Discord channel through `pi-bot`, read-only.

The job bot (ApplyPilot) runs in a container of its own, `k8s/applypilot.yaml`,
built on the PC from `applypilot/` by `deploy/install-applypilot.sh`:

| | |
|---|---|
| User | `applypilot`, uid 1500, no sudo, no Kubernetes token, read-only image, no capabilities |
| Sees | its code read-only (`~/ApplyPilot`), its data (`~/.applypilot`, `/srv/hdd2/ApplyPilot`), its Gmail login. Its own home is `/srv/hdd2/ApplyPilot/home`, mounted at the owner's home path so stored paths still work |
| Network | out to the internet only; every non-public range is refused. In: only the PC (for `tailscale serve`) and Uptime Kuma, on the live-view port |
| Inside | Xvfb `:99`, openbox, tint2, x11vnc, noVNC on 6080, the home browser, the Kuma health push and the Discord email alerts, kept up by runit (`services`) |
| Live view | `tailscale serve` on 8443 to the `liveview` Service; same admin password |
| File access | ACLs give uid 1500 the owner's permissions on its folders; other entries keep what they had (`deploy/applypilot-acl.py`, old ACLs in `/var/backups/`) |

Chrome runs with its sandbox, which needs seccomp `Unconfined` in the pod.

---

## Fans

`make fans` installs `deploy/fan-curve.py` as `pi-fans.service`. Config:
`/etc/pi-fans.json`.

| Header | Fan | Behaviour |
|---|---|---|
| pwm1 | CPU cooler | follows the CPU: slowest below 50°, full at 75°. It cannot stop (about 800 rpm minimum) |
| pwm2 | rear exhaust | off until CPU or GPU reaches 55°, then 30% rising to full at 75°; off again at 45°, after at least 1 minute on |
| pwm3 | front intake, top | as the exhaust |
| pwm4 | front intake, bottom | the hard drives only: on at 38° and off below it (after at least 1 minute), 30% up to 42° then rising each degree to full at 55°; it blows across them |
| pwm6 | nothing | free, for a fan on the GPU heatsink |

The three case fans stop fully at 0%. Stopping the service, or any failure,
hands every header back to the BIOS curve.

On the dashboard, clicking a fan opens a slider: Auto, Off (case fans only)
or a speed by hand. A manual speed holds until Auto or a reboot, with two
limits: the CPU fan never stops, and once the CPU passes 70°, the GPU 75° or a
drive 45°, the temperature curve wins whenever it asks for more. The GPU's own
fan is set by the card and is not controllable on a headless driver.

---

## What moved, and what it cost

- **Immich**: the database still held pi2's password while the new install
  generated a fresh one. Fixed by setting the database's password to the new
  secret with `ALTER USER`. Its library is on HDD2, so `install-immich.sh` now
  defaults to `/srv/hdd2`.
- **Nextcloud and Uptime Kuma**: re-running `make archive` over a populated
  archive re-owned every app's files to the login user. Nextcloud lost write
  access to its config; Kuma crashed on start. `setup-archive.sh` no longer
  recurses.
- **Uptime Kuma**: on a fresh cluster it needs the `pi` namespace, which used to
  come from the dashboard install. It now creates it.
- **Tailscale**: a new OAuth client for the operator, and a read-only OAuth
  client for the dashboard (`deploy/dashboard-oauth.sh`), which never expires.
