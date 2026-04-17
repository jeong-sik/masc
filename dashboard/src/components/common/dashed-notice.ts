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

export type DashedNoticeSize = 'sm' | 'md'
export type DashedNoticeBorderTone = 'card' | 'subtle'

/** Pure: Tailwind size tokens. Exposed so callers in a hot render path
    (e.g. a repeated fsm-hub sub-panel) can pre-build the string once. */
export function dashedNoticeClasses(
  size: DashedNoticeSize = 'sm',
  border: DashedNoticeBorderTone = 'card',
  extra?: string,
): string {
  const borderClass = border === 'subtle'
    ? 'border-[var(--white-8)]'
    : 'border-[var(--card-border)]'
  const sized = size === 'md'
    ? 'rounded-lg px-4 py-6 text-[12px]'
    : 'rounded-lg px-4 py-2 text-[10px]'
  const parts = [
    'border border-dashed text-center text-[var(--text-dim)]',
    sized,
    borderClass,
  ]
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

export interface DashedNoticeProps {
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
