/** Inline SVGs. Replaces lucide-react, which shipped ~25KB for 15 glyphs. */
type P = { size?: number; class?: string };
const S = (d: string, size = 15, cls = "") => (
  <svg class={cls} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
       stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
       dangerouslySetInnerHTML={{ __html: d }} />
);

/**
 * Filled rather than stroked. The Finder-style grid wants a solid blue folder,
 * not a line drawing, and the shading is what makes a folder read as a folder
 * at a glance in a page full of them.
 */
const F = (d: string, size = 15, cls = "") => (
  <svg class={cls} width={size} height={size} viewBox="0 0 24 24"
       dangerouslySetInnerHTML={{ __html: d }} />
);

export const FolderBig = ({ size, class: c }: P) =>
  F('<defs><linearGradient id="fg" x1="0" y1="0" x2="0" y2="1">' +
    '<stop offset="0" stop-color="#8fd0f5"/><stop offset="1" stop-color="#4aa3e0"/>' +
    '</linearGradient><linearGradient id="fb" x1="0" y1="0" x2="0" y2="1">' +
    '<stop offset="0" stop-color="#6fbdee"/><stop offset="1" stop-color="#3f93d2"/>' +
    '</linearGradient></defs>' +
    // Back flap first, so the front sits over it the way a real folder does.
    '<path fill="url(#fb)" d="M2 6.2A1.7 1.7 0 0 1 3.7 4.5h5.1l1.9 2h9.6A1.7 1.7 0 0 1 22 8.2V18a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18z"/>' +
    '<path fill="url(#fg)" d="M2 9.1h20V18a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18z"/>',
    size, c);

export const DocBig = ({ size, class: c }: P) =>
  F('<path fill="#e9edf2" stroke="#b9c2cc" stroke-width=".7" d="M5.5 2.6h8.2L19 7.9V21a.9.9 0 0 1-.9.9H5.5a.9.9 0 0 1-.9-.9V3.5a.9.9 0 0 1 .9-.9z"/>' +
    '<path fill="#cfd6de" d="M13.7 2.6 19 7.9h-4.4a.9.9 0 0 1-.9-.9z"/>', size, c);

export const Search  = ({ size, class: c }: P) => S('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.6-3.6"/>', size, c);
export const Tag     = ({ size, class: c }: P) => S('<path d="M3 3h7.6L21 13.4 13.4 21 3 10.6z"/><path d="M7.5 7.5h.01"/>', size, c);

export const Grid    = ({ size, class: c }: P) => S('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>', size, c);
export const Box     = ({ size, class: c }: P) => S('<path d="M21 8 12 3 3 8v8l9 5 9-5z"/><path d="m3 8 9 5 9-5"/><path d="M12 21V13"/>', size, c);
export const Moon    = ({ size, class: c }: P) => S('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>', size, c);
export const Sun     = ({ size, class: c }: P) => S('<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>', size, c);
export const Refresh = ({ size, class: c }: P) => S('<path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/>', size, c);
export const Thermo  = ({ size, class: c }: P) => S('<path d="M14 14.76V3.5a2.5 2.5 0 0 0-5 0v11.26a4 4 0 1 0 5 0z"/>', size, c);
export const Power   = ({ size, class: c }: P) => S('<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>', size, c);
export const Pulse   = ({ size, class: c }: P) => S('<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>', size, c);
export const Chevron = ({ size, class: c }: P) => S('<path d="m9 18 6-6-6-6"/>', size, c);
export const Back    = ({ size, class: c }: P) => S('<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>', size, c);
export const Nodes   = ({ size, class: c }: P) => S('<rect x="2" y="3" width="20" height="7" rx="2"/><rect x="2" y="14" width="20" height="7" rx="2"/><path d="M6 6.5h.01M6 17.5h.01"/>', size, c);
export const Shield  = ({ size, class: c }: P) => S('<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>', size, c);
export const Cpu     = ({ size, class: c }: P) => S('<rect x="7" y="7" width="10" height="10" rx="1"/><path d="M4 10h3M4 14h3M17 10h3M17 14h3M10 4v3M14 4v3M10 17v3M14 17v3"/>', size, c);
export const Mem     = ({ size, class: c }: P) => S('<rect x="3" y="7" width="18" height="10" rx="1"/><path d="M7 11v2M11 11v2M15 11v2M6 17v3M18 17v3"/>', size, c);
export const Disk    = ({ size, class: c }: P) => S('<rect x="2" y="14" width="20" height="6" rx="2"/><path d="m5 14 2.5-8h9L19 14"/><path d="M6 17h.01M10 17h.01"/>', size, c);
export const Net     = ({ size, class: c }: P) => S('<rect x="9" y="2" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="16" y="16" width="6" height="6" rx="1"/><path d="M12 8v4M5 16v-4h14v4"/>', size, c);
export const Alert   = ({ size, class: c }: P) => S('<path d="M12 3 2 20h20L12 3z"/><path d="M12 9v4M12 17h.01"/>', size, c);
export const Gauge   = ({ size, class: c }: P) => S('<path d="M12 14 15 9"/><path d="M20.6 18a9 9 0 1 0-17.2 0"/>', size, c);
export const List    = ({ size, class: c }: P) => S('<path d="M3 6h18M7 12h14M11 18h10"/>', size, c);
export const Files   = ({ size, class: c }: P) => S('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M7 20h10"/><path d="M9 16v4"/><path d="M15 16v4"/>', size, c);
export const Key     = ({ size, class: c }: P) => S('<circle cx="8" cy="12" r="4"/><path d="M12 12h9"/><path d="M17 12v4"/><path d="M20.5 12v3"/>', size, c);
export const Wifi    = ({ size, class: c }: P) => S('<path d="M5 12.5a10 10 0 0 1 14 0"/><path d="M8.5 16a5 5 0 0 1 7 0"/><path d="M12 20h.01"/>', size, c);
