import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { MemoryGraph } from './memory-graph'

describe('MemoryGraph', () => {
  it('renders empty state when no nodes', () => {
    const container = document.createElement('div')
    render(h(MemoryGraph, { nodes: [], edges: [] }), container)
    expect(container.textContent).toContain('노드가 없습니다')
    const el = container.querySelector('[role="img"]')
    expect(el).not.toBeNull()
  })

  it('renders svg with nodes and edges', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [
          { id: 'a', label: 'Alpha', x: 50, y: 50 },
          { id: 'b', label: 'Beta', x: 150, y: 50 },
        ],
        edges: [{ source: 'a', target: 'b' }],
      }),
      container,
    )
    expect(container.querySelector('svg')).not.toBeNull()
    expect(container.querySelectorAll('circle').length).toBe(2)
    expect(container.querySelectorAll('line').length).toBe(1)
  })

  it('truncates labels to 3 chars', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [{ id: 'a', label: 'Alpha', x: 50, y: 50 }],
        edges: [],
      }),
      container,
    )
    expect(container.textContent).toContain('Alp')
    expect(container.textContent).not.toContain('Alpha')
  })

  it('calls onSelectNode on click', () => {
    const onSelectNode = vi.fn()
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [{ id: 'a', label: 'Alpha', x: 50, y: 50 }],
        edges: [],
        onSelectNode,
      }),
      container,
    )
    const g = container.querySelector('g.cursor-pointer') as SVGGElement
    g?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(onSelectNode).toHaveBeenCalledWith('a')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [],
        edges: [],
        testId: 'mem-graph',
      }),
      container,
    )
    expect(container.querySelector('[data-testid="mem-graph"]')).not.toBeNull()
  })

  it('skips edges with missing nodes', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [{ id: 'a', label: 'Alpha', x: 50, y: 50 }],
        edges: [{ source: 'a', target: 'missing' }],
      }),
      container,
    )
    expect(container.querySelectorAll('line').length).toBe(0)
  })

  it('respects node colors', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [{ id: 'a', label: 'A', x: 50, y: 50, color: '#ff0000' }],
        edges: [],
      }),
      container,
    )
    const circle = container.querySelector('circle') as SVGCircleElement
    expect(circle?.getAttribute('fill')).toBe('#ff0000')
  })
})
