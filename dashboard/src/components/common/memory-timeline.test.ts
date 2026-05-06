import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  buildMemoryTimelineHeatmap,
  MemoryTimeline,
  summarizeMemoryTimeline,
} from './memory-timeline'

describe('MemoryTimeline', () => {
  it('summarizes totals, unique memories, peak hour, and access type mix', () => {
    const base = new Date()
    base.setHours(9, 0, 0, 0)

    expect(summarizeMemoryTimeline([
      { timestamp: base.getTime(), memoryId: 'a', accessType: 'read' },
      { timestamp: base.getTime() + 60000, memoryId: 'b', accessType: 'write' },
      { timestamp: base.getTime() + 120000, memoryId: 'a', accessType: 'search' },
    ])).toEqual({
      totalAccesses: 3,
      uniqueMemoryCount: 2,
      peakHour: 9,
      peakCount: 3,
      typeCounts: { read: 1, write: 1, search: 1 },
    })
  })

  it('builds dominant hourly heatmap metadata', () => {
    const base = new Date()
    base.setHours(9, 0, 0, 0)
    const heatmap = buildMemoryTimelineHeatmap([
      { timestamp: base.getTime(), memoryId: 'a', accessType: 'read' },
      { timestamp: base.getTime() + 60000, memoryId: 'b', accessType: 'write' },
      { timestamp: base.getTime() + 120000, memoryId: 'c', accessType: 'write' },
    ])

    expect(heatmap).toHaveLength(24)
    expect(heatmap[9]).toMatchObject({
      hour: 9,
      count: 3,
      intensity: 1,
      dominantType: 'write',
      uniqueMemoryCount: 3,
      typeCounts: { read: 1, write: 2, search: 0 },
    })
  })

  it('keeps empty hours unclassified instead of marking them as read dominant', () => {
    const heatmap = buildMemoryTimelineHeatmap([])
    expect(heatmap[0]).toMatchObject({
      hour: 0,
      count: 0,
      intensity: 0,
      dominantType: null,
      uniqueMemoryCount: 0,
    })
  })

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
    expect(img?.getAttribute('aria-label')).toBe('시간대별 메모리 접근 패턴, 접근 없음')
  })

  it('renders legend labels', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [] }), container)
    expect(container.textContent).toContain('읽기 0')
    expect(container.textContent).toContain('쓰기 0')
    expect(container.textContent).toContain('검색 0')
  })

  it('renders summary chips', () => {
    const container = document.createElement('div')
    const now = new Date()
    now.setHours(14, 0, 0, 0)
    render(
      h(MemoryTimeline, {
        entries: [
          { timestamp: now.getTime(), memoryId: 'a', accessType: 'read' },
          { timestamp: now.getTime() + 60000, memoryId: 'b', accessType: 'search' },
        ],
      }),
      container,
    )
    const summary = container.querySelector('[data-memory-timeline-summary]')
    expect(summary?.getAttribute('data-memory-timeline-total')).toBe('2')
    expect(summary?.getAttribute('data-memory-timeline-unique')).toBe('2')
    expect(summary?.getAttribute('data-memory-timeline-peak-hour')).toBe('14')
    expect(summary?.textContent).toContain('피크 14시 · 2회')
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
    expect(bar14?.getAttribute('aria-label')).toBe('14시: 2회, 읽기 우세, 고유 메모리 2개')
    expect(bar14?.getAttribute('title')).toBe('14시 — 2회 접근 · 읽기 우세 · 2개 메모리')
    expect(bar14?.getAttribute('data-memory-timeline-count')).toBe('2')
    expect(bar14?.getAttribute('data-memory-timeline-dominant-type')).toBe('read')
    expect(bar14?.getAttribute('data-memory-timeline-unique')).toBe('2')
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
    expect(bar0?.getAttribute('data-memory-timeline-dominant-type')).toBe('write')
    const hour1 = new Date(t + 3600000).getHours()
    const bar1 = bars[hour1] as HTMLElement
    expect(bar1?.style.background).toBe('var(--color-accent)')
    expect(bar1?.getAttribute('data-memory-timeline-dominant-type')).toBe('search')
  })

  it('labels empty hours as no access', () => {
    const container = document.createElement('div')
    render(h(MemoryTimeline, { entries: [] }), container)
    const firstBar = container.querySelector('[data-memory-timeline-hour="0"]')
    expect(firstBar?.getAttribute('aria-label')).toBe('0시: 접근 없음')
    expect(firstBar?.getAttribute('title')).toBe('0시 — 접근 없음')
    expect(firstBar?.getAttribute('data-memory-timeline-dominant-type')).toBe('')
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
