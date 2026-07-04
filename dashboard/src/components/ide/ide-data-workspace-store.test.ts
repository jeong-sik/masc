import { describe, expect, it } from 'vitest'
import {
  clearWorkspaceFetchIssue,
  replaceWorkspaceFetchIssue,
  retainCurrentWorkspaceFetchIssues,
  sameWorkspaceTreeIdentity,
  selectPreferredIdeRepositoryId,
  workspaceFetchIssueFromError,
  workspaceTreeIdentity,
} from './ide-data-workspace-store'
import { isDiffEditorView, viewFromRoute } from './ide-view-route'
import type { Repository } from '../../api/repositories'

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

describe('workspace fetch diagnostics', () => {
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
