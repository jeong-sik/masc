// Queue-drain status for a scheduled keeper wake.
//
// The schedule surface's calendar (default) view and KPI strip need to answer
// one operator question the list view already answers per row: did a scheduled
// keeper wake actually flow through the keeper_event_queue drain?
//
// Two backend evidence axes must be combined — neither is sufficient alone
// (see the derivation in server_dashboard_http_runtime_info.ml):
//
//   · keeper_queue_evidence  — is the last execution's wake in the durable
//     event-queue snapshot right now? matched_pending / matched_inflight mean
//     "yes, awaiting / mid drain". not_found means "in neither queue" — but that
//     is ALSO the normal post-completion state (a drained wake leaves the
//     queue), so not_found alone cannot mean "lost".
//   · keeper_reaction_evidence — what is the causally latest typed reaction for
//     the stimulus? ACK is completion; turn-start, requeue, and escalation are
//     distinct non-terminal/operator-actionable outcomes. A matched_stimulus
//     row proves only enqueue and cannot prove drain.
//
// A genuine miss is queue=not_found with either reaction=not_found or
// reaction=matched_stimulus: dispatched, no longer in either queue, and no
// handling evidence. Queue=not_found alone remains insufficient because a
// successfully drained wake also leaves the queue.

import type { DashboardScheduledAutomationRequest } from '../../api'
import type { StatusChipTone } from '../common/status-chip'

export type QueueDrainState =
  | 'pending' // in the pending queue — awaiting drain
  | 'inflight' // in the inflight queue — draining now
  | 'started' // left the queue after a turn began — not terminal yet
  | 'drained' // left the queue with a consumed ACK — healthy completion
  | 'requeued' // latest reaction explicitly returned the stimulus to work
  | 'escalated' // latest reaction escalated without requesting external input
  | 'external_input_requested' // escalation is waiting for external input
  | 'identity_conflict' // multiple queue rows claim one canonical stimulus identity
  | 'missed' // left the queue with no keeper reaction — dispatched then lost
  | 'read_error' // queue snapshot unreadable — drain state indeterminate (I/O)
  | 'indeterminate' // receipt / stimulus identity cannot be correlated

export interface QueueDrainStatus {
  readonly state: QueueDrainState
  readonly label: string
  readonly tone: StatusChipTone
  /** Tooltip explaining the two-axis derivation behind this state. */
  readonly title: string
}

const PRESENTATION: Readonly<Record<QueueDrainState, Omit<QueueDrainStatus, 'state'>>> = {
  pending: {
    label: '큐 대기',
    tone: 'info',
    title: 'wake가 keeper_event_queue pending에 있음 — 드레인 대기 중',
  },
  inflight: {
    label: '드레인 중',
    tone: 'info',
    title: 'wake가 inflight — keeper가 지금 드레인 중',
  },
  started: {
    label: '처리 시작',
    tone: 'info',
    title: '큐에서 빠진 뒤 keeper turn_started가 기록됨 — 아직 종결 ACK는 없음',
  },
  drained: {
    label: '완료',
    tone: 'neutral',
    title: '큐에서 빠졌고 최신 반응이 consumed ACK임',
  },
  requeued: {
    label: '재큐됨',
    tone: 'warn',
    title: '최신 반응이 requeue임 — 완료가 아니며 후속 드레인을 확인해야 함',
  },
  escalated: {
    label: '에스컬레이션',
    tone: 'bad',
    title: '최신 반응이 escalation임 — 완료로 처리되지 않음',
  },
  external_input_requested: {
    label: '외부 입력 필요',
    tone: 'bad',
    title: '최신 escalation이 external_input_requested=true — 외부 입력 대기 중',
  },
  identity_conflict: {
    label: '식별자 충돌',
    tone: 'bad',
    title: '동일한 canonical stimulus_id에 여러 queue row가 매칭됨 — operator 확인 필요',
  },
  missed: {
    label: '누락 ⚠',
    tone: 'warn',
    title: 'dispatch됐으나 큐에 없고 keeper 반응 기록도 없음 — 실행 누락',
  },
  read_error: {
    label: '읽기 오류',
    tone: 'warn',
    title: '큐 스냅샷 또는 reaction ledger 읽기 실패 — 드레인 상태 확인 불가',
  },
  indeterminate: {
    label: '확인 불가',
    tone: 'neutral',
    title: '영수증을 해석할 수 없거나 반응 증거가 없어 큐-반응 상관 불가',
  },
}

function stateOf(request: DashboardScheduledAutomationRequest): QueueDrainState | null {
  const queue = request.keeper_queue_evidence
  // No keeper-wake dispatch/execution yet (or a board post) — nothing to show.
  if (queue == null) return null
  switch (queue.projection_status) {
    case 'matched_pending':
      return 'pending'
    case 'matched_inflight':
      return 'inflight'
    case 'read_error':
      return 'read_error'
    case 'identity_conflict':
      return 'identity_conflict'
    case 'unrecognized_receipt':
      return 'indeterminate'
    case 'not_found': {
      const reaction = request.keeper_reaction_evidence
      if (reaction == null) return 'indeterminate'
      switch (reaction.projection_status) {
        case 'matched_consumed_ack':
          return 'drained'
        case 'matched_turn_started':
          return 'started'
        case 'matched_requeued':
          return 'requeued'
        case 'matched_escalated':
          return 'escalated'
        case 'matched_escalated_external_input':
          return 'external_input_requested'
        case 'matched_stimulus':
        case 'not_found':
          return 'missed'
        case 'read_error':
          return 'read_error'
        case 'invalid_stimulus_id':
        case 'unrecognized_receipt':
          return 'indeterminate'
      }
    }
    default:
      // Unknown future queue status: surface as indeterminate rather than
      // collapsing it into a permissive OK or an alarmist miss.
      return 'indeterminate'
  }
}

/** Combined queue-drain status for a request's last execution, or null when the
 * request has no keeper-wake queue evidence (board posts, or nothing dispatched
 * yet). */
export function queueDrainStatusOf(
  request: DashboardScheduledAutomationRequest,
): QueueDrainStatus | null {
  const state = stateOf(request)
  return state === null ? null : { state, ...PRESENTATION[state] }
}

export function isCalendarVisible(status: QueueDrainStatus): boolean {
  switch (status.state) {
    case 'drained':
    case 'indeterminate':
      return false
    case 'pending':
    case 'inflight':
    case 'started':
    case 'requeued':
    case 'escalated':
    case 'external_input_requested':
    case 'identity_conflict':
    case 'missed':
    case 'read_error':
      return true
  }
}

/** Count of requests whose last keeper-wake execution has left the queue
 * without keeper handling evidence. Feeds the KPI strip. */
export function countQueueDrainMisses(
  requests: readonly DashboardScheduledAutomationRequest[],
): number {
  let misses = 0
  for (const request of requests) {
    if (stateOf(request) === 'missed') misses += 1
  }
  return misses
}
