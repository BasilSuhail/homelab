/** How the console opens an app: its own window, or a plain browser tab. */

/**
 * Open a service the way you would open an application: its own window, with
 * no tab strip, no address bar and no bookmarks.
 *
 * This is as close as a web page can get. A page cannot hand a link to an
 * installed PWA — there is no API for it, and whether one exists is a property
 * of the machine you happen to be holding, not of this console. What it can do
 * is ask for a window with no browser furniture, which on every platform that
 * matters here looks and behaves like the app.
 *
 * The window is named after the app, so opening the same tile twice raises the
 * window that is already there instead of stacking a second one on top of it.
 */
export const openAsApp = (name: string, url: string): boolean => {
  const w = Math.min(1440, Math.round(screen.availWidth * 0.92));
  const h = Math.min(940, Math.round(screen.availHeight * 0.92));
  const left = Math.round((screen.availWidth - w) / 2);
  const top = Math.round((screen.availHeight - h) / 2);
  const handle = window.open(
    url,
    `pi-${name.replace(/[^a-z0-9]+/gi, '-')}`,
    `popup=yes,width=${w},height=${h},left=${left},top=${top}`,
  );
  // Blocked by a pop-up setting, and the click would otherwise do nothing at
  // all. Say so by returning false; the caller falls back to a plain tab,
  // which is worse than what was asked for and much better than silence.
  if (!handle) return false;
  handle.focus();
  return true;
};

/**
 * A click on an app. Plain click: the app's own window. Cmd, Ctrl or Shift
 * held, or the middle button: an ordinary browser tab, the way those keys
 * behave on any link. A blocked pop-up falls back to a tab rather than doing
 * nothing.
 */
export const openApp = (
  e: { metaKey?: boolean; ctrlKey?: boolean; shiftKey?: boolean; button?: number } | null,
  name: string,
  url: string,
) => {
  const tab = !!e && (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1);
  if (tab || !openAsApp(name, url)) window.open(url, '_blank', 'noreferrer');
};
