import { describe, expect, it } from 'vitest'
import { buildTaskLineage, filterTaskEvents, taskLineageStage } from './task-detail-state'
import type { NormalizedTaskEvent } from './task-detail-state'

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
