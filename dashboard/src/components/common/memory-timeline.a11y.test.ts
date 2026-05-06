// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MemoryTimeline } from './memory-timeline'

describe('MemoryTimeline a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeEntries = (): import('./memory-timeline').TimelineEntry[] => [
    { timestamp: Date.now() - 3600000, memoryId: 'm1', accessType: 'read' },
    { timestamp: Date.now() - 7200000, memoryId: 'm2', accessType: 'write' },
    { timestamp: Date.now() - 10800000, memoryId: 'm3', accessType: 'search' },
    { timestamp: Date.now() - 14400000, memoryId: 'm4', accessType: 'read' },
    { timestamp: Date.now() - 18000000, memoryId: 'm5', accessType: 'read' },
  ]

  it('renders accessibly with entries', async () => {
    render(html`<${MemoryTimeline} entries=${makeEntries()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty entries', async () => {
    render(html`<${MemoryTimeline} entries=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=img with aria-label', () => {
    render(html`<${MemoryTimeline} entries=${makeEntries()} />`, container)
    const img = container.querySelector('[role="img"]')
    expect(img).not.toBeNull()
    expect(img?.getAttribute('aria-label')).toContain('메모리')
    expect(img?.getAttribute('aria-label')).toContain('총 5회')
    expect(img?.getAttribute('aria-label')).toContain('고유 메모리 5개')
  })

  it('renders 24 hour bars', () => {
    render(html`<${MemoryTimeline} entries=${makeEntries()} />`, container)
    const bars = container.querySelectorAll('[role="graphics-symbol"]')
    expect(bars.length).toBe(24)
  })

  it('labels each hour with dominant access type and unique memory count', () => {
    const base = new Date()
    base.setHours(8, 0, 0, 0)
    render(html`<${MemoryTimeline}
      entries=${[
        { timestamp: base.getTime(), memoryId: 'm1', accessType: 'read' },
        { timestamp: base.getTime() + 60000, memoryId: 'm2', accessType: 'write' },
        { timestamp: base.getTime() + 120000, memoryId: 'm3', accessType: 'write' },
      ]}
    />`, container)
    const bar = container.querySelector('[data-memory-timeline-hour="8"]')
    expect(bar?.getAttribute('aria-label')).toBe('8시: 3회, 쓰기 우세, 고유 메모리 3개')
    expect(bar?.getAttribute('data-memory-timeline-dominant-type')).toBe('write')
  })

  it('exposes timeline summary metadata', () => {
    render(html`<${MemoryTimeline} entries=${makeEntries()} />`, container)
    const summary = container.querySelector('[data-memory-timeline-summary]')
    expect(summary).not.toBeNull()
    expect(summary?.getAttribute('data-memory-timeline-total')).toBe('5')
    expect(summary?.getAttribute('data-memory-timeline-unique')).toBe('5')
  })

  it('renders time labels', () => {
    render(html`<${MemoryTimeline} entries=${makeEntries()} />`, container)
    expect(container.textContent).toContain('00:00')
    expect(container.textContent).toContain('12:00')
    expect(container.textContent).toContain('23:00')
  })
})
