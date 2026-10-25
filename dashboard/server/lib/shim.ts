/** Client for the pi-metrics shim — power and throttle state. */

import type { HwStats, PowerStats, ThrottleState } from '../../shared/fleet';

export const SHIM_PORT = 9101;

/**
 * The shim refuses its file and fan routes without this. The value comes from
 * the pi-console-agent Secret; /metrics needs none, so a pod without it still
 * draws every card and only Files and the fan sliders are refused.
 */
export const withAgentToken = (headers: Record<string, string> = {}) => ({
  ...headers,
  'X-Agent-Token': process.env.AGENT_TOKEN ?? '',
});

/**
 * A fan's speed by hand, or `pct: null` for back to auto. Passed through: the
 * agent checks the header and the fan controller enforces the limits.
 */
export const postFan = (host: string, body: unknown) =>
  fetch(`http://${host}:${SHIM_PORT}/fan`, {
    method: 'POST',
    headers: withAgentToken({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body),
  });

const TIMEOUT_MS = 3000;

interface ShimResponse {
  ts: number;
  model: string | null;
  tempC: number | null;
  power: PowerStats | null;
  throttled: ThrottleState | null;
  capabilities: string[];
  /** Absent on an agent older than the disk-naming change. */
  disks?: Array<{ device: string; sizeBytes: number; rotational: boolean; model: string | null }> | null;
  /** Absent on an agent older than the desktop sensors. */
  hw?: HwStats | null;
}

/**
 * Returns null when the shim is absent. That is an ordinary outcome — a
 * non-Pi node has nothing to report here and simply renders fewer tiles.
 */
export const fetchShim = async (host: string): Promise<ShimResponse | null> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`http://${host}:${SHIM_PORT}/metrics`, {
      signal: controller.signal,
      cache: 'no-store',
    });
    return res.ok ? ((await res.json()) as ShimResponse) : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
};
