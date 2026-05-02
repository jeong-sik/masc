// DashedNotice — inline dashed-border \"nothing to show\" panel.
//
// Reference UIs (Linear empty list region, Vercel \"no deployments yet\"
// card, GitHub \"No workflow runs\"): when a small region of the page
// has no rows to render, a dashed-border placeholder says \"this area
// is intentionally empty\" — strictly better than a collapsed
// zero-height slot (operator thinks the surface is broken) or a big
// illustration (visual weight for nothing).
//
// Distinct from <EmptyState> (which has an icon + vertical layout
// for full-panel emptiness, e.g. \"no results\"). DashedNotice is the
// *inline* case: a single-line / two-line hint inside a tile, row,
// or inner card. The dashboard had 9 pre-change call sites with 3
// different padding schemes + 2 different border tones; this
// primitive pins the canonical two variants.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type DashedNoticeSize = 'sm' | 'md'
type DashedNoticeBorderTone = 'card' | 'subtle'

/** Pure: Tailwind size tokens. Exposed so callers in a hot render path
    (e.g. a repeated fsm-hub sub-panel) can pre-build the string once. */
export function dashedNoticeClasses(
  size: DashedNoticeSize = 'sm',
  border: DashedNoticeBorderTone = 'card',
  extra?: string,
): string {
  const borderClass = border === 'subtle'
    ? 'border-[var(--color-border-default)]'
    : 'border-[var(--color-border-default)]'
  const sized = size === 'md'
    ? 'rounded-[var(--r-1)] px-4 py-6 text-xs'
    : 'rounded-[var(--r-1)] px-4 py-2 text-3xs'
  const parts = [
    'border border-dashed text-center text-[var(--color-fg-disabled)]',
    sized,
    borderClass,
  ]
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

interface DashedNoticeProps {
  children?: ComponentChildren
  size?: DashedNoticeSize
  borderTone?: DashedNoticeBorderTone
  class?: string
  testId?: string
}

export function DashedNotice({
  children,
  size = 'sm',
  borderTone = 'card',
  class: cx,
  testId,
}: DashedNoticeProps) {
  const cls = dashedNoticeClasses(size, borderTone, cx)
  return html`<div
    class=${cls}
    data-dashed-notice
    data-dashed-notice-size=${size}
    data-dashed-notice-border=${borderTone}
    data-testid=${testId}
  >${children}</div>`
}
