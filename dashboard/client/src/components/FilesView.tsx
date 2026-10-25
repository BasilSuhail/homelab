/**
 * The disks, as columns: board, then disk, then folder, then file.
 *
 * Miller columns sorted biggest first — the OmniDiskSweeper layout, because
 * the question asked of a homelab disk is almost always "what is eating it"
 * rather than "where is that one file". The board is the first column rather
 * than a control above them, so moving between machines is the same gesture
 * as opening a folder.
 *
 * A board holds nothing itself. Everything is on one of its drives, so the
 * second column is drives and only drives — being "on pi" is not a place a
 * file could be saved. The archive is a folder inside the drive that holds it,
 * named to sort first there; it is not a sibling of the drives and it is not a
 * pin. Partitions are not drives either: the boot partition belongs to the
 * disk it is on, not to a row of its own.
 *
 * Every entry is shown, dotfiles included. On these boards the answer is
 * usually a dotfile — .cache, .ollama, a stray .venv — and hiding them would
 * also make each column stop adding up to its parent.
 */

import { useEffect, useRef, useState } from 'preact/hooks';
import type { DirEntry, DirListing, FleetNode } from '../../../shared/fleet';
import { getListing, getRoots, thumbUrl, upload, write } from '../lib/api';
import { bytes } from '../lib/format';
import { Alert, Chevron, Disk, DocBig, FolderBig, Grid, List, Search, Tag } from './icons';

/** A board is column zero; below it, paths are real. `@node:<id>` marks one. */
const NODE_PREFIX = '@node:';
const isNodeCol = (key: string) => key.startsWith(NODE_PREFIX);
const nodeOf = (key: string) => key.slice(NODE_PREFIX.length);

/** Column zero itself. Not a path — the fleet. */
const FLEET = '@fleet';

interface Cell {
  listing: DirListing | null;
  error: string | null;
  loading: boolean;
}

interface Picked {
  entry: DirEntry;
  /** The column the entry lives in, so opening it truncates the right tail. */
  depth: number;
  /** Key of the column, which is what its children are fetched against. */
  parent: string;
  /** Board the entry is on. Null in column zero. */
  node: string | null;
  path: string;
}

/**
 * Size drives the colour so a column reads without comparing numbers. Coarse
 * on purpose — this is meant to be skimmed, not measured.
 */
const magnitude = (n: number): string =>
  n === 0 ? 'zero' : n >= 1e9 ? 'huge' : n >= 1e8 ? 'big' : n >= 1e6 ? 'mid' : 'small';

const IMAGE = /\.(jpe?g|png|gif|webp|bmp|tiff?)$/i;

/**
 * A disk's name: what it is, then how big it is — "SSD 1TB", "HDD 6TB".
 *
 * Whether it spins comes from the agent reading sysfs (see withRotation in the
 * server); size is rounded to the capacity the shelf sold it as, because
 * "SSD 1000GB" is noise and nobody has ever said it. An agent too old to
 * report spinning falls back to the device prefix, and an SD card says so,
 * which on these boards is the one case where the kind matters more than the
 * number.
 */
const diskKind = (device: string, rotational: boolean | null | undefined): string => {
  if (rotational === true) return 'HDD';
  if (rotational === false) return 'SSD';
  const dev = device.replace(/^\/dev\//, '');
  if (/^mmcblk/.test(dev)) return 'SD card';
  return 'disk';
};

/** Sold-as capacity: 0.98 TB reads "1TB", 5.95 TB reads "6TB", 512 GB reads "512GB". */
const diskCapacity = (bytes: number): string => {
  const tb = bytes / 1e12;
  if (tb >= 0.95) return `${Math.round(tb)}TB`;
  const gb = bytes / 1e9;
  const shelf = [120, 128, 250, 256, 500, 512, 750, 768];
  const sold = shelf.find((c) => Math.abs(gb - c) / c <= 0.08);
  return `${sold ?? Math.round(gb)}GB`;
};

/**
 * One name per mounted row, decided against the whole set: when a disk has
 * more than one mounted partition, the mount point is what tells them apart,
 * and only then. A board whose disks each mount once — both of them do today —
 * shows plain "SSD 1TB" and "HDD 6TB", which is the point.
 */
const diskNames = (disks: FleetNode['disks']): string[] => {
  const counts = new Map<string, number>();
  for (const d of disks) {
    const dev = d.device.replace(/^\/dev\//, '');
    counts.set(dev, (counts.get(dev) ?? 0) + 1);
  }
  return disks.map((d) => {
    const dev = d.device.replace(/^\/dev\//, '');
    const base = `${diskKind(d.device, d.rotational)} ${diskCapacity(d.totalBytes)}`;
    return (counts.get(dev) ?? 0) > 1 && d.mount !== '/' ? `${base} · ${d.mount}` : base;
  });
};

/**
 * Where a row leads. An entry carrying its own path is followed to it — that
 * covers boards, disks, and the archive, none of which sit where their name
 * would put them. Joining the name onto the parent is the fallback for
 * ordinary directories, not the rule.
 */
const childKey = (parent: string, entry: DirEntry): string =>
  entry.path ?? `${parent.replace(/\/$/, '')}/${entry.name}`;

const entryPath = (listing: DirListing, entry: DirEntry): string =>
  childKey(listing.path, entry);

/**
 * The seven Finder tag colours, in Finder's own order. The names are the wire
 * format — the agent stores "Red\n6" and reads the name back — so these
 * strings are not labels that can be reworded, they are the values.
 */
const TAGS: { name: string; hex: string }[] = [
  { name: 'Red', hex: '#ff5f57' },
  { name: 'Orange', hex: '#ff9f2e' },
  { name: 'Yellow', hex: '#ffcc31' },
  { name: 'Green', hex: '#54c04a' },
  { name: 'Blue', hex: '#4a9df0' },
  { name: 'Purple', hex: '#c063e8' },
  { name: 'Grey', hex: '#9aa2ac' },
];

const tagHex = (name: string) => TAGS.find((t) => t.name === name)?.hex ?? '#9aa2ac';

/** Whether a keystroke belongs to a text field rather than to the browser. */
const isTyping = (target: EventTarget | null): boolean => {
  const el = target as HTMLElement | null;
  if (!el?.tagName) return false;
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable;
};

export const FilesView = ({ nodes }: { nodes: FleetNode[] }) => {
  const reachable = nodes.filter((n) => n.online && !n.error);
  const [trail, setTrail] = useState<string[]>([FLEET]);
  const [cells, setCells] = useState<Record<string, Cell>>({});

  /**
   * A column is identified by its board as well as its path. Both boards have
   * a `/` and a `/srv/archive`, so keying on the path alone made them the same
   * cached column: whichever board was opened first answered for the other,
   * and the second one never refetched because the key was already present.
   */
  const cacheKey = (node: string | null, key: string) => `${node ?? '?'}\u0000${key}`;
  const [picked, setPicked] = useState<Record<number, string>>({});
  const [sel, setSel] = useState<Picked | null>(null);
  // Grid first. Browsing is the everyday job; the column view is the one you
  // reach for when the question is which folder is eating the disk.
  const [view, setView] = useState<'list' | 'grid'>('grid');
  /** Filters the folder being looked at. Not a search of the board. */
  const [query, setQuery] = useState('');
  /**
   * What Back has taken off, newest first, so Forward can put it back. Any
   * fresh navigation drops it — a browser does the same, and keeping it would
   * offer a Forward that leads somewhere you did not come from.
   */
  const [ahead, setAhead] = useState<string[]>([]);
  const [preview, setPreview] = useState<Picked | null>(null);
  const [clip, setClip] = useState<{ node: string; path: string; name: string; cut: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  /** Bumped when a column is dropped, so the fetch effect goes and gets it. */
  const [reload, setReload] = useState(0);
  const strip = useRef<HTMLDivElement>(null);

  /** Column zero is built here rather than fetched — the fleet is already known. */
  const fleetCell: Cell = {
    loading: false,
    error: reachable.length === 0 ? 'No board is answering. The disks are only readable through one.' : null,
    listing: {
      path: FLEET,
      parent: null,
      total: 0,
      count: reachable.length,
      truncated: 0,
      complete: true,
      // No size on a board. It holds several disks and adding them together
      // produces a number that describes none of them; the figures belong on
      // the disks themselves, one column in.
      entries: reachable.map((n) => ({
        name: n.name,
        dir: true,
        link: false,
        bytes: 0,
        mtime: 0,
        hidden: false,
        path: NODE_PREFIX + n.id,
      })),
    },
  };

  const cellFor = (key: string, node: string | null): Cell =>
    key === FLEET
      ? fleetCell
      : (cells[cacheKey(node, key)] ?? { listing: null, error: null, loading: true });

  /** The board a column belongs to, walking back up the trail. */
  const nodeAt = (depth: number): string | null => {
    for (let i = depth; i >= 0; i -= 1) {
      if (isNodeCol(trail[i])) return nodeOf(trail[i]);
    }
    return null;
  };

  // Fetch any open column that has no answer yet. A board's column asks for
  // its roots; everything deeper asks for one directory.
  useEffect(() => {
    trail.forEach((key, depth) => {
      if (key === FLEET) return;
      const node = nodeAt(depth);
      if (!node) return;
      const slot = cacheKey(node, key);
      if (cells[slot]) return;
      setCells((prev) => ({ ...prev, [slot]: { listing: null, error: null, loading: true } }));

      const done = (listing: DirListing) =>
        setCells((prev) => ({ ...prev, [slot]: { listing, error: null, loading: false } }));
      const failed = (err: Error) =>
        setCells((prev) => ({ ...prev, [slot]: { listing: null, error: err.message, loading: false } }));

      if (isNodeCol(key)) {
        const board = nodes.find((n) => n.id === node);
        // The roots call is kept as a reachability check — it is the cheapest
        // question the agent answers, and a board that cannot answer it should
        // show an error rather than an empty list of drives. Its answer is no
        // longer used to build this column: drives come from the fleet poll.
        getRoots(node)
          .then(() => {
            const boardDisks = board?.disks ?? [];
            const names = diskNames(boardDisks);

            // Drives, and only drives. A board has drives; the archive is a
            // folder inside the one that holds it, not a sibling of them. An
            // earlier pass listed named roots here too and put the archive in
            // the same column as the disks, which is the thing this column
            // exists to not do.
            const entries: DirEntry[] = boardDisks.map((d, i) => ({
              name: names[i],
              dir: true,
              link: false,
              bytes: d.usedBytes,
              mtime: 0,
              hidden: false,
              path: d.mount,
              capacity: d.totalBytes,
            }));
            done({
              path: key,
              parent: null,
              total: 0,
              count: entries.length,
              truncated: 0,
              complete: true,
              entries,
            });

          })
          .catch(failed);
      } else {
        getListing(node, key)
          .then(done)
          .catch(failed);
      }
    });
    // Deliberately keyed on the trail and the reload counter alone. `cells` is
    // read inside, but adding it would re-run the effect on the very state this
    // sets and loop.
  }, [trail, reload]);

  // A new column arrives off the right edge; follow it, the way Finder does.
  useEffect(() => {
    const el = strip.current;
    if (el) el.scrollLeft = el.scrollWidth;
  }, [trail.length]);

  /**
   * The filter applies to the column being looked at and nothing else. Columns
   * further back keep their full contents, so the trail still reads as the path
   * you took rather than a row of half-empty lists.
   */
  const sift = (cell: Cell): Cell => {
    const q = query.trim().toLowerCase();
    if (!q || !cell.listing) return cell;
    const entries = cell.listing.entries.filter((e) => e.name.toLowerCase().includes(q));
    return { ...cell, listing: { ...cell.listing, entries, count: entries.length } };
  };

  const here = trail[trail.length - 1];
  const hereListing = cellFor(here, nodeAt(trail.length - 1)).listing;

  /**
   * Forget a column so it is read again. The counter is the point: the fetch
   * effect watches the trail, and dropping a cell does not change the trail,
   * so without it the column sat on its loading placeholder forever and only
   * a page reload brought it back.
   */
  const invalidate = (node: string | null, ...keys: string[]) => {
    setCells((prev) => {
      const next = { ...prev };
      for (const key of keys) delete next[cacheKey(node, key)];
      return next;
    });
    setReload((n) => n + 1);
  };

  /**
   * Every change goes through here: run it, show whatever the board said if it
   * refused, then drop the columns it touched so they are read again rather
   * than patched locally into something that might not match the disk.
   */
  const act = async (fn: () => Promise<void>, on: string | null, ...touched: string[]) => {
    setBusy(true);
    setProblem(null);
    try {
      await fn();
      invalidate(on, ...touched.filter(Boolean));
      setSel(null);
    } catch (err) {
      setProblem(err instanceof Error ? err.message : 'that was refused');
    } finally {
      setBusy(false);
    }
  };

  const select = (entry: DirEntry, parent: string, depth: number) => {
    setSel({ entry, parent, depth, node: nodeAt(depth), path: childKey(parent, entry) });
    // Drop every selection to the right: those rows belonged to what was open
    // before, and leaving them lit makes a refreshed column look stale.
    setPicked((prev) => ({
      ...Object.fromEntries(Object.entries(prev).filter(([d]) => +d < depth)),
      [depth]: entry.name,
    }));
  };

  const open = (entry: DirEntry, parent: string, depth: number) => {
    const key = childKey(parent, entry);
    select(entry, parent, depth);
    // Clicking the open folder again folds it back up. Anything to its right
    // belonged to it and goes with it.
    const alreadyOpen = trail[depth + 1] === key;
    setAhead([]);
    setTrail(entry.dir && !alreadyOpen ? [...trail.slice(0, depth + 1), key] : trail.slice(0, depth + 1));
  };

  const goBack = () => {
    if (trail.length < 2) return;
    setAhead([trail[trail.length - 1], ...ahead]);
    setTrail(trail.slice(0, -1));
    setSel(null);
    setPicked((prev) => Object.fromEntries(Object.entries(prev).filter(([d]) => +d < trail.length - 1)));
  };

  const goForward = () => {
    if (!ahead.length) return;
    setTrail([...trail, ahead[0]]);
    setAhead(ahead.slice(1));
    setSel(null);
  };

  /** Clicking under the rows drops the row selection and targets the column. */
  const targetColumn = (depth: number) => {
    setSel(null);
    setPicked((prev) => Object.fromEntries(Object.entries(prev).filter(([d]) => +d < depth)));
    setTrail(trail.slice(0, depth + 1));
  };

  const download = () => {
    if (!sel || !sel.node || sel.entry.dir) return;
    // A plain navigation, so the browser's own download handling takes over
    // rather than this holding the bytes in memory.
    window.location.href = `/api/nodes/${encodeURIComponent(sel.node)}/download?path=${encodeURIComponent(sel.path)}`;
  };

  const siblings = (): DirEntry[] =>
    (cellFor(sel?.parent ?? here, sel?.node ?? nodeAt(trail.length - 1)).listing?.entries ?? []).filter(
      (e) => !e.dir && IMAGE.test(e.name),
    );

  const step = (dir: number) => {
    if (!preview) return;
    const list = siblings();
    const at = list.findIndex((e) => e.name === preview.entry.name);
    if (at < 0 || list.length === 0) return;
    const next = list[(at + dir + list.length) % list.length];
    setPreview({ ...preview, entry: next, path: childKey(preview.parent, next) });
  };

  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      // The listener is on the window, so it also hears the search field. A
      // space typed there was being swallowed and opening Quick Look instead
      // of reaching the input, which made the field impossible to type a
      // two-word filter into.
      if (isTyping(ev.target)) return;
      if (ev.key === 'Escape') {
        setPreview(null);
        return;
      }
      if (ev.key === ' ' && (sel || preview)) {
        ev.preventDefault();
        if (preview) setPreview(null);
        else if (sel && !sel.entry.dir && IMAGE.test(sel.entry.name)) setPreview(sel);
        return;
      }
      if (preview && (ev.key === 'ArrowRight' || ev.key === 'ArrowLeft')) {
        ev.preventDefault();
        step(ev.key === 'ArrowRight' ? 1 : -1);
      }
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  });

  const canPreview = !!sel && !sel.entry.dir && IMAGE.test(sel.entry.name);
  const node = nodeAt(trail.length - 1);
  /** Writes land in the column being looked at; its own flag decides. */
  const canWriteHere = !!hereListing?.writable && !!node;
  /** Renaming or deleting changes the folder the row sits in, not the row. */
  const canChangeSel = !!sel && !!cellFor(sel.parent, sel.node).listing?.writable && !!sel.node;

  const newFolder = () => {
    const name = prompt('Name for the new folder');
    if (!name || !node) return;
    void act(() => write(node, { op: 'mkdir', path: here, name }), node, here);
  };

  const rename = () => {
    if (!sel || !sel.node) return;
    const name = prompt('Rename to', sel.entry.name);
    if (!name || name === sel.entry.name) return;
    void act(() => write(sel.node!, { op: 'rename', path: sel.path, name }), sel.node, sel.parent);
  };

  const remove = () => {
    if (!sel || !sel.node) return;
    const what = sel.entry.dir ? `${sel.entry.name} and everything in it` : sel.entry.name;
    if (!confirm(`Delete ${what}?\n\nThis cannot be undone.`)) return;
    void act(() => write(sel.node!, { op: 'delete', path: sel.path }), sel.node, sel.parent, sel.path);
  };

  const paste = () => {
    if (!clip || !node) return;
    void act(
      () => write(node, { op: clip.cut ? 'move' : 'copy', path: clip.path, to: here }),
      node,
      here,
      clip.path.replace(/\/[^/]+$/, ''),
    );
    if (clip.cut) setClip(null);
  };

  const duplicate = () => {
    if (!sel || !sel.node) return;
    void act(() => write(sel.node!, { op: 'copy', path: sel.path, to: sel.parent }), sel.node, sel.parent);
  };

  /**
   * Tags are metadata, so the folder they sit in is what gets dropped and read
   * again — the same treatment as a rename. Passing an empty list clears them.
   */
  const setTags = (names: string[]) => {
    if (!sel || !sel.node) return;
    void act(() => write(sel.node!, { op: 'tags', path: sel.path, tags: names }), sel.node, sel.parent);
  };

  /** A move by drag, and a drop of files from outside. Same destination. */
  const dropInto = (destination: string, ev: DragEvent) => {
    ev.preventDefault();
    if (!node) return;
    const files = [...(ev.dataTransfer?.files ?? [])];
    if (files.length) {
      void act(async () => {
        for (const file of files) await upload(node, destination, file);
      }, node, destination);
      return;
    }
    const moved = ev.dataTransfer?.getData('text/pi-path');
    if (!moved || moved === destination) return;
    void act(
      () => write(node, { op: 'move', path: moved, to: destination }),
      node,
      destination,
      moved.replace(/\/[^/]+$/, ''),
    );
  };

  return (
    <div class="page-stack">
      <div class="fx-bar">
        {/* Finder's order, and for Finder's reason: where you are and how you
            got here belong at the left edge, what you can do to it in the
            middle, and what you are looking for at the right. */}
        <div class="fx-nav">
          <button disabled={trail.length < 2} onClick={goBack} title="Back" aria-label="Back">
            <Chevron size={14} class="flip" />
          </button>
          <button disabled={!ahead.length} onClick={goForward} title="Forward" aria-label="Forward">
            <Chevron size={14} />
          </button>
        </div>

        <div class="fx-sel">
          <strong>{sel ? sel.entry.name : hereListing ? label(here, hereListing, nodes) : 'Storage'}</strong>
          <span class="fx-meta">
            <span>{bytes(sel ? sel.entry.bytes : (hereListing?.total ?? 0))}</span>
            <span class="fx-where">
              {sel ? readablePath(nodes, sel.path) : readablePath(nodes, hereListing?.path ?? '')}
            </span>
          </span>
        </div>

        <div class="fx-actions">
          <button class="fx-act" disabled={!canPreview} onClick={() => sel && setPreview(sel)}>
            Quick Look
          </button>
          <button class="fx-act" disabled={!sel || sel.entry.dir} onClick={download}>
            Download
          </button>
          <button
            class="fx-act"
            disabled={!sel}
            onClick={() => sel && navigator.clipboard?.writeText(sel.path).catch(() => {})}
          >
            Copy path
          </button>
          <button class="fx-act" disabled={!sel || busy} onClick={duplicate}>Duplicate</button>
          <button
            class="fx-act"
            disabled={!sel || busy}
            onClick={() => sel && setClip({ node: sel.node!, path: sel.path, name: sel.entry.name, cut: false })}
          >
            Copy
          </button>
          <button
            class="fx-act"
            disabled={!canChangeSel || busy}
            onClick={() => sel && setClip({ node: sel.node!, path: sel.path, name: sel.entry.name, cut: true })}
          >
            Cut
          </button>
          <button class="fx-act" disabled={!clip || !canWriteHere || busy} onClick={paste}>
            Paste
          </button>
          <button class="fx-act" disabled={!canWriteHere || busy} onClick={newFolder}>
            New folder
          </button>
          <button class="fx-act" disabled={!canChangeSel || busy} onClick={rename}>Rename</button>
          <button class="fx-act danger" disabled={!canChangeSel || busy} onClick={remove}>Delete</button>
        </div>

        <div class="fx-tools">
          {/* Narrow windows hide the row of actions and offer this instead. It
              opens the menu the right-click already uses, so the short bar and
              the long one cannot drift apart or disagree about what is
              allowed. Back, forward and the search field are never hidden:
              they are how you move and how you find, and a toolbar that hides
              those has stopped being a toolbar. */}
          <button
            class="fx-act fx-more"
            title="More actions"
            aria-label="More actions"
            onClick={(e) => {
              const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
              setMenu({ x: Math.max(8, r.right - 190), y: r.bottom + 6 });
            }}
          >
            »
          </button>
          {/* The tag button from Finder's toolbar. It opens the same colour row
              the right-click menu carries, so there is one list, not two. */}
          <button
            class="fx-act fx-tagbtn"
            disabled={!canChangeSel || busy}
            title="Tags"
            aria-label="Tags"
            onClick={(e) => {
              const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
              setMenu({ x: Math.max(8, r.right - 190), y: r.bottom + 6 });
            }}
          >
            <Tag size={13} />
          </button>

          {/* Open at all times, the way Finder's is once you widen the window.
              A field that has to be summoned is one you forget is there. */}
          <label class="fx-find">
            <Search size={13} />
            <input
              type="search"
              placeholder="Search"
              value={query}
              onInput={(e) => setQuery((e.currentTarget as HTMLInputElement).value)}
              aria-label="Filter this folder"
            />
            {query && (
              <button class="fx-find-x" onClick={() => setQuery('')} aria-label="Clear">×</button>
            )}
          </label>

          <div class="fx-view">
            <button class={view === 'grid' ? 'on' : ''} onClick={() => setView('grid')}>
              <Grid size={13} /> Grid
            </button>
            <button class={view === 'list' ? 'on' : ''} onClick={() => setView('list')}>
              <List size={13} /> List
            </button>
          </div>
        </div>
      </div>

      {problem && (
        <div class="warning-banner">
          <Alert size={18} />
          <div>
            <strong>That did not happen</strong>
            <span>{problem}</span>
          </div>
        </div>
      )}

      {view === 'list' ? (
        <div class="fx-strip" ref={strip}>
          {trail.map((key, depth) => (
            <Column
              key={key}
              cell={depth === trail.length - 1 ? sift(cellFor(key, nodeAt(depth))) : cellFor(key, nodeAt(depth))}
              selectedName={picked[depth] ?? null}
              node={nodeAt(depth)}
              onOpen={(entry) => open(entry, key, depth)}
              onTarget={() => targetColumn(depth)}
              onDrop={(destination, ev) => dropInto(destination, ev)}
              onMenu={(entry, ev) => {
                select(entry, key, depth);
                setMenu({ x: ev.clientX, y: ev.clientY });
              }}
            />
          ))}
        </div>
      ) : (
        <Grille
          cell={sift(cellFor(here, node))}
          node={nodeAt(trail.length - 1)}
          selectedName={sel?.entry.name ?? null}
          onSelect={(entry) => select(entry, here, trail.length - 1)}
          onOpen={(entry) => open(entry, here, trail.length - 1)}
          onPreview={(entry) => setPreview({ entry, parent: here, depth: trail.length - 1, node: nodeAt(trail.length - 1), path: childKey(here, entry) })}
        />
      )}

      {hereListing && (
        <div class="fx-status">
          <span class="fx-where">
            {hereListing.path === FLEET
              ? 'fleet'
              : isNodeCol(hereListing.path)
                ? nodeName(nodes, nodeOf(hereListing.path))
                : hereListing.path}
          </span>
          <span>
            {hereListing.count} {hereListing.count === 1 ? 'entry' : 'entries'}
            {hereListing.truncated > 0 && ` · ${hereListing.truncated} smaller not shown`}
            {!hereListing.complete && ' · sizing timed out, totals are floors'}
          </span>
        </div>
      )}

      {menu && (
        <>
          {/* One list, two ways in. The bar and the menu offer the same
              actions with the same guards, so they cannot disagree. */}
          <div class="fx-scrim" onClick={() => setMenu(null)} />
          <div class="fx-menu" style={{ left: menu.x, top: menu.y }}>
            <button disabled={!canPreview} onClick={() => { setMenu(null); sel && setPreview(sel); }}>
              Quick Look
            </button>
            {/* Finder puts the colours at the top of its menu, and they are the
                one action here that needs no confirmation and undoes itself. */}
            <div class="fx-tagrow">
              {TAGS.map((t) => (
                <button
                  key={t.name}
                  class={`fx-swatch ${sel?.entry.tags?.includes(t.name) ? 'on' : ''}`}
                  style={{ '--swatch': t.hex }}
                  title={t.name}
                  aria-label={t.name}
                  disabled={!canChangeSel || busy}
                  onClick={() => {
                    setMenu(null);
                    // Clicking the colour a file already has takes it off,
                    // which is what the same click does in Finder.
                    const has = sel?.entry.tags?.includes(t.name);
                    setTags(has ? (sel?.entry.tags ?? []).filter((n) => n !== t.name) : [t.name]);
                  }}
                />
              ))}
              <button
                class="fx-swatch none"
                title="No tag"
                aria-label="No tag"
                disabled={!canChangeSel || busy}
                onClick={() => { setMenu(null); setTags([]); }}
              />
            </div>
            <hr />
            <button disabled={!sel || sel.entry.dir} onClick={() => { setMenu(null); download(); }}>
              Download
            </button>
            <hr />
            <button disabled={!sel} onClick={() => { setMenu(null); sel && setClip({ node: sel.node!, path: sel.path, name: sel.entry.name, cut: false }); }}>
              Copy
            </button>
            <button disabled={!canChangeSel} onClick={() => { setMenu(null); sel && setClip({ node: sel.node!, path: sel.path, name: sel.entry.name, cut: true }); }}>
              Cut
            </button>
            <button disabled={!clip || !canWriteHere} onClick={() => { setMenu(null); paste(); }}>
              Paste
            </button>
            <button disabled={!sel} onClick={() => { setMenu(null); duplicate(); }}>Duplicate</button>
            <hr />
            <button disabled={!canChangeSel} onClick={() => { setMenu(null); rename(); }}>Rename</button>
            <button class="danger" disabled={!canChangeSel} onClick={() => { setMenu(null); remove(); }}>
              Delete
            </button>
          </div>
        </>
      )}

      {preview && preview.node && (
        <div class="fx-ql" onClick={() => setPreview(null)}>
          <figure onClick={(e) => e.stopPropagation()}>
            <img src={thumbUrl(preview.node, preview.path)} alt={preview.entry.name} />
            <figcaption>
              <span>{preview.entry.name}</span>
              <span>{bytes(preview.entry.bytes)} · ← → to step · Esc to close</span>
            </figcaption>
          </figure>
        </div>
      )}
    </div>
  );
};

/** A board's own key is a tailnet id, which is not a thing to show anyone. */
const nodeName = (nodes: FleetNode[], id: string): string =>
  nodes.find((n) => n.id === id)?.name ?? id;

const readablePath = (nodes: FleetNode[], key: string): string =>
  key === FLEET ? 'fleet' : isNodeCol(key) ? nodeName(nodes, nodeOf(key)) : key;

/** A board column and a roots column have no path worth printing. */
const label = (key: string, listing: DirListing, nodes: FleetNode[]): string =>
  key === FLEET
    ? 'Fleet'
    : isNodeCol(key)
      ? nodeName(nodes, nodeOf(key))
      : listing.path.split('/').pop() || listing.path;

const Column = ({
  cell,
  selectedName,
  node,
  onOpen,
  onTarget,
  onDrop,
  onMenu,
}: {
  cell: Cell;
  selectedName: string | null;
  node: string | null;
  onOpen: (entry: DirEntry) => void;
  onTarget: () => void;
  onDrop: (destination: string, ev: DragEvent) => void;
  onMenu: (entry: DirEntry, ev: MouseEvent) => void;
}) => {
  if (cell.loading && !cell.listing) {
    return (
      <div class="fx-col">
        <div class="fx-note">
          <span class="fx-spinner" /> Sizing the tree…
        </div>
      </div>
    );
  }
  if (cell.error) {
    return (
      <div class="fx-col">
        <div class="fx-note bad">
          <Alert size={14} /> {cell.error}
        </div>
      </div>
    );
  }
  const listing = cell.listing;
  if (!listing) return <div class="fx-col" />;

  return (
    <div class="fx-col">
      {listing.entries.map((entry) => (
        <button
          class={`fx-row ${entry.name === selectedName ? 'on' : ''} ${entry.hidden ? 'hidden' : ''}`}
          onClick={() => onOpen(entry)}
          onContextMenu={(ev) => { ev.preventDefault(); onMenu(entry, ev as unknown as MouseEvent); }}
          key={entry.name}
          draggable={!isNodeCol(listing.path)}
          onDragStart={(ev) =>
            ev.dataTransfer?.setData('text/pi-path', entryPath(listing, entry))
          }
          // Only a folder is a destination. Dropping on a file would have to
          // guess whether you meant beside it or into its parent.
          onDragOver={(ev) => entry.dir && ev.preventDefault()}
          onDrop={(ev) => entry.dir && onDrop(entryPath(listing, entry), ev as unknown as DragEvent)}
        >
          <span class={`fx-size ${magnitude(entry.bytes)}`}>
            {entry.bytes ? bytes(entry.bytes) : '—'}
            {entry.capacity ? <span class="fx-cap"> / {bytes(entry.capacity)}</span> : null}
          </span>
          {/* Italic for a symlink, the way a file manager sets one, so a link
              to something huge is not mistaken for the thing itself. */}
          <span class={`fx-name ${entry.link ? 'link' : ''}`}>
            {entry.tags?.length ? (
              <i class="fx-dot" style={{ background: tagHex(entry.tags[0]) }} title={entry.tags.join(', ')} />
            ) : null}
            {entry.name}
          </span>
          {/* A locked root is readable and copyable like anything else; what
              it refuses is being changed. Marked so that is visible before
              you try. */}
          {entry.locked && <span class="fx-lock" title="Read-only — copy from it, never change it">read-only</span>}
          {entry.dir && <Chevron size={13} class="fx-arrow" />}
        </button>
      ))}
      {listing.entries.length === 0 && (
        <div class="fx-note">
          {node ? 'Empty' : 'Nothing mounted. Run deploy/setup-browse.sh on this board.'}
        </div>
      )}
      {/* The dead zone: clicking below the rows targets this column's folder,
          so an action lands on what is being looked at. */}
      {/* The dead zone is also the drop target for "into the folder I am
          looking at", which is most drops. */}
      <div
        class="fx-pad"
        onClick={onTarget}
        onDragOver={(ev) => ev.preventDefault()}
        onDrop={(ev) => onDrop(listing.path, ev as unknown as DragEvent)}
      />
    </div>
  );
};

const Grille = ({
  cell,
  node,
  selectedName,
  onSelect,
  onOpen,
  onPreview,
}: {
  cell: Cell;
  node: string | null;
  selectedName: string | null;
  onSelect: (entry: DirEntry) => void;
  onOpen: (entry: DirEntry) => void;
  onPreview: (entry: DirEntry) => void;
}) => {
  // The same three states the column view renders. Grid is the default view,
  // so without these a board that refused a path or was still sizing one drew
  // an empty grid and said nothing at all about why.
  if (cell.loading && !cell.listing) {
    return (
      <div class="fx-grid empty">
        <div class="fx-note"><span class="fx-spinner" /> Sizing the tree…</div>
      </div>
    );
  }
  if (cell.error) {
    return (
      <div class="fx-grid empty">
        <div class="fx-note bad"><Alert size={14} /> {cell.error}</div>
      </div>
    );
  }
  const listing = cell.listing;
  if (!listing) return <div class="fx-grid" />;

  return (
    <div class="fx-grid">
      {listing.entries.map((entry) => (
        <button
          class={`fx-tile ${entry.name === selectedName ? 'on' : ''} ${entry.hidden ? 'hidden' : ''}`}
          key={entry.name}
          onClick={() => onSelect(entry)}
          onDblClick={() => (entry.dir ? onOpen(entry) : onPreview(entry))}
        >
          <span class="fx-shot">
            {node && !entry.dir && IMAGE.test(entry.name) ? (
              // Lazy on purpose: the board only makes a thumbnail for a tile
              // that is actually scrolled into view.
              <img
                // childKey, not a hand-rolled join: an entry carrying its own
                // path does not sit where its name would put it, and the Quick
                // Look this tile opens already resolves it that way. Two rules
                // for one path is how the thumbnail and the preview end up
                // showing different files.
                src={thumbUrl(node, childKey(listing.path, entry))}
                alt=""
                loading="lazy"
                onError={(e) => ((e.currentTarget as HTMLImageElement).style.display = 'none')}
              />
            ) : entry.dir ? (
              // A disk is still a disk; everything else that holds things is a
              // folder, and drawn as one, because that is what it looks like on
              // the other side of the same share.
              entry.capacity ? <Disk size={34} /> : <FolderBig size={54} />
            ) : (
              <DocBig size={46} />
            )}
          </span>
          <span class="fx-tname">
            {/* The dot sits in front of the name, as Finder draws it, so a
                tagged item is findable by colour without reading anything. */}
            {entry.tags?.length ? (
              <i class="fx-dot" style={{ background: tagHex(entry.tags[0]) }} title={entry.tags.join(', ')} />
            ) : null}
            {entry.name}
          </span>
          <span class="fx-tsize">{bytes(entry.bytes)}</span>
        </button>
      ))}
      {listing.entries.length === 0 && <div class="fx-note">Empty</div>}
    </div>
  );
};
