import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { explorerScopeLabel, IdeExplorer } from './ide-explorer'
import { createFileTreeStore, type FileTreeNode } from './file-tree-store'
import type { Repository } from '../../api/repositories'

const SAMPLE: ReadonlyArray<FileTreeNode> = [
  { path: 'runtime', label: 'runtime', depth: 0, parent: null, hasChildren: true, diff: null, keeperId: null, hueIndex: null },
  { path: 'runtime/router.ts', label: 'router.ts', depth: 1, parent: 'runtime', hasChildren: false, diff: '+14', keeperId: 'nick0cave', hueIndex: 1 },
  { path: 'package.json', label: 'package.json', depth: 0, parent: null, hasChildren: false, diff: null, keeperId: null, hueIndex: null },
]

function repo(id: string, name = id): Repository {
  return {
    id,
    name,
    url: '',
    local_path: `/workspace/${id}`,
    default_branch: 'main',
    status: 'active',
    auto_sync: false,
    sync_interval: 0,
    credential_id: null,
    created_at: null,
    updated_at: null,
  }
}

describe('explorerScopeLabel', () => {
  it('labels repository-backed IDE trees with the repository name', () => {
    expect(
      explorerScopeLabel(
        { kind: 'repository', repoId: 'masc-mcp' },
        '',
        [repo('masc-mcp', 'masc-mcp')],
      ),
    ).toEqual({ label: 'masc-mcp', tone: 'accent' })
  })

  it('keeps repository fallback states visibly distinct from project root', () => {
    expect(
      explorerScopeLabel(
        { kind: 'repository_unknown', repoId: 'missing-repo' },
        '',
        [],
      ),
    ).toEqual({ label: 'missing-repo fallback', tone: 'muted' })
  })
})

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

  it('renders keeper sigils in file rows instead of color-only markers', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const keeperOwnedRow = Array.from(
      container.querySelectorAll<HTMLElement>('[role="treeitem"]'),
    ).find(el => el.textContent?.includes('router.ts'))

    expect(keeperOwnedRow?.textContent).toContain('NK')
    expect(keeperOwnedRow?.textContent).toContain('router.ts')
  })

  it('renders repository source in the explorer header', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, {
      fileTreeStore: store,
      workspaceSource: () => ({ kind: 'repository', repoId: 'masc-mcp' } as const),
      repositories: () => [repo('masc-mcp', 'masc-mcp')],
    }), container)

    expect(container.textContent).toContain('EXPLORER · masc-mcp')
    expect(container.textContent).not.toContain('EXPLORER · project')
  })
})
