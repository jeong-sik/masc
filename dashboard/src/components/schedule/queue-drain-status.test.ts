import { describe, expect, it } from 'vitest'
import type {
  DashboardScheduledAutomationKeeperQueueEvidence,
  DashboardScheduledAutomationKeeperReactionEvidence,
  DashboardScheduledAutomationRequest,
} from '../../api'
import {
  countQueueDrainMisses,
  isCalendarVisible,
  queueDrainStatusOf,
} from './queue-drain-status'

type QueueStatus = DashboardScheduledAutomationKeeperQueueEvidence['projection_status']
type ReactionStatus = DashboardScheduledAutomationKeeperReactionEvidence['projection_status']

function req(
  queue: QueueStatus | null,
  reaction?: ReactionStatus,
): DashboardScheduledAutomationRequest {
  return {
    schedule_id: 'sched-1',
    status: 'scheduled',
    risk_class: 'read_only',
    approval_required: false,
    source: 'automated_request',
    recurrence: { kind: 'one_shot' },
    keeper_queue_evidence: queue === null ? null : { projection_status: queue },
    keeper_reaction_evidence: reaction === undefined ? null : { projection_status: reaction },
  }
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

  it('maps an inflight queue match to 드레인 중 (info)', () => {
    const status = queueDrainStatusOf(req('matched_inflight'))
    expect(status?.state).toBe('inflight')
    expect(status?.label).toBe('드레인 중')
  })

  it('treats not_found + a recorded keeper reaction as a healthy 완료 (drained), never a miss', () => {
    for (const reaction of ['matched_consumed_ack', 'matched_turn_started', 'matched_stimulus'] as const) {
      const status = queueDrainStatusOf(req('not_found', reaction))
      expect(status?.state, `reaction=${reaction}`).toBe('drained')
      expect(status?.label).toBe('완료')
    }
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

  it('surfaces an unrecognized receipt as 확인 불가 (indeterminate)', () => {
    expect(queueDrainStatusOf(req('unrecognized_receipt'))?.state).toBe('indeterminate')
  })
})

describe('isCalendarVisible', () => {
  it('renders the actionable/in-flight states and hides healthy-completion + legacy noise', () => {
    const visible = (queue: QueueStatus, reaction?: ReactionStatus): boolean => {
      const status = queueDrainStatusOf(req(queue, reaction))
      return status !== null && isCalendarVisible(status)
    }
    expect(visible('matched_pending')).toBe(true)
    expect(visible('matched_inflight')).toBe(true)
    expect(visible('not_found', 'not_found')).toBe(true) // missed
    expect(visible('read_error')).toBe(true)
    expect(visible('not_found', 'matched_consumed_ack')).toBe(false) // drained
    expect(visible('unrecognized_receipt')).toBe(false) // indeterminate
  })
})

describe('countQueueDrainMisses', () => {
  it('counts only genuine misses (queue=not_found AND reaction=not_found)', () => {
    const requests: DashboardScheduledAutomationRequest[] = [
      req('matched_pending'),
      req('not_found', 'not_found'), // miss
      req('not_found', 'matched_turn_started'), // drained — not a miss
      req('not_found', 'not_found'), // miss
      req('read_error'), // read error — not counted as a miss
      req(null), // no evidence
    ]
    expect(countQueueDrainMisses(requests)).toBe(2)
  })

  it('returns 0 for an empty list', () => {
    expect(countQueueDrainMisses([])).toBe(0)
  })
})
