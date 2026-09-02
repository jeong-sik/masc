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
//   · not_found + consumed_ack/turn_finished/turn_started → drained (the
//     keeper handled it)
//   · not_found + terminal_cancelled → cancelled (the queue settled it
//     without a turn; the receipt's activation reason says why when the
//     Keeper store had no such name)
//   · not_found + matched_stimulus (or no ledger row at all) → missed
//     (dispatched, but no keeper ever consumed it)

import type { DashboardScheduledAutomationRequest } from '../../api'
import type { StatusChipTone } from '../common/status-chip'

export type QueueDrainState =
  | 'pending' // in the pending queue — awaiting drain
  | 'drained' // left the queue AND the keeper reacted — healthy completion
  | 'cancelled' // left the queue through an accepted cancellation — no turn ran
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
  'matched_turn_finished',
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
    title: '큐에서 빠졌고 keeper 반응이 기록됨 (consumed_ack / turn_finished / turn_started)',
  },
  cancelled: {
    label: '취소됨',
    tone: 'warn',
    title: '큐가 accepted cancellation 으로 정리함 — keeper 턴 없이 끝난 wake',
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
      if (reaction === 'matched_terminal_cancelled') return 'cancelled'
      // Ack and cancellation both recorded for one occurrence: the ledger
      // contradicts itself, which is not a drain state to report as either.
      if (reaction === 'conflicting_terminal_evidence') return 'evidence_invalid'
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

// The receipt's activation reason, when the receipt was recognized. The
// activation branch is a discriminated union on activation_status, so the
// reason is read off the recognized shape rather than the raw record.
function receiptActivationReason(request: DashboardScheduledAutomationRequest): string | null {
  const receipt = request.dispatch_receipt
  if (!receipt || receipt.projection_status !== 'recognized') return null
  return receipt.activation_status === 'deferred' ? receipt.activation_reason : null
}

/** Combined queue-drain status for a request's last execution, or null when the
 * request has no keeper-wake queue evidence (board posts, or nothing dispatched
 * yet). */
export function queueDrainStatusOf(
  request: DashboardScheduledAutomationRequest,
): QueueDrainStatus | null {
  const state = stateOf(request)
  if (state === null) return null
  // A cancelled wake for a Keeper the store does not know is the one case
  // the operator can act on directly: the definition outlived its target.
  if (state === 'cancelled' && receiptActivationReason(request) === 'owner_absent') {
    return {
      state,
      ...PRESENTATION.cancelled,
      label: '취소됨 · keeper 없음',
      title: 'Keeper store 에 이 이름의 keeper 가 없어 큐가 wake 를 취소함 — 예약 정의가 대상보다 오래 살아남음',
    }
  }
  return { state, ...PRESENTATION[state] }
}

// States surfaced as a chip on the calendar rows. 'drained' and 'indeterminate'
// are intentionally omitted: a healthy completion and an uncorrelatable record
// are not actionable, and a chip on every recurring row would be noise.
const CALENDAR_VISIBLE: ReadonlySet<QueueDrainState> = new Set<QueueDrainState>([
  'pending',
  'cancelled',
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

/** Count of requests whose last keeper-wake execution the queue cancelled
 * without a turn. Feeds the KPI strip next to the misses. */
export function countQueueDrainCancelled(
  requests: readonly DashboardScheduledAutomationRequest[],
): number {
  let cancelled = 0
  for (const request of requests) {
    if (stateOf(request) === 'cancelled') cancelled += 1
  }
  return cancelled
}
