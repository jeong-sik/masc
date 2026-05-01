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

  it('renders hint when provided', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1', hint: 'last hour' }), container)
    expect(container.textContent).toContain('last hour')
  })

  it('applies default variant styles', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('bg-[var(--color-bg-elevated)]')).toBe(true)
  })

  it('applies gold variant styles', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1', variant: 'gold' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('bg-[var(--color-brass-soft)]')).toBe(true)
  })

  it('applies accent variant styles', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1', variant: 'accent' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('bg-[var(--color-state-active-bg)]')).toBe(true)
  })

  it('applies warn variant styles', () => {
    const container = document.createElement('div')
    render(h(StatTile, { label: 'A', value: '1', variant: 'warn' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('text-[var(--color-warn-fg)]')).toBe(true)
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
