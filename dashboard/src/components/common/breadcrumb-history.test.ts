import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { BreadcrumbHistory } from './breadcrumb-history'

describe('BreadcrumbHistory', () => {
  it('renders empty message when no items', () => {
    const container = document.createElement('div')
    render(h(BreadcrumbHistory, { items: [] }), container)
    expect(container.textContent).toContain('히스토리가 없습니다')
  })

  it('renders breadcrumb items', () => {
    const container = document.createElement('div')
    const items = [
      { id: 'a', label: 'Step A' },
      { id: 'b', label: 'Step B' },
    ]
    render(h(BreadcrumbHistory, { items }), container)
    expect(container.textContent).toContain('Step A')
    expect(container.textContent).toContain('Step B')
  })

  it('renders separators between items', () => {
    const container = document.createElement('div')
    const items = [
      { id: 'a', label: 'Step A' },
      { id: 'b', label: 'Step B' },
    ]
    render(h(BreadcrumbHistory, { items }), container)
    const separators = container.querySelectorAll('[aria-hidden="true"]')
    expect(separators.length).toBe(1)
  })

  it('calls onNavigate on item click', async () => {
    const onNavigate = vi.fn()
    const container = document.createElement('div')
    const items = [{ id: 'a', label: 'Step A' }]
    render(h(BreadcrumbHistory, { items, onNavigate }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onNavigate).toHaveBeenCalledWith('a')
  })

  it('applies active styling to active item', () => {
    const container = document.createElement('div')
    const items = [
      { id: 'a', label: 'Step A', active: true },
      { id: 'b', label: 'Step B' },
    ]
    render(h(BreadcrumbHistory, { items }), container)
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.className).toContain('text-[var(--color-accent)]')
    expect(buttons[1]?.className).not.toContain('text-[var(--color-accent)]')
  })

  it('applies aria-current to active item', () => {
    const container = document.createElement('div')
    const items = [
      { id: 'a', label: 'Step A', active: true },
      { id: 'b', label: 'Step B' },
    ]
    render(h(BreadcrumbHistory, { items }), container)
    const buttons = container.querySelectorAll('button')
    expect(buttons[0]?.getAttribute('aria-current')).toBe('page')
    expect(buttons[1]?.getAttribute('aria-current')).toBeNull()
  })

  it('renders timestamp when provided', () => {
    const container = document.createElement('div')
    const items = [{ id: 'a', label: 'Step A', timestamp: new Date('2024-01-15T09:30:00').getTime() }]
    render(h(BreadcrumbHistory, { items }), container)
    expect(container.querySelector('time')).not.toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(BreadcrumbHistory, { items: [], testId: 'bc-1' }), container)
    expect(container.querySelector('[data-testid="bc-1"]')).not.toBeNull()
  })
})
