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
    expect(input).not.toBeNull()
    expect(input?.getAttribute('aria-label')).toBe('메모리 검색')
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
})
