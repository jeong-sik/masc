import { describe, expect, it } from 'vitest'
import { GitGraphSchemaDriftError, parseGitGraphResponse } from './git-graph'

const sample = {
  generated_at: '2026-04-30T00:00:00Z',
  repos: [{
    id: 'repo:abc',
    root: '/tmp/repo',
    label: 'repo',
    current_branch: 'feature/a',
    head: 'abc123',
    dirty: true,
    conflict_count: 1,
    branch_count: 2,
    commit_count: 3,
    worktree_count: 1,
  }],
  agents: [{
    id: 'wt-feature-a',
    label: 'feature-a',
    branch: 'feature/a',
    worktree_path: '/tmp/repo/.worktrees/feature-a',
    color: '#3a86ff',
  }],
  nodes: [{
    id: 'ref:feature/a',
    kind: 'branch',
    label: 'feature/a',
    repo_id: 'repo:abc',
    agent_id: 'wt-feature-a',
    color: '#3a86ff',
    status: 'conflict',
    conflict: true,
    sha: 'abc123',
    branch: 'feature/a',
    detail: null,
  }],
  edges: [{
    id: 'points_to:commit:abc123->ref:feature/a',
    source: 'commit:abc123',
    target: 'ref:feature/a',
    kind: 'points_to',
    label: null,
  }],
  stats: {
    repo_count: 1,
    agent_count: 1,
    branch_count: 2,
    commit_count: 3,
    conflict_count: 1,
    dirty_count: 2,
  },
  warnings: [],
}

describe('parseGitGraphResponse', () => {
  it('accepts the Track 4 graph payload', () => {
    const parsed = parseGitGraphResponse(sample)
    expect(parsed.stats.conflict_count).toBe(1)
    expect(parsed.nodes[0]?.status).toBe('conflict')
  })

  it('throws on boundary drift', () => {
    expect(() => parseGitGraphResponse({ ...sample, nodes: [{ id: 'missing-fields' }] }))
      .toThrow(GitGraphSchemaDriftError)
  })
})
