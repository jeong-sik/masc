import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { DataFlowGraph } from './data-flow-graph'

describe('DataFlowGraph', () => {
  it('renders empty state when no nodes', () => {
    const container = document.createElement('div')
    render(h(DataFlowGraph, { nodes: [], edges: [] }), container)
    expect(container.textContent).toContain('노드가 없습니다')
    const el = container.querySelector('[role="img"]')
    expect(el).not.toBeNull()
  })

  it('renders svg with nodes and edges', () => {
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes: [
          { id: 'a', label: 'A', x: 10, y: 10, width: 40, height: 30 },
          { id: 'b', label: 'B', x: 100, y: 10, width: 40, height: 30 },
        ],
        edges: [{ source: 'a', target: 'b', value: 5 }],
      }),
      container,
    )
    expect(container.querySelector('svg')).not.toBeNull()
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
  })

  it('calls onSelectNode on node click', () => {
    const onSelectNode = vi.fn()
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes: [{ id: 'a', label: 'A', x: 10, y: 10, width: 40, height: 30 }],
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
      h(DataFlowGraph, {
        nodes: [],
        edges: [],
        testId: 'flow-graph',
      }),
      container,
    )
    expect(container.querySelector('[data-testid="flow-graph"]')).not.toBeNull()
  })

  it('skips edges with missing nodes', () => {
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes: [{ id: 'a', label: 'A', x: 10, y: 10, width: 40, height: 30 }],
        edges: [{ source: 'a', target: 'missing', value: 1 }],
      }),
      container,
    )
    const paths = container.querySelectorAll('path')
    expect(paths.length).toBe(0)
  })

  it('respects edge colors', () => {
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes: [
          { id: 'a', label: 'A', x: 10, y: 10, width: 40, height: 30 },
          { id: 'b', label: 'B', x: 100, y: 10, width: 40, height: 30 },
        ],
        edges: [{ source: 'a', target: 'b', value: 1, color: '#ff0000' }],
      }),
      container,
    )
    const path = container.querySelector('path') as SVGPathElement
    expect(path?.getAttribute('stroke')).toBe('#ff0000')
  })
})
