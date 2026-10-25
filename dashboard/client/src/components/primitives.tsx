import type { ComponentChildren } from 'preact';

export const StatusDot = ({ online, size = 'md' }: { online: boolean; size?: 'sm' | 'md' }) => (
  <span class={`sdot ${online ? '' : 'offline'} ${size}`} aria-label={online ? 'Online' : 'Offline'} />
);

export const Meter = ({ value, tone = '' }: { value: number; tone?: string }) => (
  <div class="meter">
    {/* Exact, no floor: 0% is an empty bar, so a bar never shows use that is not there. */}
    <span class={`mfill ${tone}`} style={{ width: `${Math.min(Math.max(value, 0), 100)}%` }} />
  </div>
);

export const PanelTitle = ({ icon, title, meta }: { icon: ComponentChildren; title: string; meta: string }) => (
  <div class="panel-title">
    <div><span class="panel-icon">{icon}</span><strong>{title}</strong></div>
    <span>{meta}</span>
  </div>
);

/**
 * Plots a real temperature series. A minimum span stops a steady reading
 * rendering as a full-height line.
 */
export const Sparkline = ({ series }: { series: number[] }) => {
  if (series.length < 2) {
    return (
      <svg class="sparkline" viewBox="0 0 280 56" preserveAspectRatio="none">
        <line x1="0" y1="28" x2="280" y2="28" stroke="currentColor" stroke-width="2" opacity=".25" />
      </svg>
    );
  }
  const min = Math.min(...series), max = Math.max(...series);
  const span = Math.max(max - min, 4);
  const lo = (min + max) / 2 - span / 2;
  const line = 'M' + series
    .map((v, i) => `${((i / (series.length - 1)) * 280).toFixed(1)} ${(52 - ((v - lo) / span) * 48).toFixed(1)}`)
    .join(' L');
  return (
    <svg class="sparkline" viewBox="0 0 280 56" preserveAspectRatio="none" aria-label="Temperature history">
      <path d={line} fill="none" stroke="currentColor" stroke-width="2.5" vector-effect="non-scaling-stroke" />
      <path d={`${line} L280 56 L0 56 Z`} fill="currentColor" opacity=".10" />
    </svg>
  );
};
