import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { EventStream } from './event-stream'

const baseEvents = [
  { id: 'e1', timestamp: new Date('2024-01-01T09:30:00').getTime(), level: 'info' as const, message: 'started', source: 'agent-a' },
  { id: 'e2', timestamp: new Date('2024-01-01T09:31:00').getTime(), level: 'warn' as const, message: 'slow', source: 'agent-b' },
  { id: 'e3', timestamp: new Date('2024-01-01T09:32:00').getTime(), level: 'error' as const, message: 'failed' },
]

describe('EventStream', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.querySelector('[data-event-stream]')).not.toBeNull()
  })

  it('renders log role', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-label')).toBe('이벤트 스트림')
  })

  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [] }), container)
    expect(container.textContent).toContain('이벤트 없음')
  })

  it('renders events', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('started')
    expect(container.textContent).toContain('slow')
    expect(container.textContent).toContain('failed')
  })

  it('renders source labels', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('agent-a')
    expect(container.textContent).toContain('agent-b')
  })

  it('renders timestamps', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('09:30:00')
    expect(container.textContent).toContain('09:31:00')
  })

  it('renders listitems', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)
  })

  it('reverses order (newest first)', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items[0]?.textContent).toContain('failed')
    expect(items[2]?.textContent).toContain('started')
  })

  it('limits to maxItems', () => {
    const container = document.createElement('div')
    const many = Array.from({ length: 10 }, (_, i) => ({
      id: `e${i}`,
      timestamp: Date.now() + i * 1000,
      level: 'info' as const,
      message: `msg-${i}`,
    }))
    render(h(EventStream, { events: many, maxItems: 5 }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(5)
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: [], testId: 'es-1' }), container)
    expect(container.querySelector('[data-testid="es-1"]')).not.toBeNull()
  })

  it('renders sr-only level labels', () => {
    const container = document.createElement('div')
    render(h(EventStream, { events: baseEvents }), container)
    expect(container.textContent).toContain('정보')
    expect(container.textContent).toContain('경고')
    expect(container.textContent).toContain('에러')
  })
})
