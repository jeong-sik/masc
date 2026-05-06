import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  BreadcrumbHistory,
  formatBreadcrumbTime,
  summarizeBreadcrumbHistory,
} from './breadcrumb-history'

describe('BreadcrumbHistory', () => {
  it('formats breadcrumb timestamps', () => {
    const timestamp = new Date('2024-01-15T09:30:00').getTime()
    expect(formatBreadcrumbTime(timestamp)).not.toBe('')
    expect(formatBreadcrumbTime()).toBe('')
  })

  it('summarizes empty history', () => {
    expect(summarizeBreadcrumbHistory([])).toEqual({
      count: 0,
      empty: true,
      activeId: '',
      activeIndex: -1,
      hasActive: false,
      hasTimestamps: false,
      items: [],
    })
  })

  it('summarizes active and timestamp metadata', () => {
    const timestamp = new Date('2024-01-15T09:30:00').getTime()
    const summary = summarizeBreadcrumbHistory([
      { id: 'a', label: 'Step A', timestamp },
      { id: 'b', label: 'Step B', active: true },
    ])
    expect(summary.count).toBe(2)
    expect(summary.activeId).toBe('b')
    expect(summary.activeIndex).toBe(1)
    expect(summary.hasActive).toBe(true)
    expect(summary.hasTimestamps).toBe(true)
    expect(summary.items[0]).toMatchObject({
      id: 'a',
      index: 0,
      active: false,
      first: true,
      last: false,
      timestamp,
      timeLabel: formatBreadcrumbTime(timestamp),
      hasTimestamp: true,
    })
    expect(summary.items[1]).toMatchObject({
      id: 'b',
      index: 1,
      active: true,
      first: false,
      last: true,
      timestamp: null,
      timeLabel: '',
      hasTimestamp: false,
    })
  })

  it('renders empty message when no items', () => {
    const container = document.createElement('div')
    render(h(BreadcrumbHistory, { items: [] }), container)
    expect(container.textContent).toContain('히스토리가 없습니다')
    const nav = container.querySelector('[data-breadcrumb-history]') as HTMLElement
    expect(nav.dataset.breadcrumbCount).toBe('0')
    expect(nav.dataset.breadcrumbEmpty).toBe('true')
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
    const nav = container.querySelector('[data-breadcrumb-history]') as HTMLElement
    expect(nav.dataset.breadcrumbCount).toBe('2')
    expect(nav.dataset.breadcrumbEmpty).toBe('false')
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
    expect(buttons[0]?.className).toContain('text-[var(--color-accent-fg)]')
    expect(buttons[1]?.className).not.toContain('text-[var(--color-accent-fg)]')
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
    const nav = container.querySelector('[data-breadcrumb-history]') as HTMLElement
    expect(nav.dataset.breadcrumbActiveId).toBe('a')
    expect(nav.dataset.breadcrumbActiveIndex).toBe('0')
    expect(nav.dataset.breadcrumbHasActive).toBe('true')
    const item = container.querySelector('[data-breadcrumb-item-id="a"]') as HTMLElement
    expect(item.dataset.breadcrumbItemActive).toBe('true')
    expect(item.dataset.breadcrumbItemFirst).toBe('true')
  })

  it('renders timestamp when provided', () => {
    const container = document.createElement('div')
    const items = [{ id: 'a', label: 'Step A', timestamp: new Date('2024-01-15T09:30:00').getTime() }]
    render(h(BreadcrumbHistory, { items }), container)
    const time = container.querySelector('time')
    expect(time).not.toBeNull()
    expect(time?.getAttribute('datetime')).not.toBeNull()
    const item = container.querySelector('[data-breadcrumb-item-id="a"]') as HTMLElement
    expect(item.dataset.breadcrumbItemHasTimestamp).toBe('true')
    expect(item.dataset.breadcrumbItemTimeLabel).not.toBe('')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(BreadcrumbHistory, { items: [], testId: 'bc-1' }), container)
    expect(container.querySelector('[data-testid="bc-1"]')).not.toBeNull()
  })
})
