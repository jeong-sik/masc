/** @jsxImportSource solid-js */
// @vitest-environment happy-dom
//
// Mirrors `kpi-strip.test.ts` (Preact) scenario coverage. Asserts the
// same DOM contract on the Solid render path: role=list, aria-label,
// SPEC strip surface (gap=1px hairline + bottom border), variant→cols
// mapping, numeric override, bare-default injection via context, and
// explicit `bare={false}` override.

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { JSX } from 'solid-js'
import { render } from 'solid-js/web'
import { KpiStrip } from './kpi-strip.solid'
import { KpiCell } from './kpi-cell.solid'
import { resolveStripCols } from './kpi-shared'

describe('resolveStripCols (pure)', () => {
  it('maps the SPEC variant cardinality table', () => {
    expect(resolveStripCols('standard', undefined)).toBe(6)
    expect(resolveStripCols('compact', undefined)).toBe(6)
    expect(resolveStripCols('stacked', undefined)).toBe(3)
  })

  it('defaults missing variant to standard (6 cols)', () => {
    expect(resolveStripCols(undefined, undefined)).toBe(6)
  })

  it('lets a positive override win over the SPEC default', () => {
    expect(resolveStripCols('standard', 5)).toBe(5)
    expect(resolveStripCols('stacked', 4)).toBe(4)
  })

  it('falls back to the SPEC default when override is non-positive', () => {
    expect(resolveStripCols('standard', 0)).toBe(6)
    expect(resolveStripCols('compact', -1)).toBe(6)
  })
})

describe('KpiStrip component (Solid)', () => {
  let container: HTMLElement
  let dispose: (() => void) | undefined

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    dispose?.()
    dispose = undefined
    document.body.removeChild(container)
  })

  function mount(jsx: () => JSX.Element): HTMLElement {
    dispose = render(jsx, container)
    return container.querySelector('[role="list"]') as HTMLElement
  }

  it('renders role=list with the supplied aria-label', () => {
    const el = mount(() => (
      <KpiStrip ariaLabel="Fleet KPI strip">
        <KpiCell label="A" value="1" />
      </KpiStrip>
    ))
    expect(el.getAttribute('role')).toBe('list')
    expect(el.getAttribute('aria-label')).toBe('Fleet KPI strip')
  })

  it('paints the SPEC strip surface (gap=1px hairline + bottom border)', () => {
    const el = mount(() => (
      <KpiStrip ariaLabel="t">
        <KpiCell label="A" value="1" />
      </KpiStrip>
    ))
    expect(el.style.display).toBe('grid')
    expect(el.style.gap).toBe('1px')
    expect(el.style.background).toContain('--color-border-default')
    expect(el.style.borderBottom).toContain('--color-border-strong')
  })

  it('uses 6 cols for variant=standard', () => {
    const el = mount(() => (
      <KpiStrip ariaLabel="t" variant="standard">
        <KpiCell label="A" value="1" />
      </KpiStrip>
    ))
    expect(el.getAttribute('data-cols')).toBe('6')
    expect(el.style.gridTemplateColumns).toContain('repeat(6')
  })

  it('uses 3 cols for variant=stacked', () => {
    const el = mount(() => (
      <KpiStrip ariaLabel="t" variant="stacked">
        <KpiCell label="A" value="1" />
      </KpiStrip>
    ))
    expect(el.getAttribute('data-cols')).toBe('3')
    expect(el.style.gridTemplateColumns).toContain('repeat(3')
  })

  it('honors a numeric cols override (e.g. 5-cell funnel)', () => {
    const el = mount(() => (
      <KpiStrip ariaLabel="t" cols={5}>
        <KpiCell label="A" value="1" />
      </KpiStrip>
    ))
    expect(el.getAttribute('data-cols')).toBe('5')
    expect(el.style.gridTemplateColumns).toContain('repeat(5')
  })

  it('injects bare into KpiCell children that have no bare prop (via context)', () => {
    mount(() => (
      <KpiStrip ariaLabel="t">
        <KpiCell label="A" value="1" testId="cell-a" />
      </KpiStrip>
    ))
    const cell = container.querySelector('[data-testid="cell-a"]') as HTMLElement
    // bare cells render no surface border (they sit on the strip's surface).
    expect(cell.style.border ?? '').toBe('')
    expect(cell.style.padding).toBe('0px')
  })

  it('preserves an explicit bare={false} override on a child', () => {
    mount(() => (
      <KpiStrip ariaLabel="t">
        <KpiCell label="A" value="1" bare={false} testId="cell-a" />
      </KpiStrip>
    ))
    const cell = container.querySelector('[data-testid="cell-a"]') as HTMLElement
    expect(cell.style.background).toContain('--bg-panel')
    expect(cell.style.border).toContain('1px solid')
  })

  it('renders all KpiCell children in order', () => {
    mount(() => (
      <KpiStrip ariaLabel="t">
        <KpiCell label="A" value="1" testId="cell-a" />
        <KpiCell label="B" value="2" testId="cell-b" />
        <KpiCell label="C" value="3" testId="cell-c" />
      </KpiStrip>
    ))
    expect(container.querySelector('[data-testid="cell-a"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="cell-b"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="cell-c"]')).toBeTruthy()
  })
})
