/**
 * Shared SSOT wire decoders for HITL tool-approval and Keeper Ask payloads
 * consumed across Shell (`shell-state`), Pulse (`pulse-data`), and Work Inbox (`inbox-tab`).
 */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function asSafeInt(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) ? value : null
}

function formatArgsWire(value: unknown): string {
  if (typeof value === 'string') return value
  if (value === undefined || value === null) return ''
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return ''
  }
}

export interface DecodedToolApprovalWire {
  readonly approvalId: string
  readonly hasExplicitApprovalId: boolean
  readonly toolCallId: string
  readonly keeper: string
  readonly tool: string
  readonly args: string
  readonly question: string
  readonly because: string
  readonly askedAt: number | null
  readonly timeoutSec: number | null
  readonly revision: string
}

/**
 * Decode `/api/v1/tool-approvals` (`{ pending: [...] }`) once across all views.
 *
 * Rows without a `keeper` or without either `approval_id` or `tool_call_id` are
 * dropped. Callers that require both `approval_id` and `tool_call_id` (or fall
 * back when only one is present) inspect `hasExplicitApprovalId` / `toolCallId`.
 */
export function decodeToolApprovalsWire(raw: unknown): readonly DecodedToolApprovalWire[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) return []
  const items: DecodedToolApprovalWire[] = []
  for (const row of raw.pending) {
    if (!isRecord(row)) continue
    const explicitApprovalId = asNonEmptyString(row.approval_id)
    const toolCallId = asNonEmptyString(row.tool_call_id) ?? ''
    const keeper = asNonEmptyString(row.keeper)
    const approvalId = explicitApprovalId ?? (toolCallId || null)
    if (!approvalId || !keeper) continue
    const askedAt = asFiniteNumber(row.asked_at)
    const revision =
      asNonEmptyString(row.revision)
      ?? (typeof row.revision === 'number' && Number.isFinite(row.revision)
        ? String(row.revision)
        : `${approvalId}:${askedAt ?? 0}`)
    items.push({
      approvalId,
      hasExplicitApprovalId: explicitApprovalId !== null,
      toolCallId,
      keeper,
      tool: typeof row.tool === 'string' ? row.tool : '',
      args: formatArgsWire(row.args),
      question: typeof row.question === 'string' ? row.question : '',
      because: asNonEmptyString(row.because) ?? '',
      askedAt,
      timeoutSec: asFiniteNumber(row.timeout_sec),
      revision,
    })
  }
  return items
}

export interface StrictToolApprovalRow {
  readonly approval_id: string
  readonly keeper: string
  readonly tool_call_id: string
  readonly tool: string
  readonly args: string
  readonly question: string
  readonly because: string
  readonly asked_at: number | null
  readonly timeout_sec: number | null
}

/**
 * Strict `/api/v1/keepers/tool-approvals` decoder used by control-plane actions
 * (`api/keeper.ts`) that require explicit `approval_id`, `keeper`, and `tool_call_id`
 * on every row and throw on schema violations.
 */
export function decodeToolApprovalsStrict(raw: unknown): StrictToolApprovalRow[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) {
    throw new Error('Invalid tool approval listing: pending must be an array')
  }
  return raw.pending.map((row): StrictToolApprovalRow => {
    const record = isRecord(row) ? row : {}
    if (typeof record.approval_id !== 'string' || record.approval_id.trim() === '') {
      throw new Error('Invalid tool approval listing: approval_id must be a non-empty string')
    }
    if (typeof record.keeper !== 'string' || record.keeper.trim() === ''
      || typeof record.tool_call_id !== 'string' || record.tool_call_id.trim() === '') {
      throw new Error('Invalid tool approval listing: keeper and tool_call_id must be non-empty strings')
    }
    return {
      approval_id: record.approval_id,
      keeper: record.keeper,
      tool_call_id: record.tool_call_id,
      tool: typeof record.tool === 'string' ? record.tool : '',
      args: typeof record.args === 'string' ? record.args : '',
      question: typeof record.question === 'string' ? record.question : '',
      because: typeof record.because === 'string' ? record.because : '',
      asked_at: asFiniteNumber(record.asked_at),
      timeout_sec: asFiniteNumber(record.timeout_sec),
    }
  })
}

const CLOSED_ASK_STATES = new Set([
  'answered',
  'resolved',
  'closed',
  'withdrawn',
  'expired',
  'cancelled',
])

/**
 * Closed-set SSOT check for whether a raw Keeper Ask row is still open.
 * - If `row.resolution.state` is present, only `'open'` is considered open.
 * - Otherwise, `row.state` is open unless it is in `CLOSED_ASK_STATES`.
 */
export function isOpenKeeperAskRow(row: Record<string, unknown>): boolean {
  if (isRecord(row.resolution) && typeof row.resolution.state === 'string') {
    const normalized = row.resolution.state.trim().toLowerCase()
    return normalized === '' || normalized === 'open'
  }
  if (typeof row.state === 'string') {
    const normalized = row.state.trim().toLowerCase()
    return normalized === '' || normalized === 'open' || !CLOSED_ASK_STATES.has(normalized)
  }
  return true
}

export interface DecodedKeeperAskChoiceWire {
  readonly choiceId: string
  readonly label: string
  readonly description: string | null
}

export interface DecodedKeeperAskQuestionWire {
  readonly questionId: string
  readonly header: string
  readonly prompt: string
  readonly mode: 'single' | 'multi'
  readonly allowFreeText: boolean
  readonly freeTextHint: string | null
  readonly choices: readonly DecodedKeeperAskChoiceWire[]
}

export interface DecodedKeeperAskWire {
  readonly askId: string
  readonly keeper: string
  readonly askedAt: number | null
  readonly context: string | null
  readonly promptSummary: string | null
  readonly questionCount: number
  readonly questions: readonly DecodedKeeperAskQuestionWire[]
  readonly revision: string
}

export type DecodedKeeperAsksResult =
  | { readonly ok: true; readonly asks: readonly DecodedKeeperAskWire[] }
  | { readonly ok: false; readonly error: string }

/**
 * Shared SSOT decoder for `/api/v1/keepers/asks` consumed across Shell, Pulse, and Inbox.
 * Requires `{ asks: [...] }`, filters closed asks via `isOpenKeeperAskRow`, and never
 * fabricates a missing `keeper` identity.
 */
export function decodeKeeperAsksWire(raw: unknown): DecodedKeeperAsksResult {
  if (!isRecord(raw) || !Array.isArray(raw.asks)) {
    return { ok: false, error: 'Keeper 질문 응답에서 질문 목록을 확인할 수 없습니다.' }
  }
  const asks: DecodedKeeperAskWire[] = []
  for (const row of raw.asks) {
    if (!isRecord(row)) continue
    if (!isOpenKeeperAskRow(row)) continue
    const askId = asNonEmptyString(row.ask_id) ?? asNonEmptyString(row.id)
    const keeper = asNonEmptyString(row.keeper) ?? asNonEmptyString(row.keeper_name)
    if (!askId || !keeper) continue

    const rawQuestions = Array.isArray(row.questions) ? row.questions : []
    const questions: DecodedKeeperAskQuestionWire[] = []
    let fallbackQuestionPrompt: string | null = null
    for (const q of rawQuestions) {
      if (!isRecord(q)) continue
      const qPrompt = asNonEmptyString(q.prompt) ?? asNonEmptyString(q.question) ?? asNonEmptyString(q.text)
      if (!fallbackQuestionPrompt && qPrompt) fallbackQuestionPrompt = qPrompt
      const qid = asNonEmptyString(q.question_id)
      const prompt = asNonEmptyString(q.prompt)
      if (!qid || !prompt) continue
      const mode = q.mode === 'multi' ? 'multi' : 'single'
      const ft = isRecord(q.free_text) ? q.free_text : null
      const choices: DecodedKeeperAskChoiceWire[] = []
      if (Array.isArray(q.choices)) {
        for (const c of q.choices) {
          if (!isRecord(c)) continue
          const cid = asNonEmptyString(c.choice_id)
          const label = asNonEmptyString(c.label)
          if (!cid || !label) continue
          choices.push({ choiceId: cid, label, description: asNonEmptyString(c.description) })
        }
      }
      questions.push({
        questionId: qid,
        header: typeof q.header === 'string' && q.header.trim() ? q.header : qid,
        prompt,
        mode,
        allowFreeText: ft?.allowed === true,
        freeTextHint: ft ? asNonEmptyString(ft.hint) : null,
        choices,
      })
    }

    const askedAt = asFiniteNumber(row.asked_at) ?? asFiniteNumber(row.created_at)
    const revision =
      asNonEmptyString(row.revision)
      ?? (typeof row.revision === 'number' && Number.isFinite(row.revision)
        ? String(row.revision)
        : `a-${askedAt ?? 0}`)
    const promptSummary =
      asNonEmptyString(row.summary)
      ?? asNonEmptyString(row.title)
      ?? asNonEmptyString(row.question)
      ?? asNonEmptyString(row.prompt)
      ?? questions[0]?.prompt
      ?? fallbackQuestionPrompt
    asks.push({
      askId,
      keeper,
      askedAt,
      context: asNonEmptyString(row.context),
      promptSummary,
      questionCount: Math.max(1, rawQuestions.length),
      questions,
      revision,
    })
  }
  return { ok: true, asks }
}

export interface DecodedGateQueueRow {
  readonly id: string
  readonly keeper: string
  readonly toolName: string
  readonly sequence: number
  readonly waitingSec: number | null
  readonly phase: string | null
  readonly raw: Record<string, unknown>
}

export type DecodedGateQueueResult =
  | { readonly ok: true; readonly rows: readonly DecodedGateQueueRow[] }
  | { readonly ok: false; readonly unavailable: boolean; readonly error: string }

export function readGateUnavailableReason(stateObj: unknown): string | null {
  if (!isRecord(stateObj)) return null
  if (stateObj.state !== 'unavailable') return null
  return (
    asNonEmptyString(stateObj.operator_detail)
    ?? asNonEmptyString(stateObj.detail)
    ?? asNonEmptyString(stateObj.error)
    ?? asNonEmptyString(stateObj.title)
    ?? 'unavailable'
  )
}

/**
 * Strict SSOT Channel Gate queue decoder (mirrors `keeper_approval_queue_projection.ml`).
 * Fails the whole queue if `approval_queue_state` is `unavailable`, `approval_queue` is
 * missing, or any row breaks the required `(id, keeper_name, tool_name, sequence > 0)` contract.
 */
export function decodeGateQueueStrict(raw: unknown): DecodedGateQueueResult {
  if (!isRecord(raw)) {
    return { ok: false, unavailable: false, error: 'Channel Gate 응답 형식이 잘못되었습니다.' }
  }
  const unavailableReason = readGateUnavailableReason(raw.approval_queue_state)
  if (unavailableReason !== null) {
    return { ok: false, unavailable: true, error: unavailableReason }
  }
  if (!Array.isArray(raw.approval_queue)) {
    return { ok: false, unavailable: false, error: '응답에서 대기 목록을 확인할 수 없습니다.' }
  }
  const rows: DecodedGateQueueRow[] = []
  for (const row of raw.approval_queue) {
    const id = isRecord(row) ? asNonEmptyString(row.id) : null
    const keeper = isRecord(row) ? asNonEmptyString(row.keeper_name) : null
    const toolName = isRecord(row) ? asNonEmptyString(row.tool_name) : null
    const sequence = isRecord(row) ? asSafeInt(row.sequence) : null
    if (!isRecord(row) || !id || !keeper || !toolName || sequence === null || sequence <= 0) {
      return {
        ok: false,
        unavailable: false,
        error: '대기 목록에 서버 계약과 다른 줄이 있어요(id·keeper_name·tool_name·sequence).',
      }
    }
    rows.push({
      id,
      keeper,
      toolName,
      sequence,
      waitingSec: asFiniteNumber(row.waiting_s),
      phase: asNonEmptyString(row.phase),
      raw: row,
    })
  }
  return { ok: true, rows }
}
