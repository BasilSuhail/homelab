/**
 * Cluster membership, used only to label nodes. Never to discover them —
 * standalone machines must appear on the dashboard too.
 *
 * Failure here is not fatal: if the cluster is unreachable every node simply
 * falls back to 'standalone'.
 */

import { readFile } from 'node:fs/promises';

import type { NodeRole, TorrentCounts, TorrentState } from '../../shared/fleet';

const TIMEOUT_MS = 3000;

/** Projected into every pod by kubelet, alongside KUBERNETES_SERVICE_HOST. */
const IN_CLUSTER_TOKEN = '/var/run/secrets/kubernetes.io/serviceaccount/token';

/**
 * Where to find the cluster, and what to authenticate with.
 *
 * Under systemd both come from the environment, written by the installer from
 * a ServiceAccount that can list nodes and nothing else. In a pod neither is
 * configured: kubelet sets the service host and projects a token for the
 * ServiceAccount the pod runs as, which is the same identity by another route.
 *
 * The projected token is re-read every poll rather than cached, because
 * kubelet rotates it and a cached copy would expire mid-run.
 */
const credentials = async (): Promise<{ server: string; token: string } | null> => {
  const server = process.env.KUBE_API_SERVER;
  const token = process.env.KUBE_TOKEN;
  if (server && token) return { server, token };

  const host = process.env.KUBERNETES_SERVICE_HOST;
  if (!host) return null;
  const port = process.env.KUBERNETES_SERVICE_PORT ?? '443';

  try {
    return { server: `https://${host}:${port}`, token: (await readFile(IN_CLUSTER_TOKEN, 'utf8')).trim() };
  } catch {
    return null;
  }
};

interface KubeNodeList {
  items: Array<{
    metadata: { name: string; labels?: Record<string, string> };
  }>;
}

/** Map of node name -> role. Empty when the cluster cannot be reached. */
export const fetchClusterRoles = async (): Promise<Map<string, NodeRole>> => {
  const roles = new Map<string, NodeRole>();

  const creds = await credentials();
  if (!creds) return roles;
  const { server, token } = creds;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const res = await fetch(`${server}/api/v1/nodes`, {
      headers: { Authorization: `Bearer ${token}` },
      signal: controller.signal,
      cache: 'no-store',
    });
    if (!res.ok) return roles;

    const { items } = (await res.json()) as KubeNodeList;
    for (const node of items) {
      const labels = node.metadata.labels ?? {};
      const isControlPlane =
        'node-role.kubernetes.io/control-plane' in labels ||
        'node-role.kubernetes.io/master' in labels;
      roles.set(node.metadata.name, isControlPlane ? 'control-plane' : 'worker');
    }
    return roles;
  } catch {
    return roles;
  } finally {
    clearTimeout(timer);
  }
};

/**
 * The one workload the console can switch on and off: qBittorrent, which runs
 * behind a VPN and is meant to be off unless something is downloading.
 *
 * Scale rather than delete. Zero replicas means nothing running and no RAM
 * held, while the deployment, its secret and its tailnet name stay exactly as
 * configured — so starting it again is one integer and not a redeploy.
 *
 * The ServiceAccount is allowed `get` and `patch` on this deployment's scale
 * subresource and nothing else in the cluster (k8s/qbittorrent.yaml). A bug
 * here cannot reach another workload even if it tried.
 */
const TORRENT = { ns: 'pi', name: 'qbittorrent' };

const scaleUrl = (server: string) =>
  `${server}/apis/apps/v1/namespaces/${TORRENT.ns}/deployments/${TORRENT.name}/scale`;

/**
 * gluetun's control server, reachable inside the cluster only. Two GET routes
 * are open on it (see the ConfigMap in k8s/qbittorrent.yaml); everything else,
 * including anything that could change the tunnel, is denied.
 *
 * Asked directly rather than inferred from the pod being ready, because
 * "running" and "protected" are different claims and only one of them matters
 * before a download starts.
 */
const GLUETUN = 'http://qbittorrent.pi.svc.cluster.local:8000';

const askGluetun = async <T>(path: string): Promise<T | null> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2000);
  try {
    const res = await fetch(`${GLUETUN}${path}`, { signal: controller.signal, cache: 'no-store' });
    return res.ok ? ((await res.json()) as T) : null;
  } catch {
    // Stopped, still starting, or not installed. All of them mean "no tunnel
    // to report", which the caller shows as an absence rather than an error.
    return null;
  } finally {
    clearTimeout(timer);
  }
};

/** The tunnel as gluetun describes it, or null when there is nothing to ask. */
const fetchVpn = async (): Promise<TorrentState['vpn']> => {
  const [status, ip] = await Promise.all([
    askGluetun<{ status?: string }>('/v1/vpn/status'),
    askGluetun<{ public_ip?: string; country?: string; city?: string }>('/v1/publicip/ip'),
  ]);
  if (!status && !ip) return null;
  return {
    status: status?.status ?? null,
    publicIp: ip?.public_ip ?? null,
    country: ip?.country ?? null,
    city: ip?.city ?? null,
    // gluetun's open routes do not say whose server it is. This is the
    // VPN_SERVICE_PROVIDER in k8s/qbittorrent.yaml; change both together.
    provider: 'AirVPN',
  };
};

/**
 * The client's own list, through the Service's web port. The WebUI lets the
 * cluster network in without a login (deploy/install-torrent.sh), and this
 * pod's requests to a cluster IP arrive from it, the same way the installer's
 * settings calls do.
 */
const QBITTORRENT = 'http://qbittorrent.pi.svc.cluster.local';

const GROUPS: Record<string, keyof Omit<TorrentCounts, 'downSpeed'>> = {
  downloading: 'downloading', forcedDL: 'downloading', metaDL: 'downloading', forcedMetaDL: 'downloading',
  allocating: 'downloading', checkingDL: 'downloading', moving: 'downloading',
  stalledDL: 'stalled',
  uploading: 'seeding', forcedUP: 'seeding', stalledUP: 'seeding', checkingUP: 'seeding',
  queuedDL: 'queued', queuedUP: 'queued', checkingResumeData: 'queued',
  // qBittorrent 5 says stopped, 4 said paused.
  stoppedDL: 'stopped', stoppedUP: 'stopped', pausedDL: 'stopped', pausedUP: 'stopped',
  error: 'errored', missingFiles: 'errored',
};

const fetchTorrents = async (): Promise<TorrentCounts | null> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const res = await fetch(`${QBITTORRENT}/api/v2/torrents/info`, { signal: controller.signal, cache: 'no-store' });
    if (!res.ok) return null;
    const list = (await res.json()) as { state?: string; dlspeed?: number }[];
    const counts: TorrentCounts = { downloading: 0, stalled: 0, seeding: 0, queued: 0, stopped: 0, errored: 0, downSpeed: 0 };
    for (const t of list) {
      const group = GROUPS[t.state ?? ''];
      if (group) counts[group] += 1;
      counts.downSpeed += t.dlspeed ?? 0;
    }
    return counts;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
};

export const fetchTorrentState = async (): Promise<TorrentState> => {
  const creds = await credentials();
  if (!creds) return { wanted: 0, ready: 0, reachable: false, vpn: null };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(scaleUrl(creds.server), {
      headers: { Authorization: `Bearer ${creds.token}` },
      signal: controller.signal,
      cache: 'no-store',
    });
    if (!res.ok) return { wanted: 0, ready: 0, reachable: false, vpn: null };
    const body = (await res.json()) as { spec?: { replicas?: number }; status?: { replicas?: number } };
    const wanted = body.spec?.replicas ?? 0;
    return {
      wanted,
      // status.replicas counts pods that exist; a pod that exists but is not
      // ready still reads as starting, which is what the button should say.
      ready: body.status?.replicas ?? 0,
      reachable: true,
      // Only worth asking when something is meant to be running. Asking a
      // stopped workload costs a two-second timeout to learn nothing.
      ...(wanted > 0
        ? await Promise.all([fetchVpn(), fetchTorrents()]).then(([vpn, torrents]) => ({ vpn, torrents }))
        : { vpn: null, torrents: null }),
    };
  } catch {
    return { wanted: 0, ready: 0, reachable: false, vpn: null };
  } finally {
    clearTimeout(timer);
  }
};

/** Start or stop it. Returns the state the cluster accepted, or null. */
export const setTorrentRunning = async (running: boolean): Promise<TorrentState | null> => {
  const creds = await credentials();
  if (!creds) return null;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(scaleUrl(creds.server), {
      method: 'PATCH',
      headers: {
        Authorization: `Bearer ${creds.token}`,
        // Merge patch rather than strategic: scale is a subresource with one
        // field worth setting, and a merge patch says exactly that.
        'Content-Type': 'application/merge-patch+json',
      },
      body: JSON.stringify({ spec: { replicas: running ? 1 : 0 } }),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { spec?: { replicas?: number }; status?: { replicas?: number } };
    // No VPN read here: the pod has only just been asked to start and the
    // tunnel cannot exist yet. The next poll reports it.
    return { wanted: body.spec?.replicas ?? 0, ready: body.status?.replicas ?? 0, reachable: true, vpn: null };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
};
