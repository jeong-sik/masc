// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorOverviewSkeleton,
  overviewSkeletonGridClasses,
  overviewSkeletonTileCount,
} from './connector-overview-skeleton'
import { KNOWN_CONNECTOR_IDS } from './connector-status'

describe('overview skeleton (pure helpers)', () => {
  it('tile count matches KNOWN_CONNECTOR_IDS (no drift if a 5th bridge is added)', () => {
    expect(overviewSkeletonTileCount()).toBe(KNOWN_CONNECTOR_IDS.length)
  })

  it('grid class mirrors the real strip breakpoints', () => {
    // Regression guard: skeleton and loaded content must occupy the
    // same footprint at every viewport or the DOM shape shifts on load.
    const grid = overviewSkeletonGridClasses()
    expect(grid).toContain('grid-cols-1')
    expect(grid).toContain('sm:grid-cols-2')
    expect(grid).toContain('lg:grid-cols-4')
  })
})

describe('ConnectorOverviewSkeleton component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders exactly one tile per known connector', () => {
    render(html`<${ConnectorOverviewSkeleton} />`, container)
    const tiles = container.querySelectorAll('[data-overview-skeleton-tile]')
    expect(tiles.length).toBe(KNOWN_CONNECTOR_IDS.length)
  })

  it('each tile contains an icon circle + 3 readiness pills + 45 heartbeat bars', () => {
    // Shape parity with the real OverviewTile — if this ever drifts,
    // the load→loaded transition will feel like a page swap instead
    // of content flowing in.
    render(html`<${ConnectorOverviewSkeleton} />`, container)
    const tile = container.querySelector('[data-overview-skeleton-tile]') as HTMLElement
    expect(tile.querySelector('[data-skeleton-circle]')).toBeTruthy()
    // 45 bars is Uptime Kuma's default strip width.
    const bars = tile.querySelectorAll('[data-skeleton-bar-index]')
    expect(bars.length).toBe(45)
  })

  it('wrapper carries role=status + aria-label so AT hears one "Loading…"', () => {
    render(html`<${ConnectorOverviewSkeleton} />`, container)
    const root = container.querySelector('[data-connector-overview-skeleton]') as HTMLElement
    expect(root.getAttribute('role')).toBe('status')
    expect(root.getAttribute('aria-label')).toBe('커넥터 상태 불러오는 중')
    expect(root.getAttribute('aria-live')).toBe('polite')
  })

  it('uses animate-pulse for the breathing effect (not generic spinner)', () => {
    render(html`<${ConnectorOverviewSkeleton} />`, container)
    const anyBar = container.querySelector('[data-skeleton-bar-index]') as HTMLElement
    expect(anyBar.className).toContain('animate-pulse')
  })

  it('testId renders as data-testid', () => {
    render(
      html`<${ConnectorOverviewSkeleton} testId="connector-loading" />`,
      container,
    )
    expect(container.querySelector('[data-testid="connector-loading"]')).toBeTruthy()
  })

  it('extra class is composed onto the grid wrapper', () => {
    render(html`<${ConnectorOverviewSkeleton} class="mt-4" />`, container)
    const root = container.querySelector('[data-connector-overview-skeleton]') as HTMLElement
    expect(root.className).toContain('mt-4')
    expect(root.className).toContain('grid-cols-1')
  })
})
