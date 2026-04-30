// @vitest-environment happy-dom

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createRoot } from 'solid-js'
import type { TreeNode } from '../headless-core/tree-view'
import { useTreeView } from './use-tree-view'

let dispose: (() => void) | undefined

beforeEach(() => {
  dispose = undefined
})

afterEach(() => {
  dispose?.()
})

function withRoot<T>(fn: () => T): T {
  return createRoot((d) => {
    dispose = d
    return fn()
  })
}

const tree: ReadonlyArray<TreeNode<{ kind: string }>> = [
  { id: 'root', label: 'Root', parentId: null, hasChildren: true },
  { id: 'a', label: 'A', parentId: 'root', hasChildren: false, data: { kind: 'file' } },
  { id: 'b', label: 'B', parentId: 'root', hasChildren: true },
  { id: 'b1', label: 'B1', parentId: 'b', hasChildren: false, data: { kind: 'file' } },
]

describe('useTreeView', () => {
  it('initial visible reflects defaultExpanded', () => {
    const { visible } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      }),
    )
    const ids = visible().map((n) => n.id)
    expect(ids).toContain('root')
    expect(ids).toContain('a')
    expect(ids).toContain('b')
    expect(ids).not.toContain('b1')
  })

  it('expand re-renders accessor with children', async () => {
    const { visible, expand } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      }),
    )
    await expand('b')
    expect(visible().map((n) => n.id)).toContain('b1')
  })

  it('select stores id in selected accessor', () => {
    const { selected, select } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      }),
    )
    select('a')
    expect(selected().has('a')).toBe(true)
  })

  it('clearSelection empties selected', () => {
    const { selected, select, clearSelection } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      }),
    )
    select('a')
    expect(selected().size).toBe(1)
    clearSelection()
    expect(selected().size).toBe(0)
  })

  it('getRootProps returns role=tree', () => {
    const { getRootProps } = withRoot(() =>
      useTreeView({ nodes: tree, selectionMode: 'single' }),
    )
    expect(getRootProps().role).toBe('tree')
  })

  it('getAriaLevel reports 1-indexed depth', () => {
    const { getAriaLevel } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root', 'b'],
      }),
    )
    expect(getAriaLevel('root')).toBe(1)
    expect(getAriaLevel('b')).toBe(2)
    expect(getAriaLevel('b1')).toBe(3)
  })

  it('expanded accessor reflects expand/collapse', () => {
    const { expanded, collapse } = withRoot(() =>
      useTreeView({
        nodes: tree,
        selectionMode: 'single',
        defaultExpanded: ['root'],
      }),
    )
    expect(expanded().has('root')).toBe(true)
    collapse('root')
    expect(expanded().has('root')).toBe(false)
  })
})
