/**
 * Glances REST API client (API v4).
 *
 * Targeted plugin fetches rather than /api/4/all — the process list is large
 * and only wanted on the node detail screen, not on every fleet poll.
 */

import type { CpuStats, DiskStats, MemStats, NetStats, ProcessRow } from '../../shared/fleet';

export const GLANCES_PORT = 61208;

// A saturated node answers its first request in ~1.2s; later ones in ~250ms.
// 3s was not enough headroom when a dozen sub-requests land at once.
const TIMEOUT_MS = 6000;

const get = async <T>(host: string, plugin: string): Promise<T | null> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`http://${host}:${GLANCES_PORT}/api/4/${plugin}`, {
      signal: controller.signal,
      cache: 'no-store',
    });
    return res.ok ? ((await res.json()) as T) : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
};

/** Cores per host, filled in by fetchCpu, used only to bound a bad window. */
const coreCount = new Map<string, number>();

/** Glances reports percentages; per-core values live under cpucore/percpu. */
export const fetchCpu = async (host: string): Promise<CpuStats | null> => {
  const [cpu, percpu, load] = await Promise.all([
    get<CpuSample>(host, 'cpu'),
    get<Array<{ total?: number; idle?: number; user?: number; system?: number }>>(host, 'percpu'),
    get<{ min1?: number; min5?: number; min15?: number }>(host, 'load'),
  ]);
  if (!cpu) return null;

  // The same empty window hits each core: idle, user and system all 0, which
  // Glances turns into a total of 100. On a fresh dashboard every thread read
  // 100% beside a CPU of 0%. Such a core takes its last good reading, or 0.
  const prevCores = lastGoodCpu.get(host)?.stats.perCore ?? [];
  const perCore = Array.isArray(percpu)
    ? percpu.map((c, i) =>
        (c.idle ?? 0) === 0 && (c.user ?? 0) === 0 && (c.system ?? 0) === 0
          ? prevCores[i] ?? 0
          : round(c.total ?? 0))
    : [];

  const stats: CpuStats = {
    cores: cpu.cpucore ?? perCore.length,
    usagePct: round(cpu.total ?? 0),
    perCore,
    loadAvg: [round(load?.min1 ?? 0), round(load?.min5 ?? 0), round(load?.min15 ?? 0)],
  };

  // Per-process CPU is bounded by the core count; this is where that number
  // is known. Recorded on every poll, and read by cpuPctOf on the next one.
  if (stats.cores) coreCount.set(host, stats.cores);

  // Glances computes CPU as a delta since the previous request rather than
  // from its own refresh timer, so two requests close together produce a
  // near-zero window and a sample where total and idle are both 0 — impossible
  // on a running system. Retrying does not help; the retry is itself a short
  // window. Serve the last good reading instead, and only briefly: a node that
  // keeps returning stale samples should show 0 rather than a frozen number.
  if (isStale(cpu)) {
    const previous = lastGoodCpu.get(host);
    if (previous && Date.now() - previous.at < STALE_FALLBACK_MS) {
      return { ...previous.stats, loadAvg: stats.loadAvg };
    }
    return stats;
  }

  lastGoodCpu.set(host, { stats, at: Date.now() });
  return stats;
};

interface CpuSample {
  total?: number;
  idle?: number;
  cpucore?: number;
}

const isStale = (c: CpuSample) => (c.total ?? 0) === 0 && (c.idle ?? 0) === 0;

/** Beyond this, a stale reading stops being worth showing. */
const STALE_FALLBACK_MS = 30_000;

const lastGoodCpu = new Map<string, { stats: CpuStats; at: number }>();

export const fetchMem = async (host: string): Promise<MemStats | null> => {
  const [mem, swap] = await Promise.all([
    get<{ total?: number; used?: number; available?: number; percent?: number }>(host, 'mem'),
    get<{ total?: number; used?: number }>(host, 'memswap'),
  ]);
  if (!mem?.total) return null;

  return {
    totalBytes: mem.total,
    usedBytes: mem.used ?? 0,
    availableBytes: mem.available ?? 0,
    usedPct: round(mem.percent ?? 0),
    swapTotalBytes: swap?.total ?? 0,
    swapUsedBytes: swap?.used ?? 0,
  };
};

/**
 * The physical disk a partition belongs to: sda2 -> sda, nvme0n1p3 -> nvme0n1.
 *
 * Lives here because the disk list is built here and fleet.ts needs the same
 * answer for the rotational join. One definition, so the two cannot disagree
 * about what counts as a disk.
 */
export const parentDisk = (dev: string): string => {
  const mp = dev.match(/^(mmcblk\d+|nvme\d+n\d+)p\d+$/);
  if (mp) return mp[1];
  const sd = dev.match(/^((?:sd|vd|xvd|hd)[a-z]+)\d+$/);
  if (sd) return sd[1];
  return dev;
};

export const fetchDisks = async (host: string): Promise<DiskStats[]> => {
  const fs = await get<Array<{
    mnt_point?: string;
    device_name?: string;
    size?: number;
    used?: number;
    percent?: number;
  }>>(host, 'fs');
  if (!Array.isArray(fs)) return [];

  // One row per physical DISK, not per filesystem. Two things collapse here:
  //
  //   A bind mount is the same filesystem seen at a second path, and Glances
  //   reports it as a second entry with identical size and usage. Summing
  //   those double-counted every board's capacity — pi read 937GB when it
  //   holds 468.
  //
  //   A partition is not a drive. /dev/sda1 is the 512MB boot partition on the
  //   same physical disk as /dev/sda2, and keying on the device name let it
  //   through as a third drive: pi2 showed "SSD 1TB, HDD 6TB, SSD 1GB" for a
  //   board with two disks in it. A machine has drives; the partitions inside
  //   one are its business, not a row of their own.
  //
  // The shallowest mount point wins, which is the disk's real root rather than
  // a bind or a partition mounted deeper: / beats /boot/firmware.
  const byDisk = new Map<string, (typeof fs)[number]>();
  for (const d of fs) {
    const disk = parentDisk((d.device_name ?? '?').replace(/^\/dev\//, ''));
    const seen = byDisk.get(disk);
    const depth = (d.mnt_point ?? '').split('/').length;
    if (!seen || depth < (seen.mnt_point ?? '').split('/').length) byDisk.set(disk, d);
  }

  return [...byDisk.values()].map((d) => ({
    mount: d.mnt_point ?? '?',
    device: d.device_name ?? '?',
    totalBytes: d.size ?? 0,
    usedBytes: d.used ?? 0,
    usedPct: round(d.percent ?? 0),
  }));
};

export const fetchNet = async (host: string, now: number = Date.now()): Promise<NetStats[]> => {
  const net = await get<Array<{
    interface_name?: string;
    bytes_recv?: number;
    bytes_sent?: number;
    time_since_update?: number;
  }>>(host, 'network');
  if (!Array.isArray(net)) return [];

  return net
    .filter((n) => n.interface_name && isRealInterface(n.interface_name))
    .map((n) => {
      const iface = n.interface_name as string;
      const { rxBps, txBps } = netRate(
        `${host}/${iface}`, n.bytes_recv, n.bytes_sent, n.time_since_update, now,
      );
      return { iface, rxBps, txBps };
    });
};

// Glances reports the bytes moved since its previous refresh and how long ago
// that was. Every plugin request can trigger a refresh, and the card sends
// several at once, so the network read often lands a few milliseconds after
// another one: no bytes in that sliver read as 0 B/s, a few KB over it as
// 629.9 GB/s. A window under a second is noise; the last good rate stands in
// for it. (Its *_gauge totals are not since-boot counters — pi2 reported 9.9 TB
// sent in a day — so they cannot be used instead.)
type NetSample = { t: number; rxBps: number; txBps: number };
const lastGoodNet = new Map<string, NetSample>();
const MIN_WINDOW_S = 1;
const MAX_BPS = 1.25e9; // 10 Gbit/s; nothing here moves more than a gigabit
const STALE_MS = 15_000;

export const netRate = (
  key: string,
  rxBytes: number | undefined,
  txBytes: number | undefined,
  windowS: number | undefined,
  now: number,
): { rxBps: number; txBps: number } => {
  const usable =
    typeof rxBytes === 'number' && typeof txBytes === 'number' &&
    typeof windowS === 'number' && windowS >= MIN_WINDOW_S &&
    rxBytes >= 0 && txBytes >= 0;
  if (usable) {
    const rxBps = Math.round(rxBytes / windowS);
    const txBps = Math.round(txBytes / windowS);
    if (rxBps <= MAX_BPS && txBps <= MAX_BPS) {
      lastGoodNet.set(key, { t: now, rxBps, txBps });
      return { rxBps, txBps };
    }
  }
  const last = lastGoodNet.get(key);
  return last && now - last.t < STALE_MS ? { rxBps: last.rxBps, txBps: last.txBps } : { rxBps: 0, txBps: 0 };
};

/**
 * Glances returns uptime as a human string, not a number:
 *   "0:44:03"  or  "3 days, 2:15:09"
 */
export const parseUptime = (raw: unknown): number | null => {
  if (typeof raw !== 'string') return null;

  const m = raw.match(/^(?:(\d+)\s+days?,\s*)?(\d+):(\d{2}):(\d{2})$/);
  if (!m) return null;

  const [, days, hours, mins, secs] = m;
  return (
    Number(days ?? 0) * 86400 +
    Number(hours) * 3600 +
    Number(mins) * 60 +
    Number(secs)
  );
};

/**
 * Docker creates a veth pair per container and a bridge per network, so a box
 * running six containers reports eight interfaces. Their traffic is already
 * counted on the physical interface it leaves by, so showing them both adds
 * noise and double-counts.
 *
 * Excluded: loopback, tailscale, docker bridges, veth pairs, k8s CNI
 * interfaces, and bridges.
 */
const VIRTUAL_IFACE = /^(lo|tailscale|docker|veth|br-|cni|flannel|cali|kube|virbr|vnet)/;

export const isRealInterface = (name: string) => !VIRTUAL_IFACE.test(name);

export const fetchSystem = async (host: string) => {
  const [sys, uptime] = await Promise.all([
    get<{
      os_name?: string;
      platform?: string;
      linux_distro?: string;
      os_version?: string;
    }>(host, 'system'),
    get<unknown>(host, 'uptime'),
  ]);
  return {
    os: sys?.linux_distro ?? sys?.os_name ?? null,
    // Glances reports bitness here ("64bit"), not the machine architecture.
    arch: sys?.platform ?? null,
    kernel: sys?.os_version ?? null,
    uptimeSec: parseUptime(uptime),
  };
};

interface RawProcess {
  pid?: number;
  name?: string;
  cmdline?: string[];
  username?: string;
  cpu_percent?: number;
  cpu_times?: { user?: number; system?: number };
  memory_percent?: number;
  memory_info?: { rss?: number };
  num_threads?: number;
  io_counters?: number[];
}

/**
 * Per-process CPU, averaged over the gap between polls.
 *
 * Glances' own `cpu_percent` is a spot sample taken over however long it has
 * been since that process was last looked at, which makes it unusable here.
 * Worst affected is Glances itself: it samples its own process immediately
 * after doing the work of building the process list, so it measures its own
 * measurement burst over a very short window. Observed at 98% and 210% of a
 * core on two idle boards whose true cost, taken from cumulative CPU time over
 * two minutes, was 0.54% and 0.07%.
 *
 * `cpu_times` is cumulative and does not have this problem. The difference
 * between two readings, over the real elapsed time, is the honest average.
 *
 * Two rules follow from having no reading rather than a bad one:
 *
 * - A process seen once reports null, not a number. The column shows "—" for
 *   one poll, which is true, where the spot sample would have shown 0.0.
 * - A result above the board's core count is a broken window, not a busy
 *   process, and is discarded in favour of the previous answer.
 */
const cpuHistory = new Map<string, Map<number, { cpuSec: number; at: number; pct: number | null }>>();

/** Below this the divisor is small enough to inflate the result — the exact
 *  failure being fixed. Two clients polling at once produce such a gap. */
const MIN_WINDOW_MS = 1000;

/**
 * Cumulative CPU seconds, or null when the reading does not carry them.
 *
 * `cpu_times` can arrive as an object holding only `children_*` and `iowait`,
 * which passes a plain truthiness check. Counting that as zero seconds puts a
 * zero into the history, and the next poll then divides the process's entire
 * lifetime by one window: k3s-server read 37989% on a four-core board that
 * way, its 2456s of accumulated time over 6.5s.
 */
const cpuSecondsOf = (times: RawProcess['cpu_times']): number | null => {
  if (!times) return null;
  if (times.user == null && times.system == null) return null;
  return (times.user ?? 0) + (times.system ?? 0);
};

const cpuPctOf = (host: string, p: RawProcess, now: number): number | null => {
  const pid = p.pid ?? 0;
  const cpuSec = cpuSecondsOf(p.cpu_times);
  // The spot sample is the thing this function exists to replace, so a reading
  // without cumulative time reports nothing rather than repeating it.
  if (cpuSec === null) return null;

  let seen = cpuHistory.get(host);
  if (!seen) cpuHistory.set(host, (seen = new Map()));

  const prev = seen.get(pid);

  // First sighting, or a pid reused by a younger process. There is no window
  // to average over, and Glances' spot sample is not a stand-in: on a fresh
  // request it covers under a millisecond, so every process reads 0.0 except
  // Glances itself. The column shows "—" for one poll instead.
  if (!prev || cpuSec < prev.cpuSec) {
    seen.set(pid, { cpuSec, at: now, pct: null });
    return null;
  }

  const elapsed = now - prev.at;
  if (elapsed < MIN_WINDOW_MS) return prev.pct;

  const pct = round(Math.max(0, (100 * (cpuSec - prev.cpuSec)) / (elapsed / 1000)));

  // A process cannot burn more CPU time than the window times the core count.
  // Above that the window is wrong, not the process, so the previous answer
  // stands and the baseline is refreshed for the next poll to divide cleanly.
  const ceiling = 100 * (coreCount.get(host) ?? 0);
  if (ceiling > 0 && pct > ceiling) {
    seen.set(pid, { cpuSec, at: now, pct: prev.pct });
    return prev.pct;
  }

  seen.set(pid, { cpuSec, at: now, pct });
  return pct;
};

export const fetchProcesses = async (host: string, limit = 30): Promise<ProcessRow[]> => {
  // The fleet poll fetches CPU alongside this and fills coreCount in, but the
  // node detail route asks for processes alone. Without the core count there
  // is no ceiling, so fetch it once for hosts that arrive that way.
  const cores = coreCount.has(host)
    ? null
    : await get<{ cpucore?: number }>(host, 'cpu');
  if (cores?.cpucore) coreCount.set(host, cores.cpucore);

  const procs = await get<RawProcess[]>(host, 'processlist');
  if (!Array.isArray(procs)) return [];

  const now = Date.now();
  const rows = procs.map((p) => ({
    pid: p.pid ?? 0,
    name: p.name ?? '?',
    cmdline: p.cmdline?.length ? p.cmdline.join(' ') : null,
    user: p.username ?? null,
    cpuPct: cpuPctOf(host, p, now),
    memBytes: p.memory_info?.rss ?? 0,
    memPct: round(p.memory_percent ?? 0),
    threads: p.num_threads ?? 0,
    // Glances returns [read_bytes, write_bytes, ...]; index 0 is what we show.
    diskReadBytes: p.io_counters?.[0] ?? 0,
  }));

  // Processes that have exited would otherwise accumulate for the life of the
  // server. The full list is walked above, so what is missing here has gone.
  const live = new Set(rows.map((r) => r.pid));
  const seen = cpuHistory.get(host);
  if (seen) for (const pid of seen.keys()) if (!live.has(pid)) seen.delete(pid);

  // A process with no CPU reading yet sorts below one measured at zero, so a
  // cold poll does not put unmeasured rows at the top of the card.
  return rows
    .sort((a, b) => (b.cpuPct ?? -1) - (a.cpuPct ?? -1) || b.memBytes - a.memBytes)
    .slice(0, limit);
};

const round = (n: number) => Math.round(n * 10) / 10;

/** Glances reads the Docker socket itself, so container stats need no extra agent. */
export const fetchContainers = async (host: string) => {
  const raw = await get<Array<{
    name?: string;
    image?: string[] | string;
    status?: string;
    cpu?: { total?: number };
    memory?: { usage?: number };
  }>>(host, 'containers');
  if (!Array.isArray(raw)) return [];

  return raw.map((c) => ({
    name: c.name ?? '?',
    image: Array.isArray(c.image) ? c.image[0] : (c.image ?? null),
    status: c.status ?? 'unknown',
    cpuPct: c.cpu?.total != null ? round(c.cpu.total) : null,
    memBytes: c.memory?.usage ?? null,
  }));
};
