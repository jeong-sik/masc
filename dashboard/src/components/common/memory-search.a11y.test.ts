// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MemorySearch } from './memory-search'

describe('MemorySearch a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeResults = (): import('./memory-search').MemorySearchResult[] => [
    { id: 'r1', content: '파일 읽기 기억', similarity: 0.92, cluster: 'io' },
    { id: 'r2', content: '사용자 설정 A', similarity: 0.78, cluster: 'prefs' },
    { id: 'r3', content: 'DB 스키마 v2', similarity: 0.65, cluster: 'schema' },
  ]

  it('renders accessibly with results', async () => {
    render(
      html`<${MemorySearch}
        query="memory"
        results=${makeResults()}
        onQueryChange=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty results', async () => {
    render(
      html`<${MemorySearch} query="" results=${[]} />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly while loading', async () => {
    render(
      html`<${MemorySearch}
        query="test"
        loading=${true}
        results=${[]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has search input with aria-label', () => {
    render(html`<${MemorySearch} />`, container)
    const input = container.querySelector('input')
    const summary = container.querySelector('[data-memory-search-summary]')
    expect(input).not.toBeNull()
    expect(input?.getAttribute('type')).toBe('search')
    expect(input?.getAttribute('aria-label')).toBe('메모리 검색')
    expect(input?.getAttribute('aria-describedby')).toBe(summary?.id)
  })

  it('renders similarity bars', () => {
    render(html`<${MemorySearch} results=${makeResults()} />`, container)
    expect(container.textContent).toContain('92%')
    expect(container.textContent).toContain('파일 읽기 기억')
    expect(container.textContent).toContain('io')
  })

  it('has list role for results', () => {
    render(html`<${MemorySearch} results=${makeResults()} />`, container)
    expect(container.querySelector('[role="list"]')).not.toBeNull()
  })

  it('exposes result summary and cluster metadata', () => {
    render(html`<${MemorySearch} results=${makeResults()} />`, container)
    const root = container.querySelector('[data-memory-search]')
    const summary = container.querySelector('[data-memory-search-summary]')
    const clusters = container.querySelector('[data-memory-search-clusters]')
    expect(root?.getAttribute('data-memory-search-result-count')).toBe('3')
    expect(root?.getAttribute('data-memory-search-cluster-count')).toBe('3')
    expect(root?.getAttribute('data-memory-search-top-similarity')).toBe('92')
    expect(summary?.textContent).toContain('결과 3개')
    expect(clusters?.getAttribute('aria-label')).toBe('관련 메모리 클러스터')
    expect(container.querySelector('[data-memory-search-cluster="io"]')?.textContent).toContain('io 1 · 92%')
  })

  it('labels result rows with rank, similarity, and cluster', () => {
    render(html`<${MemorySearch} results=${makeResults()} />`, container)
    const row = container.querySelector('[data-memory-search-result-id="r1"]')
    expect(row?.getAttribute('data-memory-search-result-rank')).toBe('1')
    expect(row?.getAttribute('data-memory-search-result-cluster')).toBe('io')
    expect(row?.getAttribute('data-memory-search-result-similarity')).toBe('92')
    expect(row?.getAttribute('aria-label')).toBe('1위 파일 읽기 기억, 유사도 92%, 클러스터 io')
  })

  it('uses accessible progressbar semantics for similarity', () => {
    render(html`<${MemorySearch} results=${makeResults()} />`, container)
    const progress = container.querySelector('[role="progressbar"]')
    expect(progress?.getAttribute('aria-valuemin')).toBe('0')
    expect(progress?.getAttribute('aria-valuemax')).toBe('100')
    expect(progress?.getAttribute('aria-valuenow')).toBe('92')
    expect(progress?.getAttribute('aria-label')).toBe('파일 읽기 기억 유사도')
  })
})
