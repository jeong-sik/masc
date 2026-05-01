import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentMemory } from './agent-memory'

const entries = [
  { id: 'e1', content: 'recent', type: 'short_term' as const, timestamp: Date.now() },
  { id: 'e2', content: 'older', type: 'short_term' as const, timestamp: Date.now() - 60000 },
  { id: 'e3', content: 'cluster-a-1', type: 'long_term' as const, timestamp: Date.now(), cluster: 'A' },
  { id: 'e4', content: 'cluster-a-2', type: 'long_term' as const, timestamp: Date.now(), cluster: 'A' },
]

describe('AgentMemory', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries: [] }), container)
    expect(container.querySelector('[data-agent-memory]')).not.toBeNull()
  })

  it('renders short term section', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    expect(container.textContent).toContain('단기 기억')
  })

  it('renders long term section', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    expect(container.textContent).toContain('장기 기억')
  })

  it('renders short term entries', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    expect(container.textContent).toContain('recent')
    expect(container.textContent).toContain('older')
  })

  it('sorts short term by recency', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    const list = container.querySelector('[aria-label="단기 기억 목록"]')
    const items = list?.querySelectorAll('[role="listitem"]')
    expect(items?.length).toBe(2)
  })

  it('renders long term clusters', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    expect(container.textContent).toContain('A')
  })

  it('renders unclustered as 미분류', () => {
    const container = document.createElement('div')
    const unc = [{ id: 'e5', content: 'x', type: 'long_term' as const, timestamp: Date.now() }]
    render(h(AgentMemory, { entries: unc }), container)
    expect(container.textContent).toContain('미분류')
  })

  it('renders similarity title when provided', () => {
    const container = document.createElement('div')
    const sim = [{ id: 'e6', content: 'similar', type: 'long_term' as const, timestamp: Date.now(), similarity: 0.85 }]
    render(h(AgentMemory, { entries: sim }), container)
    const span = container.querySelector('span[title]') as HTMLElement
    expect(span?.getAttribute('title')).toContain('85.0')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries: [], testId: 'am-1' }), container)
    expect(container.querySelector('[data-testid="am-1"]')).not.toBeNull()
  })

  it('limits short term to 10 entries', () => {
    const container = document.createElement('div')
    const many = Array.from({ length: 15 }, (_, i) => ({
      id: `e${i}`,
      content: `item-${i}`,
      type: 'short_term' as const,
      timestamp: Date.now() - i * 1000,
    }))
    render(h(AgentMemory, { entries: many }), container)
    const list = container.querySelector('[aria-label="단기 기억 목록"]')
    expect(list?.querySelectorAll('[role="listitem"]').length).toBe(10)
  })
})
