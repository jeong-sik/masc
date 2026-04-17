import { describe, expect, it } from 'vitest'
import {
  buildActionTimelineGroups,
  buildCategoryCounts,
  buildRawCategoryCounts,
  categoryForActivityKind,
  eventDetail,
} from './activity-graph-groups'
import type { ActivityGraphTimelineEvent } from '../types'

function makeEvent(
  seq: number,
  kind: string,
  options: {
    ts?: string
    actor?: string
    subjectId?: string | null
    payload?: Record<string, unknown>
  } = {},
): ActivityGraphTimelineEvent {
  const tsIso = options.ts ?? '2026-03-30T10:00:00Z'
  return {
    seq,
    ts: Date.parse(tsIso),
    ts_iso: tsIso,
    kind,
    actor: options.actor ? { id: options.actor } : {},
    summary: kind,
    subject: options.subjectId ? { id: options.subjectId, type: 'entity' } : null,
    room_id: 'default',
    tags: [],
    payload: options.payload ?? {},
  }
}

describe('categoryForActivityKind', () => {
  it('maps known kinds into the action categories', () => {
    expect(categoryForActivityKind('task.started')).toBe('task')
    expect(categoryForActivityKind('team.turn')).toBe('session')
    expect(categoryForActivityKind('message.broadcast')).toBe('message')
    expect(categoryForActivityKind('board.posted')).toBe('board')
    expect(categoryForActivityKind('policy.approved')).toBe('governance')
    expect(categoryForActivityKind('keeper.contract_verdict')).toBe('governance')
    expect(categoryForActivityKind('agent.joined')).toBe('lifecycle')
  })

  it('falls back to other for unknown kinds', () => {
    expect(categoryForActivityKind('mystery.kind')).toBe('other')
  })

  it('surfaces tool and verification payload details in summaries', () => {
    const toolEvent = makeEvent(1, 'tool.called', {
      actor: 'claude',
      payload: { tool_name: 'keeper_shell', cmd: 'gh pr create --draft' },
    })
    const verifyEvent = makeEvent(2, 'task.submit_for_verification', {
      actor: 'claude',
      subjectId: 'task-9',
      payload: { verification_id: 'vrf-77' },
    })

    expect(eventDetail(toolEvent)).toBe('gh pr create --draft')
    expect(eventDetail(verifyEvent)).toBe('vrf-77')
  })
})

describe('buildActionTimelineGroups', () => {
  it('merges task events for the same task within 15 minutes', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'task.created', { subjectId: 'task-1', actor: 'system', payload: { title: 'Fix drift' } }),
      makeEvent(2, 'task.claimed', { ts: '2026-03-30T10:05:00Z', subjectId: 'task-1', actor: 'claude' }),
      makeEvent(3, 'task.started', { ts: '2026-03-30T10:10:00Z', subjectId: 'task-1', actor: 'claude' }),
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0]!.category).toBe('task')
    expect(groups[0]!.rawCount).toBe(3)
    expect(groups[0]!.subjectId).toBe('task-1')
  })

  it('keeps session groups separate when the operation changes', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'operation.started', { subjectId: 'sess-1', actor: 'team-session' }),
      makeEvent(2, 'team.turn', { ts: '2026-03-30T10:01:00Z', subjectId: 'sess-1', actor: 'claude' }),
      makeEvent(3, 'operation.started', { ts: '2026-03-30T10:02:00Z', subjectId: 'sess-2', actor: 'team-session' }),
    ])
    expect(groups).toHaveLength(2)
    expect(groups.map(group => group.subjectId)).toEqual(['sess-2', 'sess-1'])
  })

  it('chains same-actor message events within 60 seconds', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'message.broadcast', { actor: 'claude', payload: { content: 'part 1' } }),
      makeEvent(2, 'message.mentioned', { ts: '2026-03-30T10:00:30Z', actor: 'claude', subjectId: 'gemini', payload: { content: 'part 2' } }),
      makeEvent(3, 'message.broadcast', { ts: '2026-03-30T10:01:20Z', actor: 'claude', payload: { content: 'break' } }),
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0]!.rawCount).toBe(3)
  })

  it('groups board events by post within 120 seconds', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'board.posted', { actor: 'claude', subjectId: 'post-1', payload: { content: 'hello' } }),
      makeEvent(2, 'board.commented', { ts: '2026-03-30T10:01:30Z', actor: 'gemini', subjectId: 'post-1', payload: { content: 'reply' } }),
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0]!.category).toBe('board')
    expect(groups[0]!.rawCount).toBe(2)
  })

  it('keeps lifecycle events as singletons', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'agent.joined', { actor: 'claude', subjectId: 'claude' }),
      makeEvent(2, 'agent.left', { ts: '2026-03-30T10:00:10Z', actor: 'claude', subjectId: 'claude' }),
    ])
    expect(groups).toHaveLength(2)
    expect(groups.every(group => group.category === 'lifecycle')).toBe(true)
  })
})

describe('activity graph category counters', () => {
  it('builds grouped counts and raw counts without dropping lifecycle noise', () => {
    const groups = buildActionTimelineGroups([
      makeEvent(1, 'task.started', { actor: 'claude', subjectId: 'task-7' }),
      makeEvent(2, 'agent.joined', { ts: '2026-03-30T10:00:05Z', actor: 'claude', subjectId: 'claude' }),
      makeEvent(3, 'message.broadcast', { ts: '2026-03-30T10:00:10Z', actor: 'claude', payload: { content: 'hello' } }),
    ])
    const groupedCounts = buildCategoryCounts(groups)
    const rawCounts = buildRawCategoryCounts({
      'task.started': 2,
      'agent.joined': 1,
      'message.broadcast': 3,
      'unknown.kind': 4,
    })

    expect(groupedCounts.task).toBe(1)
    expect(groupedCounts.lifecycle).toBe(1)
    expect(groupedCounts.message).toBe(1)
    expect(rawCounts.task).toBe(2)
    expect(rawCounts.lifecycle).toBe(1)
    expect(rawCounts.message).toBe(3)
    expect(rawCounts.other).toBe(4)
  })
})
