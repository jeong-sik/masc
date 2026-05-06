import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { MemoryGraph, summarizeMemoryGraph } from './memory-graph'

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

  it('summarizes linked, dangling, and isolated memory graph evidence', () => {
    const summary = summarizeMemoryGraph(
      [
        { id: 'a', label: 'Alpha', x: 50, y: 50 },
        { id: 'b', label: 'Beta', x: 150, y: 50 },
        { id: 'c', label: 'Cold', x: 250, y: 50 },
      ],
      [
        { source: 'a', target: 'b' },
        { source: 'a', target: 'missing' },
      ],
    )

    expect(summary.nodeCount).toBe(3)
    expect(summary.edgeCount).toBe(2)
    expect(summary.linkedEdgeCount).toBe(1)
    expect(summary.danglingEdgeCount).toBe(1)
    expect(summary.isolatedNodeCount).toBe(1)
    expect(summary.degreeByNode.get('a')).toBe(1)
    expect(summary.degreeByNode.get('c')).toBe(0)
  })

  it('renders summary chips for graph health', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [
          { id: 'a', label: 'Alpha', x: 50, y: 50 },
          { id: 'b', label: 'Beta', x: 150, y: 50 },
          { id: 'c', label: 'Cold', x: 250, y: 50 },
        ],
        edges: [
          { source: 'a', target: 'b' },
          { source: 'a', target: 'missing' },
        ],
      }),
      container,
    )

    const chips = Array.from(container.querySelectorAll('[data-status-chip]'))
      .map(chip => [chip.textContent?.trim(), chip.getAttribute('data-status-chip-tone')])
    expect(chips).toContainEqual(['nodes 3', 'neutral'])
    expect(chips).toContainEqual(['edges 1', 'info'])
    expect(chips).toContainEqual(['isolated 1', 'warn'])
    expect(chips).toContainEqual(['dangling 1', 'bad'])
  })

  it('renders edge labels when provided', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [
          { id: 'a', label: 'Alpha', x: 50, y: 50 },
          { id: 'b', label: 'Beta', x: 150, y: 50 },
        ],
        edges: [{ source: 'a', target: 'b', label: 'recalls' }],
      }),
      container,
    )
    expect(container.querySelector('[data-memory-graph-edge-label="recalls"]')).not.toBeNull()
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

  it('calls onSelectNode from keyboard activation', () => {
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
    const node = container.querySelector('[data-memory-graph-node="a"]') as SVGGElement
    node.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    node.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(onSelectNode).toHaveBeenCalledTimes(2)
    expect(onSelectNode).toHaveBeenLastCalledWith('a')
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

  it('describes selectable nodes with connection counts', () => {
    const container = document.createElement('div')
    render(
      h(MemoryGraph, {
        nodes: [
          { id: 'a', label: 'Alpha', x: 50, y: 50 },
          { id: 'b', label: 'Beta', x: 150, y: 50 },
        ],
        edges: [{ source: 'a', target: 'b' }],
        onSelectNode: vi.fn(),
      }),
      container,
    )

    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('role')).toBe('group')
    const node = container.querySelector('[data-memory-graph-node="a"]')
    expect(node?.getAttribute('role')).toBe('button')
    expect(node?.getAttribute('tabindex')).toBe('0')
    expect(node?.getAttribute('aria-label')).toBe('Alpha, 1 connection')
    expect(node?.getAttribute('data-memory-graph-degree')).toBe('1')
    expect(node?.getAttribute('class')).not.toContain('outline-none')
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
