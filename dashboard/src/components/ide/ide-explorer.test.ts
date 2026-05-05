import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { IdeExplorer } from './ide-explorer'
import { createFileTreeStore, type FileTreeNode } from './file-tree-store'

const SAMPLE: ReadonlyArray<FileTreeNode> = [
  { path: 'runtime', label: 'runtime', depth: 0, parent: null, hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/router.ts', label: 'router.ts', depth: 1, parent: 'runtime', hasChildren: false, diff: '+14', keeperId: 'nick0cave', hueIndex: 1 },
  { path: 'package.json', label: 'package.json', depth: 0, parent: null, hasChildren: false, diff: null, keeperId: null, hueIndex: null },
]

describe('IdeExplorer tree row keyboard accessibility', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
  })

  afterEach(() => {
    render(null, container)
  })

  it('makes every treeitem keyboard-focusable, not just directories', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const treeItems = Array.from(
      container.querySelectorAll<HTMLElement>('[role="treeitem"]'),
    )
    expect(treeItems.length).toBeGreaterThan(0)

    const tabIndexes = treeItems.map(el => el.getAttribute('tabindex'))
    for (const idx of tabIndexes) {
      expect(idx).toBe('0')
    }

    const leafItem = treeItems.find(el => el.textContent?.includes('package.json'))
    expect(leafItem).toBeDefined()
    expect(leafItem?.getAttribute('tabindex')).toBe('0')
  })
})
