/**
 * Serves the built client and the fleet API.
 *
 * Plain node:http rather than a framework — this handles four routes and a
 * static directory, and every dependency is memory that could go to the
 * workloads being watched instead.
 */

import { createGzip } from 'node:zlib';
import { fetchTorrentState, setTorrentRunning } from './lib/kube';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { pipeline } from 'node:stream/promises';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fetchApps } from './apps';
import { credentialStatus } from './lib/expiry';
import { dialHost } from './lib/dial';
import { fetchCache, fetchListing, fetchRoots, openStream, postUpload, postWrite } from './lib/files';
import { fetchFleet } from './lib/fleet';
import { handleLogin, signedIn } from './lib/login';
import { postFan } from './lib/shim';
import { fetchContentStatus, refreshStatus } from './lib/status';
import { fetchContainers, fetchProcesses } from './lib/glances';
import { fetchTailnetDevices, ipv4Of } from './lib/tailnet';

const PORT = Number(process.env.PORT ?? 8080);
const STATIC_DIR = join(dirname(fileURLToPath(import.meta.url)), 'public');

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
};

/** Below this, framing costs more than compression saves. */
const GZIP_MIN = 1024;
const COMPRESSIBLE = /^(text\/|application\/(json|javascript)|image\/svg)/;

const acceptsGzip = (req: IncomingMessage) =>
  /\bgzip\b/.test(String(req.headers['accept-encoding'] ?? ''));

const sendJson = (req: IncomingMessage, res: ServerResponse, status: number, body: unknown) => {
  const payload = Buffer.from(JSON.stringify(body));
  const head: Record<string, string | number> = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  };
  if (payload.length >= GZIP_MIN && acceptsGzip(req)) {
    head['Content-Encoding'] = 'gzip';
    head.Vary = 'Accept-Encoding';
    res.writeHead(status, head);
    const gz = createGzip();
    gz.pipe(res);
    gz.end(payload);
    return;
  }
  head['Content-Length'] = payload.length;
  res.writeHead(status, head);
  res.end(payload);
};

/** Resolves a tailnet device id to the address its agents listen on. */
const addressFor = async (id: string): Promise<string | null> => {
  const device = (await fetchTailnetDevices()).find((d) => d.id === id);
  const ip = device ? ipv4Of(device) : null;
  // Loopback for this machine's own address. See lib/dial.ts.
  return ip ? dialHost(ip) : null;
};

const readBody = async (req: IncomingMessage): Promise<string> => {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error('request body too large');
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
};

const handleApi = async (req: IncomingMessage, url: URL, res: ServerResponse): Promise<boolean> => {
  if (url.pathname === '/api/nodes') {
    sendJson(req, res, 200, await fetchFleet());
    return true;
  }

  if (url.pathname === '/api/status') {
    sendJson(req, res, 200, await fetchContentStatus());
    return true;
  }

  // The refresh button: a scan now rather than at the next 30-second tick.
  if (url.pathname === '/api/refresh' && req.method === 'POST') {
    sendJson(req, res, 200, { fresh: await refreshStatus() });
    return true;
  }

  if (url.pathname === '/api/apps') {
    sendJson(req, res, 200, await fetchApps());
    return true;
  }

  // The download stack's power switch. GET reports what the cluster has, POST
  // sets it — the only write this server can make against the cluster, and it
  // is one integer on one deployment (see the Role in k8s/qbittorrent.yaml).
  if (url.pathname === '/api/torrent') {
    if (req.method === 'POST') {
      const { running } = JSON.parse(await readBody(req)) as { running?: unknown };
      if (typeof running !== 'boolean') {
        sendJson(req, res, 400, { error: 'running must be true or false' });
        return true;
      }
      const state = await setTorrentRunning(running);
      // A refusal here is almost always RBAC: the console was deployed before
      // the Role existed, or the Role was removed. Say so rather than leaving
      // a button that silently does nothing.
      if (!state) {
        sendJson(req, res, 502, {
          error: 'the cluster refused the change — run `make torrent` to install the permission',
        });
        return true;
      }
      sendJson(req, res, 200, state);
      return true;
    }
    sendJson(req, res, 200, await fetchTorrentState());
    return true;
  }

  // Read from the environment, so no agent is involved and this cannot fail
  // the way a fleet poll can. Empty under systemd, where nothing expires.
  if (url.pathname === '/api/credentials') {
    sendJson(req, res, 200, credentialStatus());
    return true;
  }

  const files = url.pathname.match(/^\/api\/nodes\/([^/]+)\/files$/);
  if (files) {
    const host = await addressFor(decodeURIComponent(files[1]));
    if (!host) {
      sendJson(req, res, 404, { error: 'unknown node, or it has no IPv4 address' });
      return true;
    }
    // The path is not validated here. The shim owns that decision and refuses
    // anything outside its roots; duplicating the rule in two places is how
    // the two drift apart.
    const path = url.searchParams.get('path');
    try {
      sendJson(req, res, 200, path ? await fetchListing(host, path) : await fetchRoots(host));
    } catch (err) {
      const message = err instanceof Error ? err.message : 'scan failed';
      sendJson(req, res, 502, { error: message });
    }
    return true;
  }

  // Bytes rather than JSON: the body is piped straight through so a download
  // never lands in this process's memory.
  const stream = url.pathname.match(/^\/api\/nodes\/([^/]+)\/(download|thumb)$/);
  if (stream) {
    const [, rawId, kind] = stream;
    const host = await addressFor(decodeURIComponent(rawId));
    const path = url.searchParams.get('path');
    if (!host || !path) {
      sendJson(req, res, 404, { error: 'unknown node, or no path given' });
      return true;
    }
    const upstream = await openStream(host, kind as 'download' | 'thumb', path);
    if (!upstream.ok || !upstream.body) {
      sendJson(req, res, upstream.status, { error: upstream.statusText });
      return true;
    }
    const name = path.split('/').pop() ?? 'file';
    res.writeHead(200, {
      'Content-Type': upstream.headers.get('content-type') ?? 'application/octet-stream',
      ...(upstream.headers.get('content-length')
        ? { 'Content-Length': upstream.headers.get('content-length')! }
        : {}),
      // A thumbnail is keyed on the file's mtime upstream, so it is safe to
      // keep. A download is not cached: the file may have changed.
      'Cache-Control': kind === 'thumb' ? 'private, max-age=86400' : 'no-store',
      ...(kind === 'download'
        ? { 'Content-Disposition': `attachment; filename="${name.replace(/"/g, '')}"` }
        : {}),
    });
    await pipeline(upstream.body as unknown as NodeJS.ReadableStream, res).catch(() => {});
    return true;
  }

  const write = url.pathname.match(/^\/api\/nodes\/([^/]+)\/(write|upload)$/);
  if (write && req.method === 'POST') {
    const [, rawId, kind] = write;
    const host = await addressFor(decodeURIComponent(rawId));
    if (!host) {
      sendJson(req, res, 404, { error: 'unknown node' });
      return true;
    }
    // The agent decides. Its refusal, and its wording, are what the person
    // gets back — the dashboard re-stating the rules would only let the two
    // disagree.
    const upstream =
      kind === 'upload'
        ? await postUpload(
            host,
            url.searchParams.get('path') ?? '',
            url.searchParams.get('name') ?? '',
            req,
            req.headers['content-length'] ?? '0',
          )
        : await postWrite(host, JSON.parse(await readBody(req)));
    const text = await upstream.text();
    if (!upstream.ok) {
      sendJson(req, res, upstream.status, { error: upstream.statusText || text });
      return true;
    }
    sendJson(req, res, 200, JSON.parse(text || '{}'));
    return true;
  }

  const fan = url.pathname.match(/^\/api\/nodes\/([^/]+)\/fan$/);
  if (fan && req.method === 'POST') {
    const host = await addressFor(decodeURIComponent(fan[1]));
    if (!host) {
      sendJson(req, res, 404, { error: 'unknown node' });
      return true;
    }
    const upstream = await postFan(host, JSON.parse(await readBody(req)));
    const text = await upstream.text();
    if (!upstream.ok) {
      sendJson(req, res, upstream.status, { error: upstream.statusText || text });
      return true;
    }
    sendJson(req, res, 200, JSON.parse(text || '{}'));
    return true;
  }

  const cache = url.pathname.match(/^\/api\/nodes\/([^/]+)\/cache$/);
  if (cache) {
    const host = await addressFor(decodeURIComponent(cache[1]));
    if (!host) {
      sendJson(req, res, 404, { error: 'unknown node' });
      return true;
    }
    try {
      sendJson(req, res, 200, await fetchCache(host));
    } catch (err) {
      sendJson(req, res, 502, { error: err instanceof Error ? err.message : 'unreachable' });
    }
    return true;
  }

  const match = url.pathname.match(/^\/api\/nodes\/([^/]+)\/(processes|containers)$/);
  if (match) {
    const [, rawId, kind] = match;
    const host = await addressFor(decodeURIComponent(rawId));
    if (!host) {
      sendJson(req, res, 404, { error: 'unknown node, or it has no IPv4 address' });
      return true;
    }
    if (kind === 'processes') {
      const limit = Number(url.searchParams.get('limit') ?? 30);
      sendJson(req, res, 200, await fetchProcesses(host, Number.isFinite(limit) ? limit : 30));
    } else {
      sendJson(req, res, 200, await fetchContainers(host));
    }
    return true;
  }

  return false;
};

const statOrNull = async (file: string) => {
  try {
    return await stat(file);
  } catch {
    return null;
  }
};

/**
 * Vite writes a content hash into every filename under assets/, so those can be
 * held forever: changing one produces a different name. Nothing else in the
 * bundle is hashed. The icons and tile artwork are copied verbatim out of
 * public/ and keep their names across builds, so serving them immutable for a
 * year meant revised artwork could never reach a browser that had already
 * loaded the old file — which is exactly what happened when the Uptime and
 * Vault tiles were redrawn.
 */
const isHashed = (relative: string) => relative.startsWith('/assets/');

const cacheControl = (file: string): string => {
  const relative = file.slice(STATIC_DIR.length);
  if (relative.endsWith('index.html')) return 'no-store';
  return isHashed(relative) ? 'public, max-age=31536000, immutable' : 'public, max-age=3600';
};

const serveStatic = async (req: IncomingMessage, pathname: string, res: ServerResponse) => {
  // normalize() collapses any ../ before it can escape the static directory.
  const rel = normalize(pathname).replace(/^(\.\.[/\\])+/, '');
  let file = join(STATIC_DIR, rel === '/' ? 'index.html' : rel);

  let info = await statOrNull(file);
  if (info?.isDirectory()) {
    file = join(file, 'index.html');
    info = await statOrNull(file);
  }
  if (!info) {
    // Single-page app: unknown paths fall back to the shell.
    file = join(STATIC_DIR, 'index.html');
    info = await statOrNull(file);
  }

  if (!file.startsWith(STATIC_DIR)) {
    res.writeHead(403).end('forbidden');
    return;
  }

  if (!info) {
    res.writeHead(404).end('not found');
    return;
  }

  const type = MIME[extname(file)] ?? 'application/octet-stream';
  const head: Record<string, string> = {
    'Content-Type': type,
    'Cache-Control': cacheControl(file),
  };

  const { size } = info;
  const gzip = COMPRESSIBLE.test(type) && size >= GZIP_MIN && acceptsGzip(req);
  if (gzip) {
    head['Content-Encoding'] = 'gzip';
    head.Vary = 'Accept-Encoding';
  } else {
    head['Content-Length'] = String(size);
  }
  res.writeHead(200, head);

  const source = createReadStream(file);
  // A client that leaves mid-transfer aborts the pipeline; that is not an error.
  await pipeline(gzip ? [source, createGzip(), res] : [source, res]).catch(() => {});
};

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);

  // Kubernetes' probes have no password to give.
  if (url.pathname === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok');
    return;
  }

  try {
    // Everything else needs a session: Face ID / Touch ID or the admin
    // password, see lib/login.ts. Nothing is served without one, so a missing
    // password and no passkeys leaves the console shut, not open.
    if (await handleLogin(req, url, res)) return;
    if (!(await signedIn(req))) {
      if (url.pathname.startsWith('/api/')) sendJson(req, res, 401, { error: 'signed out' });
      else res.writeHead(302, { Location: '/login', 'Cache-Control': 'no-store' }).end();
      return;
    }

    if (url.pathname.startsWith('/api/')) {
      // Any web page can make a browser send a plain POST here; none can add a
      // custom header without a CORS preflight, which this server never
      // answers. So a change that arrives without it came from somewhere else.
      if (req.method !== 'GET' && req.headers['x-pi-console'] !== '1') {
        sendJson(req, res, 403, { error: 'changes are only accepted from the console itself' });
        return;
      }
      if (!(await handleApi(req, url, res))) sendJson(req, res, 404, { error: 'no such endpoint' });
      return;
    }
    await serveStatic(req, url.pathname, res);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'internal error';
    if (url.pathname.startsWith('/api/')) sendJson(req, res, 502, { error: message });
    else res.writeHead(500).end(message);
  }
});

server.listen(PORT, () => {
  console.log(`pi-console listening on :${PORT}`);
  if (!process.env.TAILSCALE_API_KEY && !process.env.TAILSCALE_OAUTH_CLIENT_ID) {
    console.warn('no Tailscale OAuth client or TAILSCALE_API_KEY — /api/nodes will return 502');
  }
});
