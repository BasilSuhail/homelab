/**
 * Where to actually connect for a node's agents.
 *
 * A board cannot always reach its own tailnet address. The dashboard runs on
 * one of the boards it monitors, and after a power cycle pi2 could reach every
 * other node over the tailnet while a connection to its own 100.x address timed
 * out — the card read "no agent responded" about agents that were answering
 * everyone else:
 *
 *     pi2 $ curl http://<pi2-tailscale-ip>:61208/api/4/cpu   ->  000
 *     pi2 $ curl http://127.0.0.1:61208/api/4/cpu      ->  200
 *
 * Routing a machine's traffic to itself out through the tailnet and back is
 * asking for a favour it does not need: the agents are on this host, and
 * loopback always works. So an address belonging to this machine is dialled as
 * loopback, and every other address is left alone.
 *
 * The set is read once. An address can be added or removed while this runs —
 * that is what happens when tailscaled restarts — so a miss costs a request
 * that fails and is retried on the next poll, which is what would have happened
 * anyway.
 */

import { networkInterfaces } from 'node:os';

const mine = new Set<string>(
  Object.values(networkInterfaces())
    .flatMap((addresses) => addresses ?? [])
    .filter((a) => a.family === 'IPv4')
    .map((a) => a.address),
);

export const dialHost = (ip: string): string => (mine.has(ip) ? '127.0.0.1' : ip);
