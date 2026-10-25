/**
 * Service launcher entries, plus a reachability probe.
 *
 * Config lives in apps.json next to this file so tiles can be added without a
 * rebuild. Absent or malformed, the launcher simply shows nothing.
 */

import { readFile } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import type { LookupFunction } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AppTile } from '../shared/fleet';
import { tailnetIpFor, tailnetName, warmTailnetIps } from './lib/tailnet';

const CONFIG =
  process.env.APPS_CONFIG ?? join(dirname(fileURLToPath(import.meta.url)), 'apps.json');
const PROBE_TIMEOUT_MS = 2000;

interface AppConfig {
  name: string;
  url: string;
  nodeId?: string;
  /** A path to artwork under client/public, or a single character to letter the tile. */
  icon?: string;
  /** Skip the probe for services that are not HTTP, e.g. Samba on 445. */
  check?: boolean;
  /** Show a power switch on the tile. Only the download stack sets this. */
  switchable?: boolean;
}

/**
 * One request, optionally to a fixed address.
 *
 * node:http rather than fetch, because fetch gives no way to choose which
 * address a name resolves to. That matters for tailnet names: the certificate
 * is issued to `board.tailnet.ts.net`, so rewriting the URL to an IP would
 * fail validation even though the route is right. Overriding the lookup keeps
 * the name for SNI and for the Host header, and changes only where the socket
 * goes.
 */
const probeRequest = (target: URL, ip: string | null): Promise<boolean> =>
  new Promise((resolve) => {
    const send = target.protocol === 'https:' ? httpsRequest : httpRequest;
    // node:net calls lookup with `all` set and wants an array back in that
    // case; answering with a bare string there fails as "Invalid IP address".
    const lookup: LookupFunction | undefined = ip
      ? (_hostname, options, callback) =>
          options.all ? callback(null, [{ address: ip, family: 4 }]) : callback(null, ip, 4)
      : undefined;

    // agent: false gives this request its own connection rather than one from
    // the keep-alive pool. Two reasons. A pooled socket was opened by an
    // earlier lookup, so reusing it would silently ignore the address chosen
    // here. And a health check that answers from a socket it opened minutes
    // ago is reporting history, not health.
    const options = { method: 'GET', timeout: PROBE_TIMEOUT_MS, agent: false as const, lookup };

    const req = send(target, options, (res) => {
      // Any HTTP response means something is listening — a 401 or 404 still
      // proves the service is up, so status is deliberately not checked.
      res.resume(); // drained, or the socket is held open until it times out
      resolve(true);
    });
    // destroy() does not reliably raise 'error', so the timeout answers for
    // itself rather than leaving the promise pending.
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
    req.end();
  });

const probe = async (url: string): Promise<boolean> => {
  let target: URL;
  try {
    target = new URL(url);
  } catch {
    return false;
  }
  if (target.protocol !== 'http:' && target.protocol !== 'https:') return false;

  // A MagicDNS name does not resolve inside a pod. Node discovery already
  // knows every board's address, so use it rather than asking DNS.
  return probeRequest(target, tailnetIpFor(target.hostname));
};

export const fetchApps = async (): Promise<AppTile[]> => {
  let config: AppConfig[];
  try {
    config = JSON.parse(await readFile(CONFIG, 'utf8')) as AppConfig[];
  } catch {
    return [];
  }
  if (!Array.isArray(config)) return [];

  // The probes below resolve tailnet names from the discovery map. On a cold
  // pod that map is empty until the first fleet poll lands, and the two
  // requests start together — so without this the whole shelf could come back
  // unreachable for the first fifteen seconds after every restart.
  await warmTailnetIps();

  const tn = tailnetName();
  const resolve = (url: string) => (tn ? url.replace(/<tailnet>/g, tn) : url);

  return Promise.all(
    config.map(async (app) => ({
      name: app.name,
      url: resolve(app.url),
      nodeId: app.nodeId ?? null,
      icon: app.icon ?? null,
      // A url beginning with # names a view inside the console rather than an
      // address to leave for. There is nothing to probe: if the tile is on
      // screen, the thing it opens is already running.
      healthy: app.url.startsWith('#') ? true : app.check === false ? null : await probe(resolve(app.url)),
      switchable: app.switchable ?? false,
    })),
  );
};
