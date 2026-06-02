// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { MemoryGraph } from './memory-graph'

describe('MemoryGraph a11y', () => {
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
      { id: 'n1', label: 'Memory A', x: 50, y: 50 },
      { id: 'n2', label: 'Memory B', x: 150, y: 100 },
      { id: 'n3', label: 'Memory C', x: 80, y: 180 },
    ],
    edges: [
      { source: 'n1', target: 'n2' },
      { source: 'n2', target: 'n3' },
    ],
  })

  it('renders accessibly with nodes', async () => {
    const { nodes, edges } = makeData()
    render(html`<${MemoryGraph} nodes=${nodes} edges=${edges} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with selectable nodes', async () => {
    const { nodes, edges } = makeData()
    render(
      html`<${MemoryGraph} nodes=${nodes} edges=${edges} onSelectNode=${vi.fn()} />`,
      container,
    )
    expect(container.querySelector('svg')?.getAttribute('role')).toBe('group')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${MemoryGraph} nodes=${[]} edges=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has aria-label on figure', () => {
    const { nodes, edges } = makeData()
    render(html`<${MemoryGraph} nodes=${nodes} edges=${edges} />`, container)
    const fig = container.querySelector('figure[aria-label="메모리 그래프"]')
    expect(fig).not.toBeNull()
  })

  it('calls onSelectNode when clicked', () => {
    const onSelect = vi.fn()
    const { nodes, edges } = makeData()
    render(
      html`<${MemoryGraph} nodes=${nodes} edges=${edges} onSelectNode=${onSelect} />`,
      container,
    )
    const node = container.querySelector('svg g[transform]') as HTMLElement
    node.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(onSelect).toHaveBeenCalledWith('n1')
  })
})
