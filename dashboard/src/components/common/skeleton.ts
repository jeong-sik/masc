// Skeleton — content-shape placeholders with a subtle pulse animation.
//
// Reference UI (Vercel Geist, Stripe Dashboard, Linear, Notion):
// skeleton loaders mimic the eventual content structure instead of a
// generic spinner. Research (Lukew / Google Web Vitals) shows perceived
// load time drops 20-30% vs spinner-only approaches, because the user
// sees the shape of what's coming rather than a vague "please wait".
//
// Design choices here:
// - Tailwind `animate-pulse` gives the breathing effect at zero extra
//   CSS cost. Real gradient shimmer would need keyframes; pulse is the
//   80% solution and stays in the theme without a stylesheet dep.
// - Background uses `var(--white-4)` so the block blends with the
//   dashboard's existing muted surfaces instead of fighting them.
// - `aria-hidden="true"` by default — AT users should hear "Loading…"
//   from the surrounding container, not "blank region" three times.
//   Callers with semantic meaning can opt in with `ariaLabel`.

import { html } from 'htm/preact'

const SKELETON_BASE = 'animate-pulse bg-[var(--color-bg-elevated)] rounded-[var(--r-1)]'

interface SkeletonProps {
  /** Tailwind width class or arbitrary value via class. Default w-full. */
  width?: string
  /** Tailwind height class. Default h-4 (~16px, matches body text line). */
  height?: string
  class?: string
  ariaLabel?: string
  testId?: string
}

/** Pure: derive the Tailwind class string for a skeleton block. Exposed
    for tests + for callers that want to compose skeletons in their own
    layout primitives without mounting this component. */
export function skeletonClasses(
  width?: string,
  height?: string,
  extra?: string,
): string {
  const parts = [
    SKELETON_BASE,
    width ?? 'w-full',
    height ?? 'h-4',
  ]
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

export function Skeleton({
  width,
  height,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonProps) {
  const cls = skeletonClasses(width, height, cx)
  const ariaHidden = ariaLabel === undefined ? 'true' : undefined
  return html`<div
    class=${cls}
    aria-hidden=${ariaHidden}
    aria-label=${ariaLabel}
    role=${ariaLabel !== undefined ? 'status' : undefined}
    data-skeleton-block
    data-testid=${testId}
  ></div>`
}

interface SkeletonTextProps {
  /** Number of stacked lines. Default 3 — enough for a paragraph preview. */
  lines?: number
  class?: string
  /** Rendered as aria-label on the wrapper + role="status". When unset
      the block is `aria-hidden` (decorative). */
  ariaLabel?: string
  testId?: string
}

/** Pure: produce a descending width pattern so a 3-line preview reads
    like a real paragraph (full / full / short tail). Exposed so other
    primitives (SkeletonTile, list-item preview) can reuse the rhythm
    without re-deriving it. */
export function skeletonTextWidths(lines: number): string[] {
  if (lines <= 0) return []
  const out: string[] = []
  for (let i = 0; i < lines; i++) {
    // Last line gets a short tail (~70%) to mimic a paragraph break.
    out.push(i === lines - 1 ? 'w-[70%]' : 'w-full')
  }
  return out
}

/** Stacked text-line skeleton — the "paragraph" preview used by most
    dashboards for log tails, card descriptions, etc. */
export function SkeletonText({
  lines = 3,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonTextProps) {
  const widths = skeletonTextWidths(lines)
  const ariaHidden = ariaLabel === undefined ? 'true' : undefined
  return html`<div
    class=${`flex flex-col gap-2 ${cx ?? ''}`}
    aria-hidden=${ariaHidden}
    aria-label=${ariaLabel}
    role=${ariaLabel !== undefined ? 'status' : undefined}
    data-skeleton-text
    data-skeleton-text-lines=${lines}
    data-testid=${testId}
  >${widths.map(w => html`<div class=${`${SKELETON_BASE} ${w} h-3`} aria-hidden="true"></div>`)}</div>`
}

interface SkeletonCircleProps {
  /** Tailwind size (e.g. "h-6 w-6"). Default h-8 w-8. */
  size?: string
  class?: string
  ariaLabel?: string
  testId?: string
}

/** Round skeleton for avatars / icon placeholders. */
export function SkeletonCircle({
  size,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonCircleProps) {
  const sizing = size ?? 'h-8 w-8'
  const ariaHidden = ariaLabel === undefined ? 'true' : undefined
  return html`<div
    class=${`animate-pulse rounded-full bg-[var(--color-bg-elevated)] ${sizing} ${cx ?? ''}`}
    aria-hidden=${ariaHidden}
    aria-label=${ariaLabel}
    role=${ariaLabel !== undefined ? 'status' : undefined}
    data-skeleton-circle
    data-testid=${testId}
  ></div>`
}
