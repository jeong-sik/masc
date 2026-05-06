import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { waitFor } from '@testing-library/preact'
import type { GitGraphResponse } from '../../api/git-graph'
import {
  buildIdeBranchContextModel,
  IdeBranchContextPanel,
} from './ide-branch-context-panel'

function makeGraph(overrides: Partial<GitGraphResponse> = {}): GitGraphResponse {
  return {
    generated_at: '2026-05-06T00:00:00Z',
    repos: [
      {
        id: 'masc',
        root: '/workspace/masc-mcp',
        label: 'masc-mcp',
        current_branch: 'fix/ide-branch',
        head: 'abcdef1234567890',
        dirty: true,
        conflict_count: 0,
        branch_count: 3,
        commit_count: 24,
        worktree_count: 2,
      },
    ],
    agents: [
      {
        id: 'lane-1',
        label: 'sangsu',
        branch: 'fix/ide-branch',
        worktree_path: '/workspace/masc-mcp/.worktrees/fix-ide-branch',
        color: '#d4a14a',
      },
    ],
    nodes: [
      {
        id: 'branch-current',
        kind: 'branch',
        label: 'fix/ide-branch',
        repo_id: 'masc',
        agent_id: 'lane-1',
        color: '#d4a14a',
        status: 'current',
        conflict: false,
        sha: 'abcdef1234567890',
        branch: 'fix/ide-branch',
        detail: 'current branch',
      },
      {
        id: 'branch-main',
        kind: 'branch',
        label: 'main',
        repo_id: 'masc',
        agent_id: null,
        color: null,
        status: 'clean',
        conflict: false,
        sha: '1111111111',
        branch: 'main',
        detail: null,
      },
    ],
    edges: [],
    stats: {
      repo_count: 1,
      agent_count: 1,
      branch_count: 3,
      commit_count: 24,
      conflict_count: 0,
      dirty_count: 1,
    },
    warnings: [],
    ...overrides,
  }
}

describe('buildIdeBranchContextModel', () => {
  it('maps graph data to compact IDE branch context', () => {
    const model = buildIdeBranchContextModel(makeGraph(), 'masc')

    expect(model?.repoLabel).toBe('masc-mcp')
    expect(model?.currentBranch).toBe('fix/ide-branch')
    expect(model?.head).toBe('abcdef1234')
    expect(model?.status).toBe('dirty')
    expect(model?.branches[0]?.tone).toBe('current')
    expect(model?.lanes[0]?.path).toBe('.worktrees/fix-ide-branch')
  })

  it('prefers conflict status over dirty status', () => {
    const model = buildIdeBranchContextModel(
      makeGraph({
        repos: [{
          ...makeGraph().repos[0]!,
          dirty: true,
          conflict_count: 2,
        }],
      }),
      'masc',
    )

    expect(model?.status).toBe('conflict')
    expect(model?.stats.conflictCount).toBe(2)
  })

  it('returns null when graph has no repositories', () => {
    expect(buildIdeBranchContextModel(makeGraph({ repos: [] }), null)).toBeNull()
  })
})

describe('IdeBranchContextPanel', () => {
  it('fetches active repository graph and renders compact branch context', async () => {
    const fetchGraph = vi.fn().mockResolvedValue(makeGraph())
    const container = document.createElement('div')

    render(
      h(IdeBranchContextPanel, {
        activeRepositoryId: () => 'masc',
        fetchGraph,
        refreshMs: null,
      }),
      container,
    )

    await waitFor(() => expect(container.textContent).toContain('BRANCH GRAPH'))
    await waitFor(() => expect(container.textContent).toContain('masc-mcp'))

    expect(fetchGraph).toHaveBeenCalledWith(expect.objectContaining({ limit: 80, repoId: 'masc' }))
    expect(container.textContent).toContain('fix/ide-branch')
    expect(container.textContent).toContain('abcdef1234')
    expect(container.querySelector('svg[aria-label="Branch graph for masc-mcp"]')).not.toBeNull()
  })

  it('waits for an active repository before fetching branch graph data', async () => {
    const fetchGraph = vi.fn().mockResolvedValue(makeGraph())
    const container = document.createElement('div')

    render(
      h(IdeBranchContextPanel, {
        activeRepositoryId: () => null,
        fetchGraph,
        refreshMs: null,
      }),
      container,
    )

    await waitFor(() => expect(container.textContent).toContain('select repository'))
    expect(fetchGraph).not.toHaveBeenCalled()
  })

  it('refreshes when active repository subscription fires', async () => {
    let repoId: string | null = 'masc'
    const listeners = new Set<() => void>()
    const fetchGraph = vi.fn().mockResolvedValue(makeGraph())
    const container = document.createElement('div')

    render(
      h(IdeBranchContextPanel, {
        activeRepositoryId: () => repoId,
        subscribeActiveRepositoryId: (listener) => {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
        fetchGraph,
        refreshMs: null,
      }),
      container,
    )

    await waitFor(() => expect(fetchGraph).toHaveBeenCalledTimes(1))
    await act(() => {
      repoId = 'oas'
      listeners.forEach(listener => listener())
      return Promise.resolve()
    })

    await waitFor(() => expect(fetchGraph).toHaveBeenCalledWith(expect.objectContaining({ repoId: 'oas' })))
  })

  it('renders error state without throwing', async () => {
    const fetchGraph = vi.fn().mockRejectedValue(new Error('graph down'))
    const container = document.createElement('div')

    render(
      h(IdeBranchContextPanel, {
        activeRepositoryId: () => 'masc',
        fetchGraph,
        refreshMs: null,
      }),
      container,
    )

    await waitFor(() => expect(container.textContent).toContain('git graph unavailable: graph down'))
    expect(container.querySelector('[role="alert"]')).not.toBeNull()
  })
})
