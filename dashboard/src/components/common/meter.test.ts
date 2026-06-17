import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Meter, meterPercent } from './meter'

describe('meterPercent (pure)', () => {
  it('clamps to 0 and 100', () => {
    expect(meterPercent(-10)).toBe(0)
    expect(meterPercent(0)).toBe(0)
    expect(meterPercent(50)).toBe(50)
    expect(meterPercent(100)).toBe(100)
    expect(meterPercent(150)).toBe(100)
  })

  it('rounds to integer', () => {
    expect(meterPercent(33.7)).toBe(34)
  })

  it('treats NaN as 0', () => {
    expect(meterPercent(NaN)).toBe(0)
  })
})

describe('Meter', () => {
  it('renders a progressbar with default 0%', () => {
    const container = document.createElement('div')
    render(html`<${Meter} />`, container)
    const el = container.querySelector('[role="progressbar"]')
    expect(el).not.toBeNull()
    expect(el?.getAttribute('aria-valuenow')).toBe('0')
    expect(el?.getAttribute('aria-valuemin')).toBe('0')
    expect(el?.getAttribute('aria-valuemax')).toBe('100')
    expect(el?.getAttribute('aria-label')).toBe('0%')
  })

  it('renders the fill width', () => {
    const container = document.createElement('div')
    render(html`<${Meter} pct=${68} />`, container)
    const fill = container.querySelector('.meter > span') as HTMLElement
    expect(fill?.style.width).toBe('68%')
  })

  it('applies hot modifier', () => {
    const container = document.createElement('div')
    render(html`<${Meter} pct=${88} hot=${true} />`, container)
    const el = container.querySelector('.meter')
    expect(el?.classList.contains('hot')).toBe(true)
  })

  it('uses custom aria-label', () => {
    const container = document.createElement('div')
    render(html`<${Meter} pct=${50} ariaLabel="Half" />`, container)
    const el = container.querySelector('[role="progressbar"]')
    expect(el?.getAttribute('aria-label')).toBe('Half')
  })

  it('forwards testId', () => {
    const container = document.createElement('div')
    render(html`<${Meter} testId="ctx-meter" />`, container)
    const el = container.querySelector('[data-testid="ctx-meter"]')
    expect(el).not.toBeNull()
  })
})
