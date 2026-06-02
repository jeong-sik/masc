import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { StatCell } from './stat-cell'

describe('StatCell', () => {
  it('renders label and value', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'CPU', value: '45%' }), container)
    expect(container.textContent).toContain('CPU')
    expect(container.textContent).toContain('45%')
  })

  it('renders detail when provided', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'Mem', value: '2GB', detail: 'of 8GB' }), container)
    expect(container.textContent).toContain('of 8GB')
  })

  it('applies tone class', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1', tone: 'warn' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('warn')).toBe(true)
  })

  it('applies size class', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1', size: 'lg' }), container)
    const strong = container.querySelector('strong')
    expect(strong?.classList.contains('text-xl')).toBe(true)
  })

  it('applies bg class', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1', bg: 'white-3' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('bg-[var(--color-bg-panel-alt)]')).toBe(true)
  })

  it('uses cockpit border token', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('border-[var(--color-border-default)]')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1', class: 'flex-1' }), container)
    const el = container.querySelector('div')
    expect(el?.classList.contains('flex-1')).toBe(true)
  })

  it('has role="group"', () => {
    const container = document.createElement('div')
    render(h(StatCell, { label: 'A', value: '1' }), container)
    const el = container.querySelector('div')
    expect(el?.getAttribute('role')).toBe('group')
  })
})
