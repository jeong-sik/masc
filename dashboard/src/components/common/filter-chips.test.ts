import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { FilterChips } from './filter-chips'

describe('FilterChips', () => {
  const chips = [
    { key: 'all' as const, label: 'All', count: 10 },
    { key: 'active' as const, label: 'Active', count: 3 },
    { key: 'done' as const, label: 'Done' },
  ]

  it('renders tablist role', () => {
    const container = document.createElement('div')
    render(h(FilterChips, { chips }), container)
    expect(container.querySelector('[role="tablist"]')).not.toBeNull()
  })

  it('renders all chips', () => {
    const container = document.createElement('div')
    render(h(FilterChips, { chips }), container)
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs.length).toBe(3)
    expect(container.textContent).toContain('All')
    expect(container.textContent).toContain('Active')
    expect(container.textContent).toContain('Done')
  })

  it('marks active chip via value', () => {
    const container = document.createElement('div')
    render(h(FilterChips, { chips, value: 'active' }), container)
    const tabs = container.querySelectorAll('[role="tab"]')
    expect(tabs[1]?.getAttribute('aria-selected')).toBe('true')
    expect(tabs[0]?.getAttribute('aria-selected')).toBe('false')
  })

  it('calls onChange on click', async () => {
    const onChange = vi.fn()
    const container = document.createElement('div')
    render(h(FilterChips, { chips, value: 'all', onChange }), container)
    const tabs = container.querySelectorAll('[role="tab"]')
    ;(tabs[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onChange).toHaveBeenCalledWith('active')
  })

  it('renders count badge when count provided', () => {
    const container = document.createElement('div')
    render(h(FilterChips, { chips, value: 'all' }), container)
    expect(container.textContent).toContain('10')
    expect(container.textContent).toContain('3')
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(FilterChips, { chips, class: 'my-bar' }), container)
    const el = container.querySelector('[role="tablist"]')
    expect(el?.classList.contains('my-bar')).toBe(true)
  })

  it('applies title attribute', () => {
    const container = document.createElement('div')
    const titledChips = [{ key: 'a' as const, label: 'A', title: 'Tip' }]
    render(h(FilterChips, { chips: titledChips }), container)
    const tab = container.querySelector('[role="tab"]')
    expect(tab?.getAttribute('title')).toBe('Tip')
  })
})
