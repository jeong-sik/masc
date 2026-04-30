// @vitest-environment happy-dom
//
// Tests the Preact fallback path that KpiStripIsland takes when
// `isVitest === true` (see kpi-strip-island.ts). In the browser the
// component mounts a Solid island via `solid-js/web` render; in
// test environments (happy-dom/jsdom) we fall back to native Preact
// because vite-plugin-solid has global side-effects that break
// Preact hook tests.
//
// These tests verify the fallback contract: the same DOM structure,
// aria attributes, and reactive updates, just rendered through
// Preact instead of Solid.

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'

describe('KpiStripIsland (vitest fallback path)', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  // Preact's useEffect schedules at task tier (setTimeout-style), not
  // microtask. The first test in a freshly-loaded happy-dom can hit
  // additional cold-start latency before the Preact reconciler commits
  // refs, so we flush twice with a short delay to be safe — once for
  // Preact's commit + ref assignment, once more so the second useEffect
  // (prop sync) gets a chance to run before assertions.
  function flush(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 10))
      .then(() => new Promise((resolve) => setTimeout(resolve, 10)))
  }

  it('mounts a Solid KpiStrip subtree inside the Preact host', async () => {
    const cells: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
      { variant: 'stacked', label: 'B', value: 2 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${cells} />`, container)
    await flush()
    const strip = container.querySelector('[role="list"]') as HTMLElement
    expect(strip).toBeTruthy()
    expect(strip.getAttribute('aria-label')).toBe('x')
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(2)
  })

  it('forwards variant and cols to the Solid KpiStrip', async () => {
    const cells: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
    ]
    render(
      html`<${KpiStripIsland} ariaLabel="x" variant="stacked" cols=${5} cells=${cells} />`,
      container,
    )
    await flush()
    const strip = container.querySelector('[role="list"]') as HTMLElement
    expect(strip.getAttribute('data-variant')).toBe('stacked')
    expect(strip.getAttribute('data-cols')).toBe('5')
  })

  it('reactively updates cells when the Preact parent re-renders', async () => {
    const initial: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
      { variant: 'stacked', label: 'B', value: 2 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${initial} />`, container)
    await flush()
    const stripBefore = container.querySelector('[role="list"]') as HTMLElement
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('1')

    const next: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 99 },
      { variant: 'stacked', label: 'B', value: 2 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${next} />`, container)
    await flush()
    const stripAfter = container.querySelector('[role="list"]') as HTMLElement
    expect(container.textContent).toContain('99')
    // Same Solid root → same DOM container reference (not re-mounted).
    expect(stripAfter).toBe(stripBefore)
  })

  it('grows and shrinks the cells array', async () => {
    const small: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${small} />`, container)
    await flush()
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(1)

    const large: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
      { variant: 'stacked', label: 'B', value: 2 },
      { variant: 'stacked', label: 'C', value: 3 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${large} />`, container)
    await flush()
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)

    const empty: KpiStripIslandData['cells'] = []
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${empty} />`, container)
    await flush()
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(0)
  })

  it('disposes the Solid root cleanly when the Preact host unmounts', async () => {
    const cells: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'A', value: 1 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${cells} />`, container)
    await flush()
    expect(container.querySelector('[role="list"]')).toBeTruthy()

    render(null, container)
    await flush()
    expect(container.querySelector('[role="list"]')).toBeNull()
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(0)
  })

  it('forwards kind and progress through to the Solid cell', async () => {
    const cells: KpiStripIslandData['cells'] = [
      { variant: 'stacked', label: 'CTX', value: '40k', kind: 'warn', progress: 73 },
    ]
    render(html`<${KpiStripIsland} ariaLabel="x" cells=${cells} />`, container)
    await flush()
    const cell = container.querySelector('[role="listitem"]') as HTMLElement
    expect(cell.getAttribute('aria-label')).toContain('progress 73%')
    expect(cell.getAttribute('aria-label')).toContain('(warning)')
    // The Bar primitive renders inside the cell, kind tints the fill.
    expect(cell.innerHTML).toContain('var(--color-status-warn)')
    expect(cell.innerHTML).toContain('width: 73%')
  })
})
