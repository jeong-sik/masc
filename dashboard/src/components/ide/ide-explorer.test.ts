import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { explorerScopeLabel, IdeExplorer } from './ide-explorer'
import { createFileTreeStore, type FileTreeNode } from './file-tree-store'
import type { Repository } from '../../api/repositories'
import { activeIdeFile, focusIdeFile, ideContextFocus } from './ide-state'

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
    created_at: null,
    updated_at: null,
  }
}

describe('explorerScopeLabel', () => {
  it('labels repository-backed IDE trees with the repository name', () => {
    expect(
      explorerScopeLabel(
        { kind: 'repository', repoId: 'masc' },
        '',
        [repo('masc', 'masc')],
      ),
    ).toEqual({ label: 'masc', tone: 'accent' })
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
    window.location.hash = ''
    focusIdeFile({
      path: 'package.json',
      origin: 'operator',
      workspace_identity: { kind: 'project' },
      availability: 'available',
    })
    ideContextFocus.value = null
  })

  it('makes every treeitem keyboard-focusable, not just directories', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const treeItems = Array.from(
      container.querySelectorAll<HTMLElement>('[role="treeitem"]'),
    )
    expect(treeItems.length).toBeGreaterThan(0)
    expect(treeItems.every(el => el.classList.contains('v2-ide-row'))).toBe(true)

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

    expect(keeperOwnedRow?.textContent).toContain('NI')
    expect(keeperOwnedRow?.textContent).toContain('router.ts')
  })

  it('summarizes workspace git changes from file tree diff badges', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const summary = container.querySelector<HTMLElement>('[aria-label="Workspace git changes: 1 changed, +14"]')
    expect(summary).not.toBeNull()
    expect(summary?.textContent).toContain('Git changes')
    expect(summary?.textContent).toContain('1 changed')
    expect(summary?.textContent).toContain('+14')

    const diffBadge = Array.from(container.querySelectorAll<HTMLElement>('[aria-label="Git diff +14"]'))
      .find(el => el.textContent === '+14')
    expect(diffBadge).toBeDefined()
  })

  it('hides the git changes summary when the workspace tree has no diffs', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE.map(node => ({ ...node, diff: null })))
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    expect(container.textContent).not.toContain('Git changes')
  })

  it('marks the repository scan button and context route buttons with v2 action classes', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    ideContextFocus.value = {
      file_path: 'runtime/router.ts',
      line: 42,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
      route_links: [
        {
          id: 'task:task-runtime',
          label: 'Task',
          tab: 'workspace',
          params: { section: 'planning', view: 'default', task: 'task-runtime' },
          evidence: 'Task task-runtime',
        },
      ],
    }

    render(h(IdeExplorer, {
      fileTreeStore: store,
      onRepositoryScan: async () => [],
    }), container)

    const scanButton = container.querySelector<HTMLButtonElement>('[aria-label="base path 아래 git 저장소 스캔"]')
    expect(scanButton?.classList.contains('v2-ide-action')).toBe(true)

    const focusedRow = Array.from(
      container.querySelectorAll<HTMLElement>('[role="treeitem"]'),
    ).find(el => el.textContent?.includes('router.ts'))
    const routeButtons = [...focusedRow!.querySelectorAll<HTMLButtonElement>('.ide-explorer-context-chip button')]
    expect(routeButtons.every(button => button.classList.contains('v2-ide-action'))).toBe(true)
  })

  it('renders repository source in the explorer header', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, {
      fileTreeStore: store,
      workspaceSource: () => ({ kind: 'repository', repoId: 'masc' } as const),
      repositories: () => [repo('masc', 'masc')],
    }), container)

    expect(container.querySelector('[data-testid="ide-explorer-source"]')?.textContent).toBe('masc')
    expect(container.querySelector('[data-testid="ide-explorer-source"]')?.getAttribute('title'))
      .toBe('Workspace source: masc')
  })

  it('labels loaded visible files distinctly from filtered results', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const count = container.querySelector<HTMLElement>('[data-testid="ide-explorer-file-count"]')
    expect(count?.textContent).toBe('2 VISIBLE')
    expect(count?.getAttribute('title')).toContain('currently loaded in the visible tree')

    const search = container.querySelector<HTMLInputElement>('[role="searchbox"]')
    expect(search).not.toBeNull()
    search!.value = 'package'
    fireEvent.input(search!)

    expect(container.querySelector('[data-testid="ide-explorer-file-count"]')?.textContent)
      .toBe('1/2 VISIBLE')
  })

  it('keeps header controls outside the scrollable tree body', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const explorer = container.querySelector<HTMLElement>('.ide-explorer')
    const scroller = container.querySelector<HTMLElement>('.ide-explorer-scroll')
    const tree = container.querySelector<HTMLElement>('.ide-explorer-tree')

    expect(explorer).not.toBeNull()
    expect(scroller).not.toBeNull()
    expect(tree).not.toBeNull()
    expect(scroller?.contains(tree)).toBe(true)
    expect(scroller?.contains(container.querySelector('header'))).toBe(false)
    expect(scroller?.contains(container.querySelector('input[type="search"]'))).toBe(false)
  })

  it('marks the file row carrying the current IDE context focus with route buttons', () => {
    const store = createFileTreeStore()
    store.seed(SAMPLE)
    ideContextFocus.value = {
      file_path: 'runtime/router.ts',
      line: 42,
      surface: 'Task',
      label: 'task task-runtime',
      source_id: 'event-1',
      activated_at_ms: Date.now(),
      route_links: [
        {
          id: 'task:task-runtime',
          label: 'Task',
          tab: 'workspace',
          params: { section: 'planning', view: 'default', task: 'task-runtime' },
          evidence: 'Task task-runtime',
        },
        {
          id: 'telemetry:turn-9',
          label: 'Telemetry',
          tab: 'monitoring',
          params: { section: 'fleet-health', view: 'event-log', q: 'turn-9' },
          evidence: 'Fleet telemetry event log · query turn-9',
        },
      ],
    }

    render(h(IdeExplorer, { fileTreeStore: store }), container)

    const focusedRow = Array.from(
      container.querySelectorAll<HTMLElement>('[role="treeitem"]'),
    ).find(el => el.textContent?.includes('router.ts'))
    const chip = focusedRow?.querySelector('.ide-explorer-context-chip')

    expect(chip?.textContent).toContain('Task')
    expect(chip?.textContent).toContain('L42')
    const routeButtons = [...focusedRow!.querySelectorAll<HTMLButtonElement>('.ide-explorer-context-chip button')]
    expect(routeButtons.every(button => button.classList.contains('v2-ide-action'))).toBe(true)
    expect(routeButtons.map(button => button.textContent)).toEqual(['Task', 'Telemetry'])
    expect(routeButtons.map(button => button.getAttribute('aria-label'))).toEqual([
      'Open Task task-runtime',
      'Open Fleet telemetry event log · query turn-9',
    ])
    expect(chip?.getAttribute('aria-label'))
      .toBe('Focused Task line 42: task task-runtime, 2 route links')

    fireEvent.click(routeButtons[1]!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=turn-9')
    expect(activeIdeFile.value).toBe('package.json')
  })
})
