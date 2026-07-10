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
//   · keeper_reaction_evidence — did the keeper actually react to the stimulus
//     (consumed_ack / turn_started / stimulus recorded)? This disambiguates a
//     drained-and-handled wake from a genuinely lost one.
//
// A genuine miss is ONLY queue=not_found AND reaction=not_found: dispatched, not
// in the queue, and never recorded as reacted. Every other not_found is a
// healthy completion. Labeling not_found alone as "missed" would false-alarm on
// every successful wake.

import type { DashboardScheduledAutomationRequest } from '../../api'
import type { StatusChipTone } from '../common/status-chip'

export type QueueDrainState =
  | 'pending' // in the pending queue — awaiting drain
  | 'inflight' // in the inflight queue — draining now
  | 'drained' // left the queue AND the keeper reacted — healthy completion
  | 'missed' // left the queue with no keeper reaction — dispatched then lost
  | 'read_error' // queue snapshot unreadable — drain state indeterminate (I/O)
  | 'indeterminate' // receipt / stimulus cannot be correlated (legacy record)

export interface QueueDrainStatus {
  readonly state: QueueDrainState
  readonly label: string
  readonly tone: StatusChipTone
  /** Tooltip explaining the two-axis derivation behind this state. */
  readonly title: string
}

// keeper_reaction_evidence statuses that prove the keeper handled the stimulus.
const REACTED: ReadonlySet<string> = new Set([
  'matched_consumed_ack',
  'matched_turn_started',
  'matched_stimulus',
])

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
  drained: {
    label: '완료',
    tone: 'neutral',
    title: '큐에서 빠졌고 keeper 반응이 기록됨 (consumed_ack / turn_started / stimulus)',
  },
  missed: {
    label: '누락 ⚠',
    tone: 'warn',
    title: 'dispatch됐으나 큐에 없고 keeper 반응 기록도 없음 — 실행 누락',
  },
  read_error: {
    label: '읽기 오류',
    tone: 'warn',
    title: '큐 스냅샷 읽기 실패 — 드레인 상태 확인 불가',
  },
  indeterminate: {
    label: '확인 불가',
    tone: 'neutral',
    title: '영수증 / stimulus_id 부재로 큐-반응 상관 불가 (레거시 기록)',
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
    case 'unrecognized_receipt':
      return 'indeterminate'
    case 'not_found': {
      const reaction = request.keeper_reaction_evidence?.projection_status
      if (reaction != null && REACTED.has(reaction)) return 'drained'
      if (reaction === 'not_found') return 'missed'
      // missing_stimulus_id / unrecognized / absent — cannot conclude "lost".
      return 'indeterminate'
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

// States surfaced as a chip on the calendar rows. 'drained' and 'indeterminate'
// are intentionally omitted: a healthy completion and a legacy-correlation gap
// are not actionable, and a chip on every recurring row would be noise.
const CALENDAR_VISIBLE: ReadonlySet<QueueDrainState> = new Set<QueueDrainState>([
  'pending',
  'inflight',
  'missed',
  'read_error',
])

export function isCalendarVisible(status: QueueDrainStatus): boolean {
  return CALENDAR_VISIBLE.has(status.state)
}

/** Count of requests whose last keeper-wake execution is a genuine miss
 * (queue=not_found AND reaction=not_found). Feeds the KPI strip. */
export function countQueueDrainMisses(
  requests: readonly DashboardScheduledAutomationRequest[],
): number {
  let misses = 0
  for (const request of requests) {
    if (stateOf(request) === 'missed') misses += 1
  }
  return misses
}
