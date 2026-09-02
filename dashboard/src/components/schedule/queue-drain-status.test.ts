import { describe, expect, it } from 'vitest'
import type {
  DashboardScheduledAutomationKeeperQueueEvidence,
  DashboardScheduledAutomationKeeperReactionEvidence,
  DashboardScheduledAutomationRequest,
} from '../../api'
import {
  countQueueDrainCancelled,
  countQueueDrainMisses,
  isCalendarVisible,
  queueDrainStatusOf,
} from './queue-drain-status'

type QueueStatus = DashboardScheduledAutomationKeeperQueueEvidence['projection_status']
type ReactionStatus = DashboardScheduledAutomationKeeperReactionEvidence['projection_status']

function req(
  queue: QueueStatus | null,
  reaction?: ReactionStatus,
  receipt?: DashboardScheduledAutomationRequest['dispatch_receipt'],
): DashboardScheduledAutomationRequest {
  return {
    schedule_id: 'sched-1',
    status: 'scheduled',
    source: 'automated_request',
    recurrence: { kind: 'one_shot' },
    keeper_queue_evidence: queue === null ? null : { projection_status: queue },
    keeper_reaction_evidence: reaction === undefined ? null : { projection_status: reaction },
    ...(receipt === undefined ? {} : { dispatch_receipt: receipt }),
  }
}

// A recognized receipt whose activation the consumer deferred because the
// Keeper store holds no Keeper under the name.
const OWNER_ABSENT_RECEIPT: DashboardScheduledAutomationRequest['dispatch_receipt'] = {
  projection_status: 'recognized',
  kind: 'masc.keeper_wake.enqueued',
  queue: 'keeper_event_queue',
  stimulus: 'schedule_due',
  stimulus_id: 'occ-1',
  reaction_ledger_status: 'recorded',
  reaction_ledger_error: null,
  keeper_name: 'taskmaster',
  schedule_id: 'sched-1',
  urgency: 'normal',
  post_id: 'occ-1',
  occurrence_status: 'awaiting_ack',
  activation_status: 'deferred',
  activation_reason: 'owner_absent',
  activation_detail: null,
}

describe('queueDrainStatusOf', () => {
  it('returns null when the request carries no keeper-wake queue evidence', () => {
    expect(queueDrainStatusOf(req(null))).toBeNull()
  })

  it('maps a pending queue match to 큐 대기 (info)', () => {
    const status = queueDrainStatusOf(req('matched_pending'))
    expect(status?.state).toBe('pending')
    expect(status?.label).toBe('큐 대기')
    expect(status?.tone).toBe('info')
  })

  it('treats not_found + a recorded keeper reaction as a healthy 완료 (drained), never a miss', () => {
    for (const reaction of ['matched_consumed_ack', 'matched_turn_finished', 'matched_turn_started'] as const) {
      const status = queueDrainStatusOf(req('not_found', reaction))
      expect(status?.state, `reaction=${reaction}`).toBe('drained')
      expect(status?.label).toBe('완료')
    }
  })

  it('reads an accepted cancellation as 취소됨, visible on the calendar, and never as a miss or a completion', () => {
    // Measured live 2026-09-02: a daily wake for a Keeper deleted days
    // earlier was cancelled by the owner-absent drain 40s after every
    // dispatch, and this classifier folded it into 확인 불가.
    const status = queueDrainStatusOf(req('not_found', 'matched_terminal_cancelled'))
    expect(status?.state).toBe('cancelled')
    expect(status?.label).toBe('취소됨')
    expect(status?.tone).toBe('warn')
    expect(status && isCalendarVisible(status)).toBe(true)
  })

  it('names the absent Keeper when the receipt says the store had no such name', () => {
    const status = queueDrainStatusOf(
      req('not_found', 'matched_terminal_cancelled', OWNER_ABSENT_RECEIPT),
    )
    expect(status?.state).toBe('cancelled')
    expect(status?.label).toBe('취소됨 · keeper 없음')
  })

  it('does not read a cancellation whose receipt was deferred for another reason as an absent Keeper', () => {
    const status = queueDrainStatusOf(
      req('not_found', 'matched_terminal_cancelled', {
        ...OWNER_ABSENT_RECEIPT,
        activation_reason: 'unregistered',
      }),
    )
    expect(status?.label).toBe('취소됨')
  })

  it('reports ack and cancellation on one occurrence as invalid evidence, not as either outcome', () => {
    expect(queueDrainStatusOf(req('not_found', 'conflicting_terminal_evidence'))?.state).toBe('evidence_invalid')
  })

  it('counts cancelled last executions separately from misses', () => {
    const requests = [
      req('not_found', 'matched_terminal_cancelled'),
      req('not_found', 'matched_terminal_cancelled', OWNER_ABSENT_RECEIPT),
      req('not_found', 'not_found'),
      req('not_found', 'matched_consumed_ack'),
    ]
    expect(countQueueDrainCancelled(requests)).toBe(2)
    expect(countQueueDrainMisses(requests)).toBe(1)
  })

  it('treats not_found + matched_stimulus as a miss: the stimulus row is only the producer dispatch record', () => {
    // The stimulus row is written fail-closed at dispatch time, so every
    // dispatched wake has one. A receipt leaves the queue only via
    // ack/cancel/drop — stimulus-only means no keeper ever consumed it.
    const status = queueDrainStatusOf(req('not_found', 'matched_stimulus'))
    expect(status?.state).toBe('missed')
    expect(status?.label).toBe('누락 ⚠')
    expect(status?.tone).toBe('warn')
  })

  it('flags a genuine miss only when the wake is in no queue AND the keeper never reacted', () => {
    const status = queueDrainStatusOf(req('not_found', 'not_found'))
    expect(status?.state).toBe('missed')
    expect(status?.label).toBe('누락 ⚠')
    expect(status?.tone).toBe('warn')
  })

  it('does not conclude a miss when the reaction cannot be correlated (missing_stimulus_id / absent)', () => {
    expect(queueDrainStatusOf(req('not_found', 'missing_stimulus_id'))?.state).toBe('indeterminate')
    expect(queueDrainStatusOf(req('not_found'))?.state).toBe('indeterminate')
  })

  it('surfaces a queue read error as 읽기 오류 (warn), not a miss', () => {
    const status = queueDrainStatusOf(req('read_error'))
    expect(status?.state).toBe('read_error')
    expect(status?.tone).toBe('warn')
  })

  it('surfaces reaction-ledger read and exact-occurrence quarantine explicitly', () => {
    expect(queueDrainStatusOf(req('not_found', 'read_error'))?.state).toBe('read_error')
    expect(queueDrainStatusOf(req('not_found', 'quarantined'))?.state).toBe('evidence_invalid')
  })

  it('surfaces an unrecognized receipt as 확인 불가 (indeterminate)', () => {
    expect(queueDrainStatusOf(req('unrecognized_receipt'))?.state).toBe('indeterminate')
  })
})

describe('isCalendarVisible', () => {
  it('renders actionable states and hides healthy completion noise', () => {
    const visible = (queue: QueueStatus, reaction?: ReactionStatus): boolean => {
      const status = queueDrainStatusOf(req(queue, reaction))
      return status !== null && isCalendarVisible(status)
    }
    expect(visible('matched_pending')).toBe(true)
    expect(visible('not_found', 'not_found')).toBe(true) // missed
    expect(visible('read_error')).toBe(true)
    expect(visible('not_found', 'quarantined')).toBe(true)
    expect(visible('not_found', 'matched_consumed_ack')).toBe(false) // drained
    expect(visible('not_found', 'matched_stimulus')).toBe(true) // missed — dispatch record only
    expect(visible('unrecognized_receipt')).toBe(false) // indeterminate
  })
})

describe('countQueueDrainMisses', () => {
  it('counts genuine misses (not_found without a keeper reaction), including stimulus-only receipts', () => {
    const requests: DashboardScheduledAutomationRequest[] = [
      req('matched_pending'),
      req('not_found', 'not_found'), // miss
      req('not_found', 'matched_stimulus'), // miss — dispatch record only
      req('not_found', 'matched_turn_started'), // drained — not a miss
      req('not_found', 'matched_consumed_ack'), // drained — not a miss
      req('not_found', 'not_found'), // miss
      req('read_error'), // read error — not counted as a miss
      req(null), // no evidence
    ]
    expect(countQueueDrainMisses(requests)).toBe(3)
  })

  it('returns 0 for an empty list', () => {
    expect(countQueueDrainMisses([])).toBe(0)
  })
})
