// ProgressBar — single-value percentage bar.
//
// Reference UIs (GitHub repo languages bar, Vercel deployment build
// step, Linear cycle progress, Stripe payout progress): a flat track
// with a tone-colored fill is the canonical \"how far along\" indicator.
// Distinct from DistributionBars (which stacks multiple labeled
// segments) — ProgressBar is the simple single-stat case. The dashboard
// had 10+ inline `<div style=\"width:X%\">` call sites with drift on
// height (h-1, h-1.5, h-2, h-full) and tone tokens (hex vs var(--X)).
//
// Pure helper exposed so callers in hot render paths (session trace
// rows, keeper detail segments) can compose the width string without
// mounting a component per row.

import { html } from 'htm/preact'

type ProgressBarSize = 'xs' | 'sm' | 'md'
type ProgressBarTone =
  | 'accent' | 'ok' | 'warn' | 'bad'
  | 'emerald' | 'amber' | 'rose' | 'sky'

/** Pure: clamp a percentage into [0, 100] and produce the inline width
    style string. Exposed so callers that need to render the bar inline
    (inside a flex row with other progress bars) can use the same
    semantics without mounting the component. */
export function progressBarWidthStyle(pct: number): string {
  const clamped = Math.max(0, Math.min(100, pct))
  return `width: ${clamped.toFixed(2)}%`
}

/** Pure: the height class for a given size token. Track + fill share
    the same height so the fill is always fully visible. */
export function progressBarHeightClass(size: ProgressBarSize = 'sm'): string {
  switch (size) {
    case 'xs': return 'h-1'     // 4px — inline with text lines
    case 'sm': return 'h-1.5'   // 6px — default row bar
    case 'md': return 'h-2'     // 8px — hero progress indicator
  }
}

/** Pure: Tailwind background class for a named tone. Callers with a
    bespoke brand color pass `class` instead. */
export function progressBarToneClass(tone: ProgressBarTone): string {
  switch (tone) {
    case 'accent': return 'bg-[var(--accent)]'
    case 'ok': return 'bg-[var(--ok)]'
    case 'warn': return 'bg-[var(--warn)]'
    case 'bad': return 'bg-[var(--bad)]'
    case 'emerald': return 'bg-[var(--ok-10)]'
    case 'amber': return 'bg-[var(--warn-10)]'
    case 'rose': return 'bg-[var(--bad-10)]'
    case 'sky': return 'bg-sky-500'
  }
}

type ProgressBarTrackTone = 'default' | 'dim' | 'muted'

/** Pure: track (muted background) bg class for a given track tone.
    Default = --white-5 (most rows); dim = --white-6 (keeper detail);
    muted = --white-8 (session trace compact overlay). Covers the three
    pre-change variants without adding arbitrary hex inputs. */
export function progressBarTrackToneClass(tone: ProgressBarTrackTone = 'default'): string {
  switch (tone) {
    case 'default': return 'bg-[var(--white-5)]'
    case 'dim': return 'bg-[var(--white-6)]'
    case 'muted': return 'bg-[var(--white-8)]'
  }
}

interface ProgressBarProps {
  /** Percentage 0–100; values outside are clamped (no throw). */
  pct: number
  size?: ProgressBarSize
  tone?: ProgressBarTone
  /** Additional classes on the fill element — use when a tone prop
      doesn't fit (e.g. threshold-varying color chosen by caller). */
  class?: string
  /** Track background tone. Default covers most rows; callers with a
      denser visual context (keeper detail / compact overlays) pick
      dim/muted. */
  trackTone?: ProgressBarTrackTone
  /** Additional classes on the track — layout overrides (flex-1) or
      atypical rounding. Appended after the base classes. */
  trackClass?: string
  /** Render a hover tooltip on the track so the numeric % is
      reachable without reading surrounding text. */
  title?: string
  /** Override the decorative default. When set, the bar exposes
      role="progressbar" + aria-valuenow so AT users hear progress. */
  ariaLabel?: string
  testId?: string
}

const TRACK_BASE = 'w-full overflow-hidden rounded-full'
const FILL_BASE = 'h-full rounded-full transition-[width] duration-300 ease-in-out'

export function ProgressBar({
  pct,
  size = 'sm',
  tone = 'accent',
  class: cx,
  trackTone = 'default',
  trackClass,
  title,
  ariaLabel,
  testId,
}: ProgressBarProps) {
  const height = progressBarHeightClass(size)
  const fillClass = cx ?? progressBarToneClass(tone)
  const trackBg = progressBarTrackToneClass(trackTone)
  const widthStyle = progressBarWidthStyle(pct)
  const clamped = Math.max(0, Math.min(100, pct))
  const semantic = ariaLabel !== undefined
  return html`<div
    class=${`${TRACK_BASE} ${height} ${trackBg} ${trackClass ?? ''}`}
    title=${title}
    role=${semantic ? 'progressbar' : undefined}
    aria-label=${ariaLabel}
    aria-valuenow=${semantic ? clamped.toFixed(0) : undefined}
    aria-valuemin=${semantic ? '0' : undefined}
    aria-valuemax=${semantic ? '100' : undefined}
    aria-hidden=${semantic ? undefined : 'true'}
    data-progress-bar
    data-progress-bar-size=${size}
    data-progress-bar-pct=${clamped.toFixed(0)}
    data-testid=${testId}
  >
    <div class=${`${FILL_BASE} ${fillClass}`} style=${widthStyle}></div>
  </div>`
}
