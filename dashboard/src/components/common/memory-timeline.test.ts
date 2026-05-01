import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { MemoryTimeline } from './memory-timeline'

describe('MemoryTimeline', () => {
  it('renders 24 bars', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [] }), container)
    const bars = container.querySelectorAll('[role="graphics-symbol"]')
    expect(bars.length).toBe(24)
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [], testId: 'timeline-1' }), container)
    expect(container.querySelector('[data-testid="timeline-1"]')).not.toBeNull()
  })

  it('has aria-label on img role container', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [] }), container)
    const img = container.querySelector('[role="img"]')
    expect(img?.getAttribute('aria-label')).toBe('시간대별 메모리 접근 패턴')
  })

  it('renders legend labels', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [] }), container)
    expect(container.textContent).toContain('읽기')
    expect(container.textContent).toContain('쓰기')
    expect(container.textContent).toContain('검색')
  })

  it('aggregates entries by hour', () => {
    const container = document.createElement('div')
    const now = new Date()
    now.setHours(14, 0, 0, 0)
    render(
      h(MemoryTimeline, {
        entries: [
          { timestamp: now.getTime(), memoryId: 'a', accessType: 'read' },
          { timestamp: now.getTime() + 60000, memoryId: 'b', accessType: 'read' },
        ],
      }),
      container,
    )
    const bars = container.querySelectorAll('[role="graphics-symbol"]')
    const bar14 = bars[14] as HTMLElement
    expect(bar14?.getAttribute('aria-label')).toBe('14시: 2회')
    expect(bar14?.getAttribute('title')).toBe('14시 — 2회 접근')
  })

  it('uses different colors per access type', () => {
    const container = document.createElement('div')
    const t = new Date().getTime()
    render(
      h(MemoryTimeline, {
        entries: [
          { timestamp: t, memoryId: 'a', accessType: 'write' },
          { timestamp: t + 3600000, memoryId: 'b', accessType: 'search' },
        ],
      }),
      container,
    )
    const bars = container.querySelectorAll('[role="graphics-symbol"]')
    const hour0 = new Date(t).getHours()
    const bar0 = bars[hour0] as HTMLElement
    expect(bar0?.style.background).toBe('var(--warn-10)')
    const hour1 = new Date(t + 3600000).getHours()
    const bar1 = bars[hour1] as HTMLElement
    expect(bar1?.style.background).toBe('var(--color-accent)')
  })

  it('shows max count in legend', () => {
    const container = document.createElement('div')
    const t = new Date().getTime()
    render(
      h(MemoryTimeline, {
        entries: [
          { timestamp: t, memoryId: 'a', accessType: 'read' },
          { timestamp: t, memoryId: 'b', accessType: 'read' },
          { timestamp: t, memoryId: 'c', accessType: 'read' },
        ],
      }),
      container,
    )
    expect(container.textContent).toContain('최대 3회')
  })
})
