import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { Tree } from './tree'

describe('Tree', () => {
  const nodes = [
    {
      id: 'a',
      label: 'A',
      children: [
        { id: 'a1', label: 'A1' },
        { id: 'a2', label: 'A2' },
      ],
    },
    { id: 'b', label: 'B' },
  ]

  it('renders tree role', () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes }), container)
    expect(container.querySelector('[role="tree"]')).not.toBeNull()
  })

  it('renders top-level nodes', () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBe(2)
    expect(container.textContent).toContain('A')
    expect(container.textContent).toContain('B')
  })

  it('expands on click to show children', async () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    ;(items[0] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    const allItems = container.querySelectorAll('[role="treeitem"]')
    expect(allItems.length).toBe(4)
    expect(container.textContent).toContain('A1')
    expect(container.textContent).toContain('A2')
  })

  it('collapses on second click', async () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    ;(items[0] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    ;(items[0] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    const allItems = container.querySelectorAll('[role="treeitem"]')
    expect(allItems.length).toBe(2)
  })

  it('calls onSelect on click', async () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(Tree, { nodes, onSelect }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    ;(items[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith('b')
  })

  it('marks selected node', () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes, selectedId: 'b' }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items[1]?.getAttribute('aria-selected')).toBe('true')
    expect(items[0]?.getAttribute('aria-selected')).toBe('false')
  })

  it('applies aria-expanded to expandable nodes', async () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items[0]?.getAttribute('aria-expanded')).toBe('false')
    expect(items[1]?.hasAttribute('aria-expanded')).toBe(false)
  })

  it('applies aria-label', () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes, 'aria-label': 'my tree' }), container)
    const tree = container.querySelector('[role="tree"]')
    expect(tree?.getAttribute('aria-label')).toBe('my tree')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(Tree, { nodes, testId: 'tree-1' }), container)
    expect(container.querySelector('[data-testid="tree-1"]')).not.toBeNull()
  })

  it('navigates with ArrowDown', async () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(Tree, { nodes, selectedId: 'a', onSelect }), container)
    const tree = container.querySelector('[role="tree"]') as HTMLElement
    const ev = new Event('keydown', { bubbles: true })
    ;(ev as any).key = 'ArrowDown'
    tree.dispatchEvent(ev)
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith('b')
  })
})
