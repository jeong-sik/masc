import { describe, expect, it } from 'vitest'
import type { GoalTreeNode, GoalTreeTask } from '../../types'
import { filterGoalTree, filterGoalTreeByPhase } from './goal-tree'

function makeTask(overrides: Partial<GoalTreeTask> = {}): GoalTreeTask {
  return {
    id: 'task-x',
    title: 'task title',
    status: 'todo',
    status_color: '#fff',
    priority: 0,
    assignee: null,
    goal_id: null,
    linkage_source: 'explicit',
    is_terminal: false,
    created_at: '2026-04-17T00:00:00Z',
    updated_at: '2026-04-17T00:00:00Z',
    ...overrides,
  }
}

function makeNode(overrides: Partial<GoalTreeNode> = {}): GoalTreeNode {
  return {
    id: 'node-x',
    title: 'goal title',
    horizon: 'quarterly',
    status: 'active',
    status_color: '#fff',
    phase: 'executing',
    phase_color: '#0ea5e9',
    health: 'on_track',
    health_color: '#4ade80',
    badges: [],
    status_reason: 'progressing',
    priority: 0,
    metric: null,
    target_value: null,
    due_date: null,
    parent_goal_id: null,
    convergence: 0,
    convergence_pct: 0,
    tasks: [],
    task_count: 0,
    task_done_count: 0,
    verification_summary: {
      effective_policy: null,
      open_request: null,
      latest_request: null,
      approve_count: 0,
      reject_count: 0,
      remaining_possible: 0,
    },
    effective_verifier_policy: null,
    active_verification_request: null,
    pending_verification_count: 0,
    timeline_events: [],
    children: [],
    child_count: 0,
    last_activity_at: '2026-04-17T00:00:00Z',
    stagnation_seconds: 0,
    linked_keeper_names: [],
    pending_approval_count: 0,
    infra_risk_count: 0,
    linkage_source: 'none',
    linkage_warning_count: 0,
    blocking_source: 'none',
    blocking_reason: '',
    latest_keeper_ref: null,
    latest_turn_ref: null,
    stalled_since: null,
    created_at: '2026-04-17T00:00:00Z',
    updated_at: '2026-04-17T00:00:00Z',
    ...overrides,
  }
}

describe('filterGoalTree', () => {
  it('returns the input reference when query is empty', () => {
    const nodes: readonly GoalTreeNode[] = [makeNode({ id: 'a', title: 'Alpha' })]
    expect(filterGoalTree(nodes, '')).toBe(nodes)
  })

  it('returns the input reference when query is whitespace only', () => {
    const nodes: readonly GoalTreeNode[] = [makeNode({ id: 'a', title: 'Alpha' })]
    expect(filterGoalTree(nodes, '   ')).toBe(nodes)
  })

  it('matches by node title (case-insensitive)', () => {
    const nodes: readonly GoalTreeNode[] = [
      makeNode({ id: 'a', title: 'Alpha Goal' }),
      makeNode({ id: 'b', title: 'Beta Goal' }),
    ]
    const result = filterGoalTree(nodes, 'ALPHA')
    expect(result.map(n => n.id)).toEqual(['a'])
  })

  it('trims the query before matching', () => {
    const nodes: readonly GoalTreeNode[] = [makeNode({ id: 'a', title: 'Alpha' })]
    expect(filterGoalTree(nodes, '  alp  ').map(n => n.id)).toEqual(['a'])
  })

  it('returns empty when nothing in the forest matches', () => {
    const nodes: readonly GoalTreeNode[] = [
      makeNode({ id: 'a', title: 'Alpha' }),
      makeNode({ id: 'b', title: 'Beta' }),
    ]
    expect(filterGoalTree(nodes, 'nonexistent-token')).toHaveLength(0)
  })

  it('preserves ancestors when a descendant matches', () => {
    const leaf = makeNode({ id: 'leaf', title: 'Payment Flow Fix' })
    const mid = makeNode({ id: 'mid', title: 'Checkout Refactor', children: [leaf] })
    const root = makeNode({ id: 'root', title: 'Q2 Platform Goals', children: [mid] })

    const result = filterGoalTree([root], 'payment')
    expect(result).toHaveLength(1)
    const rootOut = result[0]!
    expect(rootOut.id).toBe('root')
    expect(rootOut.children).toHaveLength(1)
    const midOut = rootOut.children[0]!
    expect(midOut.id).toBe('mid')
    expect(midOut.children).toHaveLength(1)
    expect(midOut.children[0]!.id).toBe('leaf')
  })

  it('keeps the entire subtree when an ancestor itself matches', () => {
    const leafA = makeNode({ id: 'la', title: 'Leaf A' })
    const leafB = makeNode({ id: 'lb', title: 'Leaf B' })
    const root = makeNode({ id: 'root', title: 'Platform Migration', children: [leafA, leafB] })

    const result = filterGoalTree([root], 'migration')
    expect(result).toHaveLength(1)
    // Self-match short-circuits — returns node as-is, children untouched.
    expect(result[0]).toBe(root)
    expect(result[0]!.children.map(c => c.id)).toEqual(['la', 'lb'])
  })

  it('matches by attached task title and prunes non-matching tasks', () => {
    const root = makeNode({
      id: 'root',
      title: 'Unrelated Goal',
      tasks: [
        makeTask({ id: 't1', title: 'investigate FD leak' }),
        makeTask({ id: 't2', title: 'refresh dashboard copy' }),
      ],
    })

    const result = filterGoalTree([root], 'fd leak')
    expect(result).toHaveLength(1)
    expect(result[0]!.tasks.map(t => t.id)).toEqual(['t1'])
    // Should NOT mutate input.
    expect(root.tasks).toHaveLength(2)
  })

  it('drops a node that has no match in title, tasks, or descendants', () => {
    const sibling = makeNode({ id: 'keep', title: 'Alpha Goal' })
    const dropped = makeNode({
      id: 'drop',
      title: 'Unrelated',
      tasks: [makeTask({ id: 't1', title: 'also unrelated' })],
      children: [makeNode({ id: 'drop-child', title: 'nothing here' })],
    })
    const result = filterGoalTree([sibling, dropped], 'alpha')
    expect(result.map(n => n.id)).toEqual(['keep'])
  })

  it('does not mutate the input nodes or their children / tasks arrays', () => {
    const leaf = makeNode({ id: 'leaf', title: 'Payment Work' })
    const other = makeNode({ id: 'other', title: 'Unrelated' })
    const root = makeNode({
      id: 'root',
      title: 'Root',
      children: [leaf, other],
      tasks: [makeTask({ id: 't1', title: 'payment followup' }), makeTask({ id: 't2', title: 'skip me' })],
    })

    const snapshotChildren = root.children.slice()
    const snapshotTasks = root.tasks.slice()

    filterGoalTree([root], 'payment')

    expect(root.children).toEqual(snapshotChildren)
    expect(root.tasks).toEqual(snapshotTasks)
  })

  it('treats empty or missing task titles as non-matches without crashing', () => {
    const root = makeNode({
      id: 'root',
      title: 'Unrelated',
      tasks: [
        makeTask({ id: 't1', title: '' }),
        // Simulate a backend-produced node whose title field is missing; the
        // filter must fall through to children / tasks rather than throw.
        makeTask({ id: 't2', title: undefined as unknown as string }),
      ],
    })
    const result = filterGoalTree([root], 'anything')
    expect(result).toHaveLength(0)
  })
})

describe('filterGoalTreeByPhase', () => {
  it('returns the input reference when phase filter is all', () => {
    const nodes: readonly GoalTreeNode[] = [makeNode({ id: 'a', phase: 'executing' })]
    expect(filterGoalTreeByPhase(nodes, 'all')).toBe(nodes)
  })

  it('keeps only nodes whose phase matches exactly', () => {
    const nodes: readonly GoalTreeNode[] = [
      makeNode({ id: 'a', phase: 'executing' }),
      makeNode({ id: 'b', phase: 'awaiting_approval' }),
      makeNode({ id: 'c', phase: 'blocked' }),
    ]
    const result = filterGoalTreeByPhase(nodes, 'awaiting_approval')
    expect(result.map(node => node.id)).toEqual(['b'])
  })

  it('preserves ancestors when a descendant matches the phase filter', () => {
    const leaf = makeNode({ id: 'leaf', phase: 'blocked', title: 'Blocked leaf' })
    const mid = makeNode({
      id: 'mid',
      phase: 'executing',
      title: 'Executing ancestor',
      tasks: [makeTask({ id: 't-mid', title: 'ancestor task' })],
      children: [leaf],
    })
    const root = makeNode({ id: 'root', phase: 'executing', children: [mid] })

    const result = filterGoalTreeByPhase([root], 'blocked')
    expect(result).toHaveLength(1)
    expect(result[0]!.id).toBe('root')
    expect(result[0]!.tasks).toEqual([])
    expect(result[0]!.children).toHaveLength(1)
    expect(result[0]!.children[0]!.id).toBe('mid')
    expect(result[0]!.children[0]!.tasks).toEqual([])
    expect(result[0]!.children[0]!.children[0]!.id).toBe('leaf')
  })

  it('prunes non-matching descendants even when the parent matches', () => {
    const root = makeNode({
      id: 'root',
      phase: 'executing',
      children: [
        makeNode({ id: 'keep', phase: 'executing' }),
        makeNode({ id: 'drop', phase: 'completed' }),
      ],
    })

    const result = filterGoalTreeByPhase([root], 'executing')
    expect(result).toHaveLength(1)
    expect(result[0]!.children.map(child => child.id)).toEqual(['keep'])
  })
})
