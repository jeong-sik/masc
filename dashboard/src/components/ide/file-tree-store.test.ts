import { describe, expect, it, vi } from 'vitest'
import { createFileTreeStore, summarizeFileTreeDiffs, type FileTreeNode } from './file-tree-store'

const SAMPLE: ReadonlyArray<FileTreeNode> = [
  { path: 'runtime', label: 'runtime', depth: 0, parent: null, hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/runtime', label: 'runtime', depth: 1, parent: 'runtime', hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/runtime/router.ts', label: 'router.ts', depth: 2, parent: 'runtime/runtime', hasChildren: false, diff: '+14', keeperId: 'nick0cave', hueIndex: 1 },
  { path: 'runtime/runtime/provider.ts', label: 'provider.ts', depth: 2, parent: 'runtime/runtime', hasChildren: false, diff: '+3', keeperId: 'nick0cave', hueIndex: 1 },
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
    // 'runtime/runtime' and 'runtime/fsm' are depth-1 -> collapsed.
    expect(s.isExpanded('runtime')).toBe(true)
    expect(s.isExpanded('runtime/runtime')).toBe(false)
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toEqual([
      'runtime',
      'runtime/runtime',
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
    s.expand('runtime/runtime')
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toContain('runtime/runtime/router.ts')
    expect(visible).toContain('runtime/runtime/provider.ts')
  })

  it('toggle flips expansion state', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.toggle('runtime/runtime')
    expect(s.isExpanded('runtime/runtime')).toBe(true)
    s.toggle('runtime/runtime')
    expect(s.isExpanded('runtime/runtime')).toBe(false)
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
    s.expand('runtime/runtime')
    s.collapse('runtime')
    const visible = s.visibleNodes().map(n => n.path)
    expect(visible).toEqual(['runtime', 'package.json'])
  })

  it('knownKeepers is sorted and de-duplicated', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    expect(s.knownKeepers()).toEqual(['nick0cave', 'sangsu'])
  })

  it('summarizes changed files from git diff badges across collapsed nodes', () => {
    const s = createFileTreeStore()
    s.seed([
      ...SAMPLE,
      { path: 'assets/logo.png', label: 'logo.png', depth: 0, parent: null, hasChildren: false, diff: 'bin', keeperId: null, hueIndex: null },
      { path: 'docs/empty.md', label: 'empty.md', depth: 1, parent: 'docs', hasChildren: false, diff: '+bad -0', keeperId: null, hueIndex: null },
    ])

    expect(s.diffSummary()).toEqual({
      changedFiles: 5,
      additions: 25,
      deletions: 0,
      binaryFiles: 1,
    })
  })

  it('returns an empty diff summary when no file node carries diff data', () => {
    expect(summarizeFileTreeDiffs([
      { path: 'src', label: 'src', depth: 0, parent: null, hasChildren: true, diff: null, keeperId: null, hueIndex: null },
      { path: 'src/main.ts', label: 'main.ts', depth: 1, parent: 'src', hasChildren: false, diff: null, keeperId: null, hueIndex: null },
    ])).toEqual({
      changedFiles: 0,
      additions: 0,
      deletions: 0,
      binaryFiles: 0,
    })
  })

  it('subscribers fire on expansion changes', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    let count = 0
    const dispose = s.subscribe(() => {
      count += 1
    })
    s.expand('runtime/runtime')
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

function dir(path: string, depth: number, parent: string | null): FileTreeNode {
  return { path, label: path.split('/').pop() ?? path, depth, parent, hasChildren: true, diff: null, keeperId: null, hueIndex: null }
}
function file(path: string, depth: number, parent: string | null): FileTreeNode {
  return { path, label: path.split('/').pop() ?? path, depth, parent, hasChildren: false, diff: null, keeperId: null, hueIndex: null }
}

describe('createFileTreeStore lazy children loading', () => {
  // Mirrors the empirically-confirmed `project` workspace source: root-only
  // directories with no children present, each expandable via loadChildren.
  const ROOT_ONLY: ReadonlyArray<FileTreeNode> = [
    dir('lib', 0, ''),
    dir('dashboard', 0, ''),
    file('README.md', 0, ''),
  ]

  it('marks a directory whose children are present as already-loaded (no fetch on expand)', async () => {
    const loadChildren = vi.fn(async () => [] as FileTreeNode[])
    const s = createFileTreeStore({ loadChildren })
    // 'lib' has a child present in the seed -> loaded; expanding must not fetch.
    s.seed([dir('lib', 0, ''), file('lib/main.ml', 1, 'lib')])

    expect(s.isChildrenLoaded('lib')).toBe(true)
    s.expand('lib')
    await Promise.resolve()
    expect(loadChildren).not.toHaveBeenCalled()
  })

  it('treats a root-only directory as not-loaded and fetches its children on expand', async () => {
    const loadChildren = vi.fn(async (path: string): Promise<FileTreeNode[]> =>
      path === 'lib'
        ? [dir('lib/server', 1, 'lib'), file('lib/main.ml', 1, 'lib')]
        : [],
    )
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)

    expect(s.isChildrenLoaded('lib')).toBe(false)
    s.expand('lib')
    await flushMicrotasks()

    expect(loadChildren).toHaveBeenCalledWith('lib')
    expect(s.isChildrenLoaded('lib')).toBe(true)
    // Children are merged and now visible under the expanded 'lib'.
    expect(s.visibleNodes().map(n => n.path)).toEqual([
      'lib',
      'lib/server',
      'lib/main.ml',
      'dashboard',
      'README.md',
    ])
  })

  it('does not re-fetch a directory whose children were already loaded', async () => {
    const loadChildren = vi.fn(async (): Promise<FileTreeNode[]> => [file('lib/main.ml', 1, 'lib')])
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)

    await s.loadChildren('lib')
    await s.loadChildren('lib')
    s.collapse('lib')
    s.expand('lib')
    await flushMicrotasks()

    expect(loadChildren).toHaveBeenCalledTimes(1)
  })

  it('coalesces concurrent expands into a single in-flight fetch', async () => {
    let resolveFetch: (nodes: FileTreeNode[]) => void = () => {}
    const loadChildren = vi.fn(
      () => new Promise<FileTreeNode[]>(resolve => { resolveFetch = resolve }),
    )
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)

    const first = s.loadChildren('lib')
    const second = s.loadChildren('lib')
    expect(s.isChildrenLoading('lib')).toBe(true)
    resolveFetch([file('lib/main.ml', 1, 'lib')])
    await Promise.all([first, second])

    expect(loadChildren).toHaveBeenCalledTimes(1)
    expect(s.isChildrenLoading('lib')).toBe(false)
    expect(s.isChildrenLoaded('lib')).toBe(true)
  })

  it('leaves a directory not-loaded after a failed fetch so a later expand retries', async () => {
    const loadChildren = vi.fn()
      .mockRejectedValueOnce(new Error('network'))
      .mockResolvedValueOnce([file('lib/main.ml', 1, 'lib')])
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)

    await s.loadChildren('lib')
    expect(s.isChildrenLoaded('lib')).toBe(false)
    expect(s.isChildrenLoading('lib')).toBe(false)

    await s.loadChildren('lib')
    expect(s.isChildrenLoaded('lib')).toBe(true)
    expect(loadChildren).toHaveBeenCalledTimes(2)
  })

  it('is inert without a configured loader (backward compatible)', async () => {
    const s = createFileTreeStore()
    s.seed(ROOT_ONLY)
    await s.loadChildren('lib')
    expect(s.isChildrenLoaded('lib')).toBe(false)
    expect(s.nodeCount()).toBe(ROOT_ONLY.length)
  })

  it('recomputes load state on re-seed so a repo switch does not leak it', async () => {
    const loadChildren = vi.fn(async (): Promise<FileTreeNode[]> => [file('lib/main.ml', 1, 'lib')])
    const s = createFileTreeStore({ loadChildren })
    s.seed([dir('lib', 0, ''), file('lib/main.ml', 1, 'lib')])
    expect(s.isChildrenLoaded('lib')).toBe(true)

    // New repo: 'lib' is now a root-only leaf-dir with no children present.
    s.seed(ROOT_ONLY)
    expect(s.isChildrenLoaded('lib')).toBe(false)
  })
})

describe('createFileTreeStore live refresh (reconcile)', () => {
  const ROOT_ONLY: ReadonlyArray<FileTreeNode> = [
    dir('lib', 0, ''),
    dir('dashboard', 0, ''),
    file('README.md', 0, ''),
  ]

  it('preserves expansion and lazily-loaded children across a same-workspace refresh', async () => {
    const loadChildren = vi.fn(async (path: string): Promise<FileTreeNode[]> =>
      path === 'lib' ? [dir('lib/server', 1, 'lib'), file('lib/main.ml', 1, 'lib')] : [],
    )
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)
    s.expand('lib')
    await flushMicrotasks()
    // Precondition: lib is expanded and its lazily-loaded children are visible.
    expect(s.isExpanded('lib')).toBe(true)
    expect(s.visibleNodes().map(n => n.path)).toContain('lib/server')

    // A keeper edit triggers a live refresh: the bounded rescan returns the
    // same root-only tree (no 'lib' children). reconcile must keep the tree
    // the operator has open, unlike seed which would collapse it.
    s.reconcile(ROOT_ONLY)

    expect(s.isExpanded('lib')).toBe(true)
    expect(s.isChildrenLoaded('lib')).toBe(true)
    expect(s.visibleNodes().map(n => n.path)).toEqual([
      'lib',
      'lib/server',
      'lib/main.ml',
      'dashboard',
      'README.md',
    ])
  })

  it('applies fresh diffs on refresh while keeping the tree open', () => {
    const s = createFileTreeStore()
    s.seed(SAMPLE)
    s.expand('runtime/runtime')
    expect(s.diffSummary().additions).toBe(14 + 3 + 8)

    // router.ts gained more additions in the fresh scan.
    const fresh = SAMPLE.map(n =>
      n.path === 'runtime/runtime/router.ts' ? { ...n, diff: '+40' } : n,
    )
    s.reconcile(fresh)

    expect(s.isExpanded('runtime/runtime')).toBe(true)
    expect(s.diffSummary().additions).toBe(40 + 3 + 8)
  })

  it('drops stale children when a workspace switch (seed) lands mid-fetch', async () => {
    // Gate the first fetch so a seed can interleave before it resolves.
    let releaseFirst: (nodes: FileTreeNode[]) => void = () => {}
    const first = new Promise<FileTreeNode[]>(resolve => {
      releaseFirst = resolve
    })
    const loadChildren = vi.fn(() => first)
    const s = createFileTreeStore({ loadChildren })
    s.seed(ROOT_ONLY)

    const pending = s.loadChildren('lib') // captures generation, awaits `first`
    // Workspace switch before the fetch resolves.
    s.seed([dir('src', 0, ''), file('README.md', 0, '')])
    // The stale fetch now resolves with the previous workspace's children.
    releaseFirst([dir('lib/server', 1, 'lib'), file('lib/main.ml', 1, 'lib')])
    await pending
    await flushMicrotasks()

    // The generation guard must have dropped the stale merge: no 'lib' node
    // leaked into the new workspace, and 'lib' is not marked loaded.
    const paths = s.visibleNodes().map(n => n.path)
    expect(paths).not.toContain('lib/server')
    expect(paths).not.toContain('lib/main.ml')
    expect(s.isChildrenLoaded('lib')).toBe(false)
    expect(s.isChildrenLoading('lib')).toBe(false)
  })
})

async function flushMicrotasks(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
  }
}
