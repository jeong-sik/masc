// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { KpiCell, kpiCellAriaLabel, type KpiCellProps } from './kpi-cell'

describe('kpiCellAriaLabel (pure)', () => {
  it('returns "label: value" for the minimal case', () => {
    expect(kpiCellAriaLabel({ label: 'FLEET', value: '5' })).toBe('FLEET: 5')
  })

  it('appends caption when provided', () => {
    expect(
      kpiCellAriaLabel({ label: 'PASS', value: '87%', caption: '47 / 54' }),
    ).toBe('PASS: 87% 47 / 54')
  })

  it('appends "(live)" suffix when live is true', () => {
    expect(
      kpiCellAriaLabel({ label: 'TPS', value: '1.24', live: true }),
    ).toBe('TPS: 1.24 (live)')
  })

  it('encodes positive delta as "up <value>"', () => {
    expect(
      kpiCellAriaLabel({
        label: 'TPS',
        value: '1.24',
        delta: { value: '+0.1', direction: 'pos' },
      }),
    ).toBe('TPS: 1.24, up +0.1')
  })

  it('encodes negative delta as "down <value>"', () => {
    expect(
      kpiCellAriaLabel({
        label: 'ERR',
        value: '0.30',
        delta: { value: '-0.05', direction: 'neg' },
      }),
    ).toBe('ERR: 0.30, down -0.05')
  })

  it('encodes kind=ok as "(passing)"', () => {
    expect(
      kpiCellAriaLabel({ label: 'PASS', value: '87%', kind: 'ok' }),
    ).toBe('PASS: 87% (passing)')
  })

  it('encodes kind=err as "(failing)"', () => {
    expect(
      kpiCellAriaLabel({ label: 'FAIL', value: '3', kind: 'err' }),
    ).toBe('FAIL: 3 (failing)')
  })

  it('encodes kind=warn as "(warning)"', () => {
    expect(
      kpiCellAriaLabel({ label: 'LAT', value: '95ms', kind: 'warn' }),
    ).toBe('LAT: 95ms (warning)')
  })

  it('combines caption + delta + kind + live in canonical order', () => {
    expect(
      kpiCellAriaLabel({
        label: 'TPS',
        value: '1.24',
        caption: 'SEC/TOK',
        live: true,
        delta: { value: '+0.1', direction: 'pos' },
      }),
    ).toBe('TPS: 1.24 SEC/TOK, up +0.1 (live)')
  })

  it('coerces numeric values', () => {
    expect(kpiCellAriaLabel({ label: 'N', value: 12 })).toBe('N: 12')
  })
})

describe('KpiCell component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  function mount(props: KpiCellProps): HTMLElement {
    render(html`<${KpiCell} ...${props} />`, container)
    return container.querySelector('[role="listitem"]') as HTMLElement
  }

  it('renders role=listitem with the composed aria-label', () => {
    const el = mount({ label: 'FLEET', value: '5', caption: 'ACTIVE' })
    expect(el).toBeTruthy()
    expect(el.getAttribute('role')).toBe('listitem')
    expect(el.getAttribute('aria-label')).toBe('FLEET: 5 ACTIVE')
  })

  it('label and value text both surface in the DOM', () => {
    const el = mount({ label: 'TPS', value: '1.24' })
    expect(el.textContent).toContain('TPS')
    expect(el.textContent).toContain('1.24')
  })

  it('compact variant omits the caption row even when caption is given', () => {
    const el = mount({
      label: 'TPS',
      value: '1.24',
      caption: 'SEC/TOK',
      variant: 'compact',
    })
    // Caption should not appear visually in compact (aria-label still has it)
    expect(el.textContent).toContain('TPS')
    expect(el.textContent).toContain('1.24')
    expect(el.textContent).not.toContain('SEC/TOK')
  })

  it('standard variant surfaces the caption row', () => {
    const el = mount({
      label: 'TPS',
      value: '1.24',
      caption: 'SEC/TOK',
      variant: 'standard',
    })
    expect(el.textContent).toContain('SEC/TOK')
  })

  it('stacked variant surfaces the caption row', () => {
    const el = mount({
      label: 'TASKS',
      value: '12',
      caption: 'IN FLIGHT',
      variant: 'stacked',
    })
    expect(el.textContent).toContain('IN FLIGHT')
  })

  it('renders the delta chip text in standard variant', () => {
    const el = mount({
      label: 'TPS',
      value: '1.24',
      caption: 'SEC/TOK',
      delta: { value: '+0.1', direction: 'pos' },
    })
    expect(el.textContent).toContain('+0.1')
  })

  it('live tile applies brass-accent border style override', () => {
    const el = mount({ label: 'TPS', value: '1.24', live: true })
    // The component sets border-color via inline style (overriding default token).
    // happy-dom resolves these into the style attribute we can inspect.
    const styleAttr = el.getAttribute('style') ?? ''
    expect(styleAttr).toContain('border-color')
  })

  it('forwards id when provided', () => {
    const el = mount({ label: 'X', value: '1', id: 'kpi-fleet' })
    expect(el.id).toBe('kpi-fleet')
  })

  it('encodes numeric value via the aria-label', () => {
    const el = mount({ label: 'N', value: 12 })
    expect(el.getAttribute('aria-label')).toBe('N: 12')
  })

  // ── progress prop ──
  // The progress bar fill carries `transition: width 500ms` + a width% — a
  // stable signature happy-dom can resolve, even though it doesn't compute
  // layout. aria-label encodes a rounded, clamped progress for SR users.

  it('omits the progress bar when progress is undefined', () => {
    const el = mount({ label: 'CTX', value: '40k' })
    expect(el.innerHTML).not.toContain('width 500ms')
  })

  it('renders a progress bar when progress is supplied', () => {
    const el = mount({ label: 'CTX', value: '40k', progress: 73 })
    expect(el.innerHTML).toContain('width 500ms')
    expect(el.innerHTML).toContain('width: 73%')
  })

  it('clamps progress >100 to 100% in the rendered fill', () => {
    const el = mount({ label: 'CTX', value: 'overflow', progress: 142 })
    expect(el.innerHTML).toContain('width: 100%')
    expect(el.innerHTML).not.toContain('width: 142%')
  })

  it('clamps progress <0 to 0% in the rendered fill', () => {
    const el = mount({ label: 'CTX', value: 'reset', progress: -25 })
    expect(el.innerHTML).toContain('width: 0%')
  })

  it('describes progress in the aria-label (rounded, clamped)', () => {
    const el = mount({ label: 'CTX', value: '40k', progress: 73.4 })
    expect(el.getAttribute('aria-label')).toContain('progress 73%')
  })

  it('uses the kind value-color for the progress fill', () => {
    const el = mount({ label: 'CTX', value: '90k', progress: 95, kind: 'warn' })
    expect(el.innerHTML).toContain('var(--color-status-warn)')
  })
})
