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

export type ProgressBarSize = 'xs' | 'sm' | 'md'
export type ProgressBarTone =
  | 'accent' | 'ok' | 'warn' | 'bad'
  | 'emerald' | 'amber' | 'rose' | 'sky'
export type ProgressBarFillSource = 'tone' | 'custom-class'

export interface ProgressBarSummary {
  readonly inputPct: number
  readonly clampedPct: number
  readonly roundedPct: number
  readonly widthStyle: string
  readonly size: ProgressBarSize
  readonly tone: ProgressBarTone
  readonly trackTone: ProgressBarTrackTone
  readonly isSemantic: boolean
  readonly fillSource: ProgressBarFillSource
  readonly hasCustomFillClass: boolean
  readonly fillClassLength: number
  readonly hasTrackClass: boolean
  readonly trackClassLength: number
  readonly hasTitle: boolean
  readonly titleLength: number
  readonly hasTestId: boolean
  readonly testIdLength: number
}

function clampProgressPct(pct: number): number {
  return Math.max(0, Math.min(100, pct))
}

/** Pure: clamp a percentage into [0, 100] and produce the inline width
    style string. Exposed so callers that need to render the bar inline
    (inside a flex row with other progress bars) can use the same
    semantics without mounting the component. */
export function progressBarWidthStyle(pct: number): string {
  const clamped = clampProgressPct(pct)
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
    case 'accent': return 'bg-[var(--color-accent-fg)]'
    case 'ok': return 'bg-[var(--color-status-ok)]'
    case 'warn': return 'bg-[var(--color-status-warn)]'
    case 'bad': return 'bg-[var(--color-status-err)]'
    case 'emerald': return 'bg-[var(--ok-10)]'
    case 'amber': return 'bg-[var(--warn-10)]'
    case 'rose': return 'bg-[var(--bad-10)]'
    case 'sky': return 'bg-[var(--accent-10)]0'
  }
}

export type ProgressBarTrackTone = 'default' | 'dim' | 'muted'

/** Pure: track (muted background) bg class for a given track tone.
    Default = --white-5 (most rows); dim = --white-6 (keeper detail);
    muted = --white-8 (session trace compact overlay). Covers the three
    pre-change variants without adding arbitrary hex inputs. */
export function progressBarTrackToneClass(tone: ProgressBarTrackTone = 'default'): string {
  switch (tone) {
    case 'default': return 'bg-[var(--color-bg-elevated)]'
    case 'dim': return 'bg-[var(--color-bg-hover)]'
    case 'muted': return 'bg-[var(--color-bg-hover)]'
  }
}

export interface ProgressBarProps {
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

const TRACK_BASE = 'w-full overflow-hidden rounded-[var(--r-0)]'
const FILL_BASE = 'h-full rounded-[var(--r-0)] transition-[width] duration-[var(--t-slow)] ease-[var(--ease-inout)]'

export function summarizeProgressBar({
  pct,
  size = 'sm',
  tone = 'accent',
  class: cx,
  trackTone = 'default',
  trackClass,
  title,
  ariaLabel,
  testId,
}: ProgressBarProps): ProgressBarSummary {
  const clampedPct = clampProgressPct(pct)
  const fillSource = cx !== undefined && cx !== '' ? 'custom-class' : 'tone'

  return {
    inputPct: pct,
    clampedPct,
    roundedPct: Number(clampedPct.toFixed(0)),
    widthStyle: progressBarWidthStyle(pct),
    size,
    tone,
    trackTone,
    isSemantic: ariaLabel !== undefined,
    fillSource,
    hasCustomFillClass: fillSource === 'custom-class',
    fillClassLength: cx?.length ?? 0,
    hasTrackClass: trackClass !== undefined && trackClass !== '',
    trackClassLength: trackClass?.length ?? 0,
    hasTitle: title !== undefined && title !== '',
    titleLength: title?.length ?? 0,
    hasTestId: testId !== undefined && testId !== '',
    testIdLength: testId?.length ?? 0,
  }
}

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
  const summary = summarizeProgressBar({
    pct,
    size,
    tone,
    class: cx,
    trackTone,
    trackClass,
    title,
    ariaLabel,
    testId,
  })
  const height = progressBarHeightClass(size)
  const fillClass = cx ?? progressBarToneClass(tone)
  const trackBg = progressBarTrackToneClass(trackTone)
  return html`<div
    class=${`${TRACK_BASE} ${height} ${trackBg} ${trackClass ?? ''}`}
    title=${title}
    role=${summary.isSemantic ? 'progressbar' : undefined}
    aria-label=${ariaLabel}
    aria-valuenow=${summary.isSemantic ? summary.roundedPct.toFixed(0) : undefined}
    aria-valuemin=${summary.isSemantic ? '0' : undefined}
    aria-valuemax=${summary.isSemantic ? '100' : undefined}
    aria-hidden=${summary.isSemantic ? undefined : 'true'}
    data-progress-bar
    data-progress-bar-size=${summary.size}
    data-progress-bar-tone=${summary.tone}
    data-progress-bar-track-tone=${summary.trackTone}
    data-progress-bar-pct=${summary.roundedPct.toFixed(0)}
    data-progress-bar-input-pct=${summary.inputPct}
    data-progress-bar-clamped-pct=${summary.clampedPct.toFixed(2)}
    data-progress-bar-is-semantic=${summary.isSemantic}
    data-progress-bar-fill-source=${summary.fillSource}
    data-progress-bar-has-custom-fill-class=${summary.hasCustomFillClass}
    data-progress-bar-fill-class-length=${summary.fillClassLength}
    data-progress-bar-has-track-class=${summary.hasTrackClass}
    data-progress-bar-track-class-length=${summary.trackClassLength}
    data-progress-bar-has-title=${summary.hasTitle}
    data-progress-bar-title-length=${summary.titleLength}
    data-progress-bar-has-test-id=${summary.hasTestId}
    data-progress-bar-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  >
    <div class=${`${FILL_BASE} ${fillClass}`} style=${summary.widthStyle}></div>
  </div>`
}
