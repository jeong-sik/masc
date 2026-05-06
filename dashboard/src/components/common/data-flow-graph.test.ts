import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  DataFlowGraph,
  getRenderableFlowEdges,
  summarizeDataFlowGraph,
} from './data-flow-graph'

describe('DataFlowGraph', () => {
  const nodes = [
    { id: 'a', label: 'A', x: 10, y: 10, width: 40, height: 30 },
    { id: 'b', label: 'B', x: 100, y: 10, width: 40, height: 30 },
  ]

  it('renders empty state when no nodes', () => {
    const container = document.createElement('div')
    render(h(DataFlowGraph, { nodes: [], edges: [] }), container)
    expect(container.textContent).toContain('노드가 없습니다')
    const el = container.querySelector('[role="img"]')
    expect(el).not.toBeNull()
    expect((el as HTMLElement).dataset.dataFlowGraphStatus).toBe('empty')
    expect((el as HTMLElement).dataset.dataFlowGraphNodeCount).toBe('0')
  })

  it('renders svg with nodes and edges', () => {
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes,
        edges: [{ source: 'a', target: 'b', value: 5 }],
      }),
      container,
    )
    const root = container.querySelector('[data-data-flow-graph]') as HTMLElement
    expect(container.querySelector('svg')).not.toBeNull()
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
    expect(container.textContent).toContain('노드')
    expect(root.dataset.dataFlowGraphStatus).toBe('connected')
    expect(root.dataset.dataFlowGraphNodeCount).toBe('2')
    expect(root.dataset.dataFlowGraphValidEdgeCount).toBe('1')
    expect(root.dataset.dataFlowGraphTotalValue).toBe('5')
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
    const root = container.querySelector('[data-data-flow-graph]') as HTMLElement
    expect(paths.length).toBe(0)
    expect(root.dataset.dataFlowGraphStatus).toBe('partial')
    expect(root.dataset.dataFlowGraphMissingEdgeCount).toBe('1')
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
    expect(path?.getAttribute('data-flow-edge-source')).toBe('a')
    expect(path?.getAttribute('data-flow-edge-target')).toBe('b')
    expect(path?.getAttribute('data-flow-edge-value')).toBe('1')
  })

  it('marks nodes with incoming and outgoing totals', () => {
    const container = document.createElement('div')
    render(
      h(DataFlowGraph, {
        nodes,
        edges: [{ source: 'a', target: 'b', value: 5 }],
      }),
      container,
    )
    const source = container.querySelector('[data-flow-node-id="a"]') as HTMLElement
    const target = container.querySelector('[data-flow-node-id="b"]') as HTMLElement

    expect(source.dataset.flowNodeOutgoing).toBe('5')
    expect(source.dataset.flowNodeIncoming).toBe('0')
    expect(target.dataset.flowNodeIncoming).toBe('5')
    expect(target.dataset.flowNodeOutgoing).toBe('0')
  })

  it('summarizes renderable and missing edges', () => {
    const edges = [
      { source: 'a', target: 'b', value: 5 },
      { source: 'a', target: 'missing', value: 2 },
    ]
    const summary = summarizeDataFlowGraph(nodes, edges)

    expect(summary).toEqual({
      nodeCount: 2,
      edgeCount: 2,
      validEdgeCount: 1,
      missingEdgeCount: 1,
      totalValue: 5,
      maxValue: 5,
      status: 'partial',
    })
    expect(getRenderableFlowEdges(nodes, edges).length).toBe(1)
  })

  it('summarizes disconnected nodes', () => {
    const summary = summarizeDataFlowGraph(nodes, [])

    expect(summary.status).toBe('disconnected')
    expect(summary.validEdgeCount).toBe(0)
    expect(summary.maxValue).toBe(1)
  })
})
