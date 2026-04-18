// ConnectorOverviewSkeleton — shape-matched placeholder for the cold-start
// of section=connector-status.
//
// Reference UIs (Vercel dashboard project grid, Linear Cycle loader, Notion
// database view): skeleton loaders that **mimic the final content shape**
// let the operator anticipate the layout before data arrives. The ~200ms
// between navigation and first snapshot becomes "I can already see where
// the 4 connector cards will sit" instead of "I see a spinner, guess what
// the page looks like".
//
// Matches the grid/tile layout of ConnectorOverviewStrip exactly — 4
// tiles, icon + title lines + 3 readiness pills + a chip row + a 45-bar
// heartbeat row. When the real data lands, the DOM shape shift is near
// zero so the transition feels like "content flowed in", not "page
// swapped".

import { html } from 'htm/preact'
import { KNOWN_CONNECTOR_IDS } from './connector-status'
import { SkeletonCircle } from './common/skeleton'

/** Pure: grid layout class for the tile row. Mirrors the real strip's
    `grid-cols-1 sm:grid-cols-2 lg:grid-cols-4` so the skeleton and the
    loaded content occupy the same footprint at every breakpoint. */
export function overviewSkeletonGridClasses(): string {
  return 'grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4'
}

/** Count of skeleton tiles to render. Exposed so tests can pin the
    invariant — the skeleton should always match the number of known
    connectors, not a hardcoded 4, so adding a 5th bridge doesn't leave
    the loader asymmetric. */
export function overviewSkeletonTileCount(): number {
  return KNOWN_CONNECTOR_IDS.length
}

const BAR = 'h-3 w-[4px] rounded-[1px] bg-[var(--white-4)] animate-pulse'
const PILL = 'h-4 flex-1 rounded-sm bg-[var(--white-4)] animate-pulse'
const LINE = 'h-3 rounded bg-[var(--white-4)] animate-pulse'

function TileSkeleton() {
  return html`
    <div
      class="flex min-w-0 flex-col gap-2 rounded border border-[var(--white-8)] bg-[var(--bg-1)] p-3"
      data-overview-skeleton-tile
    >
      <div class="flex min-w-0 items-center gap-2">
        <${SkeletonCircle} size="h-7 w-7" />
        <div class="flex min-w-0 flex-1 flex-col gap-1.5">
          <div class=${`${LINE} w-[60%]`}></div>
          <div class=${`${LINE} w-[40%] h-2`}></div>
        </div>
      </div>
      <div class="flex items-center gap-1">
        <div class=${PILL}></div>
        <div class=${PILL}></div>
        <div class=${PILL}></div>
      </div>
      <div class="flex items-center gap-1">
        <div class="h-4 w-[64px] rounded-sm bg-[var(--white-4)] animate-pulse"></div>
        <div class="h-4 w-[44px] rounded-sm bg-[var(--white-4)] animate-pulse"></div>
      </div>
      <div class="flex items-end gap-[2px]" aria-hidden="true">
        ${Array.from({ length: 45 }, (_, i) => html`<span class=${BAR} data-skeleton-bar-index=${i}></span>`)}
      </div>
    </div>
  `
}

interface ConnectorOverviewSkeletonProps {
  class?: string
  testId?: string
}

/** Shape-matched skeleton for the connector overview strip. Renders
    `KNOWN_CONNECTOR_IDS.length` tiles so the grid footprint is stable
    from first paint. The wrapper carries `role="status"` +
    `aria-label` so AT users hear one \"Loading…\" instead of N per
    block. */
export function ConnectorOverviewSkeleton({
  class: cx,
  testId,
}: ConnectorOverviewSkeletonProps = {}) {
  const count = overviewSkeletonTileCount()
  const grid = overviewSkeletonGridClasses()
  return html`<div
    class=${`${grid} ${cx ?? ''}`}
    role="status"
    aria-label="커넥터 상태 불러오는 중"
    aria-live="polite"
    data-connector-overview-skeleton
    data-testid=${testId}
  >
    ${Array.from({ length: count }, (_, i) => html`<${TileSkeleton} key=${i} />`)}
  </div>`
}
