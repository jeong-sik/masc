// StatusDot — small colored circle indicator.
//
// Reference UIs (GitHub PR status dots, Vercel deployment row, Linear
// issue state circle, Stripe subscription health): the 6-10px colored
// dot is the single most scanned visual in an operational list. Rows
// of dots let the eye catch "one of these is not like the others"
// before it parses any text. A consistent primitive matters because
// dots drift easily — different rows end up at w-1.5 / w-2 / w-2.5
// and the eye loses the grid.
//
// Deliberately NOT prescriptive about tone: callers have their own
// semantic tone helpers (statusDot / verdictTone / railPillTone) that
// return Tailwind background classes. This primitive takes the tone
// via `class` so it composes with existing helpers instead of
// duplicating them — the shared invariants are size + shape + shrink.
//
// Distinct from LivePulseDot (animate-pulse "is polling live?"
// indicator): StatusDot is the static per-row state marker. Pairing
// them is expected (LivePulseDot for the top of a list, StatusDot
// per row).

import { html } from 'htm/preact'

export type StatusDotSize = 'xs' | 'sm' | 'md' | 'lg'
export type StatusDotMode = 'decorative' | 'semantic'

export interface StatusDotSummary {
  readonly size: StatusDotSize
  readonly mode: StatusDotMode
  readonly hasCustomClass: boolean
  readonly hasAriaLabel: boolean
  readonly classNameLength: number
}

/** Pure: Tailwind size tokens for each named variant. Exposed so
    a caller that wraps its own <span> (legacy code in a hot render
    path avoiding an extra component) stays pixel-identical. */
export function statusDotSizeClass(size: StatusDotSize = 'sm'): string {
  switch (size) {
    case 'xs': return 'w-1.5 h-1.5'  // 6px — inline legend dots
    case 'sm': return 'w-2 h-2'      // 8px — default row marker
    case 'md': return 'w-2.5 h-2.5'  // 10px — prominent card marker
    case 'lg': return 'w-3 h-3'      // 12px — hero status pill
  }
}

const BASE = 'inline-block rounded-full shrink-0'

/** Pure: full class string for a dot. Exposed so callers can pre-build
    the string in a loop without mounting N components. */
export function statusDotClasses(
  size: StatusDotSize = 'sm',
  toneClass?: string,
  extra?: string,
): string {
  const parts = [BASE, statusDotSizeClass(size)]
  if (toneClass !== undefined && toneClass !== '') parts.push(toneClass)
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

export function summarizeStatusDot({
  size = 'sm',
  className,
  ariaLabel,
}: {
  size?: StatusDotSize
  className?: string
  ariaLabel?: string
}): StatusDotSummary {
  const hasAriaLabel = ariaLabel !== undefined && ariaLabel !== ''
  return {
    size,
    mode: ariaLabel !== undefined ? 'semantic' : 'decorative',
    hasCustomClass: className !== undefined && className !== '',
    hasAriaLabel,
    classNameLength: className?.length ?? 0,
  }
}

export interface StatusDotProps {
  size?: StatusDotSize
  /** Additional Tailwind classes for tone, margin, etc. Caller-owned
      because per-file helpers (`statusDot(status)`, `verdictTone(v)`,
      etc.) already own the semantic color mapping. */
  class?: string
  /** Override the decorative default. Renders role="img" when set.
      Without it, the dot is `aria-hidden` — correct for the common
      case where the dot sits next to a text label that already
      carries the narrative. */
  ariaLabel?: string
  testId?: string
}

export function StatusDot({
  size = 'sm',
  class: cx,
  ariaLabel,
  testId,
}: StatusDotProps) {
  const summary = summarizeStatusDot({ size, className: cx, ariaLabel })
  const cls = statusDotClasses(size, cx)
  const semantic = summary.mode === 'semantic'
  return html`<span
    class=${cls}
    role=${semantic ? 'img' : undefined}
    aria-label=${ariaLabel}
    aria-hidden=${semantic ? undefined : 'true'}
    data-status-dot
    data-status-dot-size=${summary.size}
    data-status-dot-mode=${summary.mode}
    data-status-dot-has-custom-class=${summary.hasCustomClass}
    data-status-dot-has-aria-label=${summary.hasAriaLabel}
    data-status-dot-class-length=${summary.classNameLength}
    data-testid=${testId}
  ></span>`
}
