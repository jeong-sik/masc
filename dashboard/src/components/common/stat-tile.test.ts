import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { StatTile, StatGrid } from './stat-tile'

describe('StatTile', () => {
  it('renders label and value', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'Uptime', value: '99.9%' }), container)
    expect(container.textContent).toContain('Uptime')
    expect(container.textContent).toContain('99.9%')
  })

  it('uses brass KPI status by default', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('kpi-cell')).toBe(true)
    expect(el?.classList.contains('is-brass')).toBe(true)
  })

  it('applies kpi-cell status class when status is provided', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'Latency', value: '42ms', status: 'crit' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('kpi-cell')).toBe(true)
    expect(el?.classList.contains('is-crit')).toBe(true)
  })

  it('applies is-live class when live is true', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'RPS', value: '1.2k', status: 'ok', live: true }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('is-live')).toBe(true)
  })

  it('renders delta with direction class', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'CPU', value: '67%', status: 'brass', delta: { direction: 'up', text: '+5%' } }), container)
    expect(container.textContent).toContain('+5%')
    const delta = container.querySelector('.kpi-delta')
    expect(delta?.classList.contains('up')).toBe(true)
  })

  it('renders delta arrow when no text provided', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'Mem', value: '4.2G', status: 'ok', delta: { direction: 'down' } }), container)
    expect(container.textContent).toContain('↓')
  })

  it('uses kpi-value class for status tiles', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'QPS', value: '999', status: 'warn' }), container)
    const val = container.querySelector('.kpi-value')
    expect(val?.textContent).toBe('999')
  })

  it('applies explicit ok status class', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1', status: 'ok' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('kpi-cell')).toBe(true)
    expect(el?.classList.contains('is-ok')).toBe(true)
  })
})

describe('StatGrid', () => {
  it('renders tiles', () => {
    const container = document.createElement('div')
    render(h(StatGrid, { items: [{ label: 'A', value: '1' }, { label: 'B', value: '2' }] }), container)
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
  })

  it('applies grid columns style', () => {
    const container = document.createElement('div')
    render(h(StatGrid, { items: [{ label: 'A', value: '1' }], cols: 3 }), container)
    const el = container.querySelector('div')
    expect(el?.getAttribute('style')).toContain('grid-template-columns: repeat(3, 1fr)')
  })
})
