import { useMemo, useState } from 'preact/hooks';
import { AppsView } from './components/AppsView';
import { DetailView } from './components/DetailView';
import { FilesView } from './components/FilesView';
import { FleetView } from './components/FleetView';
import { StatusView } from './components/StatusView';
import { Alert, Box, Grid, Moon, Power, Pulse, Refresh, Sun, Thermo, Wifi } from './components/icons';
import { getApps, getNodes, getTorrent, nodeWatts, refreshAll, useHistory, useNetHistory, usePoll, usePowerHistory, useSeries } from './lib/api';
import type { FleetNode } from '../../shared/fleet';
import { celsius, pct, watts } from './lib/format';

const POLL_MS = 3000;

type View = 'fleet' | 'detail' | 'apps' | 'files' | 'status';

/**
 * The Apps tab is paused, not deleted: Status lists the same apps and opens
 * them too. Set to true to put the button back; the view and its code are
 * untouched.
 */
const SHOW_APPS_TAB = false;

/**
 * A tile's `#name` is config, so it is checked against the views that exist
 * rather than cast. A typo in apps.json used to switch to a view nothing
 * renders, leaving the page blank with no way back but the toolbar.
 */
const VIEWS: View[] = ['fleet', 'detail', 'apps', 'files', 'status'];
const asView = (name: string): View | null =>
  (VIEWS as string[]).includes(name) ? (name as View) : null;

const gpuTempOf = (n: FleetNode) => n.hw?.gpu?.tempC;
const gpuPowerOf = (n: FleetNode) => n.hw?.gpu?.powerW;

const isDark = () =>
  document.documentElement.dataset.theme
    ? document.documentElement.dataset.theme === 'dark'
    : matchMedia('(prefers-color-scheme: dark)').matches;

export default function App() {
  const [view, setView] = useState<View>('fleet');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [spin, setSpin] = useState(false);

  const fleet = usePoll(getNodes, POLL_MS);
  const apps = usePoll(getApps, 15_000);
  const history = useHistory(fleet.data);
  const powerHistory = usePowerHistory(fleet.data);
  const netHistory = useNetHistory(fleet.data);
  const gpuTempHistory = useSeries(fleet.data, gpuTempOf);
  const gpuPowerHistory = useSeries(fleet.data, gpuPowerOf);

  const nodes = useMemo(() => fleet.data ?? [], [fleet.data]);
  const selected = nodes.find((n) => n.id === selectedId) ?? null;
  const liveNodes = nodes.filter((n) => n.online && !n.error);
  const draws = liveNodes.map(nodeWatts).filter((w): w is number => w != null);
  const totalW = draws.length ? draws.reduce((s, w) => s + w, 0) : null;
  // The toolbar's one temperature: the average of every CPU and GPU reading,
  // so the GPU counts toward it rather than living only inside the card.
  const temps = liveNodes
    .flatMap((n) => [n.temp?.cpuC, n.hw?.gpu?.tempC])
    .filter((t): t is number => t != null);
  const avgTemp = temps.length ? temps.reduce((a, t) => a + t, 0) / temps.length : null;
  // Every drive on every machine as one figure, SSDs and HDDs alike.
  const disks = liveNodes.flatMap((n) => n.disks);
  const diskTotal = disks.reduce((a, d) => a + d.totalBytes, 0);
  const storagePct = diskTotal ? (disks.reduce((a, d) => a + d.usedBytes, 0) / diskTotal) * 100 : null;
  // How hard everything is working: the mean of each machine's CPU and RAM and
  // of every drive's activity. A board that joins later counts by itself.
  const loads = liveNodes
    .flatMap((n) => [n.cpu?.usagePct, n.mem?.usedPct, ...n.disks.map((d) => d.busyPct)])
    .filter((v): v is number => v != null);
  const usagePct = loads.length ? loads.reduce((a, v) => a + v, 0) / loads.length : null;
  // The download VPN (AirVPN, through gluetun): green only once traffic is
  // actually leaving through it. Tailscale is not shown: if the tailnet were
  // down, this page would not load to say so.
  const torrent = usePoll(getTorrent, 15_000).data;
  const vpn = torrent?.vpn;
  const vpnState = !torrent || torrent.wanted === 0 ? 'idle' : vpn?.publicIp ? '' : 'warn';
  const vpnTitle = !torrent || torrent.wanted === 0
    ? 'Download VPN off (Torrent is switched off)'
    : vpn?.publicIp
      ? `Download VPN on: ${[vpn.provider, [vpn.city, vpn.country].filter(Boolean).join(', '), vpn.publicIp].filter(Boolean).join(' · ')}`
      : 'Download VPN starting';

  const openDetail = (id: string) => { setSelectedId(id); setView('detail'); };

  // Spins until the PC's scan is back, so a stopped spin means the page is now.
  const refresh = () => {
    if (spin) return;
    setSpin(true);
    void refreshAll().finally(() => setSpin(false));
  };

  const toggleTheme = () => {
    document.documentElement.dataset.theme = isDark() ? 'light' : 'dark';
    try { localStorage.setItem('appearance', document.documentElement.dataset.theme!); } catch { /* private mode */ }
  };

  // Wider with a second board, so the server's card keeps its size and the
  // Pi gets its own column beside it.
  return (
    <section class={`shell ${nodes.length > 1 ? 'wide' : ''}`}>
      <div class="toolbar">
        <div class="tb-left">
          <span class="tb-stat" title="fleet draw">
            <Power size={12} /><b>{watts(totalW)}</b>
          </span>
          <span class="tb-stat" title="average of CPU and GPU">
            <Thermo size={12} /><b>{celsius(avgTemp)}</b>
          </span>
          <span class="tb-stat" title="all drives on every machine, used">
            <span class="tb-label">STORAGE</span><b>{pct(storagePct)}</b>
          </span>
          <span class="tb-stat" title="mean of CPU, RAM and every drive's activity, on every machine">
            <span class="tb-label">USAGE</span><b>{pct(usagePct)}</b>
          </span>
          <span class="tb-stat" title={vpnTitle}>
            <span class={`dot-live ${vpnState}`} /><span class="tb-label">VPN</span>
          </span>
        </div>

        <div class="tb-center">
          <button class={`tbtn ${view === 'fleet' || view === 'detail' ? 'on' : ''}`} onClick={() => setView('fleet')}>
            <Grid size={15} /> {nodes.length === 1 ? 'Server' : 'Fleet'}
          </button>
          {SHOW_APPS_TAB && (
            <button class={`tbtn ${view === 'apps' ? 'on' : ''}`} onClick={() => setView('apps')}>
              <Box size={15} /> Apps
            </button>
          )}
          <button class={`tbtn ${view === 'status' ? 'on' : ''}`} onClick={() => setView('status')}>
            <Pulse size={15} /> Status
          </button>
        </div>

        <div class="tb-right">
          <span class="live"><span class="dot-live" /> LIVE</span>
          <span class="tdiv" />
          <button class="ibtn" onClick={toggleTheme} title="Switch appearance" aria-label="Switch appearance">
            <span class="i-moon"><Moon size={15} /></span>
            <span class="i-sun"><Sun size={15} /></span>
          </button>
          <button class={`ibtn ${spin ? 'spin' : ''}`} id="refresh" onClick={refresh} title="Refresh" aria-label="Refresh">
            <Refresh size={15} />
          </button>
        </div>
      </div>

      <div class="content">
        {fleet.error && (
          <div class="warning-banner">
            <Alert size={18} />
            <div><strong>Cannot reach the fleet</strong><span>{fleet.error}</span></div>
          </div>
        )}

        {fleet.loading && !fleet.data && (
          <div class="discovery-banner">
            <div class="discovery-icon"><Wifi size={19} /></div>
            <div><strong>Scanning the tailnet</strong><span>Discovering nodes and probing their agents.</span></div>
          </div>
        )}

        {view === 'fleet' && fleet.data && (
          <FleetView
            nodes={nodes}
            onOpen={openDetail}
            tempHistory={history}
            powerHistory={powerHistory}
            netHistory={netHistory}
            gpuTempHistory={gpuTempHistory}
            gpuPowerHistory={gpuPowerHistory}
          />
        )}
        {view === 'apps' && (
          <AppsView
            apps={apps.data ?? []}
            onOpenView={(next) => {
              const target = asView(next);
              if (target) setView(target);
            }}
          />
        )}
        {view === 'status' && <StatusView apps={apps.data ?? []} />}
        {view === 'files' && <FilesView nodes={nodes} />}
        {view === 'detail' && selected && (
          <DetailView node={selected} history={history.get(selected.id) ?? []} onBack={() => setView('fleet')} />
        )}
        {view === 'detail' && !selected && fleet.data && (
          <div class="warning-banner">
            <Alert size={18} />
            <div>
              <strong>Node is no longer on the tailnet</strong>
              <span><button class="back-link" onClick={() => setView('fleet')}>Back to Fleet</button></span>
            </div>
          </div>
        )}
      </div>

    </section>
  );
}
