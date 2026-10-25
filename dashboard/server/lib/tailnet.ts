/**
 * Node discovery.
 *
 * The dashboard asks Tailscale which machines exist, not Kubernetes. pi1 is
 * on the tailnet but not in the cluster, and asking k8s would miss it entirely.
 * Cluster membership is a label applied afterwards, not a filter.
 *
 * A machine joining the tailnet appears here with no config change.
 */

const API_BASE = 'https://api.tailscale.com/api/v2';
const TIMEOUT_MS = 5000;

export interface TailnetDevice {
  id: string;
  name: string;
  hostname: string;
  /**
   * The full MagicDNS name, e.g. `uptime.<tailnet>.ts.net`. Unique across the
   * tailnet, where `hostname` is not — Tailscale appends `-1`, `-2` here when
   * two machines claim the same one. This is what a URL contains, so it is
   * what name lookups are keyed on.
   */
  dnsName: string;
  addresses: string[];
  online: boolean;
  lastSeen: string;
  os: string;
  /** Present on machines the operator registered; absent on a real board. */
  tags?: string[];
}

/** The first label of the MagicDNS name, lowercased. See TailnetDevice. */
const magicDnsLabel = (device: TailnetDevice): string =>
  (device.dnsName.split('.')[0] || device.name).toLowerCase();

interface RawDevice {
  id: string;
  name: string;
  hostname: string;
  addresses: string[];
  lastSeen: string;
  os: string;
  /** Absent on an ordinary machine; present on anything the operator made. */
  tags?: string[];
}

/**
 * Tags carried by machines the Tailscale Kubernetes operator registers.
 *
 * The operator tags itself tag:k8s-operator and every proxy it creates
 * tag:k8s. Those are Linux devices on the tailnet with no agent on them, so
 * without this they arrive as boards that answer nothing, and the fleet reads
 * "2/4 online" while both real boards are fine.
 *
 * Tags rather than names, so a service added later is excluded the day it
 * appears rather than after someone notices a fourth broken card.
 */
const INFRA_TAGS = new Set(['tag:k8s', 'tag:k8s-operator']);

const isClusterInfra = (tags: string[] | undefined): boolean =>
  (tags ?? []).some((t) => INFRA_TAGS.has(t));

/** Tailscale reports lastSeen but not a live flag for every device type. */
const ONLINE_WINDOW_MS = 5 * 60 * 1000;

/**
 * Falls back to the local tailscaled when no API key is set.
 *
 * Works anywhere the tailscale CLI is present and the daemon is running — a
 * developer machine, or the dashboard running directly on a node rather than
 * inside a pod. In a container without the socket, the API key path is the
 * only one available.
 */
const fetchViaLocalCli = async (): Promise<TailnetDevice[] | null> => {
  let execFile: typeof import('node:child_process').execFile;
  try {
    ({ execFile } = await import('node:child_process'));
  } catch {
    return null;
  }

  const raw = await new Promise<string | null>((resolve) => {
    const child = execFile('tailscale', ['status', '--json'], { timeout: TIMEOUT_MS }, (err, stdout) =>
      resolve(err ? null : stdout),
    );
    child.on('error', () => resolve(null));
  });
  if (!raw) return null;

  interface LocalPeer {
    ID: string;
    HostName: string;
    DNSName: string;
    TailscaleIPs: string[];
    Online: boolean;
    LastSeen: string;
    OS: string;
    Tags?: string[];
  }

  try {
    const status = JSON.parse(raw) as { Peer?: Record<string, LocalPeer>; Self?: LocalPeer };
    const peers = [...Object.values(status.Peer ?? {}), ...(status.Self ? [status.Self] : [])];

    // Not filtered to Linux here. Every machine's address feeds the name map;
    // the board filter belongs to the caller. See fetchTailnetDevices.
    return peers
      .map((p) => ({
        id: p.ID,
        name: p.HostName || p.DNSName.split('.')[0],
        hostname: p.HostName,
        dnsName: p.DNSName ?? '',
        addresses: p.TailscaleIPs ?? [],
        online: p.Online,
        lastSeen: p.LastSeen,
        os: p.OS,
        tags: p.Tags,
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    return null;
  }
};

/**
 * MagicDNS label -> IPv4, rebuilt on every discovery pass.
 *
 * MagicDNS names resolve on a board, where tailscaled is the resolver. They do
 * not resolve inside a pod: DNS there goes to CoreDNS, which has never heard of
 * the tailnet. Public names are unaffected, which is why node discovery kept
 * working after the move to k3s while the launcher's health checks did not.
 *
 * Reconfiguring the pod's DNS would trade a red tile for the risk of no DNS at
 * all. The addresses are already in hand here, so anything that needs to reach
 * a tailnet name by name can ask for one instead.
 *
 * Keyed on the MagicDNS label rather than on the reported hostname. The two
 * agree only while Tailscale has never had to disambiguate: delete and re-add
 * a machine — which is exactly what the documented Uptime Kuma rollback does —
 * and two devices report the hostname `uptime` while MagicDNS calls the second
 * `uptime-1`. On the hostname the pair collide and last-write-wins decides,
 * silently, whether the tile probes the live proxy or the dead one. The label
 * is unique by construction, and it is what the URL being resolved actually
 * contains.
 *
 * Rebuilt rather than merged so a machine that goes away takes its address
 * with it. Merging left a deleted proxy's 100.x in the map forever, and under
 * the systemd install — where MagicDNS does resolve — that turned a working
 * lookup into a connection to an address nothing answers on.
 */
let tailnetIps = new Map<string, string>();
let tailnetSuffix = '';

/** Whether a discovery pass has ever filled the map. See warmTailnetIps. */
let discovered = false;

/** The tailnet identifier extracted from MagicDNS names, e.g. `tail1a2b3c`. */
export const tailnetName = (): string => tailnetSuffix;

/**
 * The address behind a MagicDNS name, or null to let ordinary DNS handle it.
 */
export const tailnetIpFor = (hostname: string): string | null => {
  // Only MagicDNS names are answered here. Everything else is someone else's
  // to resolve, and hijacking it would be a surprise.
  if (!hostname.toLowerCase().endsWith('.ts.net')) return null;
  return tailnetIps.get(hostname.toLowerCase().split('.')[0]) ?? null;
};

/**
 * Runs one discovery pass if none has run yet, so a caller that needs the
 * address map does not race the fleet poll to fill it.
 *
 * The launcher was that caller. On a cold pod both /api/nodes and /api/apps
 * are requested at the same instant; whenever the probes won, every tailnet
 * tile resolved to null, fell back to the DNS that does not work in a pod, and
 * the whole shelf rendered unreachable until the next apps poll fifteen
 * seconds later. Once warm this costs nothing.
 */
export const warmTailnetIps = async (): Promise<void> => {
  if (discovered) return;
  await fetchTailnetDevices().catch(() => []);
};

export const fetchTailnetDevices = async (): Promise<TailnetDevice[]> => {
  const devices = await discoverDevices();

  // Every machine's address is recorded, whatever it runs and whoever created
  // it. Two different questions: which machines are boards, and which names
  // this server can reach. A launcher tile may point at a service the operator
  // exposed, or at a Mac running `tailscale serve`; neither is a board, and
  // both still have to resolve. The board filters are applied after this.
  const fresh = new Map<string, string>();
  for (const device of devices) {
    const ip = ipv4Of(device);
    if (ip) fresh.set(magicDnsLabel(device), ip);
  }
  tailnetIps = fresh;
  discovered = true;
  const sample = devices.find((d) => d.dnsName.endsWith('.ts.net'));
  if (sample) tailnetSuffix = sample.dnsName.split('.')[1] ?? '';

  // Only Linux nodes run the agents; phones and laptops are viewers. Cluster
  // infrastructure is Linux but has no agent either, so it goes too.
  return devices.filter((d) => d.os === 'linux' && !isClusterInfra(d.tags));
};

/**
 * An OAuth client never expires, where an API key lasts 90 days at most and
 * carries its owner's full admin rights. The client is made read-only
 * (devices:core:read) and swapped for a one-hour token on demand.
 */
let oauthToken: { value: string; until: number } | null = null;

const oauthBearer = async (id: string, secret: string): Promise<string> => {
  if (oauthToken && Date.now() < oauthToken.until) return oauthToken.value;
  const res = await fetch(`${API_BASE}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: id, client_secret: secret, grant_type: 'client_credentials' }),
    cache: 'no-store',
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`Tailscale OAuth token request returned ${res.status}`);
  const { access_token, expires_in } = (await res.json()) as { access_token: string; expires_in?: number };
  // Renewed five minutes early, so a request never leaves with a dying token.
  oauthToken = { value: access_token, until: Date.now() + ((expires_in ?? 3600) - 300) * 1000 };
  return access_token;
};

const bearer = async (): Promise<string | null> => {
  const id = process.env.TAILSCALE_OAUTH_CLIENT_ID;
  const secret = process.env.TAILSCALE_OAUTH_CLIENT_SECRET;
  if (id && secret) return oauthBearer(id, secret);
  return process.env.TAILSCALE_API_KEY || null;
};

const discoverDevices = async (): Promise<TailnetDevice[]> => {
  const key = await bearer();
  const tailnet = process.env.TAILSCALE_TAILNET ?? '-';

  if (!key) {
    const local = await fetchViaLocalCli();
    if (local) return local;
    throw new Error(
      'no Tailscale OAuth client or API key, and the local tailscale CLI is unavailable — cannot discover nodes',
    );
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const res = await fetch(`${API_BASE}/tailnet/${tailnet}/devices`, {
      headers: { Authorization: `Bearer ${key}` },
      signal: controller.signal,
      cache: 'no-store',
    });

    if (!res.ok) {
      throw new Error(`Tailscale API returned ${res.status}`);
    }

    const { devices } = (await res.json()) as { devices: RawDevice[] };
    const now = Date.now();

    return devices
      .map((d) => ({
        id: d.id,
        name: d.hostname || d.name.split('.')[0],
        hostname: d.hostname,
        dnsName: d.name,
        addresses: d.addresses,
        online: now - new Date(d.lastSeen).getTime() < ONLINE_WINDOW_MS,
        lastSeen: d.lastSeen,
        os: d.os,
        tags: d.tags,
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  } finally {
    clearTimeout(timer);
  }
};

/** Tailscale hands out both v4 and v6; the agents listen on v4. */
export const ipv4Of = (device: TailnetDevice): string | null =>
  device.addresses.find((a) => /^\d+\.\d+\.\d+\.\d+$/.test(a)) ?? null;
