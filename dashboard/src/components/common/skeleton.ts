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

export interface SkeletonSummary {
  readonly width: string
  readonly height: string
  readonly hasSemanticLabel: boolean
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
  readonly ariaLabelLength: number
  readonly classNameLength: number
  readonly testIdLength: number
}

export interface SkeletonTextSummary {
  readonly lines: number
  readonly renderedLines: number
  readonly hasSemanticLabel: boolean
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
  readonly ariaLabelLength: number
  readonly classNameLength: number
  readonly testIdLength: number
}

export interface SkeletonCircleSummary {
  readonly size: string
  readonly hasSemanticLabel: boolean
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
  readonly ariaLabelLength: number
  readonly classNameLength: number
  readonly testIdLength: number
}

export function normalizeSkeletonAriaLabel(ariaLabel?: string): string | undefined {
  const normalized = ariaLabel?.trim()
  return normalized === undefined || normalized === '' ? undefined : normalized
}

function summarizeSkeletonChrome({
  className,
  ariaLabel,
  testId,
}: {
  className?: string
  ariaLabel?: string
  testId?: string
}) {
  const normalizedAriaLabel = normalizeSkeletonAriaLabel(ariaLabel)
  return {
    hasSemanticLabel: normalizedAriaLabel !== undefined,
    hasCustomClass: className !== undefined && className !== '',
    hasTestId: testId !== undefined && testId !== '',
    ariaLabelLength: normalizedAriaLabel?.length ?? 0,
    classNameLength: className?.length ?? 0,
    testIdLength: testId?.length ?? 0,
  }
}

export interface SkeletonProps {
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

export function summarizeSkeleton({
  width,
  height,
  className,
  ariaLabel,
  testId,
}: {
  width?: string
  height?: string
  className?: string
  ariaLabel?: string
  testId?: string
}): SkeletonSummary {
  return {
    width: width ?? 'w-full',
    height: height ?? 'h-4',
    ...summarizeSkeletonChrome({ className, ariaLabel, testId }),
  }
}

export function Skeleton({
  width,
  height,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonProps) {
  const summary = summarizeSkeleton({ width, height, className: cx, ariaLabel, testId })
  const normalizedAriaLabel = normalizeSkeletonAriaLabel(ariaLabel)
  const cls = skeletonClasses(width, height, cx)
  return html`<div
    class=${cls}
    aria-hidden=${summary.hasSemanticLabel ? undefined : 'true'}
    aria-label=${normalizedAriaLabel}
    role=${summary.hasSemanticLabel ? 'status' : undefined}
    data-skeleton-block
    data-skeleton-block-width=${summary.width}
    data-skeleton-block-height=${summary.height}
    data-skeleton-has-semantic-label=${summary.hasSemanticLabel}
    data-skeleton-has-custom-class=${summary.hasCustomClass}
    data-skeleton-has-test-id=${summary.hasTestId}
    data-skeleton-aria-label-length=${summary.ariaLabelLength}
    data-skeleton-class-length=${summary.classNameLength}
    data-skeleton-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  ></div>`
}

export interface SkeletonTextProps {
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

export function summarizeSkeletonText({
  lines = 3,
  className,
  ariaLabel,
  testId,
}: {
  lines?: number
  className?: string
  ariaLabel?: string
  testId?: string
}): SkeletonTextSummary {
  return {
    lines,
    renderedLines: skeletonTextWidths(lines).length,
    ...summarizeSkeletonChrome({ className, ariaLabel, testId }),
  }
}

/** Stacked text-line skeleton — the "paragraph" preview used by most
    dashboards for log tails, card descriptions, etc. */
export function SkeletonText({
  lines = 3,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonTextProps) {
  const summary = summarizeSkeletonText({ lines, className: cx, ariaLabel, testId })
  const normalizedAriaLabel = normalizeSkeletonAriaLabel(ariaLabel)
  const widths = skeletonTextWidths(lines)
  return html`<div
    class=${`flex flex-col gap-2 ${cx ?? ''}`}
    aria-hidden=${summary.hasSemanticLabel ? undefined : 'true'}
    aria-label=${normalizedAriaLabel}
    role=${summary.hasSemanticLabel ? 'status' : undefined}
    data-skeleton-text
    data-skeleton-text-lines=${summary.lines}
    data-skeleton-text-rendered-lines=${summary.renderedLines}
    data-skeleton-text-has-semantic-label=${summary.hasSemanticLabel}
    data-skeleton-text-has-custom-class=${summary.hasCustomClass}
    data-skeleton-text-has-test-id=${summary.hasTestId}
    data-skeleton-text-aria-label-length=${summary.ariaLabelLength}
    data-skeleton-text-class-length=${summary.classNameLength}
    data-skeleton-text-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  >${widths.map(w => html`<div class=${`${SKELETON_BASE} ${w} h-3`} aria-hidden="true"></div>`)}</div>`
}

export interface SkeletonCircleProps {
  /** Tailwind size (e.g. "h-6 w-6"). Default h-8 w-8. */
  size?: string
  class?: string
  ariaLabel?: string
  testId?: string
}

export function summarizeSkeletonCircle({
  size,
  className,
  ariaLabel,
  testId,
}: {
  size?: string
  className?: string
  ariaLabel?: string
  testId?: string
}): SkeletonCircleSummary {
  return {
    size: size ?? 'h-8 w-8',
    ...summarizeSkeletonChrome({ className, ariaLabel, testId }),
  }
}

/** Round skeleton for avatars / icon placeholders. */
export function SkeletonCircle({
  size,
  class: cx,
  ariaLabel,
  testId,
}: SkeletonCircleProps) {
  const summary = summarizeSkeletonCircle({ size, className: cx, ariaLabel, testId })
  const normalizedAriaLabel = normalizeSkeletonAriaLabel(ariaLabel)
  return html`<div
    class=${`animate-pulse rounded-full bg-[var(--color-bg-elevated)] ${summary.size} ${cx ?? ''}`}
    aria-hidden=${summary.hasSemanticLabel ? undefined : 'true'}
    aria-label=${normalizedAriaLabel}
    role=${summary.hasSemanticLabel ? 'status' : undefined}
    data-skeleton-circle
    data-skeleton-circle-size=${summary.size}
    data-skeleton-circle-has-semantic-label=${summary.hasSemanticLabel}
    data-skeleton-circle-has-custom-class=${summary.hasCustomClass}
    data-skeleton-circle-has-test-id=${summary.hasTestId}
    data-skeleton-circle-aria-label-length=${summary.ariaLabelLength}
    data-skeleton-circle-class-length=${summary.classNameLength}
    data-skeleton-circle-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  ></div>`
}
