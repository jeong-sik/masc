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
    const fig = container.querySelector('figure[aria-label="데이터 흐름 그래프"]')
    expect(fig).not.toBeNull()
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
})
