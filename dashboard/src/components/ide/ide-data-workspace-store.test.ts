import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const workspaceApiMocks = vi.hoisted(() => ({
  fetchWorkspaceTree: vi.fn(),
  fetchWorkspaceChildren: vi.fn(),
  fetchWorkspaceFile: vi.fn(),
  fetchGitBlame: vi.fn(),
  fetchGitDiff: vi.fn(),
}))
const ideApiMocks = vi.hoisted(() => ({
  fetchIdeAnnotations: vi.fn(),
  fetchIdeRegions: vi.fn(),
  ideScopeFromKeeperLane: vi.fn((keeperId: string | undefined) =>
    keeperId ? { kind: 'keeper_lane' as const, keeperId } : null),
}))
const repositoryApiMocks = vi.hoisted(() => ({
  discoverRepositories: vi.fn(),
  fetchRepositoriesList: vi.fn(),
}))

vi.mock('../../api/repositories', () => repositoryApiMocks)

vi.mock('../../api/workspace', () => workspaceApiMocks)
vi.mock('../../api/ide', () => ideApiMocks)
vi.mock('../../sse-store', () => ({
  registerIdeWorkspaceRefresh: vi.fn(() => () => {}),
}))

import {
  clearWorkspaceFetchIssue,
  createIdeDataWorkspaceStore,
  firstObservedChangedFilePath,
  replaceWorkspaceFetchIssue,
  retainCurrentWorkspaceFetchIssues,
  sameWorkspaceTreeIdentity,
  selectPreferredIdeRepositoryId,
  workspaceFetchIssueFromError,
  workspaceTreeIdentity,
} from './ide-data-workspace-store'
import { isDiffEditorView, viewFromRoute } from './ide-view-route'
import type { Repository } from '../../api/repositories'
import type { WorkspaceTreeResult, WorkspaceFileResponse } from '../../api/workspace'
import type { FileTreeNode } from './file-tree-store'
import {
  activeIdeFocus,
  activeIdeWorkspaceIdentity,
  clearIdeFileFocus,
  focusIdeFile,
  synchronizeIdeWorkspaceIdentity,
} from './ide-state'
import { activeKeeperName } from '../../keeper-state'
import { selectedTask } from '../goals/task-detail-selection'
import { route } from '../../router'

function repo(
  id: string,
  localPath: string,
  name = id,
): Repository {
  return {
    id,
    name,
    url: '',
    local_path: localPath,
    default_branch: 'main',
    status: 'active',
    auto_sync: false,
    sync_interval: 300,
    created_at: null,
    updated_at: null,
  }
}

interface Deferred<T> {
  readonly promise: Promise<T>
  readonly resolve: (value: T) => void
}

function deferred<T>(): Deferred<T> {
  let resolve: (value: T) => void = () => {
    throw new Error('deferred promise resolver was not initialized')
  }
  const promise = new Promise<T>(promiseResolve => {
    resolve = promiseResolve
  })
  return { promise, resolve }
}

function changedFile(path: string): FileTreeNode {
  const segments = path.split('/')
  return {
    path,
    label: segments[segments.length - 1] ?? path,
    depth: Math.max(0, segments.length - 1),
    parent: segments.length > 1 ? segments.slice(0, -1).join('/') : null,
    hasChildren: false,
    diff: '+1',
    keeperId: null,
    hueIndex: null,
  }
}

function repositoryTree(repoId: string, nodes: ReadonlyArray<FileTreeNode>): WorkspaceTreeResult {
  return {
    nodes,
    source: { kind: 'repository', repoId },
    basePath: `/workspace/${repoId}`,
  }
}

function projectTree(nodes: ReadonlyArray<FileTreeNode>): WorkspaceTreeResult {
  return {
    nodes,
    source: { kind: 'project' },
    basePath: '/workspace/project',
  }
}

function keeperTree(keeper: string, nodes: ReadonlyArray<FileTreeNode>): WorkspaceTreeResult {
  return {
    nodes,
    source: { kind: 'playground', keeper },
    basePath: `/workspace/keepers/${keeper}`,
  }
}

function workspaceFile(content: string): WorkspaceFileResponse {
  return { ok: true, content, language: 'ocaml' }
}

function seedWorkspaceApiMocks(): void {
  workspaceApiMocks.fetchWorkspaceTree.mockResolvedValue({
    nodes: [],
    source: { kind: 'project' },
    basePath: null,
  })
  workspaceApiMocks.fetchWorkspaceChildren.mockResolvedValue([])
  workspaceApiMocks.fetchWorkspaceFile.mockResolvedValue(null)
  workspaceApiMocks.fetchGitBlame.mockResolvedValue([])
  workspaceApiMocks.fetchGitDiff.mockResolvedValue([])
  ideApiMocks.fetchIdeAnnotations.mockResolvedValue([])
  ideApiMocks.fetchIdeRegions.mockResolvedValue([])
  repositoryApiMocks.discoverRepositories.mockResolvedValue([])
  repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([])
}

beforeEach(() => {
  vi.clearAllMocks()
  seedWorkspaceApiMocks()
  clearIdeFileFocus()
  synchronizeIdeWorkspaceIdentity({ kind: 'project' })
  activeKeeperName.value = ''
  selectedTask.value = null
  route.value = { tab: 'code', params: { view: 'source' }, postId: null }
})

afterEach(() => {
  clearIdeFileFocus()
  synchronizeIdeWorkspaceIdentity({ kind: 'project' })
  activeKeeperName.value = ''
  selectedTask.value = null
  route.value = { tab: 'overview', params: {}, postId: null }
})

describe('firstObservedChangedFilePath', () => {
  it('keeps the server-observed hidden changed path ahead of an unchanged visible file', () => {
    expect(firstObservedChangedFilePath([
      { path: '.github/workflows/ci.yml', hasChildren: false, diff: '+1' },
      { path: 'README.md', hasChildren: false, diff: null },
    ])).toBe('.github/workflows/ci.yml')
  })

  it('does not turn empty values, keeper ownership, or an arbitrary file into focus', () => {
    const nodes = [
      { path: '', hasChildren: false, diff: '+1', keeperId: null },
      { path: '.github/workflows/ci.yml', hasChildren: false, diff: '', keeperId: 'keeper-a' },
      { path: 'README.md', hasChildren: false, diff: null, keeperId: 'keeper-b' },
      { path: 'lib', hasChildren: true, diff: '+2', keeperId: null },
    ]

    expect(firstObservedChangedFilePath(nodes)).toBeNull()
  })
})

describe('selectPreferredIdeRepositoryId', () => {
  // ── Current selection persistence ────────────────────────────

  it('keeps the current repository when it is still present', () => {
    const repositories = [
      repo('repo-a', '/Users/dancer/me/workspace/repo-a'),
      repo('repo-b', '.masc/repos/repo-b'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, 'repo-b')).toBe('repo-b')
  })

  // ── Workspace repo priority (absolute paths, not mirrors) ───

  it('prefers a workspace repo over managed mirrors', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('managed-b', '.masc/repos/managed-b'),
      repo('workspace-a', '/Users/dancer/me/workspace/project-a'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('workspace-a')
  })

  it('selects the first workspace repo when multiple exist', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('workspace-alpha', '/Users/dancer/me/workspace/alpha'),
      repo('workspace-beta', '/Users/dancer/me/workspace/beta'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('workspace-alpha')
  })

  it('does not treat absolute .masc/repos mirrors as workspace checkouts', () => {
    const repositories = [
      repo('mirror-a', '/Users/dancer/me/.masc/repos/mirror-a'),
      repo('workspace-b', '/Users/dancer/me/workspace/project-b'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('workspace-b')
  })

  // ── Mirror-only fallback ─────────────────────────────────────

  it('falls back to the first non-mirror repository when only mirrors exist', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('managed-b', '.masc/repos/managed-b'),
    ]

    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('managed-a')
  })

  it('returns null for an empty repository list', () => {
    expect(selectPreferredIdeRepositoryId([], null)).toBeNull()
  })

  // ── excludeIds: self-healing after unreachable repo ──────────

  it('skips excluded repo IDs and selects the next workspace repo', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('broken-cache', '/Users/dancer/me/.cache/some-tool'),
      repo('workspace-a', '/Users/dancer/me/workspace/project-a'),
    ]

    const excluded = new Set(['broken-cache'])
    expect(selectPreferredIdeRepositoryId(repositories, null, excluded)).toBe('workspace-a')
  })

  it('drops current if it is in the exclude set', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('broken-cache', '/Users/dancer/me/.cache/some-tool'),
      repo('workspace-a', '/Users/dancer/me/workspace/project-a'),
    ]

    const excluded = new Set(['broken-cache'])
    expect(selectPreferredIdeRepositoryId(repositories, 'broken-cache', excluded)).toBe('workspace-a')
  })

  it('skips multiple excluded repos', () => {
    const repositories = [
      repo('broken-a', '/Users/dancer/me/.cache/a'),
      repo('broken-b', '/Users/dancer/me/.cache/b'),
      repo('workspace-c', '/Users/dancer/me/workspace/c'),
    ]

    const excluded = new Set(['broken-a', 'broken-b'])
    expect(selectPreferredIdeRepositoryId(repositories, null, excluded)).toBe('workspace-c')
  })

  it('returns null when all repos are excluded', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('managed-b', '.masc/repos/managed-b'),
    ]

    const excluded = new Set(['managed-a', 'managed-b'])
    expect(selectPreferredIdeRepositoryId(repositories, null, excluded)).toBeNull()
  })

  // ── Reported bug: cache dir picked as first workspace repo ──

  it('selects first workspace repo initially, even if it is a cache dir', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('llama-cpp', '/Users/dancer/me/.cache/llama.cpp'),
      repo('workspace-a', '/Users/dancer/me/workspace/project-a'),
    ]

    // Initial selection: llama-cpp is the first workspace repo.
    // The self-healing in createIdeDataWorkspaceStore handles the
    // auto-switch when workspace tree returns repository_missing.
    expect(selectPreferredIdeRepositoryId(repositories, null)).toBe('llama-cpp')
  })

  it('self-heals by excluding broken cache and selecting next workspace repo', () => {
    const repositories = [
      repo('managed-a', '.masc/repos/managed-a'),
      repo('llama-cpp', '/Users/dancer/me/.cache/llama.cpp'),
      repo('workspace-a', '/Users/dancer/me/workspace/project-a'),
    ]

    // After self-healing excludes llama-cpp:
    const excluded = new Set(['llama-cpp'])
    expect(selectPreferredIdeRepositoryId(repositories, null, excluded)).toBe('workspace-a')
  })
})

describe('IDE focus workspace provenance', () => {
  it('reselects observed focus for repo B and invalidates the repo A document before B resolves', async () => {
    const repoBTree = deferred<WorkspaceTreeResult>()
    repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([
      repo('repo-a', '/workspace/repo-a'),
      repo('repo-b', '/workspace/repo-b'),
    ])
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a') {
          return Promise.resolve(repositoryTree('repo-a', [changedFile('lib/a.ml')]))
        }
        if (opts.repoId === 'repo-b') return repoBTree.promise
        return Promise.resolve(projectTree([]))
      },
    )
    workspaceApiMocks.fetchWorkspaceFile.mockImplementation(
      (path: string, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a' && path === 'lib/a.ml') {
          return Promise.resolve(workspaceFile('let workspace = "repo-a"\n'))
        }
        if (opts.repoId === 'repo-b' && path === 'lib/b.ml') {
          return Promise.resolve(workspaceFile('let workspace = "repo-b"\n'))
        }
        return Promise.resolve(null)
      },
    )
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(store.activeRepositoryId()).toBe('repo-a')
        expect(activeIdeFocus.value).toEqual({
          path: 'lib/a.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'repository', repoId: 'repo-a' },
          availability: 'available',
        })
        expect(store.documentStore.document().content).toContain('repo-a')
      })

      store.setActiveRepositoryId('repo-b')

      expect(store.documentStore.document()).toMatchObject({
        file_path: null,
        content: '',
        lines: [],
      })
      expect(store.fileTreeStore.nodeCount()).toBe(0)
      expect(activeIdeFocus.value).toBeNull()

      repoBTree.resolve(repositoryTree('repo-b', [changedFile('lib/b.ml')]))
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'lib/b.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'repository', repoId: 'repo-b' },
          availability: 'available',
        })
        expect(store.documentStore.document()).toMatchObject({
          file_path: 'lib/b.ml',
          content: 'let workspace = "repo-b"\n',
        })
      })
    } finally {
      store.dispose()
    }
  })

  it('ignores a repo A file completion that arrives after repo B owns the focus', async () => {
    const staleRepoAFile = deferred<WorkspaceFileResponse | null>()
    repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([
      repo('repo-a', '/workspace/repo-a'),
      repo('repo-b', '/workspace/repo-b'),
    ])
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a') {
          return Promise.resolve(repositoryTree('repo-a', [changedFile('lib/a.ml')]))
        }
        if (opts.repoId === 'repo-b') {
          return Promise.resolve(repositoryTree('repo-b', [changedFile('lib/b.ml')]))
        }
        return Promise.resolve(projectTree([]))
      },
    )
    workspaceApiMocks.fetchWorkspaceFile.mockImplementation(
      (path: string, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a' && path === 'lib/a.ml') return staleRepoAFile.promise
        if (opts.repoId === 'repo-b' && path === 'lib/b.ml') {
          return Promise.resolve(workspaceFile('let workspace = "repo-b"\n'))
        }
        return Promise.resolve(null)
      },
    )
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toMatchObject({
          path: 'lib/a.ml',
          workspace_identity: { kind: 'repository', repoId: 'repo-a' },
          availability: 'available',
        })
        expect(workspaceApiMocks.fetchWorkspaceFile).toHaveBeenCalledWith(
          'lib/a.ml',
          expect.objectContaining({ repoId: 'repo-a' }),
        )
      })

      store.setActiveRepositoryId('repo-b')
      await vi.waitFor(() => {
        expect(store.documentStore.document()).toMatchObject({
          file_path: 'lib/b.ml',
          content: 'let workspace = "repo-b"\n',
        })
      })

      staleRepoAFile.resolve(workspaceFile('let workspace = "stale-repo-a"\n'))
      await staleRepoAFile.promise
      await Promise.resolve()

      expect(store.documentStore.document()).toMatchObject({
        file_path: 'lib/b.ml',
        content: 'let workspace = "repo-b"\n',
      })
    } finally {
      store.dispose()
    }
  })

  it('drops project auto-focus when a late repository list selects a repository', async () => {
    const repositories = deferred<ReadonlyArray<Repository>>()
    const repoTree = deferred<WorkspaceTreeResult>()
    repositoryApiMocks.fetchRepositoriesList.mockReturnValue(repositories.promise)
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-b') return repoTree.promise
        return Promise.resolve(projectTree([changedFile('project.ml')]))
      },
    )
    workspaceApiMocks.fetchWorkspaceFile.mockImplementation(
      (path: string, opts: { repoId?: string | null }) => {
        if (!opts.repoId && path === 'project.ml') {
          return Promise.resolve(workspaceFile('let workspace = "project"\n'))
        }
        if (opts.repoId === 'repo-b' && path === 'repo.ml') {
          return Promise.resolve(workspaceFile('let workspace = "repo-b"\n'))
        }
        return Promise.resolve(null)
      },
    )
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'project.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'project' },
          availability: 'available',
        })
        expect(store.documentStore.document().content).toContain('project')
      })

      repositories.resolve([repo('repo-b', '/workspace/repo-b')])
      await vi.waitFor(() => {
        expect(store.activeRepositoryId()).toBe('repo-b')
      })
      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
      expect(activeIdeFocus.value).toBeNull()

      repoTree.resolve(repositoryTree('repo-b', [changedFile('repo.ml')]))
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'repo.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'repository', repoId: 'repo-b' },
          availability: 'available',
        })
        expect(store.documentStore.document().content).toContain('repo-b')
      })
    } finally {
      store.dispose()
    }
  })

  it('invalidates and reselects observed focus when the keeper workspace changes', async () => {
    const keeperBTree = deferred<WorkspaceTreeResult>()
    activeKeeperName.value = 'keeper-a'
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { keeper?: string }) => {
        if (opts.keeper === 'keeper-a') {
          return Promise.resolve(keeperTree('keeper-a', [changedFile('a.ml')]))
        }
        if (opts.keeper === 'keeper-b') return keeperBTree.promise
        return Promise.resolve(projectTree([]))
      },
    )
    workspaceApiMocks.fetchWorkspaceFile.mockImplementation(
      (path: string, opts: { keeper?: string }) => {
        if (opts.keeper === 'keeper-a' && path === 'a.ml') {
          return Promise.resolve(workspaceFile('let workspace = "keeper-a"\n'))
        }
        if (opts.keeper === 'keeper-b' && path === 'b.ml') {
          return Promise.resolve(workspaceFile('let workspace = "keeper-b"\n'))
        }
        return Promise.resolve(null)
      },
    )
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(store.documentStore.document().content).toContain('keeper-a')
        expect(activeIdeFocus.value?.workspace_identity).toEqual({
          kind: 'keeper',
          keeper: 'keeper-a',
        })
      })

      activeKeeperName.value = 'keeper-b'

      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
      expect(activeIdeFocus.value).toBeNull()

      keeperBTree.resolve(keeperTree('keeper-b', [changedFile('b.ml')]))
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'b.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'keeper', keeper: 'keeper-b' },
          availability: 'available',
        })
        expect(store.documentStore.document().content).toContain('keeper-b')
      })
    } finally {
      store.dispose()
    }
  })

  it('keeps explicit provenance but materializes not-found when the target repo lacks the path', async () => {
    repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([
      repo('repo-a', '/workspace/repo-a'),
      repo('repo-b', '/workspace/repo-b'),
    ])
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a') return Promise.resolve(repositoryTree('repo-a', []))
        if (opts.repoId === 'repo-b') {
          return Promise.resolve(repositoryTree('repo-b', [changedFile('only-in-b.ml')]))
        }
        return Promise.resolve(projectTree([]))
      },
    )
    workspaceApiMocks.fetchWorkspaceFile.mockImplementation(
      (path: string, opts: { repoId?: string | null }) => {
        if (opts.repoId === 'repo-a' && path === 'shared.ml') {
          return Promise.resolve(workspaceFile('let workspace = "repo-a"\n'))
        }
        return Promise.resolve({ ok: false })
      },
    )
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(store.activeRepositoryId()).toBe('repo-a')
      })
      focusIdeFile({
        path: 'shared.ml',
        origin: 'operator',
        workspace_identity: { kind: 'repository', repoId: 'repo-a' },
        availability: 'available',
      })
      await vi.waitFor(() => {
        expect(store.documentStore.document().content).toContain('repo-a')
      })

      store.setActiveRepositoryId('repo-b')

      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'shared.ml',
          origin: 'operator',
          workspace_identity: { kind: 'repository', repoId: 'repo-b' },
          availability: 'not_found',
        })
        expect(store.workspaceIssues()).toContainEqual(expect.objectContaining({
          kind: 'file',
          file_path: 'shared.ml',
          repo_id: 'repo-b',
          message: 'explicit IDE focus not found in selected workspace: shared.ml',
        }))
      })
      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
    } finally {
      store.dispose()
    }
  })

  it('terminates explicit validation as unavailable on transport failure without claiming not-found', async () => {
    repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([
      repo('repo-a', '/workspace/repo-a'),
    ])
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => opts.repoId === 'repo-a'
        ? Promise.resolve(repositoryTree('repo-a', []))
        : Promise.resolve(projectTree([])),
    )
    workspaceApiMocks.fetchWorkspaceFile.mockRejectedValue(new Error('workspace transport offline'))
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(store.activeRepositoryId()).toBe('repo-a')
      })
      focusIdeFile({
        path: 'private.ml',
        origin: 'route',
        workspace_identity: { kind: 'repository', repoId: 'repo-a' },
        availability: 'pending',
      })

      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'private.ml',
          origin: 'route',
          workspace_identity: { kind: 'repository', repoId: 'repo-a' },
          availability: 'unavailable',
        })
        expect(store.workspaceIssues()).toContainEqual(expect.objectContaining({
          kind: 'file',
          file_path: 'private.ml',
          repo_id: 'repo-a',
          message: 'workspace transport offline',
        }))
      })
      expect(activeIdeFocus.value?.availability).not.toBe('not_found')
      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
    } finally {
      store.dispose()
    }
  })

  it('does not misclassify an unavailable observed file as an explicit not-found focus', async () => {
    repositoryApiMocks.fetchRepositoriesList.mockResolvedValue([
      repo('repo-a', '/workspace/repo-a'),
    ])
    workspaceApiMocks.fetchWorkspaceTree.mockImplementation(
      (_depth: number, opts: { repoId?: string | null }) => opts.repoId === 'repo-a'
        ? Promise.resolve(repositoryTree('repo-a', [changedFile('ghost.ml')]))
        : Promise.resolve(projectTree([])),
    )
    workspaceApiMocks.fetchWorkspaceFile.mockResolvedValue(null)
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(activeIdeFocus.value).toEqual({
          path: 'ghost.ml',
          origin: 'observed_change',
          workspace_identity: { kind: 'repository', repoId: 'repo-a' },
          availability: 'unavailable',
        })
        expect(store.workspaceIssues()).toContainEqual(expect.objectContaining({
          kind: 'file',
          file_path: 'ghost.ml',
          repo_id: 'repo-a',
          message: 'workspace file response was unavailable or malformed',
        }))
      })
      expect(workspaceApiMocks.fetchWorkspaceFile).toHaveBeenCalledTimes(1)
      expect(activeIdeFocus.value?.availability).not.toBe('not_found')
      expect(store.documentStore.document()).toMatchObject({ file_path: null, content: '' })
    } finally {
      store.dispose()
    }
  })
})

describe('workspace fetch diagnostics', () => {
  it('loads regions after the active file commits and projects them to source ownership', async () => {
    const previousFocus = activeIdeFocus.value
    const previousWorkspaceIdentity = activeIdeWorkspaceIdentity.value
    const previousKeeper = activeKeeperName.value
    const previousTask = selectedTask.value
    const previousRoute = route.value
    let resolveFile: (value: { ok: boolean; content: string; language: string }) => void = () => {
      throw new Error('workspace file request was not started')
    }

    vi.clearAllMocks()
    seedWorkspaceApiMocks()
    workspaceApiMocks.fetchWorkspaceFile.mockImplementationOnce(() => new Promise(resolve => {
      resolveFile = resolve
    }))
    ideApiMocks.fetchIdeRegions.mockResolvedValueOnce([{
      file_path: 'lib/scheduler/round.ml',
      line_start: 2,
      line_end: 3,
      keeper_id: 'sangsu',
      source_type: 'tool_call',
      source_tool_name: 'edit_file',
      source_turn: 7,
      source_note: null,
      timestamp_ms: 1_700_000_000_000,
    }])
    activeKeeperName.value = 'sangsu'
    synchronizeIdeWorkspaceIdentity({ kind: 'keeper', keeper: 'sangsu' })
    focusIdeFile({
      path: 'lib/scheduler/round.ml',
      origin: 'operator',
      workspace_identity: { kind: 'keeper', keeper: 'sangsu' },
      availability: 'available',
    })
    selectedTask.value = null
    route.value = { tab: 'code', params: { view: 'source' }, postId: null }
    const store = createIdeDataWorkspaceStore()

    try {
      await vi.waitFor(() => {
        expect(workspaceApiMocks.fetchWorkspaceFile).toHaveBeenCalledOnce()
      })
      expect(ideApiMocks.fetchIdeRegions).not.toHaveBeenCalled()

      resolveFile({ ok: true, content: 'let a = 1\nlet b = 2\n', language: 'ocaml' })

      await vi.waitFor(() => {
        expect(ideApiMocks.fetchIdeRegions).toHaveBeenCalledWith(
          'lib/scheduler/round.ml',
          expect.objectContaining({
            repoId: null,
            scope: { kind: 'keeper_lane', keeperId: 'sangsu' },
          }),
        )
      })
      await vi.waitFor(() => {
        expect(store.ownershipStore.ownership().get(2)).toMatchObject({
          keeper_id: 'sangsu',
          last_edit_kind: 'observed',
        })
      })
      expect(store.ownershipStore.ownership().get(3)).toMatchObject({
        keeper_id: 'sangsu',
      })
    } finally {
      store.dispose()
      synchronizeIdeWorkspaceIdentity(previousWorkspaceIdentity)
      if (previousFocus) focusIdeFile(previousFocus)
      else clearIdeFileFocus()
      activeKeeperName.value = previousKeeper
      selectedTask.value = previousTask
      route.value = previousRoute
    }
  })

  it('materializes failed fetches without stringly fallback coercion', () => {
    const issue = workspaceFetchIssueFromError('diff', new Error('network down'), {
      filePath: 'lib/runtime.ml',
      keeper: 'sangsu',
      repoId: 'masc',
      nowMs: 42,
    })

    expect(issue).toEqual({
      kind: 'diff',
      message: 'network down',
      file_path: 'lib/runtime.ml',
      keeper: 'sangsu',
      repo_id: 'masc',
      observed_at_ms: 42,
    })
  })

  it('keeps one issue per fetch scope and clears only that scope', () => {
    const treeIssue = workspaceFetchIssueFromError('tree', new Error('tree failed'), {
      repoId: 'masc',
      nowMs: 1,
    })!
    const diffIssue = workspaceFetchIssueFromError('diff', new Error('diff failed'), {
      filePath: 'lib/runtime.ml',
      repoId: 'masc',
      nowMs: 2,
    })!
    const newerDiffIssue = workspaceFetchIssueFromError('diff', new Error('diff still failed'), {
      filePath: 'lib/runtime.ml',
      repoId: 'masc',
      nowMs: 3,
    })!

    const issues = replaceWorkspaceFetchIssue(
      replaceWorkspaceFetchIssue(
        replaceWorkspaceFetchIssue([], treeIssue),
        diffIssue,
      ),
      newerDiffIssue,
    )

    expect(issues).toHaveLength(2)
    expect(issues.map(issue => issue.message)).toEqual(['tree failed', 'diff still failed'])
    expect(clearWorkspaceFetchIssue(issues, 'diff', {
      filePath: 'lib/runtime.ml',
      repoId: 'masc',
    })).toEqual([treeIssue])
  })

  it('does not record navigation aborts as degraded workspace fetches', () => {
    const abort = new DOMException('Aborted', 'AbortError')
    expect(workspaceFetchIssueFromError('file', abort)).toBeNull()
  })

  it('drops stale workspace-scoped issues when the active repo changes', () => {
    const repositoryIssue = workspaceFetchIssueFromError('repositories', new Error('repo list down'), {
      nowMs: 1,
    })!
    const oldTreeIssue = workspaceFetchIssueFromError('tree', new Error('old repo tree down'), {
      repoId: 'old-repo',
      nowMs: 2,
    })!
    const oldFileIssue = workspaceFetchIssueFromError('file', new Error('old repo same file down'), {
      filePath: 'README.md',
      repoId: 'old-repo',
      nowMs: 3,
    })!
    const currentDiffIssue = workspaceFetchIssueFromError('diff', new Error('current diff down'), {
      filePath: 'README.md',
      repoId: 'current-repo',
      nowMs: 4,
    })!

    expect(retainCurrentWorkspaceFetchIssues(
      [repositoryIssue, oldTreeIssue, oldFileIssue, currentDiffIssue],
      { filePath: 'README.md', repoId: 'current-repo' },
    )).toEqual([repositoryIssue, currentDiffIssue])
  })
})

describe('ide route view helpers', () => {
  it('normalizes legacy diff aliases through one shared helper', () => {
    expect(viewFromRoute('split')).toBe('split-diff')
    expect(viewFromRoute('split_diff')).toBe('split-diff')
    expect(viewFromRoute('merge')).toBe('split-diff')
    expect(isDiffEditorView(viewFromRoute('merge'))).toBe(true)
    expect(isDiffEditorView(viewFromRoute('unified'))).toBe(true)
    expect(isDiffEditorView(viewFromRoute('blame'))).toBe(false)
  })
})

describe('workspaceTreeIdentity', () => {
  it('treats the same source and base path as the same workspace', () => {
    const left = workspaceTreeIdentity({ kind: 'repository', repoId: 'masc' }, '/repo/masc')
    const right = workspaceTreeIdentity({ kind: 'repository', repoId: 'masc' }, '/repo/masc')

    expect(sameWorkspaceTreeIdentity(left, right)).toBe(true)
  })

  it('does not collapse distinct repository sources into one refresh identity', () => {
    const left = workspaceTreeIdentity({ kind: 'repository', repoId: 'masc' }, '/repo/masc')
    const right = workspaceTreeIdentity({ kind: 'repository', repoId: 'oas' }, '/repo/oas')

    expect(sameWorkspaceTreeIdentity(left, right)).toBe(false)
  })

  it('does not preserve lazy children across keeper source switches', () => {
    const left = workspaceTreeIdentity({ kind: 'playground', keeper: 'alpha' }, '/keepers/alpha')
    const right = workspaceTreeIdentity({ kind: 'playground', keeper: 'beta' }, '/keepers/beta')

    expect(sameWorkspaceTreeIdentity(left, right)).toBe(false)
  })

  it('uses basePath as part of project-source identity', () => {
    const left = workspaceTreeIdentity({ kind: 'project' }, '/Users/dancer/me')
    const right = workspaceTreeIdentity({ kind: 'project' }, '/Users/dancer/me/workspace/yousleepwhen/masc')

    expect(sameWorkspaceTreeIdentity(left, right)).toBe(false)
  })
})
