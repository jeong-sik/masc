import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  formatSimilarityPercent,
  MemorySearch,
  normalizeSimilarity,
  summarizeMemorySearchResults,
} from './memory-search'

describe('MemorySearch', () => {
  it('normalizes similarity values for display and progress bars', () => {
    expect(normalizeSimilarity(1.2)).toBe(1)
    expect(normalizeSimilarity(-0.4)).toBe(0)
    expect(normalizeSimilarity(Number.NaN)).toBe(0)
    expect(formatSimilarityPercent(0.924)).toBe('92%')
  })

  it('summarizes result and cluster metadata', () => {
    expect(summarizeMemorySearchResults([
      { id: '1', content: 'memory one', similarity: 0.85, cluster: 'A' },
      { id: '2', content: 'memory two', similarity: 0.62, cluster: 'B' },
      { id: '3', content: 'memory three', similarity: 0.91, cluster: 'A' },
    ])).toEqual({
      resultCount: 3,
      topSimilarity: 0.91,
      averageSimilarity: (0.85 + 0.62 + 0.91) / 3,
      clusterCount: 2,
      clusters: [
        { cluster: 'A', count: 2, topSimilarity: 0.91 },
        { cluster: 'B', count: 1, topSimilarity: 0.62 },
      ],
    })
  })

  it('renders input with query', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { query: 'hello' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.value).toBe('hello')
  })

  it('syncs input when controlled query changes', async () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { query: 'hello' }), container)
    render(h(MemorySearch, { query: 'updated' }), container)
    await new Promise((r) => setTimeout(r, 10))
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.value).toBe('updated')
  })

  it('calls onQueryChange on input', () => {
    const onQueryChange = vi.fn()
    const container = document.createElement('div')
    render(h(MemorySearch, { onQueryChange }), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'test'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    expect(onQueryChange).toHaveBeenCalledWith('test')
  })

  it('shows loading indicator', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { loading: true }), container)
    expect(container.textContent).toContain('검색 중...')
  })

  it('renders results with similarity bars', () => {
    const container = document.createElement('div')
    render(
      h(MemorySearch, {
        results: [
          { id: '1', content: 'memory one', similarity: 0.85, cluster: 'A' },
          { id: '2', content: 'memory two', similarity: 0.62, cluster: 'B' },
        ],
      }),
      container,
    )
    expect(container.textContent).toContain('memory one')
    expect(container.textContent).toContain('memory two')
    expect(container.textContent).toContain('85%')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
    expect(container.querySelectorAll('[role="progressbar"]').length).toBe(2)
  })

  it('renders summary and cluster metadata', () => {
    const container = document.createElement('div')
    render(
      h(MemorySearch, {
        results: [
          { id: '1', content: 'memory one', similarity: 0.85, cluster: 'A' },
          { id: '2', content: 'memory two', similarity: 0.62, cluster: 'B' },
          { id: '3', content: 'memory three', similarity: 0.91, cluster: 'A' },
        ],
      }),
      container,
    )
    const root = container.querySelector('[data-memory-search]')
    const summary = container.querySelector('[data-memory-search-summary]')
    const cluster = container.querySelector('[data-memory-search-cluster="A"]')
    expect(root?.getAttribute('data-memory-search-result-count')).toBe('3')
    expect(root?.getAttribute('data-memory-search-cluster-count')).toBe('2')
    expect(root?.getAttribute('data-memory-search-top-similarity')).toBe('91')
    expect(summary?.textContent).toContain('결과 3개')
    expect(summary?.textContent).toContain('최고 91%')
    expect(summary?.textContent).toContain('클러스터 2개')
    expect(cluster?.getAttribute('data-memory-search-cluster-count')).toBe('2')
    expect(cluster?.textContent).toContain('A 2 · 91%')
  })

  it('clamps row progress and annotates result rank metadata', () => {
    const container = document.createElement('div')
    render(
      h(MemorySearch, {
        results: [
          { id: '1', content: 'too high', similarity: 1.5, cluster: 'A' },
          { id: '2', content: 'too low', similarity: -0.5, cluster: 'B' },
        ],
      }),
      container,
    )
    const rows = container.querySelectorAll('[role="listitem"]')
    const firstProgress = rows[0]?.querySelector('[role="progressbar"]') as HTMLElement
    const secondProgress = rows[1]?.querySelector('[role="progressbar"]') as HTMLElement
    expect(rows[0]?.getAttribute('data-memory-search-result-rank')).toBe('1')
    expect(rows[0]?.getAttribute('data-memory-search-result-similarity')).toBe('100')
    expect(rows[0]?.getAttribute('aria-label')).toContain('유사도 100%')
    expect(firstProgress?.getAttribute('aria-valuenow')).toBe('100')
    expect(firstProgress?.style.width).toBe('100%')
    expect(secondProgress?.getAttribute('aria-valuenow')).toBe('0')
    expect(secondProgress?.style.width).toBe('0%')
  })

  it('renders an empty state for non-loading searches with no results', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { query: 'missing', results: [] }), container)
    expect(container.textContent).toContain('검색 결과 없음')
    expect(container.querySelector('[role="status"]')?.textContent).toBe('검색 결과 없음')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { testId: 'mem-search' }), container)
    expect(container.querySelector('[data-testid="mem-search"]')).not.toBeNull()
  })

  it('renders empty results without error', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { results: [] }), container)
    expect(container.querySelector('[role="list"]')).not.toBeNull()
  })

  it('has aria-label on input', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, {}), container)
    const input = container.querySelector('input') as HTMLInputElement
    const summary = container.querySelector('[data-memory-search-summary]')
    expect(input?.getAttribute('aria-label')).toBe('메모리 검색')
    expect(input?.getAttribute('aria-describedby')).toBe(summary?.id)
    expect(summary?.id).toContain('memory-search-summary')
  })

  it('renders result listitems with role', () => {
    const container = document.createElement('div')
    render(
      h(MemorySearch, {
        results: [{ id: '1', content: 'x', similarity: 0.5, cluster: 'C' }],
      }),
      container,
    )
    expect(container.querySelector('[role="listitem"]')).not.toBeNull()
  })
})
