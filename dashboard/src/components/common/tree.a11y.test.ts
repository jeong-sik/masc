// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { axe } from 'jest-axe'
import { Tree } from './tree'

const NODES = [
  {
    id: 'root1',
    label: 'Root 1',
    children: [
      { id: 'child1', label: 'Child 1' },
      { id: 'child2', label: 'Child 2', children: [{ id: 'grand1', label: 'Grand 1' }] },
    ],
  },
  { id: 'root2', label: 'Root 2' },
]

function StatefulTree({ nodes, initial }: { nodes: typeof NODES; initial?: string }) {
  const [selectedId, setSelectedId] = useState(initial)
  return html`<${Tree} nodes=${nodes} selectedId=${selectedId} onSelect=${setSelectedId} aria-label="Files" />`
}

describe('Tree a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly', async () => {
    render(html`<${Tree} nodes=${NODES} aria-label="Files" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has tree role and aria-label', () => {
    render(html`<${Tree} nodes=${NODES} aria-label="Files" />`, container)
    const tree = container.querySelector('[role="tree"]')
    expect(tree).not.toBeNull()
    expect(tree?.getAttribute('aria-label')).toBe('Files')
  })

  it('treeitems have aria-selected and aria-level', () => {
    render(
      html`<${Tree} nodes=${NODES} selectedId="root1" aria-label="Files" />`,
      container,
    )
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBeGreaterThan(0)
    const selected = container.querySelector('[role="treeitem"][aria-selected="true"]')
    expect(selected?.getAttribute('aria-level')).toBe('1')
  })

  it('expands and collapses with ArrowRight and ArrowLeft', async () => {
    render(html`<${Tree} nodes=${NODES} aria-label="Files" />`, container)
    const tree = container.querySelector('[role="tree"]') as HTMLElement
    tree.focus()

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBe(4)

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBe(2)
  })

  it('navigates with ArrowDown and ArrowUp', async () => {
    render(html`<${StatefulTree} nodes=${NODES} />`, container)
    const tree = container.querySelector('[role="tree"]') as HTMLElement
    tree.focus()

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let selected = container.querySelector('[aria-selected="true"]')
    expect(selected?.querySelector("span:last-child")?.textContent?.trim()).toBe('Child 1')

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    selected = container.querySelector('[aria-selected="true"]')
    expect(selected?.querySelector("span:last-child")?.textContent?.trim()).toBe('Child 2')

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    selected = container.querySelector('[aria-selected="true"]')
    expect(selected?.querySelector("span:last-child")?.textContent?.trim()).toBe('Child 1')
  })

  it('selects on Enter and calls onSelect', async () => {
    const onSelect = vi.fn()
    render(
      html`<${Tree} nodes=${NODES} onSelect=${onSelect} aria-label="Files" />`,
      container,
    )
    const tree = container.querySelector('[role="tree"]') as HTMLElement
    tree.focus()

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith('root1')
  })

  it('jumps to first and last with Home and End', async () => {
    render(html`<${StatefulTree} nodes=${NODES} initial="root2" />`, container)
    const tree = container.querySelector('[role="tree"]') as HTMLElement
    tree.focus()

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Home', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    let selected = container.querySelector('[aria-selected="true"]')
    expect(selected?.querySelector("span:last-child")?.textContent?.trim()).toBe('Root 1')

    tree.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'End', bubbles: true }),
    )
    await new Promise((r) => setTimeout(r, 0))
    selected = container.querySelector('[aria-selected="true"]')
    expect(selected?.querySelector("span:last-child")?.textContent?.trim()).toBe('Root 2')
  })
})
