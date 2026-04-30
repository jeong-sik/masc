import { describe, expect, it } from 'vitest'
import {
  COLLAB_MVP_STACK,
  COLLAB_TRACK8_PERFORMANCE_BUDGET,
  buildCollabMvpProjection,
  evaluateCollabPerformanceBudget,
} from './collab-mvp-contract'
import { normalizeTask } from './store-normalizers'
import type { Agent, Task } from './types'

describe('COLLAB_MVP_STACK', () => {
  it('separates installed dashboard pieces from contract-only Track 1 pieces', () => {
    expect(COLLAB_MVP_STACK.find(item => item.id === 'cytoscape-git-graph')).toMatchObject({
      packageName: 'cytoscape',
      status: 'installed',
      owner: 'masc',
    })
    expect(COLLAB_MVP_STACK.find(item => item.id === 'yjs-document')).toMatchObject({
      packageName: 'yjs',
      status: 'contract',
      owner: 'masc',
    })
  })
})

describe('COLLAB_TRACK8_PERFORMANCE_BUDGET', () => {
  it('captures the Track 8 dashboard collaboration performance targets', () => {
    expect(COLLAB_TRACK8_PERFORMANCE_BUDGET).toEqual([
      expect.objectContaining({
        id: 'sync_latency_p95_ms',
        unit: 'ms',
        target: 100,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'ws_connect_p95_ms',
        unit: 'ms',
        target: 500,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'checks_rate',
        unit: 'ratio',
        target: 0.99,
        comparator: 'gt',
      }),
      expect.objectContaining({
        id: 'keystroke_latency_ms',
        unit: 'ms',
        target: 16,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'fps',
        unit: 'fps',
        target: 55,
        comparator: 'gte',
      }),
      expect.objectContaining({
        id: 'lcp_ms',
        unit: 'ms',
        target: 2500,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'inp_ms',
        unit: 'ms',
        target: 200,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'document_size_bytes',
        unit: 'bytes',
        target: 10 * 1024 * 1024,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'merge_12_docs_ms',
        unit: 'ms',
        target: 100,
        comparator: 'lt',
      }),
      expect.objectContaining({
        id: 'ops_per_sec',
        unit: 'ops/sec',
        target: 1000,
        comparator: 'gt',
      }),
    ])
    expect(COLLAB_TRACK8_PERFORMANCE_BUDGET.every(metric =>
      metric.owner === 'masc' && metric.sourceSection === 'multiagent-ide-deep-analysis.md#8'
    )).toBe(true)
  })
})

describe('evaluateCollabPerformanceBudget', () => {
  it('passes samples that satisfy strict and inclusive Track 8 targets', () => {
    expect(evaluateCollabPerformanceBudget({
      sync_latency_p95_ms: 99.9,
      ws_connect_p95_ms: 499,
      checks_rate: 0.991,
      keystroke_latency_ms: 15.9,
      fps: 55,
      lcp_ms: 2499,
      inp_ms: 199,
      document_size_bytes: 10 * 1024 * 1024 - 1,
      merge_12_docs_ms: 99,
      ops_per_sec: 1001,
    })).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: 'sync_latency_p95_ms', pass: true }),
      expect.objectContaining({ id: 'fps', pass: true }),
      expect.objectContaining({ id: 'ops_per_sec', pass: true }),
    ]))
  })

  it('fails boundary and non-finite samples that violate the contract', () => {
    expect(evaluateCollabPerformanceBudget({
      sync_latency_p95_ms: 100,
      ws_connect_p95_ms: 500,
      checks_rate: 0.99,
      keystroke_latency_ms: 16,
      fps: 54.99,
      lcp_ms: 2500,
      inp_ms: 200,
      document_size_bytes: 10 * 1024 * 1024,
      merge_12_docs_ms: 100,
      ops_per_sec: Number.POSITIVE_INFINITY,
    })).toEqual([
      expect.objectContaining({ id: 'sync_latency_p95_ms', pass: false }),
      expect.objectContaining({ id: 'ws_connect_p95_ms', pass: false }),
      expect.objectContaining({ id: 'checks_rate', pass: false }),
      expect.objectContaining({ id: 'keystroke_latency_ms', pass: false }),
      expect.objectContaining({ id: 'fps', pass: false }),
      expect.objectContaining({ id: 'lcp_ms', pass: false }),
      expect.objectContaining({ id: 'inp_ms', pass: false }),
      expect.objectContaining({ id: 'document_size_bytes', pass: false }),
      expect.objectContaining({ id: 'merge_12_docs_ms', pass: false }),
      expect.objectContaining({ id: 'ops_per_sec', pass: false }),
    ])
  })
})

describe('buildCollabMvpProjection', () => {
  it('projects TODO claims, turn queue, and worktree-backed graph nodes', () => {
    const agents: Agent[] = [
      { name: 'keeper-a', status: 'active', current_task: null, last_seen: '2026-04-30T01:00:00Z' },
      { name: 'keeper-b', status: 'idle', current_task: null },
      { name: 'keeper-offline', status: 'offline', current_task: null },
    ]
    const tasks: Task[] = [
      {
        id: 'task-1',
        title: 'Implement Track 1',
        status: 'claimed',
        priority: 1,
        assignee: 'keeper-a',
        goal_id: 'goal-1',
        worktree: {
          branch: 'track1-masc-collab-mvp',
          path: '/repo/.worktrees/track1-masc-collab-mvp',
          git_root: '/repo',
          repo_name: 'masc-mcp',
        },
      },
      {
        id: 'task-2',
        title: 'Backlog item',
        status: 'todo',
        priority: 4,
      },
    ]

    const projection = buildCollabMvpProjection({
      agents,
      tasks,
      boardPosts: [],
      nowIso: '2026-04-30T02:00:00Z',
    })

    expect(projection.generatedAt).toBe('2026-04-30T02:00:00Z')
    expect(projection.summary).toMatchObject({
      activeAgents: 2,
      openClaims: 2,
      unclaimedTasks: 1,
      worktreeBackedBranches: 1,
      boardObservations: 0,
    })
    expect(projection.todoClaims[0]).toMatchObject({
      taskId: 'task-1',
      claimant: 'keeper-a',
      branch: 'track1-masc-collab-mvp',
      repoName: 'masc-mcp',
      state: 'claimed',
    })
    expect(projection.turnQueue[0]).toMatchObject({
      agentName: 'keeper-a',
      state: 'running',
      currentTaskId: 'task-1',
      rank: 1,
    })
    expect(projection.gitGraph.source).toBe('worktree')
    expect(projection.gitGraph.nodes.map(node => node.id)).toEqual(expect.arrayContaining([
      'repo:masc-mcp',
      'main:masc-mcp',
      'branch:masc-mcp:track1-masc-collab-mvp',
      'task:task-1',
    ]))
  })

  it('falls back to coordination-derived branches for active tasks without worktree metadata', () => {
    const projection = buildCollabMvpProjection({
      agents: [{ name: 'keeper-a', status: 'active', current_task: null }],
      tasks: [{
        id: 'task-9',
        title: 'No worktree yet',
        status: 'in_progress',
        assignee: 'keeper-a',
      }],
      boardPosts: [],
      nowIso: '2026-04-30T02:00:00Z',
    })

    expect(projection.todoClaims[0]).toMatchObject({
      taskId: 'task-9',
      branch: 'keeper-a/task-9',
      repoName: null,
      state: 'running',
    })
    expect(projection.gitGraph.source).toBe('coordination_fallback')
  })
})

describe('normalizeTask worktree metadata', () => {
  it('preserves task worktree fields for Track 1 git graph projection', () => {
    expect(normalizeTask({
      id: 'task-1',
      title: 'Implement Track 1',
      worktree: {
        branch: 'track1',
        path: '/repo/.worktrees/track1',
        git_root: '/repo',
        repo_name: 'masc-mcp',
      },
    })?.worktree).toEqual({
      branch: 'track1',
      path: '/repo/.worktrees/track1',
      git_root: '/repo',
      repo_name: 'masc-mcp',
    })
  })
})
