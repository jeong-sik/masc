import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { h, type ComponentChildren } from 'preact'
import { render } from 'preact'

vi.mock('./git-graph-store', () => {
  const mockState = { value: { data: null, loading: false, error: null } }
  return {
    gitGraphResource: { state: mockState },
    refreshGitGraph: vi.fn(),
    cancelGitGraphRefresh: vi.fn(),
  }
})

vi.mock('./git-graph-view', () => ({
  GitGraphView: () => h('div', { 'data-testid': 'git-graph-view' }, 'GitGraphView'),
}))

vi.mock('./common/feedback-state', () => ({
  LoadingState: ({ children }: { children?: ComponentChildren }) => h('div', { 'data-testid': 'loading-state' }, children),
  ErrorRecoverable: ({ title, detail }: { title: string; detail?: string }) => h('div', { 'data-testid': 'error-recoverable' }, [title, detail]),
  EmptyState: ({ message }: { message: string }) => h('div', { 'data-testid': 'empty-state' }, message),
}))

vi.mock('./common/button', () => ({
  ActionButton: ({ children, disabled, onClick }: {
    children?: ComponentChildren
    disabled?: boolean
    onClick?: () => void
  }) =>
    h('button', { disabled, onClick }, children),
}))

vi.mock('./common/time-ago', () => ({
  TimeAgo: ({ timestamp }: { timestamp?: string | null }) => h('span', null, timestamp),
}))

import { GitGraphPanel } from './git-graph-panel'
import { gitGraphResource, refreshGitGraph } from './git-graph-store'
import type { GitGraphResponse } from '../api/git-graph'

const mockRefreshGitGraph = vi.mocked(refreshGitGraph)
const gitGraphStats: GitGraphResponse['stats'] = {
  repo_count: 0,
  agent_count: 0,
  branch_count: 0,
  commit_count: 0,
  dirty_count: 0,
  conflict_count: 0,
}

function makeRepo(overrides: Partial<GitGraphResponse['repos'][number]> = {}): GitGraphResponse['repos'][number] {
  return {
    id: 'repo-1',
    root: '/workspace/masc',
    label: 'masc-mcp',
    current_branch: 'main',
    head: 'abc123',
    dirty: false,
    conflict_count: 0,
    branch_count: 0,
    commit_count: 0,
    worktree_count: 0,
    ...overrides,
  }
}

function makeGraph(overrides: Partial<GitGraphResponse> = {}): GitGraphResponse {
  return {
    generated_at: '',
    repos: [],
    agents: [],
    nodes: [],
    edges: [],
    stats: gitGraphStats,
    warnings: [],
    ...overrides,
  }
}

describe('GitGraphPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    gitGraphResource.state.value = { data: null, loading: false, error: null }
    vi.clearAllMocks()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders loading state', () => {
    gitGraphResource.state.value = { data: null, loading: true, error: null }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('Git graph 불러오는 중')
  })

  it('renders error state when no graph and error', () => {
    gitGraphResource.state.value = { data: null, loading: false, error: 'network fail' }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('Git graph snapshot을 불러오지 못했습니다')
    expect(container.textContent).toContain('network fail')
  })

  it('renders empty state when no repos', () => {
    gitGraphResource.state.value = {
      data: makeGraph(),
      loading: false,
      error: null,
    }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('Git repository snapshot이 없습니다')
  })

  it('renders loaded state with repo info and stats', () => {
    gitGraphResource.state.value = {
      data: makeGraph({
        repos: [makeRepo()],
        stats: { repo_count: 1, agent_count: 2, branch_count: 3, commit_count: 4, dirty_count: 5, conflict_count: 6 },
        warnings: [],
        generated_at: '2026-05-01T10:00:00Z',
      }),
      loading: false,
      error: null,
    }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('masc-mcp')
    expect(container.textContent).toContain('/workspace/masc')
    expect(container.textContent).toContain('Repos')
    expect(container.textContent).toContain('1')
    expect(container.textContent).toContain('Worktrees')
    expect(container.textContent).toContain('2')
    expect(container.textContent).toContain('Commits')
    expect(container.textContent).toContain('4')
  })

  it('renders warning banner when warnings present', () => {
    gitGraphResource.state.value = {
      data: makeGraph({
        repos: [makeRepo()],
        stats: { repo_count: 1, agent_count: 0, branch_count: 0, commit_count: 0, dirty_count: 0, conflict_count: 0 },
        warnings: ['dirty worktree detected'],
        generated_at: '',
      }),
      loading: false,
      error: null,
    }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('dirty worktree detected')
  })

  it('renders git graph view child', () => {
    gitGraphResource.state.value = {
      data: makeGraph({
        repos: [makeRepo()],
        stats: { repo_count: 1, agent_count: 0, branch_count: 0, commit_count: 0, dirty_count: 0, conflict_count: 0 },
        warnings: [],
        generated_at: '',
      }),
      loading: false,
      error: null,
    }
    render(h(GitGraphPanel, null), container)
    expect(container.querySelector('[data-testid="git-graph-view"]')).not.toBeNull()
  })

  it('refreshes graph from toolbar action', () => {
    gitGraphResource.state.value = {
      data: makeGraph({
        repos: [makeRepo()],
        stats: { repo_count: 1, agent_count: 0, branch_count: 0, commit_count: 0, dirty_count: 0, conflict_count: 0 },
        warnings: [],
        generated_at: '',
      }),
      loading: false,
      error: null,
    }
    render(h(GitGraphPanel, null), container)
    mockRefreshGitGraph.mockClear()
    const refreshButton = Array.from(container.querySelectorAll<HTMLButtonElement>('button')).find(
      button => button.textContent?.includes('새로고침'),
    )
    expect(refreshButton).not.toBeUndefined()
    refreshButton!.click()
    expect(mockRefreshGitGraph).toHaveBeenCalledTimes(1)
  })

  it('shows secondary error banner when graph exists but error present', () => {
    gitGraphResource.state.value = {
      data: makeGraph({
        repos: [makeRepo()],
        stats: { repo_count: 1, agent_count: 0, branch_count: 0, commit_count: 0, dirty_count: 0, conflict_count: 0 },
        warnings: [],
        generated_at: '',
      }),
      loading: false,
      error: 'refresh failed',
    }
    render(h(GitGraphPanel, null), container)
    expect(container.textContent).toContain('마지막 자동 갱신이 실패했습니다')
    expect(container.textContent).toContain('refresh failed')
  })
})
