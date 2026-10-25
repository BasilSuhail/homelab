/**
 * The API returns raw numbers; the design shows human strings. All the
 * conversion lives here so the components stay about layout.
 */

/**
 * Decimal, because everything this console is measured against is decimal.
 * Finder calls the archive folder 40.85 GB, the drive is sold as 6 TB, and
 * the agent names it "HDD 6TB" off the same 1e9 division. Dividing by 1024
 * and writing "GB" made the console the only thing in the room reading 38 GB
 * for the same bytes and 5 TB for a 6 TB disk — the figure was right, the
 * label was a lie, and the two never lined up.
 *
 * Two decimals, always. This is watched to see something move, and a
 * download's first hour is invisible at whole-GB resolution. The old rule
 * dropped the decimals above 100, which is exactly where a filling disk
 * lives, so the number sat still for ten gigabytes at a time.
 */
export const bytes = (n: number | null | undefined, digits = 2): string => {
  if (n == null) return '—';
  if (n < 1000) return `${Math.round(n)} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = n / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value.toFixed(digits)} ${units[unit]}`;
};

/**
 * Swap on these boards is zram — compressed RAM, not disk — so a little of it
 * costs nothing. Sustained use is the earliest sign a board is short of
 * memory, well before anything gets killed.
 */
export const swapTone = (pct: number): string => (pct >= 50 ? 'red' : pct >= 20 ? 'orange' : '');

export const bytesPerSec = (n: number | null | undefined): string =>
  n == null ? '—' : `${bytes(n, 1)}/s`;

/**
 * Installed RAM, rounded up to the next even GiB: 7.9 GiB reads "8 GB", and
 * the PC's 4+8+4+8 sticks (23.4 GiB after the kernel's share) read "24 GB".
 * Not to a power of two: mixed sticks sum to sizes like 12 or 24, which that
 * rounded up to 16 and 32. Binary on purpose and the one thing here that is,
 * since sticks are sold in GiB; every measured figure beside it goes through
 * `bytes` and is decimal.
 */
export const capacity = (totalBytes: number | null | undefined): string => {
  if (!totalBytes) return '—';
  const gb = totalBytes / 1024 ** 3;
  return `${gb < 1.5 ? Math.ceil(gb) : Math.ceil(gb / 2) * 2} GB`;
};

export const uptime = (sec: number | null | undefined): string => {
  if (sec == null) return '—';
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d) return `${d}d ${String(h).padStart(2, '0')}h`;
  if (h) return `${h}h ${String(m).padStart(2, '0')}m`;
  return `${m}m`;
};

export const relative = (iso: string | null | undefined): string => {
  if (!iso) return 'unknown';
  const diff = Date.now() - new Date(iso).getTime();
  if (diff < 60_000) return 'just now';
  const mins = Math.floor(diff / 60_000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
};

export const pct = (n: number | null | undefined): string =>
  n == null ? '—' : `${Math.round(n)}%`;

export const watts = (n: number | null | undefined): string =>
  n == null ? '—' : `${n.toFixed(1)} W`;

export const celsius = (n: number | null | undefined): string =>
  n == null ? '—' : `${Math.round(n)}°C`;

/** Meter colour thresholds, shared by every bar so they stay consistent. */
export const cpuTone = (v: number) => (v > 85 ? 'red' : v > 60 ? 'orange' : 'aqua');
export const memTone = (v: number) => (v > 90 ? 'red' : v > 75 ? 'orange' : 'green');
export const diskTone = (v: number) => (v > 90 ? 'red' : v > 75 ? 'orange' : 'aqua');

/**
 * "1 Dec". No year: nothing shown this way is more than a few months out, and
 * the year is four characters of noise in a tile that has room for none.
 */
export const shortDate = (iso: string | null | undefined): string => {
  if (!iso) return '—';
  const at = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(at.getTime())) return '—';
  return at.toLocaleDateString(undefined, { day: 'numeric', month: 'short', timeZone: 'UTC' });
};
