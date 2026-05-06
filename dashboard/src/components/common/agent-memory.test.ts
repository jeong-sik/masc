import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentMemory,
  getVisibleShortTermMemory,
  groupByCluster,
  summarizeAgentMemory,
} from './agent-memory'

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
    const root = container.querySelector('[data-agent-memory]') as HTMLElement
    expect(root).not.toBeNull()
    expect(root.dataset.agentMemoryStatus).toBe('empty')
    expect(root.dataset.agentMemoryTotalCount).toBe('0')
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
    expect(container.textContent).toContain('1개 클러스터')
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
    expect((items?.[0] as HTMLElement).dataset.memoryEntryId).toBe('e1')
    expect((items?.[0] as HTMLElement).dataset.memoryEntryRecencyIndex).toBe('0')
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
    const root = container.querySelector('[data-agent-memory]') as HTMLElement
    expect(root.dataset.agentMemoryUnclusteredCount).toBe('1')
  })

  it('renders similarity title when provided', () => {
    const container = document.createElement('div')
    const sim = [{ id: 'e6', content: 'similar', type: 'long_term' as const, timestamp: Date.now(), similarity: 0.85 }]
    render(h(AgentMemory, { entries: sim }), container)
    const span = container.querySelector('span[title]') as HTMLElement
    expect(span?.getAttribute('title')).toContain('85.0')
    expect(span.dataset.memoryEntrySimilarity).toBe('0.85')
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
    const root = container.querySelector('[data-agent-memory]') as HTMLElement
    expect(root.dataset.agentMemoryShortTermCount).toBe('15')
    expect(root.dataset.agentMemoryVisibleShortTermCount).toBe('10')
    expect(root.dataset.agentMemoryHiddenShortTermCount).toBe('5')
  })

  it('exposes memory summary metadata', () => {
    const container = document.createElement('div')
    render(h(AgentMemory, { entries }), container)
    const root = container.querySelector('[data-agent-memory]') as HTMLElement
    const shortList = container.querySelector('[data-memory-section="short_term"]') as HTMLElement
    const longList = container.querySelector('[data-memory-section="long_term"]') as HTMLElement

    expect(root.dataset.agentMemoryStatus).toBe('mixed')
    expect(root.dataset.agentMemoryTotalCount).toBe('4')
    expect(root.dataset.agentMemoryShortTermCount).toBe('2')
    expect(root.dataset.agentMemoryLongTermCount).toBe('2')
    expect(root.dataset.agentMemoryClusterCount).toBe('1')
    expect(shortList.dataset.memorySectionVisibleCount).toBe('2')
    expect(longList.dataset.memorySectionClusterCount).toBe('1')
  })

  it('summarizes memory statuses and clusters', () => {
    expect(summarizeAgentMemory([])).toMatchObject({
      totalCount: 0,
      status: 'empty',
    })
    expect(summarizeAgentMemory(entries.slice(0, 2))).toMatchObject({
      shortTermCount: 2,
      status: 'short_only',
    })
    expect(summarizeAgentMemory(entries.slice(2))).toMatchObject({
      longTermCount: 2,
      clusterCount: 1,
      status: 'long_only',
    })
    expect(groupByCluster(entries.slice(2)).A?.length).toBe(2)
    expect(getVisibleShortTermMemory(entries).map(entry => entry.id)).toEqual(['e1', 'e2'])
  })

  it('ignores invalid timestamps when summarizing latest memory', () => {
    const summary = summarizeAgentMemory([
      { id: 'bad', content: 'bad', type: 'long_term', timestamp: Number.NaN },
      { id: 'ok', content: 'ok', type: 'short_term', timestamp: 42 },
      { id: 'infinite', content: 'infinite', type: 'short_term', timestamp: Infinity },
    ])

    expect(summary.latestTimestamp).toBe(42)
  })
})
