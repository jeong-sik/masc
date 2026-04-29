// Pure TS unit tests for TreeView. No DOM.
import { describe, it, expect } from 'vitest'
import {
  createTreeView,
  type TreeKeyEvent,
  type TreeNode,
} from './tree-view'

function makeKey(
  key: string,
  opts?: Partial<TreeKeyEvent>,
): TreeKeyEvent & { _prevented: boolean } {
  let prevented = false
  return {
    key,
    shiftKey: opts?.shiftKey,
    metaKey: opts?.metaKey,
    ctrlKey: opts?.ctrlKey,
    altKey: opts?.altKey,
    preventDefault() {
      prevented = true
    },
    get _prevented() {
      return prevented
    },
  } as TreeKeyEvent & { _prevented: boolean }
}

const FLAT: ReadonlyArray<TreeNode> = [
  { id: 'a', label: 'a', parentId: null, hasChildren: true },
  { id: 'b', label: 'b', parentId: null, hasChildren: false },
  { id: 'a.1', label: 'a.1', parentId: 'a', hasChildren: false },
  { id: 'a.2', label: 'a.2', parentId: 'a', hasChildren: true },
  { id: 'a.2.x', label: 'a.2.x', parentId: 'a.2', hasChildren: false },
  { id: 'c', label: 'c', parentId: null, hasChildren: false },
]

describe('createTreeView — flat→nested build', () => {
  it('getVisible returns only roots when nothing expanded', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'none' })
    const ids = t.getVisible().map((n) => n.id)
    expect(ids).toEqual(['a', 'b', 'c'])
  })

  it('aria-level is correct for nested nodes', () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a', 'a.2'],
    })
    expect(t.getAriaLevel('a')).toBe(1)
    expect(t.getAriaLevel('a.1')).toBe(2)
    expect(t.getAriaLevel('a.2.x')).toBe(3)
  })
})

describe('createTreeView — expand / collapse', () => {
  it('expand makes children visible', async () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'none' })
    await t.expand('a')
    const ids = t.getVisible().map((n) => n.id)
    expect(ids).toEqual(['a', 'a.1', 'a.2', 'b', 'c'])
  })

  it('collapse removes descendants', async () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a', 'a.2'],
    })
    expect(t.getVisible().map((n) => n.id)).toEqual([
      'a',
      'a.1',
      'a.2',
      'a.2.x',
      'b',
      'c',
    ])
    t.collapse('a')
    expect(t.getVisible().map((n) => n.id)).toEqual(['a', 'b', 'c'])
  })

  it('expand on lazy node calls onLoadChildren and merges', async () => {
    const lazyNodes: ReadonlyArray<TreeNode> = [
      { id: 'r', label: 'root', parentId: null, hasChildren: 'lazy' },
    ]
    let loaded = false
    const t = createTreeView({
      nodes: lazyNodes,
      selectionMode: 'none',
      onLoadChildren: async (id) => {
        loaded = true
        if (id !== 'r') return []
        return [{ id: 'r.1', label: 'r.1', parentId: 'r', hasChildren: false }]
      },
    })
    await t.expand('r')
    expect(loaded).toBe(true)
    expect(t.getVisible().map((n) => n.id)).toEqual(['r', 'r.1'])
  })

  it('lazy load reject leaves node collapsed', async () => {
    const t = createTreeView({
      nodes: [{ id: 'r', label: 'r', parentId: null, hasChildren: 'lazy' }],
      selectionMode: 'none',
      onLoadChildren: async () => {
        throw new Error('nope')
      },
    })
    await t.expand('r')
    expect(t.expanded.has('r')).toBe(false)
  })
})

describe('createTreeView — keyboard contract', () => {
  it('ArrowRight on collapsed: expand', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'none' })
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    expect(t.expanded.has('a')).toBe(true)
  })

  it('ArrowRight on expanded: focus first child', async () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a'],
    })
    expect(t.activeId).toBe('a') // first enabled visible
    t.getRootProps().onKeyDown(makeKey('ArrowRight'))
    expect(t.activeId).toBe('a.1')
  })

  it('ArrowLeft on expanded: collapse', () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a'],
    })
    t.getRootProps().onKeyDown(makeKey('ArrowLeft'))
    expect(t.expanded.has('a')).toBe(false)
  })

  it('ArrowLeft on collapsed/leaf: focus parent', () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a'],
    })
    // Move to a.1 then ArrowLeft -> back to a
    t.getRootProps().onKeyDown(makeKey('ArrowDown'))
    expect(t.activeId).toBe('a.1')
    t.getRootProps().onKeyDown(makeKey('ArrowLeft'))
    expect(t.activeId).toBe('a')
  })

  it('* expands all siblings of focused', () => {
    const wide: ReadonlyArray<TreeNode> = [
      { id: 'p', label: 'p', parentId: null, hasChildren: true },
      { id: 'q', label: 'q', parentId: null, hasChildren: true },
      { id: 'r', label: 'r', parentId: null, hasChildren: false },
      { id: 'p.1', label: 'p.1', parentId: 'p', hasChildren: false },
      { id: 'q.1', label: 'q.1', parentId: 'q', hasChildren: false },
    ]
    const t = createTreeView({ nodes: wide, selectionMode: 'none' })
    t.getRootProps().onKeyDown(makeKey('*'))
    expect(t.expanded.has('p')).toBe(true)
    expect(t.expanded.has('q')).toBe(true)
  })
})

describe('createTreeView — selection', () => {
  it('Enter selects in single mode', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'single' })
    t.getRootProps().onKeyDown(makeKey('ArrowDown'))
    t.getRootProps().onKeyDown(makeKey('Enter'))
    expect([...t.selected]).toEqual(['b'])
  })

  it('multi: shift+click range select', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'multi' })
    t.getNodeProps('a').onClick({})
    t.getNodeProps('c').onClick({ shiftKey: true })
    expect([...t.selected].sort()).toEqual(['a', 'b', 'c'])
  })

  it('multi: mod+click toggle', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'multi' })
    t.getNodeProps('a').onClick({})
    t.getNodeProps('b').onClick({ metaKey: true })
    expect([...t.selected].sort()).toEqual(['a', 'b'])
    t.getNodeProps('a').onClick({ metaKey: true })
    expect([...t.selected]).toEqual(['b'])
  })

  it('selectionMode none: select is no-op', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'none' })
    t.select('a')
    expect(t.selected.size).toBe(0)
  })

  it('clearSelection empties', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'single' })
    t.select('a')
    expect(t.selected.size).toBe(1)
    t.clearSelection()
    expect(t.selected.size).toBe(0)
  })
})

describe('createTreeView — getNodeProps', () => {
  it('aria-expanded only set when hasChildren', () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a'],
    })
    expect(t.getNodeProps('a')['aria-expanded']).toBe(true)
    expect(t.getNodeProps('b')['aria-expanded']).toBeUndefined()
  })

  it('aria-selected only set when selectionMode != none', () => {
    const sel = createTreeView({ nodes: FLAT, selectionMode: 'single' })
    sel.select('a')
    expect(sel.getNodeProps('a')['aria-selected']).toBe(true)
    expect(sel.getNodeProps('b')['aria-selected']).toBe(false)
    const none = createTreeView({ nodes: FLAT, selectionMode: 'none' })
    expect(none.getNodeProps('a')['aria-selected']).toBeUndefined()
  })

  it('aria-multiselectable only set on root for multi mode', () => {
    const m = createTreeView({ nodes: FLAT, selectionMode: 'multi' })
    expect(m.getRootProps()['aria-multiselectable']).toBe(true)
    const s = createTreeView({ nodes: FLAT, selectionMode: 'single' })
    expect(s.getRootProps()['aria-multiselectable']).toBeUndefined()
  })
})

describe('createTreeView — getDescendants', () => {
  it('returns all descendants of an id, depth-first', () => {
    const t = createTreeView({
      nodes: FLAT,
      selectionMode: 'none',
      defaultExpanded: ['a', 'a.2'],
    })
    const ids = t.getDescendants('a').map((n) => n.id)
    expect(ids).toEqual(['a.1', 'a.2', 'a.2.x'])
  })
})

describe('createTreeView — subscribe', () => {
  it('listener fires on expand / select; unsubscribe stops', () => {
    const t = createTreeView({ nodes: FLAT, selectionMode: 'single' })
    let count = 0
    const dispose = t.subscribe(() => {
      count += 1
    })
    void t.expand('a')
    t.select('b')
    expect(count).toBeGreaterThan(0)
    const before = count
    dispose()
    t.collapse('a')
    expect(count).toBe(before)
  })
})
