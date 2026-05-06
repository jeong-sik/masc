import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { FileTree, visibleFileTreeRows } from './file-tree'

describe('FileTree', () => {
  const nodes = [
    {
      id: 'd1',
      name: 'src',
      type: 'directory' as const,
      children: [
        { id: 'f1', name: 'index.ts', type: 'file' as const, gitStatus: 'modified' as const },
      ],
    },
    { id: 'f2', name: 'README.md', type: 'file' as const },
  ]

  it('renders tree role', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes }), container)
    expect(container.querySelector('[role="tree"]')).not.toBeNull()
  })

  it('renders treeitems when expanded', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, expandedIds: ['d1'] }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items.length).toBe(3)
  })

  it('flattens visible rows with ARIA sibling metadata', () => {
    const rows = visibleFileTreeRows(nodes, new Set(['d1']))
    expect(rows.map(row => [row.node.id, row.depth, row.posInSet, row.setSize])).toEqual([
      ['d1', 0, 1, 2],
      ['f1', 1, 1, 1],
      ['f2', 0, 2, 2],
    ])
  })

  it('shows directory arrow when collapsed', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes }), container)
    expect(container.textContent).toContain('▶')
  })

  it('shows directory arrow down when expanded', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, expandedIds: ['d1'] }), container)
    expect(container.textContent).toContain('▼')
  })

  it('calls onToggle on directory click', async () => {
    const onToggle = vi.fn()
    const container = document.createElement('div')
    render(h(FileTree, { nodes, onToggle }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    ;(items[0] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onToggle).toHaveBeenCalledWith('d1')
  })

  it('supports left and right arrow directory expansion shortcuts', async () => {
    const onToggle = vi.fn()
    const container = document.createElement('div')
    render(h(FileTree, { nodes, onToggle }), container)

    const dir = container.querySelector<HTMLElement>('[data-file-tree-row="d1"]')
    dir?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onToggle).toHaveBeenCalledWith('d1')

    render(h(FileTree, { nodes, expandedIds: ['d1'], onToggle }), container)
    const expandedDir = container.querySelector<HTMLElement>('[data-file-tree-row="d1"]')
    expandedDir?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(onToggle).toHaveBeenCalledTimes(2)
  })

  it('calls onSelect on file click', async () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(FileTree, { nodes, onSelect }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    ;(items[1] as HTMLElement).click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ id: 'f2', name: 'README.md' }))
  })

  it('applies aria-expanded to directories', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, expandedIds: ['d1'] }), container)
    const items = container.querySelectorAll('[role="treeitem"]')
    expect(items[0]?.getAttribute('aria-expanded')).toBe('true')
    expect(items[2]?.hasAttribute('aria-expanded')).toBe(false)
  })

  it('applies ARIA tree position metadata to visible rows', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, expandedIds: ['d1'] }), container)

    const src = container.querySelector('[data-file-tree-row="d1"]')
    const child = container.querySelector('[data-file-tree-row="f1"]')
    const readme = container.querySelector('[data-file-tree-row="f2"]')

    expect(src?.getAttribute('aria-level')).toBe('1')
    expect(src?.getAttribute('aria-posinset')).toBe('1')
    expect(src?.getAttribute('aria-setsize')).toBe('2')
    expect(child?.getAttribute('aria-level')).toBe('2')
    expect(child?.getAttribute('aria-posinset')).toBe('1')
    expect(child?.getAttribute('aria-setsize')).toBe('1')
    expect(readme?.getAttribute('aria-level')).toBe('1')
    expect(readme?.getAttribute('aria-posinset')).toBe('2')
  })

  it('renders git status as a semantic StatusChip instead of a color-only marker', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, expandedIds: ['d1'] }), container)

    const status = container.querySelector('[data-file-tree-git-status="modified"]')
    const chip = status?.querySelector('[data-status-chip]')

    expect(status?.getAttribute('aria-label')).toBe('modified git status')
    expect(chip?.textContent?.trim()).toBe('M')
    expect(chip?.getAttribute('data-status-chip-tone')).toBe('warn')
    expect(chip?.getAttribute('data-status-chip-uppercase')).toBe('false')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, testId: 'ft-1' }), container)
    expect(container.querySelector('[data-testid="ft-1"]')).not.toBeNull()
  })
})
