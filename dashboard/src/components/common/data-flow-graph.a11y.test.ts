// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { DataFlowGraph } from './data-flow-graph'

describe('DataFlowGraph a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeData = () => ({
    nodes: [
      { id: 'a', label: 'Agent A', x: 20, y: 40, width: 80, height: 40 },
      { id: 'b', label: 'Agent B', x: 200, y: 40, width: 80, height: 40 },
    ],
    edges: [
      { source: 'a', target: 'b', value: 10 },
    ],
  })

  it('renders accessibly with nodes', async () => {
    const { nodes, edges } = makeData()
    render(html`<${DataFlowGraph} nodes=${nodes} edges=${edges} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${DataFlowGraph} nodes=${[]} edges=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has aria-label on figure', () => {
    const { nodes, edges } = makeData()
    render(html`<${DataFlowGraph} nodes=${nodes} edges=${edges} />`, container)
    const graph = container.querySelector('figure[data-data-flow-graph]') as HTMLElement
    expect(graph).not.toBeNull()
    expect(graph.getAttribute('aria-label')).toContain('데이터 흐름 그래프')
    expect(graph.dataset.dataFlowGraphStatus).toBe('connected')
    expect(graph.dataset.dataFlowGraphValidEdgeCount).toBe('1')
  })

  it('calls onSelectNode when clicked', () => {
    const onSelect = vi.fn()
    const { nodes, edges } = makeData()
    render(
      html`<${DataFlowGraph} nodes=${nodes} edges=${edges} onSelectNode=${onSelect} />`,
      container,
    )
    const node = container.querySelector('svg g[transform]') as HTMLElement
    node.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(onSelect).toHaveBeenCalledWith('a')
  })

  it('exposes node and edge metadata', () => {
    const { nodes, edges } = makeData()
    render(html`<${DataFlowGraph} nodes=${nodes} edges=${edges} />`, container)
    const source = container.querySelector('[data-flow-node-id="a"]')
    const edge = container.querySelector('[data-flow-edge]')
    expect(source?.getAttribute('data-flow-node-label')).toBe('Agent A')
    expect(source?.getAttribute('data-flow-node-outgoing')).toBe('10')
    expect(edge?.getAttribute('data-flow-edge-source')).toBe('a')
    expect(edge?.getAttribute('data-flow-edge-target')).toBe('b')
  })

  it('announces empty state with graph metadata', () => {
    render(html`<${DataFlowGraph} nodes=${[]} edges=${[]} />`, container)
    const graph = container.querySelector('[data-data-flow-graph]') as HTMLElement
    expect(graph.dataset.dataFlowGraphStatus).toBe('empty')
    expect(graph.getAttribute('aria-label')).toContain('노드 없음')
  })
})
