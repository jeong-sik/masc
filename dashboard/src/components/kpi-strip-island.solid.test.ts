// @vitest-environment happy-dom
//
// Integration test for the Preact→Solid island bridge. Verifies:
//   1. Initial mount produces the Solid subtree (role=list + cells).
//   2. Re-rendering the Preact parent with new `cells` prop reaches
//      the Solid signal and updates only changed cells (no re-mount).
//   3. Unmounting the Preact parent disposes the Solid root cleanly.
//
// These three scenarios are the contract that PR #4 promises: a Preact
// parent can keep its render cycle while a Solid child stays
// reactive without any cross-framework bridge code at the call site.

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KpiStripIsland, type KpiStripIslandData } from './kpi-strip-island'

describe('KpiStripIsland (Preact→Solid bridge)', () => {
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
