# Build log

What has actually been done to the boards, in order, with the reasoning. Issue #5 is the plan; this is the record.

Convention: `pi1` is the 8GB board, `pi2` the 16GB board. Names follow the storage, not the silicon.

---

## Boards as they stand

| | pi1 | pi2 |
|---|---|---|
| RAM | 8GB | 16GB |
| Boot | SD card, `/boot/firmware` only — must stay in the slot | its own SSD |
| Root | its own 512GB SSD | 1TB SSD — apps, and the faster small backups |
| Expansion | none | Waveshare PCIe SATA HAT — ASMedia ASM106x, one port in use |
| Bulk | — | 6TB HDD (ST6000VX009) on the HAT, 12V barrel fitted — plain storage, not the archive |
| LAN | see `~/.ssh/config` on the Mac | same |
| OS | Debian 13 trixie, aarch64, 4 cores | same |
| Runs | OSINT stack (Docker Compose), `llama-server` | k3s server |
| Role | untouched. Docker Compose only. | cluster control plane |

DHCP assigns both addresses; they are not reserved. Worth pinning in the home router at some point.

---

## 1. SSH access to pi2

New board had no key access. Ended up on password auth by choice — key auth was set up, then deliberately reverted.

`~/.ssh/config` on the Mac now carries:

```
Host pi
    HostName <pi1-lan>
    User pi
    PubkeyAuthentication no

Host pi2
    HostName <pi2-lan>
    User pi
    PubkeyAuthentication no
```

`PubkeyAuthentication no` is doing real work: an older passphrase-protected key exists on the Mac whose passphrase is unknown. Without this, ssh offers that key, the server accepts it as a candidate, and the client blocks on a passphrase prompt that can never be satisfied. Forcing password auth skips the whole path.

Two leftovers on pi2, harmless but worth clearing eventually:

- `~/.ssh/authorized_keys` holds two public keys whose private halves are unused
- `~/.ssh/id_ed25519_pi` on the Mac — a passphraseless key that was generated, then abandoned

Config backups: `~/.ssh/config.bak*` on the Mac, four of them.

**Consequence:** every remote command is interactive. Nothing can be scripted against the boards over SSH.

---

## 2. cgroups on pi2

Pi kernels boot with cgroup memory accounting disabled. Two effects, one of which was live on pi1 and unnoticed:

1. k3s installs, reports Ready, and then never schedules a pod. Nothing in the error mentions cgroups.
2. **`mem_limit` in every Compose file is silently ignored.** `docker stats` on pi1 reports `0B / 0B` for all six OSINT containers — the kernel declining to account, not Docker declining to display.

That second one means guard #2 in issue #1 has never been in force. `llama-server` runs outside Docker at 3.2GB and is the largest process on pi1, so it is what the OOM killer selects. Exactly the failure that guard was written to prevent.

Applied to pi2:

```bash
sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
sudo sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
sudo reboot
```

`cmdline.txt` must remain a single line with no trailing newline, or the board does not boot.

**Verification is not `/proc/cgroups`.** Debian 13 is cgroup v2 only, so the v1 table has no memory row and looks like a failure. The authoritative file:

```
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory pids
```

`memory` present — correct.

One detail worth knowing. The Pi bootloader prepends its own parameters, including `cgroup_disable=memory`:

```
reboot=w ... cgroup_disable=memory ... cgroup_memory=1 cgroup_enable=memory
             ↑ firmware                  ↑ ours, appended last
```

The kernel reads left to right and the last value wins. This is why the flags must go at the **end** of `cmdline.txt`.

**pi1 has not had this applied.** Its memory limits remain unenforced.

---

## 3. k3s server on pi2

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
```

Installed **v1.36.4+k3s1**, containerd 2.3.4.

`--write-kubeconfig-mode 644` lets the `pi` user read the kubeconfig without sudo. Convenience only.

| Path | What |
|---|---|
| `/usr/local/bin/k3s` | the binary — API server, scheduler, controller-manager, kubelet, containerd |
| `/var/lib/rancher/k3s/server/db/state.db` | **SQLite. This is the cluster.** Back it up; nothing else matters. |
| `/var/lib/rancher/k3s/server/node-token` | join secret. Never commit. |
| `/etc/rancher/k3s/k3s.yaml` | kubeconfig, mode 644 |
| `/usr/local/bin/k3s-uninstall.sh` | complete undo |

Bundled and running: CoreDNS, Traefik, local-path-provisioner (default StorageClass), metrics-server.

Verified:

```
NAME   STATUS   ROLES           VERSION
pi2   Ready    control-plane   v1.36.4+k3s1
```

`helm-install-traefik` errored twice before completing — a race against the CRD job on first start. It self-corrected without intervention; RESTARTS 2 then `Completed`.

### Cost

| | RAM | CPU |
|---|---|---|
| pi2 before k3s | 327Mi | — |
| pi2 with k3s idle | 1.0Gi (`kubectl top`: 852Mi) | 54m, 1% |
| plus 5 nginx pods | 913Mi | 89m, 2% |

**Control plane ≈ 700MB.** Five containers on top cost ~60MB. The overhead is the orchestrator, not the workloads — which is the argument for keeping the cluster to one node until something actually needs to move.

---

## 4. kubectl from the Mac

```bash
brew install kubectl                                        # kubernetes-cli 1.37.0
ssh pi2 'cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-pi2
chmod 600 ~/.kube/config-pi2
sed -i '' 's|<loopback>|pi2|' ~/.kube/config-pi2
```

`KUBECONFIG` exported in `~/.zshrc`.

The `sed` is required: k3s writes the server as the loopback address, which resolves to the wrong machine when the file is read anywhere but the Pi.

Home LAN only. The cluster's TLS certificate carries pi2's LAN address, so connecting via any other name fails the cert check. A `tls-san` entry would fix that if remote `kubectl` is ever wanted.

---

## 5. Reconciliation, demonstrated

```bash
kubectl create deployment hello --image=nginx --replicas=2
kubectl delete pods -l app=hello        # both
# 12 seconds later: two new pods, different names, Running
kubectl scale deployment hello --replicas=5
kubectl delete deployment hello
```

Deleting every pod and running nothing else returned two new ones. Desired state said 2, actual said 0, the controller closed the gap.

This is the difference from Compose. `restart: always` retries a container on the box it is already on. A controller re-creates it wherever the cluster has room — which is worth nothing on one node, and is the entire point on several.

---

## 6. Node agents on both boards

`agent/install.sh` on each board. Two services:

| Port | Service | What |
|---|---|---|
| 61208 | `glances.service` | REST API, `--disable-webui`. CPU, memory, disks, network, processes, containers. |
| 9101 | `pi-metrics.service` | stdlib Python. PMIC power draw and `vcgencmd` throttle state — the two things Glances cannot see. |

The shim returns empty `capabilities` on hardware without `vcgencmd`, so the same file drops onto any Linux node and the frontend renders fewer tiles rather than breaking.

Three things went wrong, all worth recording:

**The shim exited 0 in a restart loop.** Stripping a literal bind address to satisfy the commit guard left a trailing comment ahead of the chained call, so `.serve_forever()` was swallowed into it. The server was constructed and never started. No traceback — the process exited cleanly, so systemd reported `active` between attempts and the port stayed closed.

**Glances kept running under the package's own configuration.** Debian starts it at install time, so `systemctl enable --now` found the unit already active and left it alone — serving XML-RPC on another port rather than the REST API. Needs an explicit `restart`.

**Glances needs `python3-docker`** to read the Docker socket. Without it the containers plugin returns an empty list rather than an error, so pi1 would have shown no containers with nothing indicating why.

## 7. Fleet dashboard

`docs/dashboard.md` is the design. Frontend by the operator, backend here.

Discovery goes through the **Tailscale API, not the Kubernetes node list** — pi1 is on the tailnet but not in the cluster, so asking k8s would miss the busiest machine in the house. Cluster membership is applied afterwards as a label.

The frontend arrived as a Manus scaffold. The stylesheet, layout and view structure were kept as authored; the scaffold around them was removed — tRPC, Drizzle, MySQL, OAuth, S3, LLM and voice endpoints, Google Maps, 52 unused shadcn components, Tailwind (no utility class appears in the markup), wouter, react-query. **Roughly ninety dependencies became ten.** Next.js went with them; this is a static bundle plus a `node:http` server, 218KB of client and 14KB of server with no framework runtime.

Five bugs found by pointing the client at live agents rather than at fixtures:

| | |
|---|---|
| `uptime` is a string | `"0:44:03"`, or `"3 days, 2:15:09"` past a day — not a number. Reading `.seconds` returned null forever, and nothing would have looked broken. |
| `os_version` is the kernel | `hr_name` is a full description string. `platform` is bitness, not architecture. |
| Virtual interfaces dominate | pi1 reported nine: wlan0 plus a docker bridge and six veth pairs. pi2 nine too, via k3s CNI. Their traffic is already counted on the physical interface. |
| CPU samples arrive uninitialised | Glances computes CPU as a delta since the previous request, not from its own timer, so requests close together produce a window near zero and a sample where `total` and `idle` are both 0 — impossible on a running system. Retrying is itself a short window and makes it worse. A last-known-good cache with a 30s ceiling covers it. |
| `apps.json` was never read | Resolved beside the bundle but only present in source, so the launcher silently returned `[]`. |

## 8. Dashboard live on pi2

`deploy/install-dashboard.sh`. Builds on the board — the boards are arm64 and cross-building from the Mac buys nothing — then installs a systemd service.

Node 22 is installed if needed; Debian 13 ships 20, which the build rejects. Only `dist/` is installed: the client is bundled and the server imports nothing outside the standard library, so the runtime needs no packages at all.

The first unit would not start: `status=216/GROUP`, restarting every five seconds, 43 attempts. It set `SupplementaryGroups=tailscale` to reach the tailscaled socket without root, and **Debian's tailscale package creates no such group**. systemd refuses to spawn a process whose supplementary group does not resolve. Runs as the login user instead, who can already query the daemon.

Exposed with `tailscale serve --bg 8080` — real certificate, tailnet-only, no open ports, reachable from a phone with no client beyond Tailscale itself.

```
https://pi2.<tailnet>.ts.net   →  200
```

## 9. Archive tree on pi2

`deploy/setup-archive.sh`. Creates `/srv/archive` and nothing inside it.

The 8TB is still blocked on 12V, and the archive did not need to wait for it.
pi2 holds 873GB free, which covers Wikipedia at ~100GB, the book library and a
first laptop backup with room left. The tier that issue #1 describes — Samba,
Kiwix, Jellyfin, Calibre-Web — can be built now and moved later, because every
service is pointed at the path and never at a device.

The tree used to be seeded with `backups/`, `documents/`, `photos/` and four
more. That was someone else deciding how you file things, so the script now
creates the root and stops; it also clears the seeded folders on boards that
still carry them, but only the ones it made and only while they are empty —
`rmdir` refusing a non-empty directory is the whole safety mechanism.

Directories are `2775`: group-writable with the setgid bit, so anything written
later inherits the group rather than depending on which daemon created it.

**The trap this sets, and how the script defuses it.** `/srv/archive` is a plain
directory on `/dev/sda2` today and a mount point later. Mounting a disk over a
directory does not move what is underneath — those files stay on the root
filesystem, keep consuming it, and become invisible while the mount is live. The
script detects it is not on a mount point and prints the migration in full:
copy to the new disk mounted elsewhere, verify, then swap and delete. It also
refuses to run anywhere with less than 200GB free, since Wikipedia alone would
not fit.

Placement was decided by measurement, before the SATA HAT moved. pi1 sustains
~350% of a core during ingest bursts against a load average of 4.33 on four
cores; pi2 idles at 1.6% with load 0.038. Reads for Jellyfin and Samba belong
on the board that has cycles to serve them.

The hardware has since agreed with the measurement. The Waveshare PCIe SATA HAT
came off pi1 and went onto pi2, so the board that will hold the bulk disks is
also the board with the cycles to serve them. Each board still boots and roots
from a single SSD of its own; nothing is attached to the HAT's spare ports yet.

The 6TB's first hot-plug left the controller disabled, and the symptom was
misleading enough to be worth recording. Connecting a powered drive glitched
the PCIe link; the kernel recovered it, and the controller came back with its
COMMAND register at `0x0000` — memory decoding off, so every hardware register
read `0xffffffff` and no disk could be detected while the drive spun happily
and the HAT's activity LED showed green. Every visible symptom pointed at the
disk or the 12V supply, and both were fine. A reboot restored it;
`deploy/check-sata-hat.sh` reads that register now.

### One folder per drive

`deploy/setup-browse.sh`. The share opens on drives and only drives, the way
"This PC" does on Windows. A machine has drives, the drives are what you open,
and anything that is not a drive has no business sitting beside them. Two disks
in pi2 is two folders; plug in a third and there are three.

```
pi2/
├── SSD-1TB/          <- /            "1) Archive", bin, boot, etc, ...
├── HDD-6TB/          <- /srv/storage
└── MY STICK/         <- /media/MY STICK   (only while it is plugged in)
```

**The archive is a directory, not a mount.** It lives at `/1) Archive`, at the
root of the disk, named what it is called. It appears first in that disk's own
listing because digits sort before letters — no pin, no bind, no shortcut, and
no special case in the console. `deploy/setup-archive.sh` renames `/srv/archive`
to it, which on one filesystem is instant and moves no data.

Three earlier attempts put it somewhere else and each produced a duplicate: a
pin bound inside the disk folder, then a folder at the top level beside the
drives, then a bind named "1) Archive" inside the disk. Every one of them made
the same files reachable by two paths within one drive. A directory cannot do
that, which is the whole reason for the change.

**Mount propagation was making copies of everything.** systemd leaves `/`
shared, so `mount --bind / /srv/browse/SSD-1TB` joins the same peer group and
every mount created under `/` afterwards is copied inside the bind. pi2 had
grown a full set:

```
/srv/browse/SSD-1TB/srv/browse/HDD-6TB
/srv/browse/SSD-1TB/srv/browse/1) Archive
/srv/browse/SSD-1TB/srv/browse/2) Plugged in
```

Every disk folder is `--make-rprivate` immediately after it is bound now. A
drive's folder shows that drive as it was when the tree was built, and nothing
else.

A drive found only under `/media` is one somebody plugged in, and it gets a
folder like any other drive, named by its label — `PHOTOS` says more than
`SSD-32GB`. A disk already seen elsewhere is skipped there, because that mount
is the OS, or an already-mounted disk, turning up twice.

**The console counts drives the same way.** `fetchDisks` deduplicated by device
name, so `/dev/sda1` — the 512MB boot partition on the same physical disk as
`/dev/sda2` — came through as a third drive: "SSD 1TB, HDD 6TB, SSD 1GB" for a
board with two disks. It keys on the physical disk now, and the board's column
lists drives and nothing else.

**The sizing bug underneath all of it.** `subtree_bytes` stopped at a device
boundary the way `du -x` does, and a bind mount of a filesystem onto itself
keeps the same `st_dev`, so the guard never fired: `/srv/browse/SSD-1TB` is `/`
bound at a path inside `/`, and walking the root walked the whole disk twice.
`/srv` read 60.6GB on a disk holding 27.3GB. It reads `/proc/self/mountinfo`
now and refuses to descend into a mount point below the one it started at.

### `findmnt` answers with rows, not a row

`make automount` failed on pi2 with `umount: /media/bootfs: not mounted`, and
succeeded on pi while quietly doing none of what it claimed. One cause behind
both: every call here treated `findmnt` as though it returns a single line
naming a device. It returns a row per mount, a path can carry more than one,
and a `systemd` automount unit reports its source as `systemd-1` rather than a
device.

**The udev rule was invalid.** `findmnt -no SOURCE /boot/firmware` came back
three rows deep on pi, so the exclusion list was built as a multi-line string
and the rule went out as:

```
ENV{DEVNAME}!="/dev/sda2" ENV{DEVNAME}!="/dev/sda1
/dev/sda1
/dev/sda1"
```

udev cannot parse that, so the whole rule was dropped — which means the
automount rule has not been in force on either board, and the boot-partition
exclusion it exists to enforce was not enforcing anything.

**The cleanup unmounted nothing, then aborted.** It asked `findmnt -T`, which
answers for the filesystem *containing* a path rather than the one mounted at
it. An empty leftover directory under `/media` therefore reported the root
filesystem, matched the exclusion list, and the script tried to unmount
something that had never been mounted — fatal under `set -e`, which is pi2's
error. On pi the directories really were mounted, but the multi-row source
came back as `systemd-1` first and matched nothing, so the OS partitions stayed
mounted under `/media`, writable, which is the hazard the cleanup exists to
remove.

`device_at` now takes the first row naming a device, the cleanup asks whether
the path *is* a mount point rather than what contains it, and a drive that will
not unmount is reported rather than fatal — this is opportunistic tidying of an
old mistake, and it should not be able to end the run.

### Why `make browse` kept failing on pi2

```
umount: /srv/browse/SSD-1TB: target is busy.
  /srv/browse/SSD-1TB is busy. Close Finder windows and shells on it, then re-run.
```

Samba. `smbd` forks a process per connection and parks its working directory
inside the share, so one Finder window left open on a Mac anywhere on the
tailnet pins `/srv/browse/<disk>` — and the rebuild, which unmounts the whole
tree before recreating it, cannot proceed. pi2 hit it and pi did not because
pi2 is the board whose share was actually being browsed; it has nothing to do
with k3s, which mounts nothing under `/srv`.

Telling the operator to go and close windows was the wrong answer to a
condition the script can resolve itself: the share is being rebuilt, so the
thing serving it should not be running. `smbd` is stopped for the rebuild and
started again on the way out, including on failure — that is what the `trap`
is for. Finder reconnects on its own.

Two smaller changes fell out of the same look. The agent's own scan holds a
directory open while it runs, which is transient rather than a standing
conflict, so the unmount is retried a few times before it gives up. And when it
does give up, `fuser -vm` names the pid and command still holding the mount,
because a bare "target is busy" sends you hunting for a Finder window that may
not be the problem.

### Plug something in and read it

`deploy/setup-automount.sh`, and a folder in the share that mirrors it.

The goal is that a USB stick needs no commands: plug it in, it is in Finder and
in the console, unplug it and it is gone. Four things stood between that and
what the rule actually did.

**The mount point was built inline as `/media/$env{ID_FS_LABEL}`.** With no
label that expands to `/media/` — the directory itself, not a mount under it.
With a space in the label, udev splits `RUN` arguments on whitespace and hands
`systemd-mount` two arguments, so `MY STICK` mounted nowhere. The note this
script printed promised a device-name fallback the rule never had. Naming now
happens in a helper that reads the device itself, so a label never has to
survive udev's argument splitting: control characters and slashes come out, a
leading dot comes off (or Finder hides the drive), and a label left with
nothing falls back to `sda1`. Two sticks with the same label are told apart by
the first block of the UUID.

**FAT, exFAT and NTFS have no ownership of their own**, so they mounted
root-owned and read-only to everyone else — visible in the console, unreadable
through Samba, never writable. They now get `uid`/`gid`/`umask` at mount time.
Filesystems that *do* carry ownership are left alone: forcing a uid onto ext4
would hide the real owner of every file on the disk.

**exFAT and NTFS drivers were not installed.** The rule fired, the mount
failed, nothing said why. `exfatprogs` and `ntfs-3g` are installed as part of
the run, best-effort so a board with no network keeps what it has.

**`--automount=yes` deferred the mount to first access.** A deferred mount is
invisible to anything that looks without opening — a `df`, a directory
listing, the share's mirror of `/media`. Removable media now mounts for real,
at once. Fixed disks keep the deferred mount, which is the case it was for: a
sleeping 6TB should not spin up because something indexed a directory.

Then the share has to show it, and a plain bind mount cannot — a filesystem
mounted under the source after the bind was made stays invisible through it.
`2) Plugged in` is an **`--rbind`** of `/media` instead, which joins the same
propagation group, so mounts appearing later show up on their own with the
script never run again. `--make-rslave` makes that one-way: left shared,
unmounting the mirror would travel back and unmount the drive itself, so
rebuilding the folder tree would quietly eject every stick someone had plugged
in. The cleanup re-asserts slave before unmounting for the same reason, and
refuses to run its recursive delete at all while anything under `/srv/browse`
is still mounted.

The console needs nothing new: Glances already reports the mount, `/media` is
already a writable root, and adding it as a named root would put the same
drive in two rows of the same column — the duplication this PR exists to
remove.


## 11. Jellyfin, Kiwix, and where an app's files live

`deploy/install-media.sh`. Two new services, and the same storage layout
applied to the two that were already running.

**The split is by how a file is read, not by what it is called.**

```
SSD-1TB/1) Archive/Apps/     read at random — settings, databases, caches
├── Jellyfin/
│   ├── data/    library database, artwork
│   └── cache/   transcode scratch, image cache
├── Kiwix/       the library index
├── Vaultwarden/ all of it. settings, vault, attachments, key.
└── Uptime/      all of it. a few megabytes.

HDD-6TB/                     read start to finish — things you would call files
├── Jellyfin/
│   └── Media/   Movies/ and Shows/
└── Kiwix/       the .zim archives
```

The obvious cut — "app on the fast disk, data on the big disk" — is right in
spirit and wrong on one word. A database is called data and behaves like an
app: thousands of tiny reads scattered across a file, where a seek costs a
spinning disk around 5ms against an SSD's 0.1. Jellyfin's library index is
50MB. Putting it on the 6TB buys nothing and makes every library browse and
every scan feel slow from the far side of a seek. Its cache is worse in
principle: rewritten constantly, thrown away without consequence, and the least
useful possible tenant for six terabytes.

Uptime Kuma moved to the SSD entirely for the other half of the same argument.
It writes a heartbeat row per monitor every sixty seconds, forever — tiny,
constant, and enough on its own to keep a 6TB disk awake day and night for a
database that would fit on a floppy.

What is left on the 6TB is what the rule was always reaching for: films, `.zim`
archives, attachments. Things you would recognise as files, read start to
finish, which is the one thing a spinning disk is genuinely good at. Both paths
are `APPS_DIR` and `DATA_DIR` on the installer, so the cut is a decision rather
than a fact of the code.

**No PersistentVolumeClaims.** k3s' local-path provisioner puts a volume in
`/var/lib/rancher/k3s/storage/pvc-<uuid>_<ns>_<name>`. Vaultwarden's vault was
sitting in one: a directory named after a UUID, inside a container runtime's
internals. You cannot find it, you cannot back up what you cannot find, and it
tells you nothing about what is eating the disk. `hostPath` directories on
named drives do all three. The old PVCs are left in place by the installer —
repointing a workload and deleting its old volume in the same breath is how
data goes missing — and removed by hand once the pods are up.

**Jellyfin has to be told to split itself.** Left alone it writes the library
database and the artwork inside its config directory, so `JELLYFIN_CONFIG_DIR`,
`JELLYFIN_DATA_DIR` and `JELLYFIN_CACHE_DIR` are set explicitly. Without those
three the split would be a lie.

**Kiwix is given a library file, not a glob.** A shell glob that matches
nothing expands to a literal `*.zim`, and `kiwix-serve` exits on a file it
cannot open — so an empty content folder would be a crash loop on first deploy.
The library is rebuilt from whatever `.zim` files are present on every start,
which also means the folder is the only source of truth: there is no index that
can disagree with what is on the disk. Drop a file in and restart.

**What was deliberately not changed.** Vaultwarden and Uptime Kuma still run
exactly as they did — same user, same capabilities. Only their storage moved.
Kuma's entrypoint hands off through `setpriv` and already needed three
capabilities added back to survive that; forcing a uid on top of it is the
same guess that caused the crash loop recorded in `k8s/uptime-kuma.yaml`.
Jellyfin and Kiwix, which have no such history, run as the login user so their
files stay manageable from Finder. The cost of the caution is that
Vaultwarden's `db.sqlite3` is still written `0600 root` — findable and
visible now, which it was not before, but copying it out is a `sudo` job.

**hostPath volumes are not chowned by Kubernetes.** `fsGroup` is honoured for
volume types that support ownership management and a raw `hostPath` is not one
of them, so whatever a directory is created as is what the container gets.
Uptime Kuma is the case that nearly broke: its entrypoint drops to the image's
`node` account through `setpriv`, and it had been sitting on a local-path
volume — whose provisioner creates directories world-writable, which is the
only reason ownership was never a question before. Moving it to a plain
directory made it one.

Readiness proves a process answers, not that it can write where it was pointed,
and a media server that cannot write its database will serve a login page while
failing at the only thing it is for. The installer asks each container directly
after the rollout, with a `touch` in its own data folder, and prints the `id`
and `chown` to run if any of them cannot.

**A capability that was missing for as long as nothing was new.** Uptime Kuma's
entrypoint runs `chown -R node:node /app/data` before handing off, and the
manifest drops every capability except the three `setpriv` and ICMP need — so
`CAP_CHOWN` was gone. That was invisible while it sat on its old volume,
because `chown(1)` skips the syscall when ownership already matches and the
directory had been correct since the day it was created. Pointed at a fresh
directory it actually tries, and dies before Kuma's own code runs:

```
chown: changing ownership of '/app/data': Operation not permitted
```

`CHOWN` added. Its data also moved one level down, to `Uptime/data`, because
Kuma takes ownership of everything inside its mount — including the note left
beside it naming where the data went, which it then failed on by name.

This is the third time this workload has taught the same lesson: read what the
container says rather than reasoning about what it ought to need. The write
test at the end of the install is what caught it, and readiness alone would
not have.

**Jellyfin on a Pi 5 direct-plays and does not transcode.** A client that needs
the video re-encoded will stutter and 4K will not work. That is the hardware,
not the configuration.


### Noticing the 6TB fall off

Set up through Uptime Kuma's Settings > Backup > Import. The 6TB monitor
exists because it is the only disk on either board whose failure is not
already obvious.

Both boards boot from their SSD. If that disk goes, the board goes, and the
ping monitor already says so — a second monitor for it would only repeat what
is being said. The 6TB is separate: it can disappear without the board noticing
at all, and nothing else would tell you.

| endpoint | keyword |
|---|---|
| the agent on pi2, which reads `/sys/block` | `ST6000VX009` |

Sysfs rather than the mount table, because a disconnected disk leaves its mount
entry behind in `/proc/mounts` and only stops answering when something tries to
read it — so a mount-based check can sit green over a drive that is physically
gone. The device node vanishes the moment the disk leaves the bus. The model
string is the keyword because nothing else on the board can be confused for it.

Verified against the live board in both directions before being written down:
the real model string matches, and a model string for a disk that does not
exist does not. A monitor that cannot go down is decoration.

The Discord notification is deliberately not in that file. It is a webhook URL,
which is a credential, and the import assumes it is notification id 1 — the
first one set up, which it will be on a fresh install.

### Three more monitors, and a file that described a board that did not exist

The boards, the console, both Glances agents, both file shims and the three
OSINT endpoints were being watched. Jellyfin, the tunnel and the download
client were not, which is how the client spent a day connected to nothing
while every signal anyone looked at was green.

**And the 6TB was not being watched either**, despite this document saying it
was. The tracked `uptime-monitors.json` held exactly one monitor, that one,
and it had never been imported. The live Kuma held eight, none of which were
in the file — not one name overlapped. The file was a proposal that had been
written up as a fact, and it had been wrong for months without anyone noticing,
because nothing ever compares the two.

That is worse than a stale file. The install instructions said to import it,
and the import offers "Overwrite", which deletes every existing monitor and
its history. Following this repo's own instructions with the wrong radio
button would have wiped a working setup and replaced it with a single disk
check.

**The file is gone rather than fixed.** Kuma is the record of what is being
watched. A copy in git is a second record with no mechanism keeping it honest,
which is exactly how this one drifted, and the export also carries notification
tokens. Export from Kuma when a copy is wanted and keep it out of the repo. The
monitors themselves are described here instead, which is a document that does
not pretend to be executable.

| monitor | endpoint | keyword |
|---|---|---|
| HDD 6TB | the agent on pi2, reading `/sys/block` | `ST6000VX009` |
| Jellyfin | `/health` on its in-cluster name | `Healthy` |
| Torrent VPN tunnel | gluetun's control server, `/v1/vpn/status` | `"status":"running"` |
| Torrent swarm | qBittorrent's API, `/api/v2/transfer/info` | `"connection_status":"connected"` |

**The keyword is the check, not the status code.** gluetun's status route
answers `200` from the moment its control server binds a socket, with
`{"status":"stopped"}` in the body while WireGuard is still handshaking. A
plain HTTP monitor on it would be green before the tunnel existed — which is
not hypothetical, it is precisely what the pod's own `startupProbe` was doing,
and what let qBittorrent start into a pod with no `tun0`.

**The swarm monitor is the one that was missing.** "The tunnel is up" and "the
pod is ready" were both true throughout that failure and neither was the
question. Whether the client has a connection to the swarm is a third claim,
it is the one that matters, and qBittorrent answers it in one field. This
monitor goes down for that fault and the other two do not.

**Down is not always a fault.** The torrent stack is meant to be off most of
the time, so both torrent monitors sit red whenever it is switched off. That
is deliberate rather than tolerated: it makes the pair a session signal, and
Discord says when a download session comes up properly connected and when it
goes away. Nothing inside the cluster can tell "switched off" apart from
"broken" — the replica count is the difference and only the console reads it.
The console is not in the cluster yet (`make dashboard-k8s`, still unrun), and
its API is reachable only through `tailscale serve` on pi2, which a pod is
not a tailnet peer of. A monitor built on that would have been shipped untested,
which is the habit that caused the fault it is meant to catch.

**No password on the two torrent monitors.** qBittorrent's web interface
exempts the cluster's own subnets from its login, and Kuma's pod is in one of
them. The same exemption is why the tailnet proxy reaches it without one.

Matched with Uptime Kuma's own algorithm — axios parses the body, Kuma
`JSON.stringify`s anything that is not a string, then does `includes` — run
against the live endpoints rather than against what they ought to return. The
6TB keyword included, which had been written down as verified and was checked
again here because the rest of that section turned out not to be true.

### The node card, one row per drive

`FleetView.tsx` and the meter block in `index.css`.

The card showed a single `DISK` bar for the filesystem the board booted from,
which was true of pi and a lie about pi2 the moment the 6TB arrived. Every
drive gets a row now, named for what it is — `SSD1`, `HDD1`, `SD1` — numbered
per kind, because the number answers "which of these" and there is no useful
ordering between an SSD and a spinning disk to encode. Deliberately shorter
than the Files view's names: there the question is which drive you are opening
and "SSD 1TB" answers it, here the name sits in a 46px column beside a meter
and the capacity is already on the row.

The figure is used and total rather than a percentage. `27 GB / 917 GB` answers
both how full and how big; the meter carries the proportion on its own.

**Rows share a left edge and a right edge, and the meter takes what is left.**
So a row reading `27 GB / 917 GB` gets a shorter bar than one reading `5%`, and
the ragged bar ends are the figures saying how much they had to say. Fixed
columns would have to be as wide as the longest figure on any board, spending
that room on every row that does not need it.

Swap and the thumbnail cache keep sharing one line — neither is a drive, and
two halves cost one row where two rows cost two — and each now carries a small
tag naming the disk it sits on, which is the boot disk in both cases.

**The footer was `space-between`, so it never lined up.** Each reading sat
wherever its own text width put it: `3.1 W` on one board and `2.4 W` on the
next landed in different places and no two cards in the row agreed. Fixed
tracks fix that horizontally, and `margin-top:auto` fixes it vertically — a
board with one drive keeps its footer level with a board that has three,
because the slack collects above the rule instead of leaving the readings
stranded mid-card. Each reading also names itself now: `9h 33m` is not
guessable, and the row had the room.


## 12. qBittorrent behind AirVPN

`deploy/install-torrent.sh`. Two containers, one pod, one network namespace.

gluetun brings up WireGuard and owns the routing; qBittorrent has no network
of its own and uses whatever gluetun has set up. That shared namespace is the
whole security property — the client cannot be configured around the VPN,
cannot fall back to the host's connection, and cannot start talking before the
tunnel exists, because there is no other route for it to take.

It is also why the VPN is **not separately switchable**. A toggle that could
leave the client running with the tunnel down is exactly the failure this shape
exists to make impossible, so the two start and stop together.

**Nothing here touches the board's networking.** The WireGuard interface lives
in the pod's namespace; the Pi's routing table, and tailscaled with it, are in
a different one and never see it. A host-level VPN would take the default route
and drop Tailscale — the console, the shares and SSH with it — which is the
failure this arrangement avoids rather than risks.

**One exception to "everything through the tunnel", and it has to be right.**
The Tailscale ingress reaches this pod over cluster networking, and the
killswitch would drop the reply: the deployment comes up healthy and the page
never loads. `FIREWALL_OUTBOUND_SUBNETS` allows the cluster's own pod and service
networks to answer directly, and nothing outside them bypasses the VPN. Those
ranges are read from the live cluster at install time rather than written into
the manifest: k3s' defaults are only defaults, and a wrong value here does not
fail loudly — it presents as a healthy pod whose web interface never loads.

**The whole 6TB is mounted, not a folder inside it.** A finished download is
hard-linked into place, and a hard link cannot cross a mount boundary — two
mounts would mean copying every completed file, so a 40GB film would cost 80GB
for as long as it kept seeding.

**The image's default save path is `/downloads`, which is not mounted here.**
Left alone, every download would land in the container's writable layer,
disappear on the next restart, and fill the boot disk on the way. The installer
seeds a config once, and only when one is absent — qBittorrent owns that file
after its first start and a re-run must not stamp on settings changed since.

Incomplete files stay on the 6TB beside the finished ones rather than staging
on the SSD. Completing a download is then a rename inside one filesystem:
instant, and no second copy. A fast staging area on the other disk would mean
writing every byte twice and reading it once more, which on a spinning
destination is slower than not staging at all.

That wide mount is why **Vaultwarden's data moved to the SSD**. It belonged
there anyway by the rule the rest of the layout uses — a few megabytes of
SQLite read at random is the definition of what goes on the fast disk, and it
sat on the 6TB to be findable rather than because it was big. A torrent client
with write access to a password vault is a bad trade for a convenience.

### Seeing the tunnel, not trusting it

The tile does not say "running". It says where the traffic is leaving from.

`gluetun` is asked directly for `/v1/vpn/status` and `/v1/publicip/ip`, and the
address it reports is what the console shows. A pod being up and a tunnel being
up are different claims, and only the second one matters before a download
starts — so the console makes the second one rather than the first.

Two things had to be got right, and both were found by reading gluetun's
documentation rather than assuming:

**`/v1/openvpn/status` is the legacy OpenVPN path** and answers nothing on a
WireGuard tunnel. As a readiness probe it would never have passed, and the pod
would have sat un-ready forever with a tunnel that was working fine.

**Every control route is private by default** in recent versions — there are no
public routes at all. The probe would have been refused for the second reason
as well. Exactly two GET routes are opened, in a config file mounted from a
ConfigMap: the status, and the public IP. Neither is a secret; one is a boolean
and the other is AirVPN's own address, which every peer already sees. Anything
that could change the tunnel — `PUT /v1/vpn/status` in particular — stays
denied, so nothing else in the cluster can quietly drop the VPN.

The control port is on the Service and not on the Ingress, so it is reachable
inside the cluster and never from the tailnet.

### The console's power switch, and what it costs

The workload installs stopped and is meant to be off unless something is
downloading. Turning it on is a button on its Apps tile, which is the first
write the console can make against the cluster in the life of this project.

The grant is the smallest thing that can implement it:

| | |
|---|---|
| `Role`, not `ClusterRole` | it cannot leave the `pi` namespace |
| `deployments/scale` | it can set a replica count. It cannot edit the pod spec, read a secret, or exec into anything |
| `resourceNames` | this one deployment by name. Jellyfin, the vault and the console itself are out of reach |

The subresource is the part doing the work. Write access to a *deployment*
would be a node compromise waiting to happen — you could add a privileged
container with the host filesystem mounted. `scale` accepts one integer and
refuses everything else, so the worst it can do is start or stop a torrent
client, or ask for an absurd number of replicas on a board that is already
fully readable to the same process through the agents.

`make torrent-on` and `make torrent-off` throw the same switch from the Mac.
They exist so the button stays optional: delete the RoleBinding and the console
loses its only cluster write while both targets keep working.


### A class name that ate the toolbar

The selected toolbar button rendered at 8px in a monospace face with a pixel of
padding, while the unselected one beside it looked normal. Clicking either made
the other one shrink.

The tag naming which disk swap and the cache live on was given the class `on`.
A bare `.on`, in a stylesheet where `on` already means "selected" — on the
toolbar buttons, the segmented sort control, a selected file row. Every other
use is scoped to its component; that one was not, and being declared later in
the file it beat `.tbtn`'s own `font-size` on source order.

It is `on-disk` now. Worth remembering that a class name is a global, and that
a two-letter one describing a relationship ("on which disk") will collide with
the same two letters describing a state.

### Opening a service as an application

The Apps shelf gives every tile two ways in.

**The tile opens the app.** A window of its own with no tab strip, no address
bar and no bookmarks — `window.open` with `popup=yes`, sized to the screen and
named after the service so pressing the same tile twice raises the window that
is already open rather than stacking a second one behind it.

**The corner opens a browser tab**, and says so: `( Open in Browser )` where
the chevron used to be. The words replace the glyph and nothing else moves —
same corner, same tile. Padding for the thumb is cancelled by an equal negative
margin, so the hit area is bigger than the text without the text leaving the
corner. The health line stops short of it rather than running underneath, and
only tiles that lead somewhere else get one, since a tile that opens a view
inside the console has no browser to open it in.

**What this is not, and cannot be.** A web page cannot hand a link to an
installed PWA. There is no API for it, and whether one is installed is a
property of the machine someone happens to be holding rather than of this
console. What a page *can* ask for is a window with no browser furniture, which
on every platform this is used from looks and behaves like the application. The
genuine article — a Dock icon, its own login, surviving a browser restart — is
still Safari's File > Add to Dock, once per service, and nothing on the server
side can do it for you.

The `href` stays real and stays on the anchor, so cmd-click, middle-click and
Open in New Tab keep working exactly as the browser defines them. Only an
unmodified left click is taken over, and only to give it a better window. A
pop-up blocker turns the click into a plain tab rather than into nothing.

### No password on the download client

qBittorrent asked for one and nobody could answer it. Version 5 ships no
default: it generates a password at every start, prints it to its log once, and
voids it the moment the process restarts — so a password noted after one deploy
is wrong after the next, and the failure reads `Invalid Username or Password.
Server response: Unauthorized`, which sounds like a permissions problem rather
than an expired secret.

The right answer was not a better way to find the password. It was to stop
asking for one, for the same reason the console does not:

**Reaching this at all means being on the tailnet.** No port is open, the name
resolves nowhere else, and the certificate is issued to a machine only an
authenticated device can route to. Tailscale has already answered "who is
this". A second password on top of that is not a second lock — it is the same
lock, and one nobody holds a key to.

`WebUI\AuthSubnetWhitelist` is set to the cluster's own networks, which is
where the ingress proxy sits and the only place a request can arrive from.
Nothing outside the cluster can present those addresses. Applied whether or not
the installer wrote the config, since a board set up before this is holding a
generated password nobody knows.

**Two things this took to get right.**

qBittorrent rewrites its config when it exits, so an edit made while it is
running is discarded on the way out. The client is stopped, edited, and put
back the way it was found.

And the edit is done in python, not sed. The key contains a backslash, the
value contains slashes, and the whole thing passes through a heredoc: nested
sed escaping produced `WebUI\\AuthSubnetWhitelistEnabled`, a doubled
backslash and a key qBittorrent does not recognise. The first python attempt
then died on `bad escape \A`, because a backslash in a `re.sub` *replacement*
is an escape sequence too. It is line-based now, with no regular expression
anywhere near the value.

**A wrong turn worth recording.** The first diagnosis was `Host` header
validation: qBittorrent 5 checks it, recognises only localhost, and refuses
anything else with a page reading `Unauthorized` served as HTTP 200 — which
matched the symptom exactly, including every probe reporting the service
healthy. It was wrong. The login page renders on the tailnet name, so the
header is accepted. The fix that followed from it, `WebUI\ServerDomains=*`,
would have turned off a real defence against DNS rebinding to solve a problem
that did not exist. Dropped before it shipped.

### Where the tunnel comes out

An exit in Singapore, from a config generated for Europe.

Not a mistake in the config. **AirVPN's WireGuard keys are account-wide** — any
of their servers accepts them — so the file the keys came from says nothing
about where the connection lands. gluetun picks from the whole list, and
without being told otherwise the whole list is the whole world.

`SERVER_COUNTRIES` pins it, defaulting to the Netherlands, Germany and Belgium,
and overridable per run:

```
make torrent VPN_COUNTRIES="Netherlands"
```

Several countries rather than one so a server going out of service is a
different exit rather than no tunnel. Distance is the whole point: a link to
the far side of the world is slow however good it is, and every byte of a
download crosses it twice.
### Zero DHT nodes, and a tunnel that looked perfect

A magnet sat on "retrieving metadata" forever. The same magnet on a laptop
resolved instantly. The tunnel was up, reporting a healthy exit address, and
every probe said the service was fine.

qBittorrent's own log had it:

It was listening on loopback, and on the pod's own address on `eth0`, and on
no `tun0` at all.

Both containers start at once in an ordinary pod, and qBittorrent won the race
— it bound the interfaces that existed at that moment, then tried to reach the
swarm through `eth0`. The killswitch dropped every packet. `connection: firewalled`,
`dht_nodes: 0`, and a magnet that can never find a peer to ask for its
metadata.

The tunnel being healthy is what made it hard to see. Everything that could be
checked from outside said the VPN was working, because it was — nothing was
using it.

Three things, one cause:

**gluetun is a native sidecar now** — an init container with
`restartPolicy: Always` and a `startupProbe`. Init containers start in order,
and that probe is what holds qBittorrent back until the tunnel answers. The
ordering is a guarantee rather than a race that usually goes the right way.

**`Session\InterfaceName=tun0`** binds qBittorrent to the tunnel explicitly, so
even if the ordering were ever wrong again it has nowhere else to send. It is
also a second killswitch, at the application rather than the firewall.

**`Session\Port`** is set to the port reserved with AirVPN. It had been
choosing a random one, so the forwarded port pointed at nothing and the client
reported itself firewalled even once traffic could flow.


### One DNS answer, and everything downstream of it

Every tracker in a magnet reported the same thing:

```
Host not found (authoritative)
```

DHT sat at zero nodes. Nothing connected to a peer, ever, and a magnet stayed
on "downloading metadata" indefinitely.

**gluetun runs its own DNS-over-TLS resolver, points the pod's
`/etc/resolv.conf` at `127.0.0.1`, and ships a malicious-hostname blocklist
turned on by default.** Public BitTorrent trackers are on that list. A blocked
name is answered NXDOMAIN — an *authoritative denial*, not a timeout — which is
why it never presented as a network fault.

DHT was dead for the same reason: bootstrapping resolves
`router.bittorrent.com`.

**Everything else worked, and said so.** The tunnel was up, reporting a healthy
exit address. `curl https://ipinfo.io/ip` from inside the very same container
returned an AirVPN address, because ipinfo is not on the blocklist. Readiness
passed, the pod was 2/2, the web interface served. Every signal available said
the stack was fine, and every one of them was telling the truth. One DNS answer
was wrong.

`BLOCK_MALICIOUS=off`, and then the rest of gluetun's DNS with it.

There are two ways that resolver can fail and only one of them is the
blocklist. The other is the TLS half: gluetun resolves upstream over DNS-over-
TLS by default, which means a connection to port 853 has to succeed through the
tunnel before any name resolves at all, and gluetun's own issue tracker carries
reports of it timing out with precisely this symptom — magnets stuck
downloading metadata while everything else works. Neither cause is provable
from outside the pod and both are the same component, so the component goes:

```
DNS_UPSTREAM_RESOLVER_TYPE=plain
DNS_UPSTREAM_PLAIN_ADDRESSES=1.1.1.1:53,1.0.0.1:53
```

No TLS handshake to fail, no blocklist to consult, just a query sent through
the tunnel like any other packet. The tunnel is what keeps this private and it
does that job either way — encrypting a DNS query inside an already-encrypted
tunnel was buying nothing and cost everything.

**And then the actual difference.** Every working gluetun + qBittorrent setup
published anywhere is docker-compose. This one is Kubernetes, and Kubernetes
writes a different `/etc/resolv.conf`:

```
nameserver 127.0.0.1
search pi.svc.cluster.local svc.cluster.local cluster.local ...
options ndots:5
```

`ndots:5` means a name with fewer than five dots has the search list tried
**first**. `tracker.opentrackr.org` has two. So the first query actually sent
is for `tracker.opentrackr.org.pi.svc.cluster.local`, which does not exist,
and the answer is an authoritative NXDOMAIN — the exact string qBittorrent
reported against every tracker.

Docker sets no search domains and `ndots:1`. Same image, same gluetun, same
magnet, different resolver behaviour. `dnsPolicy: None` takes the search list
away; nothing in this pod resolves a cluster service by short name, so there is
nothing to lose.

Two public write-ups of the same symptom were read on the way
(qdm12/gluetun#2735, and a linuxserver.io thread on the identical tracker
error). Neither carries a fix — both are docker-compose users, where this
particular cause cannot occur, which is why the answer was not going to be
found by reading them.

**What this cost, and what caused the cost.** The route to it ran through three
wrong diagnoses — a pop-up blocker, `Host` header validation, and an interface
binding — each of which explained the symptom and none of which was true. Two
of them were fixed and shipped before being disproved. The common mistake was
reaching for a plausible cause instead of the log that names the actual one:
`torrents/trackers` had `Host not found (authoritative)` on it the whole time
and was not read until the fourth attempt.

**Removed on the way.** `Session\InterfaceName=tun0` was set on the theory that
qBittorrent had bound the wrong interface. It had, but that is not the key that
binds — `Session\Interface` is; `InterfaceName` is a label. Setting the real
one made things worse: qBittorrent tried `tun0:32250`, never bound, and went
from `firewalled` to `disconnected`. gluetun's default route already sends
everything through the tunnel and its firewall drops anything that is not, so
the binding was belt to an existing pair of braces and it did not fit. Gone.

### Firewalled, and a port nobody forwards

With DNS fixed the client downloads — a Debian ISO at 17 MiB/s through the
tunnel, which is what finally proved the stack end to end. Two things were
still wrong, and they are the same thing.

`connection_status: firewalled` and `listen_port: 32250`. AirVPN forwards the
port reserved by hand in its control panel; qBittorrent had picked a random one
and was listening there, so the forwarded port pointed at nothing and no peer
could open a connection inbound. A firewalled client can still download from
peers that accept incoming — which is why Debian worked — but it reaches far
fewer of them, and a magnet with a thin swarm may reach none.

**The port is set through qBittorrent's API now, not its config file.** The
file route failed silently twice: the value is read at startup and rewritten on
exit, so an edit made at the wrong moment vanishes, and a key with a backslash
in it that the client does not recognise looks identical on disk to one it
does. The API is what the settings page itself uses, applies immediately, and
says whether it worked. It is called from inside the pod against localhost,
which is exempt from the web interface's own authentication.

UPnP is turned off with it. UPnP negotiates a port with a router on the local
network; this client's only route out is a tunnel and the port at the far end
was reserved by hand. Left on, it retries forever against a gateway that will
never answer.


### The same failure again, and the probe that never held anything back

A magnet stuck on "retrieving metadata". `connection: firewalled`,
`dht_nodes: 0`, `last_external_address_v4` empty. The identical symptom to the
one two sections above says was fixed, on a stack carrying every fix since.

qBittorrent's own log, read first this time:

```
04:48:34  Trying to listen on the following list of IP addresses: "0.0.0.0:32250"
04:48:34  Successfully listening on IP. IP: "127.0.0.1"
04:48:34  Successfully listening on IP. IP: "<the pod's own eth0 address>"
04:48:34  Successfully listening on IP. IP: "::1"
04:48:34  Successfully listening on IP. IP: "fe80::...%eth0"
```

Loopback and `eth0`. No `tun0`. Exactly the race the native sidecar was
introduced to close.

But `tun0` existed. qBittorrent will list the pod's interfaces over its own
API, which is a shell inside the pod that needs no shell:

```
GET /api/v2/app/networkInterfaceList          lo, eth0, tun0
GET /api/v2/app/networkInterfaceAddressList   tun0 -> the WireGuard address
```

The tunnel was up. It was up before the check and it had been up for minutes.
It simply was not up at `04:48:34`, when qBittorrent enumerated interfaces
once and never looked again.

**The startupProbe was passing before the tunnel came up.** It was an
`httpGet` on gluetun's `/v1/vpn/status`, and an `httpGet` probe only sees the
status code. That route answers `200` from the moment gluetun's control server
binds a socket — with a body of `{"status":"stopped"}` while WireGuard is still
handshaking. So the probe passed in the first second or two, the init container
was declared started, qBittorrent launched into a pod with no `tun0`, and the
ordering guarantee that the whole native-sidecar shape exists to provide
guaranteed nothing at all.

An `exec` probe reads the body, which is where the answer actually is:

```yaml
startupProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - wget -qO- http://127.0.0.1:8000/v1/vpn/status | grep -q '"status":"running"'
```

**And the binding comes back, correctly this time.** The section above records
it being tried and removed, on the grounds that gluetun's routing and firewall
already send everything through the tunnel. That reasoning was wrong, and the
recurrence is what shows why: the killswitch is not a backstop for a socket
bound to `eth0`, it is the thing that silently drops its traffic. Names still
resolve, because the resolver is not bound to anything. Nothing errors. The
client just sits there.

The earlier attempt also failed for a reason worth separating from the idea.
Binding by *device name* does not work here — set `tun0` and libtorrent logs
`Trying to listen on "tun0:32250"` and then no success line at all, and the
client drops from `firewalled` to `disconnected`. Binding by *address* works
first time:

```
04:55:19  Trying to listen on the following list of IP addresses: "<tunnel address>:32250"
04:55:19  Successfully listening on IP. IP: "<tunnel address>". Port: "TCP/32250"
```

That is `current_interface_address` through the API, and the installer now
reads the address out of the same secret the WireGuard key came from — AirVPN
issues it per key, so it is stable across reconnects and never lands in this
repository.

Measured, in that order, from `dht_nodes: 0`:

| after | connection | DHT nodes | exit address |
|---|---|---|---|
| bound to eth0 | firewalled | 0 | none |
| bound to `tun0` by name | disconnected | 0 | none |
| bound to the tunnel address | connected | 324 | AirVPN's, as it should be |

Then a 1.6 GB magnet, from a standing start: metadata in seconds, 12 MB/s
sustained, complete in a little over two minutes.

**What this cost, and what caused it.** One line of a previous write-up said
the sidecar ordering was "a guarantee rather than a race that usually goes the
right way". It was neither — it was a race with an extra step in it. The claim
was written from the shape of the configuration rather than from evidence that
the shape did what it looked like it did, and no probe response body was ever
read to check. A probe that cannot fail is not a probe, and this one could not
fail while gluetun was running at all.

**Still open.** `listen_port` is `32250`, which is not the port AirVPN
forwards. Downloads are unaffected and the client reports `connected`, but it
accepts no incoming connection, so it seeds to far fewer peers than it could.
Re-running `deploy/install-torrent.sh` on the board sets it from the secret,
along with the binding above.

## 13. Immich on pi2

Written, not yet run on the board. Section reads as the plan until a deploy
has happened and been measured; the numbers below are the estimates it will be
checked against, not readings.

### The blocker that was not one

Issue #1 has carried Immich under *NO, holds — still needs a GPU* since the
start. That is wrong. Immich's own requirements ask for 6GB of RAM and two
cores, and name no GPU at all; hardware acceleration is an optional image tag
that makes indexing faster. What the original entry was really encoding was the
8GB board, where a photo manager's ML would have fought `llama-server` for
memory. pi2 is a different machine.

Read from the console API on 2026-09-05, before anything was written:

| | pi | pi2 |
|---|---|---|
| RAM available | 3.1GB of 7.9 | 13.7GB of 15.8 |
| CPU | 98.9%, load 5.6 | 2.6%, load 0.1 |
| Free | 478GB SSD | 954GB SSD, 5.9TB HDD |

pi is saturated by the OSINT analytics worker and was never a candidate. pi2
is doing nothing at all, which is what makes a slow CPU-only backfill free
rather than expensive.

All four images are published for `linux/arm64`, checked against ghcr.io rather
than assumed.

### Four containers

More than anything else here runs, and the count is not negotiable:

| | |
|---|---|
| `immich-server` | API, web interface, and the job workers |
| `immich-machine-learning` | CLIP and the face model, CPU only |
| `immich-postgres` | library index and vector search index |
| `immich-redis` | the job queue, Valkey |

The Postgres cannot be pi's. Immich's image carries VectorChord and
pgvecto.rs compiled in, and the search index is a column in that database
rather than a service beside it. Swapping in stock `postgres:14` gives a server
that starts, accepts connections, and fails every search. This is the same
objection that keeps Miniflux off the list — *wants its own Postgres* — and it
is the one case where the answer is yes anyway.

Valkey gets no volume. It holds "these twenty photos still need thumbnails",
which the admin Jobs page can re-run with one click. Persisting it would keep a
disk awake for writes nobody would miss.

### Storage, the same split as section 11

| | |
|---|---|
| `1) Archive/Apps/Immich/db` | Postgres. SSD, `700`, owned by uid 999 |
| `1) Archive/Apps/Immich/model-cache` | downloaded weights. SSD |
| `/srv/storage/Immich` | the photos. 6TB |

The database is the case section 11 was written about: thousands of small
random reads, roughly 5ms a seek on a spinning disk against 0.1ms on the SSD.
Putting it on the 6TB because it is "data" would have made every search slow.

Every `hostPath` is `type: Directory`, never `DirectoryOrCreate`, for the
reason `k8s/vaultwarden.yaml` records: with the 6TB unmounted `/srv/storage`
still exists as an empty mount point on the boot disk, and `DirectoryOrCreate`
would begin filling the boot SSD with a second library that remounting the disk
would then hide underneath the real one.

`deploy/install-immich.sh` also refuses outright if `DATA_DIR` is not a mount
point, so the failure is a sentence rather than a pod stuck in
`ContainerCreating`.

### The Ingress is not Traefik

`ingressClassName: tailscale` means the operator runs its own proxy pod that
forwards straight to the Service. A first draft of the manifest carried a
`traefik.ingress.kubernetes.io/router.middlewares` annotation and a `Middleware`
raising the request body limit for phone uploads. Both would have been accepted
by the API server and then ignored, which is worse than absent. Removed, and
the manifest now says why so it is not re-added.

### Probes

The liveness probes are far more generous than any default worth copying:

| | |
|---|---|
| `immich-server` | 300s initial delay |
| `immich-machine-learning` | 180s |
| `immich-postgres` | 90s |

The server's first start runs every schema migration against an empty database
on four ARM cores, and the ML container's first request loads a model that is
not in the cache yet. A probe that fires during either produces a crash loop
that reads exactly like a broken image — the same lesson `k8s/uptime-kuma.yaml`
records about guessing at an entrypoint.

### Budget

Estimates, to be checked after a deploy:

| | requests | limit |
|---|---|---|
| server | 512Mi | 2Gi |
| machine-learning | 256Mi | 3Gi |
| postgres | 256Mi | 1Gi |
| valkey | 32Mi | 256Mi |

`MACHINE_LEARNING_MODEL_TTL` is left at its default of 300, which unloads a
model after five minutes idle. That is the difference between roughly a
gigabyte resident all day and a gigabyte only while the queue is draining.

Requests total about 1GB against 13.7GB free. The limits are ceilings for a
backfill, not an expectation.

CPU is capped too, which the first draft missed entirely — it set requests and
no limits, so a backfill could have taken all four cores for as long as the
queue lasted:

| | CPU limit |
|---|---|
| server | 1500m |
| machine-learning | 1000m |
| postgres | 500m |
| valkey | 100m |
| total | 3100m of 4000m |

Roughly nine tenths of a core stays outside Immich's reach whatever it does,
which is what k3s, the metrics agent, the console, Jellyfin and Kiwix keep
running out of. The ML container gets the tightest cap because indexing is a
batch job and nobody is waiting on it: one core makes a backfill about four
times slower and costs nothing else. The server gets more because it answers
the phone and the browser, where throttling is felt as latency.

Deliberately not a `ResourceQuota` on the namespace. `pi` also holds the
console, Uptime Kuma, Vaultwarden, Jellyfin, Kiwix and qBittorrent, and a quota
on CPU or memory makes the API server reject every pod in the namespace that
does not declare both. That would break the running apps at their next restart
rather than at apply time. With four fixed containers the sum above is already
bounded by the per-container limits, so a quota adds a footgun and no ceiling.

Disk has no equivalent. Nothing here caps the photo tree on a 6TB with 5.9TB
free; the lever is Immich's own per-user storage quota, which is a policy about
people rather than about containers.

### Jobs, and the three schedules

Machine learning is queued per upload, not continuous and not at search time:

```
Upload → Metadata → Storage Template → Thumbnails
                                         ├→ Smart Search → Duplicate Detection
                                         ├→ Face Detection → Facial Recognition
                                         ├→ OCR
                                         └→ Video Transcoding
```

The queue drains and the workers sleep. Searching is a lookup against work
already done, so it costs the same at 5000 photos as at 500.

Three recurring schedules exist and all three default to the middle of the
night. The installer prints them, and they are set by hand in the admin UI
rather than pinned in the manifest, because they are preferences rather than
deployment:

| | default | wanted |
|---|---|---|
| `nightlyTasks.startTime` | `00:00` | `06:00` |
| `library.scan.cronExpression` | `0 0 * * *` | `0 6 * * *` |
| `backup.database.cronExpression` | `0 02 * * *` | off |

`TZ` is written into a ConfigMap from the board's own clock by the installer.
Without it all three run in UTC and a `06:00` setting silently means something
else — `TZ` is what Immich uses for cron execution, not just log timestamps.

The third is a database dump, on by default. Nothing else on these boards runs
a scheduled backup, so it is a decision rather than a default. It would dump
the database only: albums, faces and the search index, not the photos.

### What it costs

Immich owns its data layout, which is the one real argument against it and a
better one than the GPU ever was. The storage template is set to
`{{y}}/{{MM}}/{{filename}}` so the tree stays walkable in Finder and in the
console's file browser, and existing photos can be added as an external
library, which Immich reads and never moves.

Losing the Postgres costs albums, faces and search. Not the pictures.

### Checked against upstream, after the fact

The manifest was written first and the homework done second, which is the
wrong order. Three things came back, and two of them changed it.

**There is an official Helm chart** — `immich-app/immich-charts`, maintained,
and Immich's Kubernetes page points at it. It does not fit. It ships no
database: `DB_HOSTNAME` is left blank in the values file and the examples point
at a CloudNativePG cluster, so using it means running a Postgres operator on
pi2 or hand-writing this Postgres anyway. Its library volume is
`existingClaim`, with "automatically creating the library volume is not
supported by this chart" — a PersistentVolumeClaim for the photos, which is the
thing #113 moved the vault out of and section 11 was written to avoid. Kept the
hand-written manifest, now for a stated reason rather than by reflex.

**The Alpine DNS caveat does not apply.** Immich's Kubernetes page warns that
its Alpine images hit a musl resolver bug when the host has a search domain
set. Checked the image config for all four rather than assuming: server is
Debian trixie, machine-learning bookworm, the Postgres is stock `postgres:14`
underneath, and the pinned Valkey digest is the Debian variant, not the
`-alpine` tag the Helm chart defaults to. Nothing here is Alpine.

**`immich-app/immich#26162` is open and unfixed**, and it is the one that
matters. `immich-api` grows until the cgroup kills it at 95-97% of whatever
limit it was given — one reporter reproduced that at both 4g and 6g, on an
idle instance with no jobs queued. It is not JS heap: that reporter measured a
V8 heap limit of 2.24GB against an RSS of 5.8GB, so the growth is native and
`NODE_OPTIONS` does not reach it. The suspected mechanism is a client retrying
an asset that can never succeed, and it correlates with large libraries and an
iOS client backing up — which is this deployment.

That changes what a limit is for. Raising it buys nothing, because the process
grows to fill whatever it is given; the 2Gi stays, and its comment now says why.
On compose, which is what everyone in that thread runs, hitting `mem_limit`
takes the host down with it. Here kubelet restarts one container in seconds and
the other three keep running. The symptom to watch for is `immich-server`
accumulating restarts with `OOMKilled` as its last state on an otherwise idle
board — that is the upstream bug, not a mistake in this manifest.

The estimates in the budget table above are therefore a floor for a small
library and not a promise. What actually happens gets read off the console.

### The first deploy, and what broke

`make photos` ran to completion on the manifests. Postgres and Valkey came up
and stayed up. Both Immich containers crash-looped, six restarts in four
minutes, and the image had nothing to do with it — it pulled in 79 seconds.

```
Initializing Immich v3.1.0
Detected CPU Cores: 1
Error: Invalid environment variables:
  - [IMMICH_PORT] Invalid input: expected number, received NaN
```

The kubelet still injects Docker-link-era environment variables for every
Service in the namespace. A Service named `immich` becomes `IMMICH_PORT`,
`IMMICH_SERVICE_HOST`, `IMMICH_PORT_80_TCP` and the rest, in every pod in
`pi`. `IMMICH_PORT` is also the name of Immich's own listening-port setting,
which expects a number, so it read `tcp://10.43.x.x:80` and exited on its first
line. Both Immich containers read that variable; Postgres and Valkey have never
heard of it, which is exactly why two of four were healthy.

The collision is between the Service name and the application's own
vocabulary, so no amount of reading the app's configuration would have found
it. `enableServiceLinks: false` on all four pods is the fix, rather than
renaming the Service, because the next collision is already latent: name
anything in this namespace `redis` and `REDIS_PORT` arrives as a URL too.
Nothing here wanted the injected variables — every address in the manifest is a
DNS name. Both ports are now also set explicitly, since an explicit env entry
beats an injected one.

Worth keeping from that log line: **Detected CPU Cores: 1**. The `cpu` limits
are not decoration — Immich reads the cgroup quota and sizes itself to it, so
the caps above are doing exactly what they were written to do.

### Not verified

Nothing here has run. The manifest validates clean against the Kubernetes
1.36 schema under `kubeconform -strict`, and the two probe paths were read out
of Immich's source rather than guessed — `/ping` on the ML container, and
`server.controller.ts` plus the `/api` global prefix for `/api/server/ping`.
That is the whole of it. Untested: whether the images pull on this board,
whether Postgres accepts the data directory's ownership, first-start migration
time, real idle memory, and how long a backfill actually takes per photo.


## 14. One PC: homelab

Both boards were replaced by one x86 desktop, homelab (`docs/pc.md` is the
machine as built). Everything that ran under k3s on pi2 moved across; the
detailed history of that move is issue #197, and what is still open is #198.
This section covers what happened on the PC afterwards.

### The SSD mirror, built and then broken by a drive

The two SSDs became an mdadm RAID 1 on 2026-10-14 (`deploy/ssd-mirror.sh`):
the Samsung 860 EVO as the main half, a 512GB T-Force Vulcan Z as the
write-mostly backup half. Getting there took six failed runs, one of which
unmounted the host's own `/sys` and `/dev/pts` and needed the power cut at the
house. Every failure, its cause and the rules it left behind are in issue
#199; the short version is identify disks by `/dev/disk/by-id` only, never
`umount -R` a tree that may hold a propagated `/sys`, and never iterate on the
live machine at night.

**On 16 Oct at 07:04 the T-Force dropped out mid-run.** mdadm marked both of
its partitions failed and the PC carried on, degraded, on the Samsung, which is
what the mirror is for. It never came back, and finding out why took a day:

| Test | Result |
|---|---|
| Reboot, full power cut, reseat | not detected |
| T-Force on the Samsung's data cable and port | not detected; the Samsung worked on the T-Force's |
| T-Force on the Samsung's power plug as well | not detected; the Samsung worked on the T-Force's |
| Kernel log at boot | `ata5: SATA link down (SStatus 0)`: the port sees no device at all |
| USB-SATA adapter on a laptop, first try | worked: 512GB, all five partitions, SMART "Verified" |
| Second try | the adapter enumerated, the drive did not |
| Third try, contacts cleaned | appeared, then the drive and the adapter vanished within a minute, untouched |

It was also hot to the touch while idle, which means power reached it and its
controller was running without a link. **Verdict: the drive is failing.** It
is under warranty and going back.

Two things worth keeping from the diagnosis. `SStatus 0` is not a failed
handshake but no presence on the wire, so it points at the drive or its
connector before any software. And one good result does not clear a drive:
the first USB test looked like a healthy drive with a PC-side problem, and was
written up that way, until the next two tests showed it dropping out on its
own. Change one thing per test, and repeat the test that passed.

**Still open:** mdmonitor logged the Fail events at 07:05, but the first
Discord alert anyone saw was the next day, on a boot. Whether the 07:05 post
went out was never confirmed. A replacement backup half goes in with
`ssd-mirror.sh add <disk> --backup`; a returning member would use
`mdadm --re-add`, never `add`.

### Fans by hand

The Fleet view's fan tiles open a slider (`agent/pi-metrics.py`'s `POST /fan`,
applied by `deploy/fan-curve.py`): Auto, Off for the case fans, or a speed.
The agent writes `/run/pi-fans-manual/manual.json` and the curve reads it, so a
manual speed lasts until Auto or a reboot. Two limits keep a slider from doing
harm: the CPU fan never goes below its floor, and past 70° on the CPU, 75° on
the GPU or 45° on a drive the temperature curve wins whenever it asks for more.
Case fans snap up to their start duty or go fully off, because between the two
they stall.

### A local AI on the idle GPU

The GTX 1050 Ti sat idle except for Jellyfin transcodes, so it now also runs a
small model that answers questions about the PC in its own Discord channel
(issue #200). Local only, read-only, and nothing runs on its own.

- **Runtime: llama.cpp built from source**, not pulled (`ai/Dockerfile`).
  Every prebuilt image was wrong for this card: the official CUDA builds use
  12.8 (needs NVIDIA driver 570; Debian ships 550) or 13 (dropped Pascal).
  CUDA 12.4.1, compiled for `sm_61` only. Ollama was rejected for the same
  driver requirement.
- **Model: Qwen3.5-4B at Q4_K_M**, checksummed on download. 8K context, flash
  attention, an 8-bit KV cache. Measured: 19 tokens/s writing, 96 tokens/s
  reading, 3.1GB of the card's 4GB. It unloads after ten idle minutes.
- **Sharing the card with Jellyfin needs nothing.** Both pods use the
  `nvidia` RuntimeClass with `NVIDIA_VISIBLE_DEVICES=all` and no device
  plugin, so neither holds the GPU exclusively. Tested with the model loaded
  and a transcode running: smooth.
- **First deploy failed its probes** because `llama-server` listens on
  127.0.0.1 by default; `--host 0.0.0.0` fixed it.
- **Talking to it:** the existing Discord bot (`pi-bot`) sends every message in
  one channel to `deploy/pi-ask.py`, which gives the model a fixed list of
  read-only checks: apps, logs, the mirror, drives, SMART, temperatures, the
  GPU, Kuma, incidents. The model picks a check and, for some, an app or disk
  name that must be one of the real ones. It never gets a shell. Asked "is
  everything ok?" it ran the overview and the mirror check and correctly
  reported the degraded mirror.
- Known noise: a question pegs the GPU at 99% while it answers, which the
  watcher records as trouble.

### Noise that was not trouble

Nextcloud's Postgres logs a `duplicate key` error about every hour on
`oc_filecache_extended_pkey` and `fs_storage_path_hash`. It is Collabora's
hourly refresh of its discovery files racing itself, harmless, and the morning
report now skips those two constraints.

systemd printed `Failed to allocate directory watch: Too many open files` on
every `daemon-reload`. Not open files: the per-user inotify instance limit
(128 by default), which k3s and its containers exhaust. Raised in
`/etc/sysctl.d/90-inotify.conf` to 1024 instances and 524288 watches.

### Gitea

Self-hosted Git at `git.<tailnet>.ts.net` (issue #201): rootless Gitea, the
login user's UID, SQLite, HTTPS only. Registration is closed; the installer
creates the admin. The database and `app.ini` are on the SSD with the other
apps' settings, the repos on HDD2 with their data. The Status tab counts repos
on disk, so it needs no token.

Backups are manual: `sudo gitea-backup` runs Gitea's own `gitea dump`, checks
the archive holds the database and `app.ini`, and moves it to
`/srv/hdd2/Backups/Gitea`. The image's default data path would have put the
dump folder inside what `gitea dump` copies, so each backup would have held
the last one; `APP_DATA_PATH` is moved to `data/` to stop that.

Two things the first install hit: Gitea rejects `@` in usernames (the CLI says
so only after generating a password), and the first manifest put the repos on
the SSD. That was moved to HDD2 before anything was pushed.

**What goes where.** GitHub is public, so it gets the code, the docs and this
log, under the no-names, no-secrets rules. Gitea is private and on the PC, so
it gets everything: the repo with its issues, the working notes and chat
history, and the PC's secrets and system configs.


### Job-search bot and its live browser

A personal job-search bot moved here from a laptop so it can run around the
clock (issue #202). It runs as the login user, not in k3s: a real browser,
a long-lived CLI login and a virtual screen are simpler on the host. Code and
settings are on the SSD; its database, documents, logs and reports are on HDD2
under `ApplyPilot/`, so the reports open over Samba from the Mac.

The browser draws on a virtual screen (Xvfb `:99`, openbox), shared by x11vnc
on localhost only and shown by noVNC on port 6080, bound to the tailnet
address and nothing else. A home Chromium window keeps the view from ever
being a black screen. A CAPTCHA the bot cannot solve becomes a Discord ping
with the live-view link, and the user solves it from a phone.

The Status tab's Browser row says who is on it. `pi-when content` adds Browser
rows to the active list: the bot when its round is running, a Claude session,
and each tailnet device with an established connection to port 6080, named
from `tailscale status`. Checked live: the row read "Free", then named the
laptop as soon as it opened the view.

Kuma watches it with two monitors: a push from the bot when its browser and
profiles are fine, and a check of the live-view page.

### The job bot in its own container

The bot reads untrusted job pages, and it ran as `homelab`, which has
passwordless sudo and sees everything. Rather than give up passwordless sudo
(the owner drives the PC from a phone), the bot moved out (issue #204):
`applypilot/` is its image, `k8s/applypilot.yaml` the pod, and
`deploy/install-applypilot.sh` builds it with buildkit like the console and
switches over. The bot's code, data, Chrome profiles and Gmail login stay where
they were and are mounted in at the same paths. Google sign-ins carried over:
Chrome's cookies there use the basic store, not a keyring.

What went wrong on the way:

- **The agent's browser tool writes beside Playwright's browsers.** Mounted
  read-only, every job failed as `browser_unavailable` with `EROFS` before a
  page opened. The bot now has its own writable copy in its home.
- **A round started from `kubectl exec` died with the terminal.** `nohup` was
  not enough: when the exec session with a terminal closed, its background
  round went too. `jobbot start` now uses `setsid -f` and waits for
  `round.pid`.
- **Kuma could not check `https://<homelab>:8443`.** `tailscale serve` answers
  tailnet devices, and a pod is not one. Kuma checks the `liveview` Service
  inside the cluster instead, and the network policy lets Kuma in on that port.
- **Adding an ACL entry widens the mask**, which would have widened the
  `www-data` entries on the HDD folders (rwx, held to r-x or less by the
  mask). The ACL script pins every existing entry to what it granted first.
- **The protocol hooks** reject private addresses and home paths in commits,
  and the usual process manager's name trips the word screen. The manifest
  gets its addresses and paths filled in at install, and runit keeps the
  services up.

### Jellyfin's door to the internet

Jellyfin is on Funnel for about ten people, because one user's
provider slows Tailscale itself to about 0.5 Mbit/s. The audit (#204) had
listed "no Funnel" as already right; that was wrong, and was corrected there.

What was found on the live server: no account ever locked. Jellyfin only
counts wrong passwords when `LoginAttemptsBeforeLockout` has a value, and all
six had none, so slow guessing stayed under `jellyfin-guard`'s thresholds.
And Jellyfin could not tell the internet from home: with no `KnownProxies`,
every visitor was the Tailscale proxy pod, a private address, so "local".

Fixed in three parts:

- **Locks.** `deploy/jellyfin-accounts.py --apply`: 5 wrong passwords disable
  an account, 3 the admin; the admin may not sign in from the internet.
  `--unlock NAME` works through the API key, so even a locked-out admin is
  one command away.
- **Real addresses.** Tailscale's serve proxy overwrites `X-Forwarded-For`
  with the visitor's address and adds `Tailscale-Funnel-Request: ?1` to
  Funnel requests; a visitor can fake neither. Jellyfin now trusts forwarded
  addresses from the pod network only (`KnownProxies`) and counts the pods,
  home and the tailnet as local (`LocalNetworkSubnets`). Its default with
  nothing set is every private range, which leaves the tailnet out.
- **A bouncer.** Unprivileged Nginx between the Tailscale proxy and Jellyfin
  (`k8s/jellyfin-edge.yaml`). For Funnel requests it refuses admin-only
  changes with 403 and limits sign-ins per address to 5 at once, then one
  every 10 seconds (6 a minute, burst 4; 429 past that). It
  logs each request with the real address and whether it came from the
  internet, the path only (stream URLs carry an API key in the query).

Tested from the internet side, by resolving the Funnel name through public
DNS so the request leaves and comes back through Funnel: public info 200,
the log page and a plugin install 403, the sixth sign-in in a minute 429.
A 1 GB film read through the bouncer and straight from Jellyfin both ran at
about 860 Mbit/s, so the extra hop costs nothing a viewer could notice.

Two things the switch hit: the operator rewrote the proxy's serve config but
the running proxy kept the old route until it restarted (the installer now
restarts it), and Claude Code's web fetch runs on the Mac, so it reached
Jellyfin over the tailnet and could not test Funnel.

### Docs caught up, and three things found on the way

A check of every doc against the last forty commits found the README, the
deploy, dashboard and storage pages still describing the two Pis. All were
rewritten for homelab. Three findings were more than wording:

- **`make` would have rolled homelab back.** Every target reset the PC's checkout
  to `origin/main`, and the PC's work is on `feat/pc-server`. Any `make` run
  would have installed old code. Targets now deploy the branch the Mac is on
  (`BRANCH=` overrides), and so does `make bootstrap`.
- **Uptime Kuma 2.x has no export.** Settings > Backup is gone, so the JSON
  files `kuma-import-json.py` writes have nowhere to go. A copy of Kuma is its
  database: `sqlite3 kuma.db ".backup <file>"`, safe while it runs. A monitor
  changed by editing that database needs Kuma stopped first: it works from the
  monitors it loaded at start.
- **homelab has 24 GB of RAM** (8 + 8 + 4 + 4), not the 16 the docs said.

Nextcloud's admin view now uses Finder's drive names (`HDD-6TB`, `HDD-6TB-2`,
`SSD-250GB`, `SSD-512GB`) and gained the 1TB as `HDD-1TB`, read-only. Nextcloud
has no command to rename external storage, so the installer renames the old
`HDD1`/`HDD2`/`SSD1`/`SSD2` rows in its database instead of deleting and
re-creating them, which keeps what it knows about the files.

## Security posture

| | |
|---|---|
| API server `:6443` | LAN only. No router forwarding. |
| Unauthenticated request | `401 Unauthorized` — verified |
| Auth | TLS client certificate. No password, nothing to brute-force. |
| Cert scope | `cluster-admin`, unrestricted |
| `~/.kube/config-pi2` | mode 600 |

The exposure is not the API server. It is the kubeconfig itself: plaintext admin credentials with no expiry. A `.gitignore` covering kubeconfigs, tokens, keys, env files and disk images landed with this file.

SSH remains password-authenticated on both boards, which is the weaker of the two doors.

That was the Pi era. The PC's security, from the October 2026 audit (issue
#204), is in [pc.md](pc.md#security).

---

## Open

The list below is from the Pi era. What is open on the PC is issue #198.

- [x] **12V supply.** A 12V 3A barrel is fitted and working: the drive spins up and the SATA link trains at 6.0 Gbps, which no dead or wrong-polarity supply would allow. Never metered — proven by the disk instead, which is the test that matters. Comfortable for one 3.5" drive, marginal for two.
- [x] **Confirm the SATA HAT enumerates on pi2.** Done, read out of `/sys` over the shim's file endpoint without a shell on the board. `0001:01:00.0` is an ASMedia `1b21:0612` SATA controller in AHCI mode, linked at 5.0 GT/s x1 — Gen 2, which is that part's maximum — in power state D0 with the `ahci` driver bound. It creates `ata1` and `ata2`. pi2's own 1TB SSD is on `host0`, not on the HAT. Both ports were free at that check; `link1` now carries the 6TB at 6.0 Gbps.
- [x] **Mount the 6TB as plain storage.** Done, live: formatted ext4 and mounted at `/srv/storage` on a `nofail` fstab line of its own — the documented "mount it anywhere, by UUID" route, fixed rather than plug-in. `/srv/archive` never moved in the end: a half-run migration was undone folder by folder, and the SSD's original is the copy in place. The copy the detour left on the 6TB is just files, deletable whenever. Disk naming — `SSD 1TB` / `HDD 6TB` in the console and Finder alike — lands with this PR: the agent reports whether a disk spins, and both the Files view and `setup-browse.sh` name from that plus the sold-as size.
- [ ] **Run `make agents` and `make browse` on both boards.** The archive becomes `1) Archive` at the top of the share, the duplicate pin inside the disk folder goes, and the sizer stops counting a self-bind twice. Until the re-run, the console keeps reporting `/srv` at 60.6GB on a disk holding 27.3GB.
- [ ] **Run `make automount` on both boards.** Two reasons now. The rule was mounting each board's own root and boot partitions under `/media` at every boot — writable, through the console's file browser — fixed by excluding them by device and PARTUUID, and both boards still carry the self-mounts. It also installs the helper that makes a plugged-in stick mount immediately, with a usable name and an owner. Until it runs, a USB does nothing on either board.
- [ ] **cgroup flag on pi1.** Its `mem_limit`s are unenforced today, and container memory reads `—` on the dashboard until it is applied. Needs a reboot, which drops OSINT for about a minute.
- [ ] Point `dashboard/server/apps.json` at the real services. It carries two placeholder entries.
- [ ] DHCP reservations for both boards in the home router.
- [ ] Clear the two dead public keys from pi2's `authorized_keys`.
- [ ] Image pi1's SD card. Boot-only and holds no data, but its loss means the board will not start.
- [ ] Wired ethernet. Both boards are on `wlan0`; issue #1 says a first Time Machine backup over wifi is hours.
- [ ] **Run `make photos`.** Section 13 is written but has never run on pi2. Until it does, there is no photo library and nothing for the phone to back up to.

Deferred by decision, not oversight:

- **pi1 joining the cluster.** Waits until `llama-server` moves to the Mac Mini and pi1's real free RAM can be measured, since `--kubelet-arg=system-reserved` must be a measured number. A scheduler that cannot see Docker will place pods into RAM that OSINT already holds.
- **Migrating OSINT into k8s.** Not planned. Issue #2 settled it: containers pinned to their own disk gain nothing from an orchestrator.
- **Moving the dashboard into k3s.** Merged in [#92](../../pull/92), not yet run on the board. `make dashboard-k8s`. Section 10 gets written once it has actually been deployed and measured; until then section 8 above is still what is live on pi2.
