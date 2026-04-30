import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { FileTree } from './file-tree'

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

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(FileTree, { nodes, testId: 'ft-1' }), container)
    expect(container.querySelector('[data-testid="ft-1"]')).not.toBeNull()
  })
})
