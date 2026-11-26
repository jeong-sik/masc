import { describe, expect, it } from 'vitest'
import {
  decodeRecentTurns,
  decodeTurnPreparation,
  decodeTurnWorkContext,
  decodeWaitingSummary,
  decodeWaitingUnavailable,
  isWaitingUnavailable,
  preparationHalted,
  preparationHaltedLabel,
  startReasonLabel,
  waitingRowDetailLines,
} from './turn-context'

const head = (extra: Record<string, unknown> = {}) => ({
  source: 'operation_queue', waiting_on: 'keeper_turn', what: '진행 중인 대화 요청',
  wake_producer: 'keeper_owner', since: 100, due_at: null, next_action: 'keeper_owner_settle_operation', ...extra,
})

describe('keeper turn context', () => {
  it('reads a halted preparation as not working', () => {
    const rejected = decodeTurnPreparation({ phase: 'context', state: 'rejected', turn_ref: null })
    expect(rejected).toEqual({ phase: 'context', state: 'rejected' })
    expect(preparationHalted(rejected)).toBe(true)
    expect(preparationHaltedLabel({ phase: 'context', state: 'rejected' })).toBe('컨텍스트 준비 거절')
    expect(preparationHalted(decodeTurnPreparation({ phase: 'tools', state: 'active' }))).toBe(false)
    expect(preparationHalted(decodeTurnPreparation({ phase: 'tools', state: 'prepared' }))).toBe(false)
    expect(decodeTurnPreparation({ phase: 'tools', state: 'exploded' })).toBeNull()
  })

  it('reads why a turn started and its task', () => {
    expect(decodeTurnWorkContext({ task_id: 'task-4085', start_reasons: ['scheduled_automation_due', 'task_backlog'] }))
      .toEqual({ task_id: 'task-4085', start_reasons: ['scheduled_automation_due', 'task_backlog'] })
    expect(decodeTurnWorkContext({ task_id: null, start_reasons: [] })).toEqual({ task_id: null, start_reasons: [] })
    expect(decodeTurnWorkContext({ task_id: 3, start_reasons: [] })).toBeNull()
    expect(startReasonLabel('scheduled_automation_due')).toBe('예약 작업 도래')
    expect(startReasonLabel('something_new')).toBe('something_new')
  })

  it('shows the operator sentence and never an action name as the due time', () => {
    const summary = decodeWaitingSummary({
      keeper_name: 'wkbl-growth', state: 'busy', waiting_count: 4, sources: { operation_queue: 4 },
      since: 100, due_at: null, waiting_heads: [head()],
    })
    expect(summary?.primary_reason).toBe('진행 중인 대화 요청')
    expect(summary?.due_at).toBeNull()
    expect(summary?.heads[0]?.next_action).toBe('keeper_owner_settle_operation')
    expect(summary?.state).toBe('busy')
  })

  it('turns a due time into an instant', () => {
    const summary = decodeWaitingSummary({
      state: 'deferred', waiting_count: 1, due_at: 1_795_700_000, waiting_heads: [head({ due_at: 1_795_700_000 })],
    })
    expect(summary?.due_at).toBe(new Date(1_795_700_000_000).toISOString())
    expect(summary?.heads[0]?.due_at).toBe(new Date(1_795_700_000_000).toISOString())
  })

  it('keeps an unreadable waiting inventory apart from nothing waiting', () => {
    expect(decodeWaitingUnavailable([])).toBeNull()
    const unavailable = decodeWaitingUnavailable([head({ what: 'approval queue read failed' })])
    expect(unavailable).toEqual({ unavailable: true, reason: 'approval queue read failed' })
    expect(isWaitingUnavailable(unavailable)).toBe(true)
    expect(decodeWaitingSummary({ state: 'mystery', waiting_count: 1, waiting_heads: [] })).toBeNull()
  })

  it('says why a waiting row is blocked', () => {
    expect(waitingRowDetailLines({
      route: 'haiku-then-glm',
      candidates: [
        { runtime_id: 'claude_code_a', cause: 'seven_day', resets_at: '2026-11-30T00:00:00Z' },
        { runtime_id: 'claude_code_b', cause: 'five_hour', resets_at: null },
      ],
    })).toEqual([
      'claude_code_a · seven_day · 복귀 2026-11-30T00:00:00Z',
      'claude_code_b · five_hour · 복귀 시각 미확인',
    ])
    expect(waitingRowDetailLines({ failure_stage: 'joining_lanes', failure_detail: 'lane 3 did not stop' }))
      .toEqual(['종료 막힘: joining_lanes · lane 3 did not stop'])
    expect(waitingRowDetailLines({ rejection_reason: 'no evidence' })).toEqual(['거절 이유: no evidence'])
    expect(waitingRowDetailLines(null)).toEqual([])
  })

  it('sums recent turns with their causes, or says nothing when a slot is off', () => {
    const slot = { starts_at: 0, ok: 2, rested: 1, failed: 4, scheduled: 3, reacted: 2, chat: 1, own: 1, unknown: 0 }
    expect(decodeRecentTurns({ slots: [slot, slot] })).toEqual({
      ok: 4, rested: 2, failed: 8,
      causes: { scheduled: 6, reacted: 4, chat: 2, own: 2, unknown: 0 },
    })
    expect(decodeRecentTurns({ slots: [{ ...slot, unknown: 1 }] })).toBeNull()
    expect(decodeRecentTurns({ slots: [{ starts_at: 0, ok: 1, rested: 0, failed: 0 }] })).toBeNull()
    expect(decodeRecentTurns({ slots: [] })).toEqual({
      ok: 0, rested: 0, failed: 0, causes: { scheduled: 0, reacted: 0, chat: 0, own: 0, unknown: 0 },
    })
  })
})
