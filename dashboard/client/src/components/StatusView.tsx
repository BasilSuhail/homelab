import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import type { ActiveUse, AppTile, ContentStatus, PastUse, Person, TorrentCounts, TorrentState } from '../../../shared/fleet';
import { getStatus, getTorrent, onRefresh, setTorrent, usePoll } from '../lib/api';
import { bytes, bytesPerSec, relative } from '../lib/format';
import { openApp } from '../lib/open';

/** Older than this, "who is using what" is history, not now. */
const STALE_MS = 3 * 60_000;

const isArt = (icon: string | null | undefined): icon is string =>
  !!icon && (icon.startsWith('/') || icon.startsWith('http'));

/** "admin is uploading 4.2 Mbit/s", the first of several with a count. */
const nowLine = (uses: ActiveUse[]): string | null => {
  if (!uses.length) return null;
  const [u] = uses;
  // Jellyfin's own sessions name the film; pi-paths already starts with a verb.
  const what = u.what.startsWith('"') ? `watching ${u.what}` : u.what;
  return `${u.who} is ${what}${uses.length > 1 ? ` · +${uses.length - 1} more` : ''}`;
};

/** The live-view browser lists everyone on it, not just the first: the job
 *  bot, a Claude agent session and each device watching can overlap. */
const browserLine = (uses: ActiveUse[]): string | null =>
  uses.length
    ? uses.map((u) => (u.who === 'User' ? `${u.device} is ${u.what}` : `${u.who} is ${u.what}`)).join(' · ')
    : null;

/** "2 downloading · 1 stalled · 0 seeding · 0 stopped", plus queued and errors when there are any. */
const qbitLine = (c: TorrentCounts): string =>
  [
    `${c.downloading} downloading`,
    `${c.stalled} stalled`,
    `${c.seeding} seeding`,
    `${c.stopped} stopped`,
    c.queued ? `${c.queued} queued` : '',
    c.errored ? `${c.errored} with errors` : '',
  ].filter(Boolean).join(' · ');

const torrentLine = (t: TorrentState | null): { text: string; on: boolean; bad?: boolean } => {
  if (!t) return { text: 'Checking…', on: false };
  if (!t.reachable) return { text: 'Cluster unreachable', on: false, bad: true };
  if (t.wanted === 0) return { text: t.ready > 0 ? 'Stopping…' : 'Off', on: false };
  if (t.ready === 0) return { text: 'Starting…', on: true };
  const v = t.vpn;
  if (!v?.publicIp) return { text: 'On · waiting for the VPN', on: true };
  const where = [v.city, v.country].filter(Boolean).join(', ');
  return { text: ['On', v.provider, where, v.publicIp].filter(Boolean).join(' · '), on: true };
};

interface RowProps {
  name: string;
  app?: AppTile;
  letter: string;
  accent: string;
  sub: string | null;
  tone?: 'busy' | 'bad' | null;
  value?: string;
  value2?: string;
  /** False holds the row shut, e.g. qBittorrent while the switch is off. */
  canOpen?: boolean;
  right?: ComponentChildren;
}

const Row = ({ name, app, letter, accent, sub, tone, value, value2, canOpen = true, right }: RowProps) => {
  const opens = !!app && canOpen && !right;
  const go = (e: MouseEvent | KeyboardEvent | null) => { if (opens && app) openApp(e, app.name, app.url); };
  return (
    <div
      class={`srow${opens ? ' opens' : ''}`}
      role={opens ? 'link' : undefined}
      tabIndex={opens ? 0 : undefined}
      title={opens ? `Open ${name} · ⌘, Ctrl or Shift-click for a browser tab` : undefined}
      onClick={(e) => go(e)}
      onAuxClick={(e) => { if (e.button === 1) go(e); }}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(e); } }}
    >
      <div class={`sico ${isArt(app?.icon) ? 'art' : accent}`}>
        {isArt(app?.icon) ? <img src={app!.icon!} alt="" loading="lazy" /> : <span>{letter}</span>}
      </div>
      <div class="smain">
        <span class="st">{name}</span>
        <span class={`ss${tone ? ` ${tone}` : ''}`}>{sub ?? 'No one using it'}</span>
      </div>
      {right ?? (
        <>
          {(value || value2) && (
            <span class="svv">
              {value && <span class="sv">{value}</span>}
              {value2 && <span class="sv2">{value2}</span>}
            </span>
          )}
          {opens && <span class="schev">›</span>}
        </>
      )}
    </div>
  );
};

/** One line under an app: a user and their share. Not clickable. */
const SubRow = ({ name, value }: { name: string; value: string }) => (
  <div class="srow sub">
    <div class="smain"><span class="st">{name}</span></div>
    <span class="sv">{value}</span>
  </div>
);

/** "14:05" today, "Yesterday 22:10", or "Sat 09:30" further back. */
const clock = (sec: number): string => {
  const at = new Date(sec * 1000);
  const hm = at.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  const midnight = new Date();
  midnight.setHours(0, 0, 0, 0);
  if (at >= midnight) return hm;
  if (at.getTime() >= midnight.getTime() - 86_400_000) return `Yesterday ${hm}`;
  return `${at.toLocaleDateString(undefined, { weekday: 'short' })} ${hm}`;
};

/** "14:05–15:20", or the one time for a use seen once. */
const span = (u: PastUse): string =>
  u.end - u.start < 60
    ? clock(u.start)
    : `${clock(u.start)}–${new Date(u.end * 1000).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}`;

type Pane = 'data' | 'history';

/** One half of the Users line: a button that opens its list below. */
const Half = ({ on, letter, accent, title, sub, busy, onClick }: {
  on: boolean; letter: string; accent: string; title: string; sub: string; busy?: boolean; onClick: () => void;
}) => (
  <div
    class={`srow opens${on ? ' on' : ''}`}
    role="button"
    tabIndex={0}
    aria-expanded={on}
    onClick={onClick}
    onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); } }}
  >
    <div class={`sico ${accent}`}><span>{letter}</span></div>
    <div class="smain">
      <span class="st">{title}</span>
      <span class={`ss${busy ? ' busy' : ''}`}>{sub}</span>
    </div>
    <span class={`schev${on ? ' down' : ''}`}>›</span>
  </div>
);

/** "Jellyfin (admin) · Nextcloud · Immich (off)". */
const appsLine = (p: Person) =>
  Object.entries(p.apps)
    .map(([app, a]) => `${app}${a.disabled ? ' (off)' : a.admin ? ' (admin)' : ''}`)
    .join(' · ');

const lastSeen = (p: Person) => {
  const seen = Object.values(p.apps).map((a) => a.lastSeen ?? 0);
  const at = Math.max(0, ...seen);
  return at ? `seen ${relative(new Date(at * 1000).toISOString())}` : '';
};

/**
 * One line, two halves: User data (who has an account where) and User
 * activity history (who used what, and when). Either opens its list below,
 * full width; the line itself stays split.
 */
const UsersPanel = ({ now, log, accounts }: {
  now: ActiveUse[]; log: PastUse[]; accounts: ContentStatus['accounts'] | undefined;
}) => {
  const [pane, setPane] = useState<Pane | null>(null);
  const toggle = (p: Pane) => setPane(pane === p ? null : p);
  const recent = [...log].reverse();
  const last = recent[0];
  const people = accounts?.people ?? [];
  const apps = Object.entries(accounts?.apps ?? {});
  const history = now.length
    ? `${now[0].who} on ${now[0].app}${now.length > 1 ? ` · +${now.length - 1} more` : ''}`
    : last
      ? `Last: ${last.who} on ${last.app} · ${clock(last.end)}`
      : 'No one has used anything yet';
  const live = (u: PastUse) => now.some((a) => a.app === u.app && a.who === u.who && a.device === u.device);
  return (
    <>
      <div class="ssplit">
        <Half on={pane === 'data'} letter="U" accent="blue" title="User data" onClick={() => toggle('data')}
          sub={accounts ? `${people.length} ${people.length === 1 ? 'person' : 'people'} · ${count(apps.length, 'app')}` : 'Waiting for the PC'} />
        <Half on={pane === 'history'} letter="H" accent="pink" title="User activity history" onClick={() => toggle('history')}
          sub={history} busy={now.length > 0} />
      </div>
      {pane === 'data' && (
        <>
          {apps.length > 0 && (
            <div class="srow sub">
              <div class="smain"><span class="ss">{apps.map(([app, n]) => `${app} ${n}`).join(' · ')}</span></div>
            </div>
          )}
          {people.map((p) => (
            <div class="srow sub" key={p.name}>
              <div class="smain">
                <span class="st">{p.name}</span>
                <span class="ss">{appsLine(p)}</span>
              </div>
              <span class="svv">
                <span class="sv">{count(Object.keys(p.apps).length, 'app')}</span>
                {lastSeen(p) && <span class="sv2">{lastSeen(p)}</span>}
              </span>
            </div>
          ))}
          {!people.length && <div class="srow sub"><div class="smain"><span class="ss">No accounts read yet</span></div></div>}
        </>
      )}
      {pane === 'history' && (
        <>
          {recent.map((u) => (
            <div class="srow sub" key={`${u.app}|${u.who}|${u.device}|${u.start}`}>
              <div class="smain">
                <span class="st">{u.who}</span>
                <span class={`ss${live(u) ? ' busy' : ''}`}>{[u.app, u.what, u.device].filter(Boolean).join(' · ')}</span>
              </div>
              <span class="sv">{live(u) ? `${clock(u.start)}–now` : span(u)}</span>
            </div>
          ))}
          {!recent.length && <div class="srow sub"><div class="smain"><span class="ss">Nothing in the last 2 days</span></div></div>}
        </>
      )}
    </>
  );
};

const count = (n: number, one: string) => `${n.toLocaleString()} ${one}${n === 1 ? '' : 's'}`;

export const StatusView = ({ apps }: { apps: AppTile[] }) => {
  const feed = usePoll(getStatus, 30_000);
  const [torrent, setTorrentState] = useState<TorrentState | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  // As on the Apps tab: slow while nothing is changing, quick mid-transition.
  useEffect(() => {
    let live = true;
    const read = () => { void getTorrent().then((t) => live && setTorrentState(t)).catch(() => {}); };
    read();
    const moving = torrent && torrent.reachable && (torrent.wanted ? torrent.ready === 0 : torrent.ready > 0);
    const timer = setInterval(read, moving ? 3000 : 15000);
    const off = onRefresh(read);
    return () => { live = false; clearInterval(timer); off(); };
  }, [torrent?.wanted, torrent?.ready, torrent?.reachable]);

  const flip = (running: boolean) => {
    setBusy(true);
    setProblem(null);
    void setTorrent(running)
      .then(setTorrentState)
      .catch((err: Error) => setProblem(err.message))
      .finally(() => setBusy(false));
  };

  const status: ContentStatus | null = feed.data ?? null;
  const fresh = !!status && Date.now() - status.ts * 1000 < STALE_MS;
  const app = (name: string) => apps.find((a) => a.name === name);
  const uses = (name: string) => (fresh ? status!.active.filter((a) => a.app === name) : []);

  /** The line under an app's name: who is on it, unless it is not answering. */
  const sub = (tile: AppTile | undefined, appName: string): Pick<RowProps, 'sub' | 'tone'> => {
    if (tile?.healthy === false) return { sub: 'Not answering', tone: 'bad' };
    const line = nowLine(uses(appName));
    return line ? { sub: line, tone: 'busy' } : { sub: null };
  };
  const upDown = (tile: AppTile | undefined) =>
    tile?.healthy === true ? 'Up' : tile?.healthy === false ? 'Down' : '';

  const jf = status?.jellyfin ?? null;
  const kx = status?.kiwix ?? null;
  const im = status?.immich ?? null;
  const nc = status?.nextcloud ?? null;
  const gt = status?.gitea ?? null;
  const tl = torrentLine(torrent);
  const qb = app('qBittorrent');
  const osint = (name: string) => {
    const tile = app(name);
    return tile?.healthy
      ? { sub: null, value: 'Up' }
      : { sub: 'Not on the PC yet', value: 'not live' };
  };

  return (
    <div class="page-stack">
      <div class="page-heading">
        <div>
          <p class="eyebrow">STATUS <span class="mini-led" /></p>
          <h1>Your content, at a glance.</h1>
          <p class="subhead">Each app, who is using it and what they are doing. Click to open; ⌘-click for a browser tab.</p>
        </div>
      </div>

      <div class="sgroups">
        <div class="sstack">
          <div class="sgrp">
            <h3>Media</h3>
            <div class="slist">
              <Row name="Jellyfin" app={app('Jellyfin')} letter="J" accent="purple" {...sub(app('Jellyfin'), 'Jellyfin')}
                value={jf ? `${jf.films} films · ${jf.series} series` : undefined}
                value2={jf?.bytes != null ? bytes(jf.bytes, 0) : undefined} />
              <Row name="Kiwix" app={app('Kiwix')} letter="K" accent="green" {...sub(app('Kiwix'), 'Kiwix')}
                value={kx ? `${kx.books} ${kx.books === 1 ? 'book' : 'books'} · ${bytes(kx.bytes, 0)}` : undefined} />
              <Row name="Torrent" letter="T" accent="orange" sub={tl.text} tone={tl.bad ? 'bad' : tl.on ? 'busy' : null}
                right={
                  <button
                    class={`stog${tl.on ? ' on' : ''}`}
                    disabled={busy || !torrent?.reachable || (torrent.wanted === 0 ? torrent.ready > 0 : torrent.ready === 0)}
                    aria-label="Torrent"
                    aria-pressed={tl.on}
                    title={tl.on ? 'Stop the client and drop the VPN with it' : 'Bring the VPN up, then the client'}
                    onClick={() => flip(!tl.on)}
                  />
                } />
              <Row name="qBittorrent" app={qb} letter="q" accent="blue"
                canOpen={!!torrent && torrent.wanted > 0 && torrent.ready > 0}
                sub={!tl.on ? 'Off · switch Torrent on to use it'
                  : torrent?.torrents ? qbitLine(torrent.torrents)
                  : torrent && torrent.ready > 0 ? 'Not answering yet' : 'Starting…'}
                tone={tl.on && torrent?.torrents?.downloading ? 'busy' : null}
                value={tl.on && torrent?.torrents?.downSpeed ? bytesPerSec(torrent.torrents.downSpeed) : undefined} />
            </div>
          </div>

          <div class="sgrp">
            <h3>OSINT</h3>
            <div class="slist">
              <Row name="OSINT" app={app('OSINT')} letter="O" accent="blue" canOpen={!!app('OSINT')?.healthy} {...osint('OSINT')} />
              <Row name="OSINT News" app={app('OSINT News')} letter="N" accent="blue" canOpen={!!app('OSINT News')?.healthy} {...osint('OSINT News')} />
            </div>
          </div>

          <div class="sgrp">
            <h3>Browser</h3>
            <div class="slist">
              <Row name="Browser" app={app('Browser')} letter="B" accent="blue"
                sub={app('Browser')?.healthy === false ? 'Not answering' : browserLine(uses('Browser')) ?? 'Free · open to use it'}
                tone={app('Browser')?.healthy === false ? 'bad' : uses('Browser').length ? 'busy' : null}
                value={uses('Browser').length ? [...new Set(uses('Browser').map((u) => u.who))].join(' · ') : 'Free'} />
            </div>
          </div>

          <div class="sgrp">
            <h3>Watching over it</h3>
            <div class="slist">
              <Row name="Uptime Kuma" app={app('Uptime')} letter="U" accent="green"
                sub={app('Uptime')?.healthy === false ? 'Not answering' : 'Monitor counts come with a Kuma key'}
                tone={app('Uptime')?.healthy === false ? 'bad' : null} value={upDown(app('Uptime'))} />
              <UsersPanel now={fresh ? status!.active : []} log={status?.users ?? []} accounts={status?.accounts} />
            </div>
          </div>
        </div>

        <div class="sgrp">
          <h3>Cloud</h3>
          <div class="slist">
            <Row name="Nextcloud" app={app('Nextcloud')} letter="N" accent="blue" {...sub(app('Nextcloud'), 'Nextcloud')}
              value={nc ? bytes(nc.bytes, 1) : upDown(app('Nextcloud'))}
              value2={nc ? count(nc.users.length, 'user') : undefined} />
            {nc?.users.map((u) => <SubRow key={u.name} name={u.name} value={bytes(u.bytes, 1)} />)}
            <Row name="Immich" app={app('Photos')} letter="I" accent="orange" {...sub(app('Photos'), 'Immich')}
              value={im ? `${bytes(im.bytes, 1)} · ${count(im.photos, 'photo')}` : upDown(app('Photos'))}
              value2={im ? count(im.videos, 'video') : undefined} />
            {im?.users.map((u) => (
              <SubRow key={u.name} name={u.name}
                value={`${bytes(u.bytes, 1)} · ${count(u.photos, 'photo')} · ${count(u.videos, 'video')}`} />
            ))}
            <Row name="Vaultwarden" app={app('Vault')} letter="V" accent="purple" {...sub(app('Vault'), 'Vaultwarden')} value={upDown(app('Vault'))} />
            <Row name="ArchiveBox" app={app('ArchiveBox')} letter="A" accent="pink" {...sub(app('ArchiveBox'), 'ArchiveBox')} value={upDown(app('ArchiveBox'))} />
            <Row name="Gitea" app={app('Gitea')} letter="G" accent="green" {...sub(app('Gitea'), 'Gitea')}
              value={gt ? `${count(gt.repos, 'repo')} · ${bytes(gt.bytes, 1)}` : upDown(app('Gitea'))}
              value2={gt ? (gt.lastBackup ? `backed up ${relative(new Date(gt.lastBackup * 1000).toISOString())}` : 'no backup yet') : undefined} />
          </div>
          <p class="sfoot">
            {[!nc && 'Nextcloud', !im && 'Immich', 'ArchiveBox'].filter(Boolean).join(', ')} totals and Kuma's monitors
            arrive as each one is set up.
          </p>
        </div>
      </div>

      {!status && !feed.loading && (
        <p class="sfoot">Who is using what appears once the PC writes it (pi-status.timer, every 30 s).</p>
      )}
      {status && !fresh && (
        <p class="sfoot">
          Who is using what was last written {Math.round((Date.now() - status.ts * 1000) / 60_000)} min ago, so it is
          not shown: sudo systemctl status pi-status.timer
        </p>
      )}
      {problem && <p class="sfoot bad">The switch did not work: {problem}</p>}
    </div>
  );
};
