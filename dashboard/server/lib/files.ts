/**
 * Client for the shim's directory scanner.
 *
 * The scan walks a whole subtree to size it, so the timeout here is far longer
 * than any other call in this server. The shim gives up on its own at 20s and
 * answers with what it has and `complete: false`, which is the case this has
 * to stay connected long enough to receive.
 */

import type { DirListing, DirRoots, ThumbCache } from '../../shared/fleet';
import { SHIM_PORT, withAgentToken } from './shim';

const TIMEOUT_MS = 25_000;

const get = async <T>(host: string, query: string): Promise<T> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`http://${host}:${SHIM_PORT}/files${query}`, {
      signal: controller.signal,
      cache: 'no-store',
      headers: withAgentToken(),
    });
    if (!res.ok) {
      // 403 and 404 are the shim refusing a path, and the reason it gives is
      // worth showing rather than flattening into "something went wrong".
      throw new Error(`${res.status} ${res.statusText}`);
    }
    return (await res.json()) as T;
  } finally {
    clearTimeout(timer);
  }
};

/** The tops of the browsable tree, when the client has no path yet. */
export const fetchRoots = (host: string) => get<DirRoots>(host, '');

export const fetchListing = (host: string, path: string) =>
  get<DirListing>(host, `?path=${encodeURIComponent(path)}`);

/**
 * Cheap enough for the fleet poll to ask on every pass, so it gets the short
 * timeout rather than the scanner's long one.
 *
 * It had no timeout at all, which mattered because fleet.ts calls it inside the
 * Promise.all that builds a card: a board that accepted the connection and then
 * stopped answering would hold that request open with no deadline, and
 * /api/nodes would never return for any board. Every other call in this server
 * had a deadline; this one was the hole.
 */
const CACHE_TIMEOUT_MS = 3000;

export const fetchCache = async (host: string): Promise<ThumbCache> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CACHE_TIMEOUT_MS);
  try {
    const res = await fetch(`http://${host}:${SHIM_PORT}/cache`, {
      signal: controller.signal,
      cache: 'no-store',
    });
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
    return (await res.json()) as ThumbCache;
  } finally {
    clearTimeout(timer);
  }
};

/**
 * File bytes and thumbnails are streamed rather than parsed, so these hand
 * back the response for the caller to pipe. A thumbnail is small; a download
 * can be gigabytes, and buffering one would take the board out.
 */
export const openStream = (host: string, kind: 'download' | 'thumb', path: string) =>
  fetch(`http://${host}:${SHIM_PORT}/${kind}?path=${encodeURIComponent(path)}`, {
    cache: 'no-store',
    headers: withAgentToken(),
  });

/**
 * Writes are passed through rather than interpreted. The agent owns the rules
 * — which roots are writable, what counts as a usable name, whether a
 * destination already exists — and duplicating any of that here is how the two
 * drift apart and one of them starts allowing what the other refuses.
 */
export const postWrite = (host: string, body: unknown) =>
  fetch(`http://${host}:${SHIM_PORT}/write`, {
    method: 'POST',
    headers: withAgentToken({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body),
  });

export const postUpload = (
  host: string,
  path: string,
  name: string,
  stream: NodeJS.ReadableStream,
  length: string,
) =>
  fetch(
    `http://${host}:${SHIM_PORT}/upload?path=${encodeURIComponent(path)}&name=${encodeURIComponent(name)}`,
    {
      method: 'POST',
      headers: withAgentToken({ 'Content-Length': length }),
      body: stream as unknown as BodyInit,
      // Node refuses to stream a request body without this.
      duplex: 'half',
    } as RequestInit,
  );
