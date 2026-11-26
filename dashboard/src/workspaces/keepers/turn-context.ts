/**
 * Why a Keeper turn started, whether its preparation halted, and what the
 * Keeper waits on. Decoders for the turns read (`GET /api/v1/keepers/turns`)
 * and the turn preview, plus the labels the Keeper view shows. The TUI shows
 * the same facts (lib/masc_tui/store/chat_transcript.ml).
 */

import type {
  KeeperTurnPreparation,
  KeeperTurnWorkContext,
  KeeperWaitingHead,
  KeeperWaitingSummary,
  KeeperWaitingUnavailable,
} from './types'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function nonBlank(v: unknown): string | null {
  return typeof v === 'string' && v.trim() !== '' ? v.trim() : null
}

function unixToIso(v: unknown): string | null {
  if (typeof v !== 'number' || !Number.isFinite(v)) return null
  const date = new Date(v * 1000)
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
}

function decodePreparationState(v: unknown): KeeperTurnPreparation['state'] | null {
  switch (v) {
    case 'active':
    case 'prepared':
    case 'rejected':
    case 'raised':
    case 'cancelled':
      return v
    default:
      return null
  }
}

/** Server `preparation_to_json`. An unreadable value is `null`. */
export function decodeTurnPreparation(raw: unknown): KeeperTurnPreparation | null {
  if (!isRecord(raw)) return null
  const phase = nonBlank(raw.phase)
  const state = decodePreparationState(raw.state)
  return phase !== null && state !== null ? { phase, state } : null
}

/** Server `work_context_to_json`. */
export function decodeTurnWorkContext(raw: unknown): KeeperTurnWorkContext | null {
  if (!isRecord(raw) || !Array.isArray(raw.start_reasons)) return null
  const reasons: string[] = []
  for (const reason of raw.start_reasons) {
    const text = nonBlank(reason)
    if (text === null) return null
    reasons.push(text)
  }
  if (raw.task_id !== null && raw.task_id !== undefined && nonBlank(raw.task_id) === null) return null
  return { task_id: nonBlank(raw.task_id), start_reasons: reasons }
}

/** A preparation that ended other than `prepared`: the turn cannot go on
 *  from it, so it is not "working". */
export function preparationHalted(preparation: KeeperTurnPreparation | null): boolean {
  if (preparation === null) return false
  switch (preparation.state) {
    case 'rejected':
    case 'raised':
    case 'cancelled':
      return true
    case 'active':
    case 'prepared':
      return false
  }
}

const PREPARATION_PHASE_LABEL: Readonly<Record<string, string>> = {
  task: 'Task',
  world: '월드',
  context: '컨텍스트',
  prompt: '프롬프트',
  tools: '도구',
  skills: '스킬',
  lane_inputs: '레인 입력',
  workspace_memory: '작업공간 메모리',
  wiki: '위키',
}

export function preparationHaltedLabel(preparation: KeeperTurnPreparation): string {
  const phase = PREPARATION_PHASE_LABEL[preparation.phase] ?? preparation.phase
  switch (preparation.state) {
    case 'rejected':
      return `${phase} 준비 거절`
    case 'raised':
      return `${phase} 준비 중 예외`
    case 'cancelled':
      return `${phase} 준비 취소`
    case 'active':
    case 'prepared':
      return `${phase} 준비`
  }
}

// Same words as the TUI's start_reason_label. A reason this table does not
// know is shown as the server wrote it.
const START_REASON_LABEL: Readonly<Record<string, string>> = {
  mention_pending: '멘션 도착',
  board_event_pending: '보드 이벤트',
  scope_message_pending: '범위 메시지',
  bootstrap_stimulus_pending: '첫 실행',
  never_started: '첫 실행',
  tool_result_ready_pending: '도구 결과 도착',
  connector_attention_pending: '연동 이벤트',
  ask_answered_pending: '질문 답변 도착',
  hitl_resolved_pending: '도구 승인 결정',
  completion_authority_rejection_pending: '완료 증거 반려',
  task_outcome_pending: 'Task 결과 도착',
  task_cancellation_pending: 'Task 취소',
  workspace_message_pending: '작업공간 메시지',
  deferred_runtime_lane_pending: '보류한 실행 재개',
  scheduled_autonomous_turn: '자율 실행 주기',
  scheduled_automation_due: '예약 작업 도래',
  task_backlog: '대기 중인 Task',
}

export function startReasonLabel(reason: string): string {
  return START_REASON_LABEL[reason] ?? reason
}

function decodeWaitingState(v: unknown): KeeperWaitingSummary['state'] | null {
  switch (v) {
    case 'idle':
    case 'busy':
    case 'waiting':
    case 'deferred':
      return v
    default:
      return null
  }
}

function decodeWaitingHead(raw: unknown): KeeperWaitingHead | null {
  if (!isRecord(raw)) return null
  const source = nonBlank(raw.source)
  const what = nonBlank(raw.what)
  const nextAction = nonBlank(raw.next_action)
  if (source === null || what === null || nextAction === null) return null
  return { source, what, next_action: nextAction, due_at: unixToIso(raw.due_at) }
}

/** Server `keeper_turns_json`. `null` for a Keeper the read did not cover or
 *  a body this dashboard cannot read. */
export function decodeWaitingSummary(raw: unknown): KeeperWaitingSummary | null {
  if (!isRecord(raw) || !Array.isArray(raw.waiting_heads)) return null
  const state = decodeWaitingState(raw.state)
  const count = raw.waiting_count
  if (state === null || typeof count !== 'number' || !Number.isInteger(count) || count < 0) return null
  const heads: KeeperWaitingHead[] = []
  for (const entry of raw.waiting_heads) {
    const head = decodeWaitingHead(entry)
    if (head === null) return null
    heads.push(head)
  }
  return {
    state,
    count,
    primary_reason: heads[0]?.what ?? null,
    due_at: unixToIso(raw.due_at),
    heads,
  }
}

/** The turns read's `waiting_errors`: when it is not empty, no Keeper's
 *  waiting was read, so each is unknown rather than empty. */
export function decodeWaitingUnavailable(raw: unknown): KeeperWaitingUnavailable | null {
  if (!Array.isArray(raw) || raw.length === 0) return null
  const first: unknown = raw[0]
  return { unavailable: true, reason: isRecord(first) ? nonBlank(first.what) : null }
}

export function isWaitingUnavailable(
  waiting: KeeperWaitingSummary | KeeperWaitingUnavailable | null | undefined,
): waiting is KeeperWaitingUnavailable {
  return waiting !== null && waiting !== undefined && 'unavailable' in waiting
}

/** The facts in a waiting row's `detail` that tell the operator why it is
 *  blocked (server lib/server_keeper_waiting_inventory.ml). Other detail keys
 *  are identities and stay out. */
export function waitingRowDetailLines(detail: unknown): readonly string[] {
  if (!isRecord(detail)) return []
  const lines: string[] = []
  const rejection = nonBlank(detail.rejection_reason)
  if (rejection !== null) lines.push(`거절 이유: ${rejection}`)
  const cancelled = nonBlank(detail.cancelled_reason)
  if (cancelled !== null) lines.push(`취소 이유: ${cancelled}`)
  const stage = nonBlank(detail.failure_stage)
  const failure = nonBlank(detail.failure_detail)
  if (stage !== null || failure !== null) {
    lines.push(`종료 막힘: ${[stage, failure].filter((part) => part !== null).join(' · ')}`)
  }
  if (Array.isArray(detail.candidates)) {
    for (const candidate of detail.candidates) {
      if (!isRecord(candidate)) continue
      const runtime = nonBlank(candidate.runtime_id)
      if (runtime === null) continue
      const cause = nonBlank(candidate.cause)
      const resets = nonBlank(candidate.resets_at)
      lines.push([runtime, cause, resets === null ? '복귀 시각 미확인' : `복귀 ${resets}`]
        .filter((part) => part !== null)
        .join(' · '))
    }
  }
  return lines
}
