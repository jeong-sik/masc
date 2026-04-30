import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { MemorySearch } from './memory-search'

describe('MemorySearch', () => {
  it('renders input with query', () => {
    const container = document.createElement('div')
    render(h(MemorySearch, { query: 'hello' }), container)
    const input = container.querySelector('input') as HTMLInputElement
    expect(input?.value).toBe('hello')
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
    expect(input?.getAttribute('aria-label')).toBe('메모리 검색')
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
