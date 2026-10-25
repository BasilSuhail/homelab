/**
 * The Status tab's feed: who is using which app, and what Jellyfin and Kiwix
 * hold.
 *
 * Read from a file rather than worked out here. Who is using what comes from
 * the PC's journal and Jellyfin's sessions, which only root on the PC can
 * read; `pi-when content` does that every 30 seconds (pi-status.timer) and
 * the pod sees the directory read-only (k8s/dashboard.yaml). The Discord bot
 * asks the same code, so the two never disagree.
 */

import { readFile, writeFile } from 'node:fs/promises';
import type { ContentStatus } from '../../shared/fleet';

const FILE = process.env.STATUS_FILE ?? '/run/pi-status/status.json';

/** Null when the timer has not run yet, or this console is not on the PC. */
export const fetchContentStatus = async (): Promise<ContentStatus | null> => {
  try {
    return JSON.parse(await readFile(FILE, 'utf8')) as ContentStatus;
  } catch {
    return null;
  }
};

/**
 * Where the refresh button asks for a scan now. The pod cannot run one: the
 * scan reads the journal and Jellyfin as root on the PC. Writing this file is
 * all it can do, and pi-status-now.path on the PC answers it by running
 * pi-paths and then `pi-when content` (deploy/install-dashboard-k8s.sh).
 */
const TRIGGER = process.env.STATUS_TRIGGER ?? '/run/pi-console/refresh';
const WAIT_MS = 15_000;
/** A held-down button is one scan, not one per click. */
const MIN_GAP_MS = 5_000;
let last = 0;

/** Asks the PC for a scan and waits for the feed it writes. False if there is
 *  no PC to ask, or it did not answer in time. */
export const refreshStatus = async (): Promise<boolean> => {
  const asked = Date.now();
  if (asked - last >= MIN_GAP_MS) {
    try {
      await writeFile(TRIGGER, String(asked));
    } catch {
      return false;
    }
    last = asked;
  }
  // The feed's ts is whole seconds from when the scan began, after the ask.
  const since = Math.floor(last / 1000);
  while (Date.now() - asked < WAIT_MS) {
    const now = await fetchContentStatus();
    if (now && now.ts >= since) return true;
    await new Promise((r) => setTimeout(r, 400));
  }
  return false;
};
