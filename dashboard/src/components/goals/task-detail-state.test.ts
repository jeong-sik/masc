import { describe, expect, it } from 'vitest'
import { buildTaskLineage, filterGoalRelations, filterTaskEvents, taskLineageStage } from './task-detail-state'
import type { NormalizedTaskEvent } from './task-detail-state'
import type { Goal } from '../../types'

function lineageEvent(overrides: Partial<NormalizedTaskEvent> & { label: string }): NormalizedTaskEvent {
  return { agent: null, actorKind: null, taskId: 't-1', ts: null, notes: null, ...overrides }
}

const sample: NormalizedTaskEvent[] = [
  {
    label: 'claim',
    agent: 'alice',
    actorKind: 'keeper',
    taskId: 't-1',
    ts: '2026-04-17T00:00:00Z',
    notes: 'picked up high-priority task',
  },
  {
    label: 'done',
    agent: 'executor',
    actorKind: 'keeper',
    taskId: 't-2',
    ts: '2026-04-17T01:00:00Z',
    notes: null,
  },
  {
    label: 'cancelled',
    agent: null,
    actorKind: null,
    taskId: 't-3',
    ts: '2026-04-17T02:00:00Z',
    notes: 'superseded by newer plan',
  },
  {
    label: 'approve',
    agent: 'verifier',
    actorKind: 'human',
    taskId: 't-4',
    ts: null,
    notes: 'looks good',
  },
  {
    // row with only the required label field populated
    label: 'unknown',
    agent: null,
    actorKind: null,
    taskId: null,
    ts: null,
    notes: null,
  },
]

describe('filterTaskEvents', () => {
  it('returns the input reference when query is empty', () => {
    expect(filterTaskEvents(sample, '')).toBe(sample)
    expect(filterTaskEvents(sample, '   ')).toBe(sample)
  })

  it('matches case-insensitive substring on label', () => {
    const out = filterTaskEvents(sample, 'CANCEL')
    expect(out.map(e => e.label)).toEqual(['cancelled'])
  })

  it('matches on agent', () => {
    const out = filterTaskEvents(sample, 'alice')
    expect(out.map(e => e.label)).toEqual(['claim'])
  })

  it('matches on actorKind', () => {
    const out = filterTaskEvents(sample, 'human')
    expect(out.map(e => e.label)).toEqual(['approve'])
  })

  it('matches on notes substring', () => {
    const out = filterTaskEvents(sample, 'superseded')
    expect(out.map(e => e.label)).toEqual(['cancelled'])
  })

  it('trims whitespace around the query', () => {
    const out = filterTaskEvents(sample, '  done  ')
    expect(out.map(e => e.label)).toEqual(['done'])
  })

  it('returns empty array when nothing matches', () => {
    expect(filterTaskEvents(sample, 'no-such-needle')).toEqual([])
  })

  it('handles rows with missing optional fields without throwing', () => {
    // label='unknown' row has every other field null; it must be filterable
    const out = filterTaskEvents(sample, 'unknown')
    expect(out.map(e => e.label)).toEqual(['unknown'])
  })

  it('does not mutate the input array', () => {
    const before = sample.slice()
    filterTaskEvents(sample, 'alice')
    expect(sample).toEqual(before)
  })

  it('can match multiple rows when substring is shared', () => {
    const out = filterTaskEvents(sample, 'keeper')
    expect(out.map(e => e.label)).toEqual(['claim', 'done'])
  })
})

function makeGoal(overrides: Partial<Goal> = {}): Goal {
  return {
    id: 'g-1',
    title: 'default title',
    metric: null,
    target_value: null,
    due_date: null,
    priority: 3,
    status: 'active',
    phase: 'executing',
    parent_goal_id: null,
    last_review_note: null,
    last_review_at: null,
    created_at: '2026-04-17T00:00:00Z',
    updated_at: '2026-04-17T00:00:00Z',
    ...overrides,
  }
}

describe('filterGoalRelations', () => {
  const store: Record<string, Goal> = {
    'g-alpha': makeGoal({ id: 'g-alpha', title: 'Reduce tool error rate', status: 'active', metric: 'error_rate' }),
    'g-beta': makeGoal({ id: 'g-beta', title: 'Lift runtime coverage', status: 'paused', metric: 'coverage_pct' }),
    'g-gamma': makeGoal({ id: 'g-gamma', title: 'Keeper idle audit', status: 'completed', metric: null }),
  }
  const ids: string[] = ['g-alpha', 'g-beta', 'g-gamma', 'g-orphan']
  const resolve = (id: string): Goal | undefined => store[id]

  it('returns the input reference when query is empty', () => {
    expect(filterGoalRelations(ids, '', resolve)).toBe(ids)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterGoalRelations(ids, '   ', resolve)).toBe(ids)
  })

  it('trims query before matching', () => {
    expect(filterGoalRelations(ids, '  alpha  ', resolve)).toEqual(['g-alpha'])
  })

  it('matches resolved goal title (case-insensitive)', () => {
    const out = filterGoalRelations(ids, 'RUNTIME', resolve)
    expect(out).toEqual(['g-beta'])
  })

  it('matches resolved goal status', () => {
    const out = filterGoalRelations(ids, 'paused', resolve)
    expect(out).toEqual(['g-beta'])
  })

  it('matches resolved goal metric substring', () => {
    const out = filterGoalRelations(ids, 'coverage', resolve)
    expect(out).toEqual(['g-beta'])
  })

  it('matches raw id even when the goal is unresolved', () => {
    const out = filterGoalRelations(ids, 'orphan', resolve)
    expect(out).toEqual(['g-orphan'])
  })

  it('returns empty when no id or resolved field matches', () => {
    expect(filterGoalRelations(ids, 'nonexistent-token', resolve)).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const before = ids.slice()
    filterGoalRelations(ids, 'alpha', resolve)
    expect(ids).toEqual(before)
  })

  it('matches multiple ids sharing a substring and preserves input order', () => {
    const out = filterGoalRelations(ids, 'g-', resolve)
    expect(out).toEqual(['g-alpha', 'g-beta', 'g-gamma', 'g-orphan'])
  })
})

describe('taskLineageStage', () => {
  it('maps raw history labels (and aliases) to lifecycle stages', () => {
    expect(taskLineageStage('claimed').key).toBe('claimed')
    expect(taskLineageStage('claim').key).toBe('claimed')
    expect(taskLineageStage('in_progress').key).toBe('started')
    expect(taskLineageStage('handoff').key).toBe('handoff')
    expect(taskLineageStage('submit_for_verification').key).toBe('submitted')
    expect(taskLineageStage('awaiting_verification').key).toBe('submitted')
    expect(taskLineageStage('approved').key).toBe('approved')
    expect(taskLineageStage('rejected').key).toBe('rejected')
    expect(taskLineageStage('done').key).toBe('done')
    expect(taskLineageStage('cancelled').key).toBe('cancelled')
  })

  it('falls back to a generic transition stage for unknown labels', () => {
    expect(taskLineageStage('some_unmapped_event').key).toBe('transition')
  })
})

describe('buildTaskLineage', () => {
  it('builds a rail from history and a de-duplicated ownership chain', () => {
    const events: NormalizedTaskEvent[] = [
      lineageEvent({ label: 'created', agent: 'alice', ts: '2026-04-17T00:00:00Z' }),
      lineageEvent({ label: 'claimed', agent: 'alice', ts: '2026-04-17T00:05:00Z' }),
      lineageEvent({ label: 'handoff', agent: 'alice', ts: '2026-04-17T01:00:00Z', notes: 'to bob' }),
      lineageEvent({ label: 'started', agent: 'bob', ts: '2026-04-17T01:05:00Z' }),
      lineageEvent({ label: 'done', agent: 'bob', ts: '2026-04-17T02:00:00Z' }),
    ]

    const lineage = buildTaskLineage(events, { status: 'done', assignee: 'bob' })

    expect(lineage.synthesized).toBe(false)
    expect(lineage.rows).toHaveLength(5)
    expect(lineage.rows.map(r => r.stage.key)).toEqual(['created', 'claimed', 'handoff', 'started', 'done'])
    // Ownership chain de-duplicates consecutive/repeat actors in event order.
    expect(lineage.chain).toEqual(['alice', 'bob'])
  })

  it('synthesizes a minimal flow from status + assignee when no history exists', () => {
    const lineage = buildTaskLineage([], { status: 'in_progress', assignee: 'sangsu' })

    expect(lineage.synthesized).toBe(true)
    expect(lineage.rows.map(r => r.stage.key)).toEqual(['created', 'claimed', 'started'])
    expect(lineage.rows.every(r => r.actor === 'sangsu')).toBe(true)
    expect(lineage.chain).toEqual(['sangsu'])
  })

  it('synthesizes an unassigned single-step flow for an unclaimed todo', () => {
    const lineage = buildTaskLineage([], { status: 'todo', assignee: undefined })

    expect(lineage.synthesized).toBe(true)
    expect(lineage.rows.map(r => r.stage.key)).toEqual(['created'])
    expect(lineage.rows[0]!.actor).toBeNull()
    expect(lineage.chain).toEqual([])
  })
})
