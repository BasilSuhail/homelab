/**
 * Credentials the dashboard holds and cannot renew for itself.
 *
 * There is one today. Under systemd the server asked the local tailscaled
 * socket which machines exist, and a socket does not expire. A pod has no
 * socket, so it carries a Tailscale API key instead, and Tailscale caps those
 * at ninety days.
 *
 * The failure is silent, which is the whole reason this file exists. On the
 * day the key lapses /api/nodes starts answering 502 and the fleet empties,
 * while both the readiness and liveness probes go on checking a static path
 * that keeps returning 200. Kubernetes calls the pod healthy throughout.
 *
 * The date cannot be discovered from the key: Tailscale will not tell a token
 * when it dies, and asking for the tailnet's key list needs a scope this one
 * deliberately does not have. So the installer records the date beside the key
 * in the same Secret, and this reads it back.
 */

import type { CredentialStatus } from '../../shared/fleet';

/** Below this the tile turns orange. Two weeks is enough notice to act. */
const WARN_DAYS = 14;

const DAY_MS = 86_400_000;

/**
 * Calendar days between today and that date, both in UTC.
 *
 * Today is floored to midnight before subtracting. Measuring from the current
 * instant instead would make a key that dies tonight report -1 and read as
 * already gone, and a ninety-day key report 89 on the day it was made.
 */
const daysUntil = (isoDate: string, now: number): number | null => {
  const at = Date.parse(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(at)) return null;
  const today = Math.floor(now / DAY_MS) * DAY_MS;
  return Math.round((at - today) / DAY_MS);
};

export const credentialStatus = (now = Date.now()): CredentialStatus[] => {
  // An OAuth client does not expire, so there is nothing to count down.
  if (process.env.TAILSCALE_OAUTH_CLIENT_ID && process.env.TAILSCALE_OAUTH_CLIENT_SECRET) return [];
  // No key means the local tailscaled socket is doing the work, and there is
  // nothing here to warn about. The tile disappears rather than reading zero.
  if (!process.env.TAILSCALE_API_KEY) return [];

  const recorded = process.env.TAILSCALE_KEY_EXPIRES?.trim();
  const daysLeft = recorded ? daysUntil(recorded, now) : null;

  return [
    {
      name: 'Tailscale key',
      // A date that will not parse is the same as no date, and saying so is
      // better than rendering "Invalid Date" in the tile.
      expiresAt: daysLeft === null ? null : (recorded ?? null),
      daysLeft,
      state:
        daysLeft === null ? 'unknown'
        : daysLeft < 0 ? 'expired'
        : daysLeft <= WARN_DAYS ? 'soon'
        : 'ok',
    },
  ];
};
