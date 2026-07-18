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

const latestReactionBase = {
  sequence: '2',
  event_id: 'event-2',
  recorded_at: 200,
  recorded_at_iso: '1970-01-01T00:03:20Z',
}

const latestSettlementBase = {
  ...latestReactionBase,
  transition_id: 'transition-2',
  source_index: 0,
  source_count: 1,
}

function reactionEvidence(
  projectionStatus: ReactionStatus,
): DashboardScheduledAutomationKeeperReactionEvidence {
  switch (projectionStatus) {
    case 'matched_consumed_ack':
      return {
        projection_status: projectionStatus,
        latest_reaction: { ...latestSettlementBase, kind: 'event_queue_ack' },
      }
    case 'matched_turn_started':
      return {
        projection_status: projectionStatus,
        latest_reaction: { ...latestReactionBase, kind: 'turn_started' },
      }
    case 'matched_requeued':
      return {
        projection_status: projectionStatus,
        latest_reaction: { ...latestSettlementBase, kind: 'event_queue_requeued' },
      }
    case 'matched_escalated':
      return {
        projection_status: projectionStatus,
        latest_reaction: {
          ...latestSettlementBase,
          kind: 'event_queue_escalated',
          external_input_requested: false,
        },
      }
    case 'matched_escalated_external_input':
      return {
        projection_status: projectionStatus,
        latest_reaction: {
          ...latestSettlementBase,
          kind: 'event_queue_escalated',
          external_input_requested: true,
        },
      }
    case 'matched_stimulus':
    case 'not_found':
    case 'read_error':
    case 'invalid_stimulus_id':
    case 'unrecognized_receipt':
      return { projection_status: projectionStatus }
  }
}

function req(
  queue: QueueStatus | null,
  reaction?: ReactionStatus,
): DashboardScheduledAutomationRequest {
  const queueEvidence: DashboardScheduledAutomationKeeperQueueEvidence | null =
    queue === null
      ? null
      : queue === 'identity_conflict'
        ? {
            projection_status: queue,
            operator_action_required: true,
            matched_identity_count: 2,
          }
        : { projection_status: queue }
  return {
    schedule_id: 'sched-1',
    status: 'scheduled',
    source: 'automated_request',
    recurrence: { kind: 'one_shot' },
    keeper_queue_evidence: queueEvidence,
    keeper_reaction_evidence: reaction === undefined ? null : reactionEvidence(reaction),
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

  it('treats only a latest ACK as healthy 완료', () => {
    const status = queueDrainStatusOf(req('not_found', 'matched_consumed_ack'))
    expect(status?.state).toBe('drained')
    expect(status?.label).toBe('완료')
  })

  it('keeps turn-start distinct from terminal completion', () => {
    const status = queueDrainStatusOf(req('not_found', 'matched_turn_started'))
    expect(status?.state).toBe('started')
    expect(status?.label).toBe('처리 시작')
    expect(status !== null && isCalendarVisible(status)).toBe(true)
  })

  it('preserves requeue and both escalation outcomes as actionable states', () => {
    expect(queueDrainStatusOf(req('not_found', 'matched_requeued'))?.state).toBe('requeued')
    expect(queueDrainStatusOf(req('not_found', 'matched_escalated'))?.state).toBe('escalated')
    const externalInput = queueDrainStatusOf(
      req('not_found', 'matched_escalated_external_input'),
    )
    expect(externalInput?.state).toBe('external_input_requested')
    expect(externalInput?.label).toBe('외부 입력 필요')
    expect(externalInput?.tone).toBe('bad')
  })

  it('treats matched_stimulus as enqueue-only evidence and reports a missing queue item as actionable', () => {
    const status = queueDrainStatusOf(req('not_found', 'matched_stimulus'))
    expect(status?.state).toBe('missed')
    expect(status?.label).toBe('누락 ⚠')
    expect(status?.tone).toBe('warn')
    expect(status !== null && isCalendarVisible(status)).toBe(true)
  })

  it('flags not_found reaction evidence as a genuine miss', () => {
    const status = queueDrainStatusOf(req('not_found', 'not_found'))
    expect(status?.state).toBe('missed')
    expect(status?.label).toBe('누락 ⚠')
    expect(status?.tone).toBe('warn')
  })

  it('does not conclude a miss when reaction evidence is absent', () => {
    expect(queueDrainStatusOf(req('not_found'))?.state).toBe('indeterminate')
  })

  it('surfaces a queue read error as 읽기 오류 (warn), not a miss', () => {
    const status = queueDrainStatusOf(req('read_error'))
    expect(status?.state).toBe('read_error')
    expect(status?.tone).toBe('warn')
  })

  it('surfaces a reaction-ledger read failure explicitly', () => {
    expect(queueDrainStatusOf(req('not_found', 'read_error'))?.state).toBe('read_error')
  })

  it('surfaces an unrecognized receipt as 확인 불가 (indeterminate)', () => {
    expect(queueDrainStatusOf(req('unrecognized_receipt'))?.state).toBe('indeterminate')
  })

  it('surfaces a canonical stimulus identity conflict as operator-actionable', () => {
    const request = req(null)
    request.keeper_queue_evidence = {
      projection_status: 'identity_conflict',
      operator_action_required: true,
      matched_identity_count: 2,
    }
    const status = queueDrainStatusOf(request)
    expect(status?.state).toBe('identity_conflict')
    expect(status?.tone).toBe('bad')
    expect(status !== null && isCalendarVisible(status)).toBe(true)
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
    expect(visible('identity_conflict')).toBe(true)
    expect(visible('not_found', 'read_error')).toBe(true)
    expect(visible('not_found', 'matched_turn_started')).toBe(true)
    expect(visible('not_found', 'matched_requeued')).toBe(true)
    expect(visible('not_found', 'matched_escalated')).toBe(true)
    expect(visible('not_found', 'matched_escalated_external_input')).toBe(true)
    expect(visible('not_found', 'matched_consumed_ack')).toBe(false) // drained
    expect(visible('unrecognized_receipt')).toBe(false) // indeterminate
  })
})

describe('countQueueDrainMisses', () => {
  it('counts queue misses with no keeper handling evidence', () => {
    const requests: DashboardScheduledAutomationRequest[] = [
      req('matched_pending'),
      req('not_found', 'not_found'), // miss
      req('not_found', 'matched_turn_started'), // in progress — not a miss
      req('not_found', 'matched_stimulus'), // enqueue-only evidence — miss
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
