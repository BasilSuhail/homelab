/**
 * The contract between backend and frontend. Documented in docs/dashboard.md.
 *
 * Two rules the UI must respect:
 *   - `capabilities` decides what renders. A non-Pi node has no power reading.
 *   - `online: false` is a normal state, not an error. Boards get turned off.
 */

export type NodeRole = 'control-plane' | 'worker' | 'standalone';

export type Capability = 'power' | 'throttle';

export interface CpuStats {
  cores: number;
  usagePct: number;
  perCore: number[];
  loadAvg: [number, number, number];
}

export interface MemStats {
  totalBytes: number;
  usedBytes: number;
  availableBytes: number;
  usedPct: number;
  swapTotalBytes: number;
  swapUsedBytes: number;
}

export interface ThrottleState {
  raw: string;
  /** Throttling right now. Worth shouting about. */
  now: boolean;
  /** Happened at some point since boot. Worth mentioning, not alarming. */
  everSinceBoot: boolean;
  reasons: string[];
  reasonsSinceBoot: string[];
}

export interface TempStats {
  cpuC: number | null;
  throttled: ThrottleState | null;
}

export interface PowerRail {
  name: string;
  volts: number;
  amps: number;
  watts: number;
}

/** Pi 5 only — measured from the PMIC, not estimated. */
export interface PowerStats {
  watts: number;
  rails: PowerRail[];
}

export interface DiskStats {
  mount: string;
  device: string;
  totalBytes: number;
  usedBytes: number;
  usedPct: number;
  /** Spins, rather than flashes. Null when the agent is too old to say. */
  rotational?: boolean | null;
  /** Null until drivetemp is loaded, or for a drive it cannot read. */
  tempC?: number | null;
  /** % of the last few seconds spent reading or writing. Null until the agent has two readings. */
  busyPct?: number | null;
  /** The backup SSD of the mirror: every write lands on it too. */
  mirror?: boolean;
  /** What is on a mirror SSD, shown when its row is opened. `copy`: the
   *  mirror's copy of a part the main SSD holds. */
  parts?: Array<{ name: string; mount: string; usedBytes: number; totalBytes: number; copy?: boolean }>;
}

/**
 * Hardware a Pi does not have, read by the shim on a desktop board. Every part
 * is optional in practice: an empty list or a null means the driver is not
 * installed yet, and the card leaves that row out rather than inventing it.
 */
export interface GpuStats {
  name: string;
  utilPct: number | null;
  memUsedBytes: number | null;
  memTotalBytes: number | null;
  tempC: number | null;
  powerW: number | null;
  fanPct: number | null;
  /** NVENC and NVDEC load: what a Jellyfin transcode shows up as. */
  encoderPct: number | null;
  decoderPct: number | null;
}

export interface HwStats {
  cpuModel: string | null;
  /** CPU package power. Needs root to read on current kernels, so usually null. */
  cpuWatts: number | null;
  /**
   * `managed`: the fan controller sets this one, so 0 rpm means switched off.
   * The rest come from a controller that takes manual speeds: its header, the
   * speed it is at, whether that was set by hand, the lowest speed it keeps
   * turning at, and whether it may be switched off.
   */
  fans: Array<{
    label: string; rpm: number; managed?: boolean;
    pwm?: string; pct?: number; manual?: boolean; minPct?: number; canStop?: boolean;
  }>;
  /** Heat is overriding the manual speeds. Absent on an older agent. */
  fansHeld?: boolean;
  /** Only rails the sensor driver has labelled, and therefore scaled. */
  volts: Array<{ label: string; volts: number }>;
  /** Keyed by block device: sda, nvme0n1. */
  driveTemps: Record<string, number>;
  /** % of the last few seconds each drive spent reading or writing. Absent on an older agent. */
  driveBusy?: Record<string, number>;
  /** mdN -> its main and backup (write-mostly) disks. Absent on an older agent. */
  mirrors?: Record<string, { main: string; backup: string | null }>;
  gpu: GpuStats | null;
  wifi: Array<{ iface: string; signalDbm: number }>;
}

export interface NetStats {
  iface: string;
  rxBps: number;
  txBps: number;
}

export interface FleetNode {
  id: string;
  name: string;
  tailscaleIp: string;
  online: boolean;
  /**
   * True when part of this card came from the previous poll rather than this
   * one, because the board was too busy to answer in time. The board is up;
   * the numbers are a few seconds old. Absent on an offline node.
   */
  stale?: boolean;
  /** ISO timestamp. Meaningful mainly when offline. */
  lastSeen: string;
  role: NodeRole;

  model: string | null;
  os: string | null;
  arch: string | null;
  kernel: string | null;
  uptimeSec: number | null;

  cpu: CpuStats | null;
  mem: MemStats | null;
  /** The thumbnail cache on this board's disk. Null when the agent is old. */
  cache: ThumbCache | null;
  temp: TempStats | null;
  power: PowerStats | null;
  disks: DiskStats[];
  net: NetStats[];
  /** Null from an agent older than the desktop sensors. */
  hw: HwStats | null;

  capabilities: Capability[];
  /** Busiest few, for the card's table. Full list stays on the detail route. */
  topProcesses: ProcessRow[];
  /** Set when the node is on the tailnet but its agents did not answer. */
  error?: string;
}

export interface ProcessRow {
  pid: number;
  name: string;
  cmdline: string | null;
  user: string | null;
  /** Null until a second reading exists to average over. See glances.ts. */
  cpuPct: number | null;
  memBytes: number;
  memPct: number;
  threads: number;
  /** Cumulative bytes read since the process started. */
  diskReadBytes: number;
}

export interface ContainerRow {
  name: string;
  image: string | null;
  status: string;
  cpuPct: number | null;
  memBytes: number | null;
}

export interface AppTile {
  name: string;
  url: string;
  nodeId: string | null;
  icon: string | null;
  healthy: boolean | null;
  /**
   * A tile the console can switch on and off rather than only open. True for
   * the download stack, which runs behind a VPN and is meant to be off unless
   * something is downloading, and for nothing else — the cluster permission
   * behind the switch names one deployment.
   */
  switchable?: boolean;
}

/** What the cluster says about the switchable workload. */
export interface TorrentState {
  /** Replicas asked for: what the switch last set. */
  wanted: number;
  /** Replicas that exist. Between the two is starting, or stopping. */
  ready: number;
  /** False when the cluster cannot be reached, which is not the same as off. */
  reachable: boolean;
  /**
   * The tunnel, read from gluetun itself rather than inferred from the pod
   * being up. "running" is not the same as "protected", and the difference is
   * the whole reason this workload exists in the shape it does.
   *
   * Null while it is stopped or still coming up.
   */
  vpn: {
    /** gluetun's own word: "running", "stopped", "starting". */
    status: string | null;
    /** The address traffic is leaving from. AirVPN's, not yours. */
    publicIp: string | null;
    country: string | null;
    /** Where that exit server is. Absent from an older console. */
    city?: string | null;
    /** Whose server it is, as k8s/qbittorrent.yaml configures it. */
    provider?: string | null;
  } | null;
  /**
   * What the client holds, by qBittorrent's own state. Null while it is off or
   * not answering; absent from an older console.
   */
  torrents?: TorrentCounts | null;
}

/** Each torrent counted once, in the group its state puts it in. */
export interface TorrentCounts {
  downloading: number;
  stalled: number;
  seeding: number;
  queued: number;
  stopped: number;
  errored: number;
  /** Bytes per second, all torrents together. */
  downSpeed: number;
}

/** One person using one app right now. Written by `pi-when content` on the PC. */
export interface ActiveUse {
  /** The app as the Status tab names it: Jellyfin, Nextcloud, Immich, Torrent... */
  app: string;
  who: string;
  what: string;
  device: string;
}

/** One stretch of one person using one app, from the PC's 2-day log. */
export interface PastUse extends ActiveUse {
  /** Unix seconds, first and last seen. */
  start: number;
  end: number;
}

/** The Status tab's feed. Null parts are ones the PC could not read. */
export interface ContentStatus {
  /** Unix seconds the PC wrote this. */
  ts: number;
  active: ActiveUse[];
  jellyfin: { films: number; series: number; episodes: number; bytes: number | null } | null;
  /** Each account's files, from occ. Users biggest first. */
  nextcloud?: { bytes: number; users: Array<{ name: string; bytes: number }> } | null;
  /** Absent from a PC without an Immich key. Users biggest first. */
  immich?: {
    photos: number;
    videos: number;
    bytes: number;
    users: Array<{ name: string; photos: number; videos: number; bytes: number }>;
  } | null;
  kiwix: { books: number; bytes: number } | null;
  /** Repos counted on disk; lastBackup is the newest `sudo gitea-backup`, Unix seconds. */
  gitea?: { repos: number; bytes: number; lastBackup: number | null } | null;
  /** Who used what in the last 2 days, oldest first. Absent from an older pi-when. */
  users?: PastUse[];
  /** Who has an account where. Apps that could not be read are missing from both. */
  accounts?: { apps: Record<string, number>; people: Person[] };
}

/** One person's accounts, joined across apps by name. */
export interface Person {
  name: string;
  apps: Record<string, { admin: boolean; disabled: boolean; lastSeen: number | null }>;
}

/**
 * One entry in a directory, as the shim's scanner reports it.
 *
 * `bytes` on a directory is its whole subtree, which is the number that makes
 * a size-sorted listing useful. Hidden entries are included — a dotfile is
 * usually what is eating the disk, and dropping them would make the totals
 * disagree with the parent.
 */
export interface DirEntry {
  name: string;
  dir: boolean;
  link: boolean;
  bytes: number;
  /** Unix seconds. */
  mtime: number;
  hidden: boolean;
  /**
   * Set only on the synthetic columns — the fleet and a board's roots — where
   * a child's key cannot be made by joining a name onto its parent.
   */
  path?: string;
  /** Total size of the board's disks. Column zero only. */
  capacity?: number;
  /** A root that refuses every write. Shown before you try, not after. */
  locked?: boolean;
  /**
   * Finder tag names, read from the same extended attribute Finder writes, so
   * the two cannot disagree. Colour names only — Red, Blue, and the rest.
   */
  tags?: string[];
}

export interface DirListing {
  path: string;
  /** Null at a root: there is nowhere further up that may be read. */
  parent: string | null;
  total: number;
  count: number;
  /** Entries beyond the cap, which are the smallest ones. */
  truncated: number;
  /** False when the sizing hit its deadline. The numbers are then floors. */
  complete: boolean;
  entries: DirEntry[];
  /** Set when the directory could not be read at all. */
  error?: string;
  /** False for anything outside the writable roots — the system, in practice. */
  writable?: boolean;
}

export interface DirRoots {
  /** `writable` is the agent's answer, not the UI's guess: a read-only root
   *  refuses a write whatever the interface offers. */
  roots: Array<{ path: string; name: string; writable: boolean }>;
}

/** What the cache holds, and whether the board can make thumbnails at all. */
export interface ThumbCache {
  bytes: number;
  count: number;
  capBytes: number;
  /** False when vipsthumbnail is not installed — only Exif thumbs are possible. */
  tool: boolean;
}

/**
 * A credential the dashboard holds and cannot renew for itself.
 *
 * Empty under systemd, where node discovery uses the local tailscaled socket
 * and there is nothing to expire. See server/lib/expiry.ts.
 */
export interface CredentialStatus {
  name: string;
  /** ISO date the credential dies. Null when nobody recorded one. */
  expiresAt: string | null;
  /** Whole days from today, negative once it has lapsed. Null if unrecorded. */
  daysLeft: number | null;
  state: 'ok' | 'soon' | 'expired' | 'unknown';
}
