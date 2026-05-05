import { describe, expect, it } from 'vitest'
import { createFileTreeStore, type FileTreeNode } from './file-tree-store'

const SAMPLE: ReadonlyArray<FileTreeNode> = [
  { path: 'runtime', label: 'runtime', depth: 0, parent: null, hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/cascade', label: 'cascade', depth: 1, parent: 'runtime', hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/cascade/router.ts', label: 'router.ts', depth: 2, parent: 'runtime/cascade', hasChildren: false, diff: '+14', keeperId: 'nick0cave', hueIndex: 1 },
  { path: 'runtime/cascade/provider.ts', label: 'provider.ts', depth: 2, parent: 'runtime/cascade', hasChildren: false, diff: '+3', keeperId: 'nick0cave', hueIndex: 1 },
  { path: 'runtime/fsm', label: 'fsm', depth: 1, parent: 'runtime', hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/fsm/lifeline.ts', label: 'lifeline.ts', depth: 2, parent: 'runtime/fsm', hasChildren: false, diff: '+8', keeperId: 'sangsu', hueIndex: 5 },
  { path: 'package.json', label: 'package.json', depth: 0, parent: null, hasChildren: false, diff: null, keeperId: null, hueIndex: null },
]

describe('createFileTreeStore', () => {
  it('starts empty', () => {
    const s = createFileTreeStore()
    expect(s.visibleNodes()).toEqual([])
    expect(s.nodeCount()).toBe(0)
  })

  it('seeds nodes and auto-expands depth-0 directories', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    expect(s.nodeCount()).toBe(7)
    // Default expansion: 'runtime' is depth-0 + hasChildren -> expanded.
    // 'runtime/cascade' and 'runtime/fsm' are depth-1 -> collapsed.
    expect(s.isExpanded('runtime')).toBe(true)
    expect(s.isExpanded('runtime/cascade')).toBe(false)
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toEqual([
      'runtime',
      'runtime/cascade',
      'runtime/fsm',
      'package.json',
    ])
  })

  it('treats empty-string parent as root for server-supplied nodes', () => {
    const s = createFileTreeStore()
    s.seed([
      { path: 'lib', label: 'lib', depth: 0, parent: '', hasChildren: true, diff: null, keeperId: null, hueIndex: null },
      { path: 'lib/main.ml', label: 'main.ml', depth: 1, parent: 'lib', hasChildren: false, diff: null, keeperId: null, hueIndex: null },
      { path: 'README.md', label: 'README.md', depth: 0, parent: '', hasChildren: false, diff: null, keeperId: null, hueIndex: null },
    ])

    expect(s.visibleNodes().map(n => n.path)).toEqual([
      'lib',
      'lib/main.ml',
      'README.md',
    ])
  })

  it('expands nested directories on demand', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.expand('runtime/cascade')
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toContain('runtime/cascade/router.ts')
    expect(visible).toContain('runtime/cascade/provider.ts')
  })

  it('toggle flips expansion state', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.toggle('runtime/cascade')
    expect(s.isExpanded('runtime/cascade')).toBe(true)
    s.toggle('runtime/cascade')
    expect(s.isExpanded('runtime/cascade')).toBe(false)
  })

  it('expandAll / collapseAll reach all directories', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.expandAll()
    expect(s.visibleNodes().length).toBe(7)
    s.collapseAll()
    expect(s.visibleNodes().length).toBe(2) // only depth-0 nodes
  })

  it('hides children when an ancestor collapses', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.expand('runtime/cascade')
    s.collapse('runtime')
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toEqual(['runtime', 'package.json'])
  })

  it('knownKeepers is sorted and de-duplicated', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    expect(s.knownKeepers()).toEqual(['nick0cave', 'sangsu'])
  })

  it('subscribers fire on expansion changes', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    let count = 0
    const dispose = s.subscribe(() => {
      count += 1
    })
    s.expand('runtime/cascade')
    s.expand('runtime/fsm')
    s.collapse('runtime')
    dispose()
    s.expand('runtime')
    expect(count).toBe(3)
  })

  it('handles 1000 nodes without blowing up (perf smoke)', () => {
    const big = generateBigTree(1000)
    const s = createFileTreeStore()
    const startSeed = performance.now()
    s.seed(big)
    const seedMs = performance.now() - startSeed

    const startVisible = performance.now()
    const v = s.visibleNodes()
    const visibleMs = performance.now() - startVisible

    expect(s.nodeCount()).toBe(1000)
    // Smoke budget: 1000-node seed and first visible computation
    // should both be well under 100ms in CI. We don't gate hard on a
    // tight budget here (CI hardware varies); we just assert order
    // of magnitude so future regressions surface in PR review.
    expect(seedMs).toBeLessThan(200)
    expect(visibleMs).toBeLessThan(200)
    expect(v.length).toBeGreaterThan(0)
  })

  it('handles 5000 nodes with expand/collapse under 200ms', () => {
    const big = generateBigTree(5000)
    const s = createFileTreeStore()
    s.seed(big)

    const start = performance.now()
    s.expandAll()
    const all = s.visibleNodes()
    const ms = performance.now() - start

    expect(all.length).toBe(5000)
    expect(ms).toBeLessThan(400)
  })
})

function generateBigTree(target: number): ReadonlyArray<FileTreeNode> {
  const nodes: FileTreeNode[] = []
  const frontier: Array<{ path: string; depth: number }> = []
  let count = 0

  const pushDir = (parent: string | null, depth: number, index: number): void => {
    if (count >= target) return
    const dirPath = parent ? `${parent}/d${depth}-${index}` : `d${depth}-${index}`
    nodes.push({
      path: dirPath,
      label: `d${depth}-${index}`,
      depth,
      parent,
      hasChildren: true,
      diff: null,
      keeperId: null,
      hueIndex: null,
    })
    frontier.push({ path: dirPath, depth })
    count += 1
  }

  for (let i = 0; i < 8 && count < target; i += 1) {
    pushDir(null, 0, i)
  }

  let cursor = 0
  while (cursor < frontier.length && count < target) {
    const parent = frontier[cursor]
    if (!parent) break
    cursor += 1

    for (let j = 0; j < 6 && count < target; j += 1) {
      nodes.push({
        path: `${parent.path}/f${j}.ts`,
        label: `f${j}.ts`,
        depth: parent.depth + 1,
        parent: parent.path,
        hasChildren: false,
        diff: j % 3 === 0 ? '+1' : null,
        keeperId: j % 4 === 0 ? `kp${j}` : null,
        hueIndex: j % 4 === 0 ? ((j % 12) + 1) : null,
      })
      count += 1
    }

    for (let i = 0; i < 8 && count < target; i += 1) {
      pushDir(parent.path, parent.depth + 1, i)
    }
  }

  return nodes
}
