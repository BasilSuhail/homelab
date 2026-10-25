# Storage

Two ways into the same files. Both point at `/srv/browse`, and neither owns
anything: underneath are plain directories on plain filesystems, so either can
be removed without losing a byte.

| | Storage view | Samba |
|---|---|---|
| Where | the console, any browser | Finder on the Mac |
| What it is for | finding what is eating a disk | moving files, backups |
| Writes | no, read-only by design | yes |
| Hidden files | shown | shown |

## The browse root

One directory per disk, named by what the disk is, so both doors into the
files answer "which drive?" before "where on it?". On homelab:

```
/srv/browse/
├── SSD-250GB/      the Samsung: Debian, and /srv/ssd with "1) Archive"
├── SSD-512GB/      the T-Force's spare space; empty since it failed
├── HDD-6TB/        HDD1, /srv/storage: media, downloads
├── HDD-6TB-2/      HDD2, /srv/hdd2: the apps' data
└── HDD-1TB/        HDD3, /srv/hdd1: the old NTFS disk
```

Two disks of the same size get a number, `HDD-6TB-2`. Which holds what:
[pc.md](pc.md#disks).

The console's Files view carries the same names from the same sysfs facts —
whether the disk spins, and its sold-as size — so Finder and the console agree
without sharing code.

Bind mounts rather than symlinks. Samba only follows a symlink out of a share
with `wide links = yes`, which switches off a protection worth keeping; a bind
mount gives the same view without that.

A mount under a bound root is invisible through the bind — the bind shows the
directory underneath, not what is mounted on it — so a second filesystem on the
same disk is bound again inside the disk's folder, at its real path. A
filesystem on a *different* disk is deliberately not: an HDD's mount point
inside `SSD-250GB` shows the empty directory that is really there, and the HDD
is reached under its own name.

Build or rebuild it with:

```bash
make browse
```

It reads what is mounted, names each physical disk from sysfs, binds each
disk's filesystem into a folder of its own, and writes an fstab line per bind
so the tree survives a reboot. It is idempotent: a re-run clears the old tree
and rebuilds, and refuses to continue while Finder or a shell holds a folder
open, because deleting around a live mount is how files get lost.

**Adding a disk later** is two steps: mount it anywhere (`/mnt/whatever`, by
UUID, with `nofail`), then re-run the script. It appears under its own name in
the console and in Finder with no further configuration.

## The Storage view

`Storage` in the console toolbar. Columns, biggest first, in the shape
OmniDiskSweeper uses — because the question asked of a homelab disk is nearly
always "what is eating it", not "where is that one file".

The first column is the fleet, the second is that machine's disks, and the
rest are directories. Moving between machines is the same gesture as opening
a folder, and each machine's total reads before anything is clicked. Clicking an
open folder again collapses it; clicking the empty space under a column
targets that column's own folder.

`Grid` swaps the columns for thumbnails — list stays the default. Space opens
Quick Look on an image, arrow keys step through the folder.

Sizes on directories are the whole subtree. That means a walk, so the first
visit to a large tree takes time; the answer is then cached until that
directory changes. If a scan passes twenty seconds it returns what it has and
says the numbers are floors.

Dotfiles are shown, dimmed but never dropped. `.cache` is usually the answer, and hiding them would also make a column
stop adding up to its parent.

## Thumbnails

Grid view asks the agent for a 256px WebP per image, and only for tiles
actually scrolled into view. There is no background pass over the disks: a
nightly crawl is what rules out the photo managers that would otherwise do
this job.

The machine needs libvips for this. **homelab does not have it yet**, so today
only images with an Exif preview get a thumbnail:

```bash
sudo apt-get install -y libvips-tools
```

Without it, only images carrying an Exif thumbnail preview — which is few.
Across a sample of 144 photos here, 5 had one; downloads and export pipelines
strip them. `/api/nodes/<id>/cache` reports whether the tool is present.

The agent shells out to `vipsthumbnail` rather than importing an imaging
library, so its own memory never grows: measured over a cold batch of eight
photos, resident memory moved 26320K to 26352K. Generation was 52-113ms per
image on a laptop, once per file ever.

The cache lives in systemd's `CacheDirectory` — `/var/cache/pi-thumbs`, the
one path the service may write under `ProtectSystem=strict`. It is bounded
three ways: 500MB with least-recently-used pruning, a refusal to write below
5GB free, and a key of path plus mtime plus size. Everything in it is derived,
so deleting the directory costs nothing but the next regeneration.

The scanner lives in the metrics agent on each machine, restricted to the roots
in `BROWSE_ROOTS` in `agent/pi-metrics.service`. It is read-only, it never
follows a symlink out of a root, and the unit runs it as `nobody` under
`ProtectSystem=strict`. A directory that `nobody` cannot enter is skipped
rather than failing the scan — its size then reads low.

## Changing things

Read everywhere, write in a few places. `BROWSE_WRITABLE` in
`agent/pi-metrics.service` names them: the archive, `/srv/browse`, and
`/media` and `/mnt`, which is where drives land. Every file route needs the
console's token (`X-Agent-Token`); without it the agent answers 401.

The same list appears again as `ReadWritePaths`, which is the one that
matters. `ProtectSystem=strict` makes the whole filesystem read-only to the
agent; those lines punch through for those paths and nothing else. A bug in
the write endpoints cannot reach `/etc` or a home directory even if every
check in the code were wrong, because the kernel refuses the open first.

Nothing overwrites. A copy landing on a name that exists becomes `name copy`.
Credential files are never copied, for the same reason they are never served.

## Plugging a drive in

```bash
make automount
```

Once per machine. After that a drive is mounted when you attach it — USB, SATA,
whatever the kernel recognises — under `/media`, and appears in the console as
its own disk, writable, with nothing to configure.

Label a disk if you want a readable name:

```bash
sudo e2label /dev/sdX1 photos
```

Unlabelled drives mount under their device name instead. The machine's
existing disks are untouched: they stay in fstab and stay where they are.

## Samba

```bash
ssh <node> 'bash ~/PI/deploy/install-samba.sh'
```

Prompts once for an SMB password, which is separate from the login password
and is never stored in this repo. Then, in Finder, ⌘K:

```
smb://<node>/<node>
```

One share, `browse`, holding every disk. No Time Machine target: backups here
are made by hand.

`smbd` listens on every address, and `hosts allow` decides who is served —
the Tailscale range and this machine, nothing else. Asking Samba to bind the
Tailscale address alone was tried twice and does not work: its interface
handling wants something it recognises as a network, and a host route on a tun
device is not that. The cost is that port 445 is visible on the home LAN, where
nothing can read a file, and homelab's firewall (`deploy/firewall.nft`) drops it
there anyway. **Do not port forward 445.** SMB is the protocol
ransomware worms travel on, and there is no version of exposing it to the
internet that ends well.

homelab does not advertise itself over mDNS or NetBIOS, so they will not
appear under Network in the Finder sidebar. That is deliberate — the advert
offered a door that `hosts allow` refuses — and it is why the names are written
down here.

## Mounting them on the Mac

```bash
make mounts
```

Once, on the Mac. It stores each machine's SMB password in the login keychain and
installs a LaunchAgent that runs `deploy/sync-share-mounts.sh` every 15 seconds.
Nothing in it needs `sudo`, and it creates no directories — NetFS makes and
removes the mount point itself, under `/Volumes`.

Each pass compares two things — what `tailscale status` can reach, and what is
in the mount table — and makes them match. Nothing is remembered between
passes, so there is no state to go stale and no order to get wrong.

### Why NetFS, and not mount_smbfs

`mount_smbfs` takes a password from a terminal and nowhere else. It opens
`/dev/tty` and ignores stdin, so a password piped into it is discarded and it
prompts instead. With a person sitting there, that looks like it works. From an
agent there is no terminal, nothing answers the prompt, and every mount fails
with an authentication error while the stored password is perfectly correct.

That cost an afternoon: hours of `Authentication error` in the log, read as
evidence that the boards disagreed about the password, when the password was
never reaching them.

NetFS takes the credential as a parameter, which is what an unattended mount
needs. It is reached through `osascript`, with the script fed on stdin rather
than named on the command line, so the password is not in argv where `ps` would
show it and is never written to disk. The quotes and backslashes in it are
escaped, since it lands inside an AppleScript string literal.

NetFS names the mount after the share and cannot be told otherwise, which is why
each machine's share carries its name — `[homelab]` on homelab — rather than being
called `browse`. Two shares of the same name arrive as
`browse` and `browse-1`, and which is which depends on the order they mounted.

It also makes and removes the mount point itself, so there is nothing to create
and nothing left behind.

### A mount can be dead while the machine is fine

A wifi drop long enough for the server to forget the session leaves the mount
in the mount table and the machine perfectly reachable. macOS offers to Ignore
it, and Ignore means keep waiting:

```
$ mount | grep smbfs
//homelab@homelab/homelab on ... (smbfs, ...)   # listed
$ ls /Volumes/homelab                      # hangs until killed
```

Tailnet up, machine online, mount present — every reason the pass has to act says
there is nothing wrong. So each pass probes a mounted share and forces it off
if it does not answer, and the next pass remounts it.

The probe cannot be a simple command with a time limit. Everything that touches
a wedged path blocks, including `smbutil statshares`, which reads kernel state
rather than the server and still hung until the mount was forced away by hand.
macOS ships no `timeout`, and a process stuck in uninterruptible I/O on a dead
mount may not die on `SIGKILL` either.

So a child does the reading and touches a file if it gets an answer, and the
parent watches the clock and walks away when it runs out — without waiting for
the child, because waiting for it is the same hang by another route. The forced
unmount that follows is what actually releases it. The unmount runs in the
background too, one at a time per mount point, and the next pass reports what
really happened rather than this one waiting to find out.

None of this may block, and that is the reason for all of it: launchd will not
start a second copy of an agent that is still running, so a pass that hangs is
not a pass that was missed. It is the last one that ever runs, and it hangs
holding the mount it was supposed to clear.

Two reasons it is a timer and not a login item:

- macOS does not remount SMB across a reboot. The mount lives in memory, and
  nothing in the system puts it back.
- Tailscale is not up all the time, and an SMB mount whose server has gone is
  not inert. Finder blocks on it, and so does anything that walks the
  filesystem. Dropping the mount when the tailnet goes is the half that
  matters; putting it back when the tailnet returns is the easy half.

### Where the password lives

In the login keychain, one entry per machine, handed to `mount_smbfs` on stdin at
mount time.

There are three ways to give `mount_smbfs` a password and only one of them is
any good. Embedded in the mount URL before the `@`, it lands in argv, which `ps`
shows to every process on this Mac. In `~/Library/Preferences/nsmb.conf` — which
is what `man mount_smbfs` still tells you to do — it does not work at all:
macOS 15 no longer reads a password from that file, and `smbutil crypt`, which
used to scramble the value, has been removed. That was tried here first and it
silently did nothing.

The third way is stdin. `mount_smbfs` prompts for a password, and a prompt reads
whatever is on stdin, so a pipe answers it. The password goes from the keychain
into a pipe and no further: not into argv, not into a file. `-N` must not be
used alongside it, since that flag suppresses the prompt and the prompt is the
thing doing the reading.

The installer reads each entry back after storing it. Writing to the keychain
and reading from it are different permissions, and the read is the one that
matters — the pass runs from an agent, with nobody there to dismiss a dialog.
Better to find a keychain that will not answer while a person is watching.

### Which user

The machine's login name, not the Mac's. `install-samba.sh` takes `valid
users` from whoever runs it there, so the share on `homelab` admits `homelab` and
refuses everyone else. The installer reads the name out of your ssh config
(`ssh -G <node>`) and bakes the mapping into the agent, so there is one place
that records how to reach a machine rather than two.

```bash
tail -f ~/Library/Logs/pi.share-mounts.log
```

The log only records changes, so it is a list of mounts and unmounts rather
than a heartbeat. `Authentication error` in it means the stored password is not
the one the machine has; set it again there and re-run `make mounts`:

```bash
ssh <node> 'sudo smbpasswd <user>'
```

To stop the whole thing:

```bash
launchctl bootout gui/$(id -u)/pi.share-mounts
```

## Why no Filebrowser

It was the plan until the layout above was settled on. Filebrowser is a good
file *manager* and has no concept of recursive directory size, so it cannot
answer the question this view exists to answer. Samba covers writing, in a
better interface than any web upload, and the console covers looking. Adding
it would mean a third way to see the same files and a second set of passwords.
