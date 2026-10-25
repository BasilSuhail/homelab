import { useState } from 'preact/hooks';
import { Alert, Back, Box, Cpu, Disk, Gauge, List, Mem, Net, Power, Refresh, Thermo, Wifi } from './icons';
import type { ContainerRow, FleetNode, ProcessRow } from '../../../shared/fleet';
import { getContainers, getProcesses, nodeWatts, usePoll } from '../lib/api';
import { bytes, bytesPerSec, capacity, cpuTone, diskTone, pct, uptime } from '../lib/format';
import { Meter, PanelTitle, Sparkline, StatusDot } from './primitives';

type Sort = 'cpu' | 'ram';

export const DetailView = ({
  node,
  history,
  onBack,
}: {
  node: FleetNode;
  history: number[];
  onBack: () => void;
}) => {
  const [sort, setSort] = useState<Sort>('cpu');

  /**
   * The same chained poll the rest of the console uses, rather than a bare
   * setInterval.
   *
   * An interval fires whether or not the previous request came back. A process
   * list from pi during an ingest burst can take seconds — the Glances client
   * allows six of them — so a five second interval stacked requests on the one
   * board least able to absorb them, and each one made the next slower. usePoll
   * waits for the answer before scheduling the next ask.
   */
  const detail = usePoll(
    async () =>
      Promise.all([
        getProcesses(node.id).catch(() => [] as ProcessRow[]),
        getContainers(node.id).catch(() => [] as ContainerRow[]),
      ]),
    5000,
    [node.id],
  );

  const [processes, containers] = detail.data ?? [[] as ProcessRow[], [] as ContainerRow[]];

  const sorted = [...processes].sort((a, b) =>
    sort === 'cpu' ? (b.cpuPct ?? -1) - (a.cpuPct ?? -1) : b.memBytes - a.memBytes,
  );

  const mem = node.mem;
  const load = node.cpu?.loadAvg ?? [0, 0, 0];
  const throttled = node.temp?.throttled;
  const temp = node.temp?.cpuC ?? 0;

  // Glances reports used/available; cache is the gap between them and free.
  const cacheBytes = mem ? Math.max(mem.availableBytes - (mem.totalBytes - mem.usedBytes), 0) : 0;
  const freeBytes = mem ? mem.totalBytes - mem.usedBytes - cacheBytes : 0;

  // A desktop's extra hardware. Each panel below appears only when the agent
  // read the thing, so a Pi's detail page is what it always was.
  const gpu = node.hw?.gpu ?? null;
  const fans = node.hw?.fans ?? [];
  const drawW = nodeWatts(node);
  // Every temperature the machine reports beside the CPU's, hottest first.
  const otherTemps = [
    ...(gpu?.tempC != null ? [{ name: 'GPU', c: gpu.tempC }] : []),
    ...node.disks.filter((d) => d.tempC != null).map((d) => ({ name: d.mount, c: d.tempC as number })),
  ].sort((a, b) => b.c - a.c);

  return (
    <div class="page-stack">
      <button class="back-link" onClick={onBack}>
        <Back size={15} /> Back to Fleet
      </button>

      <div class="detail-heading">
        <div>
          <p class="eyebrow">
            <span class="mini-led" /> NODE DETAIL
          </p>
          <h1>
            {node.name} <span class="title-chip">{node.role}</span>
          </h1>
          <p class="subhead">
            {node.tailscaleIp} · {node.model ?? node.os ?? 'unknown hardware'}
            {gpu ? ` · ${gpu.name.replace(/^NVIDIA\s+(GeForce\s+)?/i, '')}` : ''} · up {uptime(node.uptimeSec)}
          </p>
        </div>
        <StatusDot online={node.online} />
      </div>

      {throttled?.now && (
        <div class="warning-banner">
          <Alert size={18} />
          <div>
            <strong>Throttling right now</strong>
            <span>{throttled.reasons.join(', ')}</span>
          </div>
        </div>
      )}
      {!throttled?.now && throttled?.everSinceBoot && (
        <div class="warning-banner">
          <Alert size={18} />
          <div>
            <strong>Throttled at some point since boot</strong>
            <span>{throttled.reasonsSinceBoot.join(', ')} · not happening now</span>
          </div>
        </div>
      )}

      <div class="detail-grid">
        <section class="panel cpu-panel">
          <PanelTitle
            icon={<Cpu />}
            title="Processor"
            meta={`load average ${load.map((l) => l.toFixed(2)).join(' · ')}`}
          />
          <div class="core-list">
            {(node.cpu?.perCore ?? []).map((value, index) => (
              <div class="core-row" key={index}>
                <span>core {index}</span>
                <Meter value={value} tone={cpuTone(value)} />
                <strong>{pct(value)}</strong>
              </div>
            ))}
          </div>
          <div class="panel-foot">
            <span>cores</span>
            <strong>{node.cpu?.cores ?? '—'}</strong>
            <span>arch</span>
            <strong>{node.arch ?? '—'}</strong>
          </div>
        </section>

        <section class="panel temp-panel">
          <PanelTitle icon={<Thermo />} title="Thermals" meta={`last ${history.length} samples`} />
          <div class="temp-reading">
            <strong>{Math.round(temp)}°</strong>
            <span>CPU temperature</span>
          </div>
          <Sparkline series={history} />
          <div class="sparkline-labels">
            <span>earlier</span>
            <span>now</span>
          </div>
          <div class="temp-status">
            <span class="check-mark">{temp > 80 ? '!' : '✓'}</span>
            {temp > 80 ? 'thermal zone hot' : 'thermal zone nominal'}
            <strong>limit 85°</strong>
          </div>
          {otherTemps.map((t) => (
            <div class="sensor-row" key={t.name}>
              <span>{t.name}</span>
              <Meter value={(t.c / 90) * 100} tone={t.c >= 70 ? 'red' : t.c >= 55 ? 'orange' : 'aqua'} />
              <strong>{Math.round(t.c)}°</strong>
            </div>
          ))}
        </section>

        <section class="panel memory-panel">
          <PanelTitle icon={<Mem />} title="Memory" meta={`${capacity(mem?.totalBytes)} installed`} />
          <div class="memory-bar">
            <span style={{ width: `${mem?.usedPct ?? 0}%` }} />
          </div>
          <div class="memory-legend">
            <span>
              <i class="dot used" /> used <strong>{bytes(mem?.usedBytes)}</strong>
            </span>
            <span>
              <i class="dot cache" /> cache <strong>{bytes(cacheBytes)}</strong>
            </span>
            <span>
              <i class="dot free" /> free <strong>{bytes(freeBytes)}</strong>
            </span>
            <span>
              <i class="dot swap" /> swap <strong>{bytes(mem?.swapUsedBytes)}</strong>
            </span>
          </div>
        </section>

        {node.power ? (
          <section class="panel power-panel">
            <PanelTitle icon={<Power />} title="Power draw" meta="Pi 5 PMIC" />
            <div class="power-number">
              <strong>{node.power.watts.toFixed(2)} W</strong>
              <span>now</span>
            </div>
            <div class="power-detail">
              <span>
                rails <b>{node.power.rails.length}</b>
              </span>
              <span>
                peak rail <b>{node.power.rails.reduce((m, r) => (r.watts > m.watts ? r : m)).name}</b>
              </span>
            </div>
          </section>
        ) : drawW != null ? (
          // A desktop: no meter for the whole machine, so this is the CPU
          // package from its own energy counter, plus the GPU if it reports.
          <section class="panel power-panel">
            <PanelTitle icon={<Power />} title="Power draw" meta="RAPL counter" />
            <div class="power-number">
              <strong>{drawW.toFixed(1)} W</strong>
              <span>{gpu?.powerW != null ? 'cpu + gpu' : 'cpu package'}</span>
            </div>
            <div class="power-detail">
              <span>
                cpu <b>{node.hw?.cpuWatts != null ? `${node.hw.cpuWatts.toFixed(1)} W` : '—'}</b>
              </span>
              <span>
                gpu <b>{gpu?.powerW != null ? `${gpu.powerW.toFixed(1)} W` : 'not reported'}</b>
              </span>
            </div>
          </section>
        ) : (
          <section class="panel power-panel">
            <PanelTitle icon={<Power />} title="Power draw" meta="unavailable" />
            <div class="offline-copy">
              <span>No power reading on this machine</span>
            </div>
          </section>
        )}
      </div>

      <section class="panel full-panel">
        <PanelTitle icon={<Disk />} title="Disks" meta="mount points" />
        {node.disks.map((disk) => (
          <div class="disk-row" key={disk.mount}>
            <span class="mount">{disk.mount}</span>
            <Meter value={disk.usedPct} tone={diskTone(disk.usedPct)} />
            <strong>{pct(disk.usedPct)}</strong>
            <span>
              {bytes(disk.usedBytes)} / {bytes(disk.totalBytes)}
              {disk.tempC != null ? ` · ${Math.round(disk.tempC)}°` : ''}
            </span>
          </div>
        ))}
      </section>

      {(gpu || fans.length > 0) && (
        <div class="detail-grid lower">
          {gpu && (
            <section class="panel">
              <PanelTitle icon={<Gauge />} title="Graphics" meta={gpu.name.replace(/^NVIDIA\s+(GeForce\s+)?/i, '')} />
              {([
                ['load', gpu.utilPct],
                ['vram', gpu.memTotalBytes ? ((gpu.memUsedBytes ?? 0) / gpu.memTotalBytes) * 100 : null],
                ['encode', gpu.encoderPct],
                ['decode', gpu.decoderPct],
              ] as Array<[string, number | null]>).filter(([, v]) => v != null).map(([name, v]) => (
                <div class="sensor-row" key={name}>
                  <span>{name}</span>
                  <Meter value={v as number} tone="gpu" />
                  <strong>{pct(v)}</strong>
                </div>
              ))}
              <div class="panel-foot">
                <span>temp</span>
                <strong>{gpu.tempC != null ? `${Math.round(gpu.tempC)}°` : '—'}</strong>
                <span>vram</span>
                <strong>{bytes(gpu.memUsedBytes)} / {bytes(gpu.memTotalBytes)}</strong>
                <span>fan</span>
                <strong>{gpu.fanPct != null ? `${Math.round(gpu.fanPct)}%` : '—'}</strong>
              </div>
            </section>
          )}
          {fans.length > 0 && (
            <section class="panel">
              <PanelTitle
                icon={<Refresh />}
                title="Fans"
                meta={fans.some((f) => f.managed) ? 'by temperature' : 'BIOS curve'}
              />
              {fans.map((f) => (
                <div class="sensor-row" key={f.label}>
                  <span>{f.label}</span>
                  <Meter value={Math.min(100, (f.rpm / 3000) * 100)} tone={f.rpm ? 'aqua' : ''} />
                  <strong>{f.rpm ? `${f.rpm.toLocaleString()} rpm` : 'off'}</strong>
                </div>
              ))}
            </section>
          )}
        </div>
      )}

      <div class="detail-grid lower">
        <section class="panel full-panel">
          <PanelTitle icon={<Net />} title="Network" meta="throughput" />
          {node.net.length === 0 && <div class="offline-copy"><span>No physical interfaces reported</span></div>}
          {node.net.map((n) => (
            <div class="network-row" key={n.iface}>
              <span>
                {n.iface.startsWith('wl') ? <Wifi size={15} /> : <Disk size={15} />} {n.iface}
              </span>
              <strong>{bytesPerSec(n.rxBps)}</strong>
              <span class="network-secondary">rx</span>
              <strong>{bytesPerSec(n.txBps)}</strong>
              <span class="network-secondary">
                tx <Disk size={13} />
              </span>
            </div>
          ))}
        </section>

        <section class="panel full-panel">
          <PanelTitle icon={<Box />} title="Containers" meta={`${containers.length} running`} />
          <div class="mini-table">
            <div class="mini-table-head">
              <span>NAME</span>
              <span>STATUS</span>
              <span>CPU</span>
              <span>RAM</span>
            </div>
            {containers.length === 0 && (
              <div class="mini-table-row">
                <span>—</span>
                <span>no containers</span>
                <span />
                <span />
              </div>
            )}
            {containers.map((c) => (
              <div class="mini-table-row" key={c.name}>
                <span>{c.name}</span>
                <span>
                  <i class="health-dot" /> {c.status}
                </span>
                <span>{c.cpuPct == null ? '—' : pct(c.cpuPct)}</span>
                {/* Blank until cgroup memory accounting is enabled on the node. */}
                <span>{c.memBytes == null ? '—' : bytes(c.memBytes)}</span>
              </div>
            ))}
          </div>
        </section>
      </div>

      <section class="panel full-panel process-panel">
        <PanelTitle icon={<List />} title="Processes" meta="click a column to sort" />
        <div class="process-table">
          <div class="process-head">
            <span>PID</span>
            <span>NAME</span>
            <button onClick={() => setSort('cpu')}>CPU% {sort === 'cpu' ? '↓' : ''}</button>
            <button onClick={() => setSort('ram')}>RAM {sort === 'ram' ? '↓' : ''}</button>
          </div>
          {sorted.map((p) => (
            <div class="process-row" key={p.pid}>
              <span>{p.pid}</span>
              <span>{p.name}</span>
              <span>{p.cpuPct == null ? '—' : p.cpuPct.toFixed(1)}</span>
              <span>{bytes(p.memBytes)}</span>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
};
