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
//     event-queue snapshot right now? matched_pending means "yes, awaiting
//     drain". not_found means "not pending" — but that is ALSO the normal
//     post-completion state (a drained wake leaves the
//     queue), so not_found alone cannot mean "lost".
//   · keeper_reaction_evidence — did the keeper actually react to the stimulus
//     (consumed_ack / turn_started)? This disambiguates a
//     drained-and-handled wake from a genuinely lost one.
//
// matched_stimulus is NOT a keeper reaction: it is the producer's own dispatch
// record, written fail-closed when the wake was enqueued
// (server_schedule_consumers.ml). Because every successfully dispatched wake
// has it, treating it as "reacted" absorbs every genuine loss into a healthy
// completion and makes the miss detector structurally inert.
//
// A receipt leaves the queue only via ack (normal), cancel, or drop/reset —
// never silently between dispatch and turn start. So:
//   · not_found + consumed_ack/turn_started → drained (the keeper handled it)
//   · not_found + matched_stimulus (or no ledger row at all) → missed
//     (dispatched, but no keeper ever consumed it)

import type { DashboardScheduledAutomationRequest } from '../../api'
import type { StatusChipTone } from '../common/status-chip'

export type QueueDrainState =
  | 'pending' // in the pending queue — awaiting drain
  | 'drained' // left the queue AND the keeper reacted — healthy completion
  | 'missed' // left the queue with no keeper reaction — dispatched then lost
  | 'read_error' // queue snapshot unreadable — drain state indeterminate (I/O)
  | 'evidence_invalid' // the exact occurrence row is quarantined
  | 'indeterminate' // receipt / stimulus / ledger completeness cannot be correlated

export interface QueueDrainStatus {
  readonly state: QueueDrainState
  readonly label: string
  readonly tone: StatusChipTone
  /** Tooltip explaining the two-axis derivation behind this state. */
  readonly title: string
}

// keeper_reaction_evidence statuses that prove the keeper handled the stimulus.
// matched_stimulus is deliberately absent: it is the producer's dispatch
// record, not a keeper reaction (see the header note).
const REACTED: ReadonlySet<string> = new Set([
  'matched_consumed_ack',
  'matched_turn_started',
])

const PRESENTATION: Readonly<Record<QueueDrainState, Omit<QueueDrainStatus, 'state'>>> = {
  pending: {
    label: '큐 대기',
    tone: 'info',
    title: 'wake가 keeper_event_queue pending에 있음 — 드레인 대기 중',
  },
  drained: {
    label: '완료',
    tone: 'neutral',
    title: '큐에서 빠졌고 keeper 반응이 기록됨 (consumed_ack / turn_started)',
  },
  missed: {
    label: '누락 ⚠',
    tone: 'warn',
    title:
      'dispatch 기록만 남았고 keeper 반응(turn_started/ack)이 없음 — 큐에서 빠졌으나 아무도 소비 안 함',
  },
  read_error: {
    label: '읽기 오류',
    tone: 'warn',
    title: '큐 스냅샷 또는 reaction ledger 읽기 실패 — 드레인 상태 확인 불가',
  },
  evidence_invalid: {
    label: '증거 격리',
    tone: 'warn',
    title: '해당 occurrence의 reaction ledger 행이 격리되어 정확한 드레인 판정 불가',
  },
  indeterminate: {
    label: '확인 불가',
    tone: 'neutral',
    title: '영수증, stimulus_id, 또는 ledger completeness 부재로 큐-반응 상관 불가',
  },
}

function stateOf(request: DashboardScheduledAutomationRequest): QueueDrainState | null {
  const queue = request.keeper_queue_evidence
  // No keeper-wake dispatch/execution yet (or a board post) — nothing to show.
  if (queue == null) return null
  switch (queue.projection_status) {
    case 'matched_pending':
      return 'pending'
    case 'read_error':
      return 'read_error'
    case 'unrecognized_receipt':
      return 'indeterminate'
    case 'not_found': {
      const reaction = request.keeper_reaction_evidence?.projection_status
      if (reaction != null && REACTED.has(reaction)) return 'drained'
      // matched_stimulus means only the producer's dispatch record exists.
      // A receipt leaves the queue only via ack/cancel/drop, so stimulus-only
      // is a dispatched wake no keeper ever consumed — a genuine miss, not a
      // healthy completion.
      if (reaction === 'matched_stimulus') return 'missed'
      if (reaction === 'not_found') return 'missed'
      if (reaction === 'read_error') return 'read_error'
      if (reaction === 'quarantined') return 'evidence_invalid'
      // quarantine / missing identity / unrecognized / absent:
      // exact negative evidence is unavailable, so this can never be a miss.
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
// are intentionally omitted: a healthy completion and an uncorrelatable record
// are not actionable, and a chip on every recurring row would be noise.
const CALENDAR_VISIBLE: ReadonlySet<QueueDrainState> = new Set<QueueDrainState>([
  'pending',
  'missed',
  'read_error',
  'evidence_invalid',
])

export function isCalendarVisible(status: QueueDrainStatus): boolean {
  return CALENDAR_VISIBLE.has(status.state)
}

/** Count of requests whose last keeper-wake execution is a genuine miss
 * (queue=not_found AND no keeper reaction — matched_stimulus counts as a miss
 * because it is only the producer's dispatch record). Feeds the KPI strip. */
export function countQueueDrainMisses(
  requests: readonly DashboardScheduledAutomationRequest[],
): number {
  let misses = 0
  for (const request of requests) {
    if (stateOf(request) === 'missed') misses += 1
  }
  return misses
}
