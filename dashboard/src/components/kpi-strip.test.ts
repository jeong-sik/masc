// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KpiStrip } from './kpi-strip'
import { KpiCell } from './kpi-cell'
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

describe('KpiStrip component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(node: ReturnType<typeof html>): HTMLElement {
    render(node, container)
    return container.querySelector('[role="list"]') as HTMLElement
  }

  it('renders role=list with the supplied aria-label', () => {
    const el = mount(html`
      <${KpiStrip} ariaLabel="Fleet KPI strip">
        <${KpiCell} label="A" value="1" />
      <//>
    `)
    expect(el.getAttribute('role')).toBe('list')
    expect(el.getAttribute('aria-label')).toBe('Fleet KPI strip')
  })

  it('paints the SPEC strip surface (gap=1px hairline + bottom border)', () => {
    const el = mount(html`
      <${KpiStrip} ariaLabel="t">
        <${KpiCell} label="A" value="1" />
      <//>
    `)
    expect(el.style.display).toBe('grid')
    expect(el.style.gap).toBe('1px')
    // The 1px gap is shown as a hairline because the strip's
    // background bleeds through; cell surfaces sit on top.
    expect(el.style.background).toContain('--color-border-default')
    expect(el.style.borderBottom).toContain('--color-border-strong')
  })

  it('uses 6 cols for variant=standard', () => {
    const el = mount(html`
      <${KpiStrip} ariaLabel="t" variant="standard">
        <${KpiCell} label="A" value="1" />
      <//>
    `)
    expect(el.getAttribute('data-cols')).toBe('6')
    expect(el.style.gridTemplateColumns).toContain('repeat(6')
  })

  it('uses 3 cols for variant=stacked', () => {
    const el = mount(html`
      <${KpiStrip} ariaLabel="t" variant="stacked">
        <${KpiCell} label="A" value="1" />
      <//>
    `)
    expect(el.getAttribute('data-cols')).toBe('3')
    expect(el.style.gridTemplateColumns).toContain('repeat(3')
  })

  it('honors a numeric cols override (e.g. 5-cell funnel)', () => {
    const el = mount(html`
      <${KpiStrip} ariaLabel="t" cols=${5}>
        <${KpiCell} label="A" value="1" />
      <//>
    `)
    expect(el.getAttribute('data-cols')).toBe('5')
    expect(el.style.gridTemplateColumns).toContain('repeat(5')
  })

  it('injects bare into KpiCell children that have no bare prop', () => {
    mount(html`
      <${KpiStrip} ariaLabel="t">
        <${KpiCell} label="A" value="1" testId="cell-a" />
      <//>
    `)
    const cell = container.querySelector('[data-testid="cell-a"]') as HTMLElement
    // bare cells render no border (they sit on the strip's surface).
    expect(cell.style.border ?? '').toBe('')
    // padding=0 is the bare signature in kpi-cell.ts.
    expect(cell.style.padding).toBe('0px')
  })

  it('preserves an explicit bare={false} override on a child', () => {
    // Caller deliberately wants the cell to keep its own surface — the
    // strip shouldn't override that.
    mount(html`
      <${KpiStrip} ariaLabel="t">
        <${KpiCell} label="A" value="1" bare=${false} testId="cell-a" />
      <//>
    `)
    const cell = container.querySelector('[data-testid="cell-a"]') as HTMLElement
    // Non-bare cells paint the standard surface.
    expect(cell.style.background).toContain('--bg-panel')
    expect(cell.style.border).toContain('1px solid')
  })

  it('renders all KpiCell children in order', () => {
    mount(html`
      <${KpiStrip} ariaLabel="t">
        <${KpiCell} label="A" value="1" testId="cell-a" />
        <${KpiCell} label="B" value="2" testId="cell-b" />
        <${KpiCell} label="C" value="3" testId="cell-c" />
      <//>
    `)
    expect(container.querySelector('[data-testid="cell-a"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="cell-b"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="cell-c"]')).toBeTruthy()
  })
})
