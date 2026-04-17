import { describe, expect, it } from 'vitest'
import { filterTaskEvents } from './task-detail-state'
import type { NormalizedTaskEvent } from './task-detail-state'

const sample: NormalizedTaskEvent[] = [
  {
    label: 'claim',
    agent: 'dreamer',
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
    const out = filterTaskEvents(sample, 'dreamer')
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
    filterTaskEvents(sample, 'dreamer')
    expect(sample).toEqual(before)
  })

  it('can match multiple rows when substring is shared', () => {
    const out = filterTaskEvents(sample, 'keeper')
    expect(out.map(e => e.label)).toEqual(['claim', 'done'])
  })
})
