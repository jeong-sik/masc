/**
 * Work Workspace (`2 Work`) — Shared Props, Closed-Sum Wire Types, Decoders & Safe Formatters.
 *
 * Constitution invariants enforced here:
 * - Strict closed-sum `GoalPhase` decoder rejects any Goal object carrying a legacy `status` field.
 * - Strict `decodeGoalConfirmation()` reads `verification.completion.state === 'proof_proven'` ->
 *   `verdict.{request_id, verification_run_id, criterion.revision, authority.actor, evidence, recorded_at}`
 *   + `raw.inspection_operator_id` + server `runtime_instance_id` from `/health?full=1`, failing closed.
 * - Strict closed-sum `TaskStatus` with accurate mutually-consistent filter counts
 *   (`active = Claimed + InProgress`, eliminating contradictory active vs in_progress metrics).
 * - Goalless tasks may link to a Goal once; already-linked tasks are refused (`Already_assigned`).
 * - Candle `supply.*_milli` & `decayed_milli` arrive as decimal strings while `balance_milli` is numeric;
 *   all milli parsers distinguish absent (`"없음"`) from zero (`"0.000"`).
 */

import type { ComponentChildren } from 'preact'
import { decodeGoalProof } from '../../api/goal-proof'
import { parseStoredHandoff, type StoredHandoff } from '../../store-normalizers'
import type { ApprovalQueuePhase, GateDecisionSource, KeeperSummaryAttemptDisposition } from '../../types/gate'
import { formatMilliCandleObserved } from '../../api/keeper-diagnostics'
import type { GoalProof } from '../../types/core'
import { ok, err, type Result } from '../../lib/result'
import { authSession } from '../../core/auth'
import { apiGet, apiMutate, type ApiError } from '../../core/transport'
import { resourceCache, type Observed } from '../../core/resource-cache'

export interface WorkspaceInspectPayload {
  title: string
  subtitle?: string
  kind: string
  data?: unknown
  render?: () => ComponentChildren
}

export interface WorkspaceViewProps {
  subroute: string
  entityId?: string
  entityTab?: string
  onNavigate: (path: string) => void
  onInspect: (payload: WorkspaceInspectPayload) => void
}

export type WorkSubroute = 'goals' | 'tasks' | 'inbox' | 'candle'

export function normalizeWorkSubroute(raw: string): WorkSubroute {
  const s = raw.trim().toLowerCase()
  if (s === 'tasks' || s === 'inbox' || s === 'candle' || s === 'goals') return s
  return 'goals'
}

export function isMultiAccountSession(): boolean {
  return authSession.value.kind === 'multi_account_signed_in'
}

export interface ExpectedWorkspace {
  readonly base_path: string
  readonly masc_root: string
}

export interface WorkspacePreconditionSnapshot {
  readonly base_path: string
  readonly masc_root: string
  readonly runtime_instance_id: string | null
}

// ── Safe Type Guards ──────────────────────────────────────────────────────

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

export function asNonEmptyString(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t.length > 0 ? t : null
}

export function asString(v: unknown, fallback = ''): string {
  return typeof v === 'string' ? v : fallback
}

export function asFiniteNumber(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

export function asSafeInt(v: unknown): number | null {
  return typeof v === 'number' && Number.isSafeInteger(v) ? v : null
}

export function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string' && x.trim().length > 0)
}

// ── Formatting Helpers (Zero vs Absent Honesty) ───────────────────────────

export function formatCompactCount(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return '없음'
  const abs = Math.abs(n)
  if (abs >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (abs >= 10_000) return `${(n / 1_000).toFixed(1)}k`
  return String(Math.trunc(n))
}

export function formatRelativeTime(tsInput: number | string | null | undefined, nowMs = Date.now()): string {
  if (tsInput === null || tsInput === undefined || tsInput === '') return '없음'
  let ms: number
  if (typeof tsInput === 'number') {
    if (!Number.isFinite(tsInput)) return '없음'
    ms = tsInput < 1_000_000_000_000 ? tsInput * 1000 : tsInput
  } else {
    const parsed = Date.parse(tsInput)
    if (Number.isNaN(parsed)) return tsInput
    ms = parsed
  }
  const diffSec = Math.round((nowMs - ms) / 1000)
  if (diffSec < 0) {
    const ahead = Math.abs(diffSec)
    if (ahead < 60) return `${ahead}초 후`
    if (ahead < 3600) return `${Math.floor(ahead / 60)}분 후`
    if (ahead < 86400) return `${Math.floor(ahead / 3600)}시간 후`
    return `${Math.floor(ahead / 86400)}일 후`
  }
  if (diffSec < 45) return '방금 전'
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}분 전`
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}시간 전`
  return `${Math.floor(diffSec / 86400)}일 전`
}

// ── Workspace Precondition & MCP Tool Helper (Core Transport Only) ────────

function extractRuntimeInstanceId(health: Record<string, unknown>): string | null {
  const candidates: Record<string, unknown>[] = []
  if (isRecord(health.build)) candidates.push(health.build)
  if (isRecord(health.startup)) candidates.push(health.startup)
  candidates.push(health)
  for (const obj of candidates) {
    const rid = asNonEmptyString(obj.runtime_instance_id) ?? asNonEmptyString(obj.instance_id)
    if (rid) return rid
  }
  return null
}

/**
 * Reads `GET /health?full=1` to obtain authoritative `expected_workspace`
 * (`effective_base_path`, `effective_masc_root`) and `runtime_instance_id`
 * matching `lib/masc_tui/protocol/wire_common.ml:521-525`.
 */
export async function readWorkspacePrecondition(
  signal?: AbortSignal,
): Promise<Result<WorkspacePreconditionSnapshot, ApiError>> {
  const obs = await resourceCache.fetch<WorkspacePreconditionSnapshot>(
    'work:workspace-precondition',
    async (s) => {
      const res = await apiGet<Record<string, unknown>>('/health?full=1', { signal: signal ?? s })
      if (!res.ok) return res
      const paths = isRecord(res.value.paths) ? res.value.paths : null
      const basePath = paths
        ? (asNonEmptyString(paths.effective_base_path) ?? asNonEmptyString(paths.base_path))
        : null
      const mascRoot = paths
        ? (asNonEmptyString(paths.effective_masc_root) ?? asNonEmptyString(paths.masc_root))
        : null
      if (!basePath || !mascRoot) {
        return err({
          kind: 'decode',
          status: 200,
          code: 'missing_workspace_paths',
          message: '서버 /health?full=1 응답에서 작업 공간 경로(effective_base_path, effective_masc_root)를 확인하지 못했습니다.',
          retryable: false,
        })
      }
      return ok({
        base_path: basePath,
        masc_root: mascRoot,
        runtime_instance_id: extractRuntimeInstanceId(res.value),
      })
    },
    { ttlMs: 30_000, topics: ['workspace', 'config'] },
  )
  if (obs.kind === 'value') return ok(obs.data)
  if (obs.kind === 'failed') return err(obs.error)
  return err({
    kind: 'server',
    status: null,
    code: 'workspace_unavailable',
    message: '작업 공간 경로를 확인할 수 없습니다.',
    retryable: true,
  })
}

export function toExpectedWorkspaceBody(snap: WorkspacePreconditionSnapshot): ExpectedWorkspace {
  return { base_path: snap.base_path, masc_root: snap.masc_root }
}

let mcpSeq = 1

export async function callMcpToolViaCore(
  toolName: string,
  args: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Result<{ rawText: string; parsed: unknown }, ApiError>> {
  const id = `work-${Date.now()}-${mcpSeq++}`
  const body = {
    jsonrpc: '2.0',
    id,
    method: 'tools/call',
    params: {
      name: toolName,
      arguments: args,
      _meta: {
        'io.modelcontextprotocol/protocolVersion': '2026-07-28',
        'io.modelcontextprotocol/clientCapabilities': {},
      },
    },
  }
  const res = await apiMutate<unknown>('POST', '/mcp', body, {
    headers: {
      Accept: 'application/json, text/event-stream',
      'Mcp-Protocol-Version': '2026-07-28',
      'Mcp-Method': 'tools/call',
      'Mcp-Name': toolName,
    },
    signal,
  })
  if (!res.ok) return res

  let rpcObj: Record<string, unknown> | null = null
  if (isRecord(res.value)) {
    rpcObj = res.value
  } else if (typeof res.value === 'string') {
    const dataLine = res.value
      .split(/\r?\n/)
      .filter((l) => l.startsWith('data:'))
      .map((l) => l.slice(5).trim())
      .filter(Boolean)
      .pop()
    if (dataLine) {
      try {
        const parsedLine: unknown = JSON.parse(dataLine)
        if (isRecord(parsedLine)) rpcObj = parsedLine
      } catch {
        // fall through
      }
    }
  }

  if (rpcObj && isRecord(rpcObj.error)) {
    return err({
      kind: 'validation',
      status: 200,
      code: String(rpcObj.error.code ?? 'mcp_error'),
      message: asString(rpcObj.error.message, `${toolName} 호출 실패`),
      retryable: false,
    })
  }

  const resultObj = rpcObj && isRecord(rpcObj.result) ? rpcObj.result : null
  const contentArr = resultObj && Array.isArray(resultObj.content) ? resultObj.content : []
  const textParts = contentArr
    .filter((c): c is Record<string, unknown> => isRecord(c) && c.type === 'text' && typeof c.text === 'string')
    .map((c) => c.text as string)
  const rawText = textParts.join('\n')
  const isError = resultObj?.isError === true

  let parsed: unknown = rawText
  if (rawText.trim().startsWith('{') || rawText.trim().startsWith('[')) {
    try {
      parsed = JSON.parse(rawText)
    } catch {
      parsed = rawText
    }
  }

  if (isError) {
    const errMsg = isRecord(parsed) && typeof parsed.error === 'string'
      ? parsed.error
      : rawText || `${toolName} 거절됨`
    return err({
      kind: 'validation',
      status: 200,
      code: 'tool_rejected',
      message: errMsg,
      retryable: false,
    })
  }

  return ok({ rawText, parsed })
}

// ── 1. Goals Closed-Sum Types & Strict Decoders ───────────────────────────

export type GoalResumablePhase = 'Executing' | 'Verifying' | 'Awaiting_confirmation'

export type GoalPhase =
  | 'Executing'
  | 'Verifying'
  | 'Awaiting_confirmation'
  | 'Blocked'
  | 'Paused'
  | 'Completed'
  | 'Dropped'

export const GOAL_PHASES: readonly GoalPhase[] = [
  'Executing',
  'Verifying',
  'Awaiting_confirmation',
  'Blocked',
  'Paused',
  'Completed',
  'Dropped',
] as const

export type GoalAction =
  | 'request_complete'
  | 'pause'
  | 'resume'
  | 'block'
  | 'unblock'
  | 'drop'
  | 'reopen'

export type GoalMeasure =
  | { readonly kind: 'count'; readonly noun: string; readonly total: number }
  | { readonly kind: 'quantity'; readonly unit: string; readonly direction: 'at_least' | 'at_most'; readonly target: number }
  | { readonly kind: 'done_when'; readonly condition: string }

export type GoalCriterionVerdict =
  | { readonly kind: 'pending'; readonly state: string; readonly detail: string | null }
  | { readonly kind: 'viable'; readonly reason: string }
  | { readonly kind: 'needs_revision'; readonly reason: string }
  | { readonly kind: 'unavailable'; readonly detail: string }

export interface GoalLinkedTaskRef {
  readonly id: string
  readonly title: string
  readonly status: TaskStatus
  readonly assignee: string | null
  readonly priority: number
}

export interface GoalItem {
  readonly id: string
  readonly title: string
  readonly phase: GoalPhase
  readonly resumePhase: GoalResumablePhase | null
  readonly priority: number
  readonly measure: GoalMeasure | null
  readonly measureText: string
  readonly procedure: string
  readonly dueDate: string | null
  readonly criterionRevision: string | null
  readonly criterionVerdict: GoalCriterionVerdict
  readonly lastReviewNote: string | null
  readonly verification: GoalProof | null
  readonly linkedTaskCount: Observed<number>
  readonly linkedTasks: readonly GoalLinkedTaskRef[]
  /** Open Gate approvals linked to this goal. Null when the payload has no
   *  count (the planning fallback does not send one). */
  readonly pendingApprovalCount: number | null
  readonly activity: GoalActivity
  readonly createdAt: string | null
  readonly updatedAt: string | null
}

/** Where the goal tree found the goal's newest activity
 *  (`Dashboard_goals_types_builder`: task, approval, runtime, goal_metadata,
 *  or several at the same instant). */
export type GoalActivitySource = 'task' | 'approval' | 'runtime' | 'goal_metadata' | 'multiple'

export type GoalActivity =
  /** `stagnationSeconds` is how long ago that activity was, measured by the
   *  server when it built the payload. */
  | { readonly kind: 'observed'; readonly source: GoalActivitySource; readonly lastActivityAt: string | null; readonly stagnationSeconds: number }
  /** The server looked and found no timestamped activity. */
  | { readonly kind: 'unavailable' }
  /** The payload carries no readable activity fields. */
  | { readonly kind: 'unknown' }

function parseGoalActivitySource(raw: unknown): GoalActivitySource | null {
  switch (raw) {
    case 'task':
    case 'approval':
    case 'runtime':
    case 'goal_metadata':
    case 'multiple':
      return raw
    default:
      return null
  }
}

export function decodeGoalActivity(raw: Record<string, unknown>): GoalActivity {
  if (raw.activity_observation === 'unavailable') {
    return raw.stagnation_seconds === null || raw.stagnation_seconds === undefined
      ? { kind: 'unavailable' }
      : { kind: 'unknown' }
  }
  const source = parseGoalActivitySource(raw.activity_observation)
  const stagnationSeconds = asSafeInt(raw.stagnation_seconds)
  if (source === null || stagnationSeconds === null || stagnationSeconds < 0) return { kind: 'unknown' }
  return { kind: 'observed', source, lastActivityAt: asNonEmptyString(raw.last_activity_at), stagnationSeconds }
}

export function goalActivitySourceLabel(source: GoalActivitySource): string {
  switch (source) {
    case 'task': return '태스크'
    case 'approval': return '승인'
    case 'runtime': return 'Keeper 실행'
    case 'goal_metadata': return 'Goal 수정'
    case 'multiple': return '여러 곳'
  }
}

function parseResumablePhase(raw: unknown): GoalResumablePhase | null {
  if (typeof raw !== 'string') return null
  switch (raw.trim().toLowerCase()) {
    case 'executing':
      return 'Executing'
    case 'verifying':
      return 'Verifying'
    case 'awaiting_confirmation':
      return 'Awaiting_confirmation'
    default:
      return null
  }
}

/**
 * Strict Goal phase decoder per `docs/constitution.xml`:
 * - Refuses any Goal object carrying a legacy `status` property (`strict_parse_no_default`).
 * - Maps wire phase tokens to the exact 7-variant closed sum `GoalPhase`.
 * - Preserves `resume_phase` when `Paused` or `Blocked` and rejects it on active/terminal phases.
 */
export function decodeGoalPhaseStrict(
  raw: Record<string, unknown>,
): Result<{ phase: GoalPhase; resumePhase: GoalResumablePhase | null }, string> {
  if ('status' in raw && raw.status !== undefined) {
    return err('Goal 객체에 금지된 레거시 status 필드가 포함되어 있습니다 (phase만 허용).')
  }
  const rawPhase = asNonEmptyString(raw.phase)
  if (!rawPhase) {
    return err('Goal phase 필드가 비어 있습니다.')
  }
  const lower = rawPhase.toLowerCase()
  const rawResume = raw.resume_phase

  switch (lower) {
    case 'executing':
      if (rawResume !== undefined && rawResume !== null) {
        return err('Executing 상태에는 resume_phase가 없어야 합니다.')
      }
      return ok({ phase: 'Executing', resumePhase: null })
    case 'verifying':
      if (rawResume !== undefined && rawResume !== null) {
        return err('Verifying 상태에는 resume_phase가 없어야 합니다.')
      }
      return ok({ phase: 'Verifying', resumePhase: null })
    case 'awaiting_confirmation':
      if (rawResume !== undefined && rawResume !== null) {
        return err('Awaiting_confirmation 상태에는 resume_phase가 없어야 합니다.')
      }
      return ok({ phase: 'Awaiting_confirmation', resumePhase: null })
    case 'completed':
      if (rawResume !== undefined && rawResume !== null) {
        return err('Completed 상태에는 resume_phase가 없어야 합니다.')
      }
      return ok({ phase: 'Completed', resumePhase: null })
    case 'dropped':
      if (rawResume !== undefined && rawResume !== null) {
        return err('Dropped 상태에는 resume_phase가 없어야 합니다.')
      }
      return ok({ phase: 'Dropped', resumePhase: null })
    case 'paused':
    case 'blocked': {
      const rp = parseResumablePhase(rawResume)
      if (!rp) {
        return err(`${lower} 상태의 Goal에는 유효한 resume_phase가 필요합니다.`)
      }
      return ok({ phase: lower === 'paused' ? 'Paused' : 'Blocked', resumePhase: rp })
    }
    default:
      return err(`알 수 없는 Goal phase: ${rawPhase}`)
  }
}

export function formatGoalMeasure(m: GoalMeasure): string {
  switch (m.kind) {
    case 'count':
      return `${m.total} ${m.noun}`
    case 'quantity':
      return `${m.direction === 'at_least' ? '≥' : '≤'} ${m.target} ${m.unit}`
    case 'done_when':
      return m.condition
  }
}

export function decodeGoalMeasureStrict(raw: unknown): GoalMeasure | null {
  if (!isRecord(raw)) return null
  if (raw.kind === 'count') {
    const noun = asNonEmptyString(raw.noun)
    const total = asSafeInt(raw.total)
    if (!noun || total === null || total < 1) return null
    return { kind: 'count', noun, total }
  }
  if (raw.kind === 'quantity') {
    const unit = asNonEmptyString(raw.unit)
    const target = asFiniteNumber(raw.target)
    const dir = raw.direction === 'at_least' || raw.direction === 'at_most' ? raw.direction : null
    if (!unit || target === null || !dir) return null
    return { kind: 'quantity', unit, direction: dir, target }
  }
  if (raw.kind === 'done_when') {
    const condition = asNonEmptyString(raw.condition)
    if (!condition) return null
    return { kind: 'done_when', condition }
  }
  return null
}

export function validateNewGoalInput(input: {
  title: string
  measureKind: 'done_when' | 'count' | 'quantity'
  condition: string
  noun: string
  total: string
  unit: string
  direction: 'at_least' | 'at_most'
  target: string
  procedure: string
  priority: number
}): Result<{ title: string; measure: GoalMeasure; procedure: string; priority: number }, string> {
  const title = input.title.trim()
  if (!title) return err('목표 제목을 입력하세요.')
  const procedure = input.procedure.trim()
  if (!procedure) {
    return err('constitution.xml 규약상 비어 있지 않은 측정 절차(procedure)가 필수입니다.')
  }
  let measure: GoalMeasure
  if (input.measureKind === 'done_when') {
    const cond = input.condition.trim()
    if (!cond || cond.includes('\n')) {
      return err('완료 조건(done_when.condition)은 비어 있지 않은 한 줄 텍스트여야 합니다.')
    }
    measure = { kind: 'done_when', condition: cond }
  } else if (input.measureKind === 'count') {
    const noun = input.noun.trim()
    const total = Number(input.total)
    if (!noun || noun.includes('\n')) return err('개수 측정 단위(noun)를 한 줄로 입력하세요.')
    if (!Number.isSafeInteger(total) || total < 1) return err('목표 개수(total)는 1 이상의 정수여야 합니다.')
    measure = { kind: 'count', noun, total }
  } else {
    const unit = input.unit.trim()
    const target = Number(input.target)
    if (!unit || unit.includes('\n')) return err('수량 단위(unit)를 한 줄로 입력하세요.')
    if (!Number.isFinite(target)) return err('목표 수치(target)는 유한한 숫자여야 합니다.')
    measure = { kind: 'quantity', unit, direction: input.direction, target }
  }
  const priority = Number.isSafeInteger(input.priority) ? input.priority : 2
  return ok({ title, measure, procedure, priority })
}

export function decodeCriterionVerdict(raw: unknown): GoalCriterionVerdict {
  if (!isRecord(raw)) return { kind: 'pending', state: 'unchecked', detail: null }
  const state = (asNonEmptyString(raw.state) ?? asNonEmptyString(raw.status) ?? 'unchecked').toLowerCase()
  const reason = asNonEmptyString(raw.reason) ?? asNonEmptyString(raw.detail)
  if (state === 'viable' || state === 'valid' || state === 'approved' || state === 'passed') {
    return { kind: 'viable', reason: reason ?? '실재성·도달 가능성 확인됨' }
  }
  if (state === 'needs_revision' || state === 'invalid' || state === 'rejected' || state === 'failed') {
    return { kind: 'needs_revision', reason: reason ?? '성공 조건 보완 필요' }
  }
  if (state === 'unavailable' || state === 'execution_unknown') {
    return { kind: 'unavailable', detail: reason ?? '심사 상태 관측 불가' }
  }
  return { kind: 'pending', state, detail: asNonEmptyString(raw.detail) }
}

export function availableGoalActions(phase: GoalPhase): readonly GoalAction[] {
  switch (phase) {
    case 'Executing':
      return ['request_complete', 'pause', 'block', 'drop']
    case 'Verifying':
      return ['pause', 'block', 'drop']
    case 'Awaiting_confirmation':
      return ['pause', 'block', 'drop']
    case 'Paused':
      return ['resume', 'drop']
    case 'Blocked':
      return ['unblock', 'drop']
    case 'Completed':
      return ['reopen']
    case 'Dropped':
      return ['reopen']
  }
}

export function goalPhaseLabel(phase: GoalPhase): string {
  switch (phase) {
    case 'Executing': return 'Executing'
    case 'Verifying': return 'Verifying'
    case 'Awaiting_confirmation': return 'Awaiting Confirmation'
    case 'Blocked': return 'Blocked'
    case 'Paused': return 'Paused'
    case 'Completed': return 'Completed'
    case 'Dropped': return 'Dropped'
  }
}

export function goalPhaseTone(phase: GoalPhase): 'ok' | 'info' | 'warn' | 'err' | 'stalled' | 'idle' {
  switch (phase) {
    case 'Executing': return 'info'
    case 'Verifying': return 'stalled'
    case 'Awaiting_confirmation': return 'warn'
    case 'Blocked': return 'err'
    case 'Paused': return 'idle'
    case 'Completed': return 'ok'
    case 'Dropped': return 'idle'
  }
}

function decodeNonNegativeCount(raw: unknown): number | null {
  const count = asSafeInt(raw)
  return count !== null && count >= 0 ? count : null
}

export function decodeGoalItem(raw: unknown): Result<GoalItem, string> {
  if (!isRecord(raw)) return err('Goal 항목이 JSON 객체가 아닙니다.')
  const phaseRes = decodeGoalPhaseStrict(raw)
  if (!phaseRes.ok) return phaseRes
  const id = typeof raw.id === 'string' && raw.id.length > 0 ? raw.id : null
  const title = asNonEmptyString(raw.title)
  if (!id || !title) return err('Goal id 또는 title이 누락되었습니다.')

  const measureObj = decodeGoalMeasureStrict(raw.measure)
  const measureText = measureObj
    ? formatGoalMeasure(measureObj)
    : typeof raw.measure === 'string' && raw.measure.trim()
      ? raw.measure.trim()
      : '측정 조건 없음'

  const rawTasks = Array.isArray(raw.tasks) ? raw.tasks : []
  const linkedTasks: GoalLinkedTaskRef[] = []
  for (const t of rawTasks) {
    if (!isRecord(t)) continue
    const tid = asNonEmptyString(t.id)
    const ttitle = asNonEmptyString(t.title)
    const tstatus = parseTaskStatus(t.status)
    if (!tid || !ttitle || !tstatus) continue
    linkedTasks.push({
      id: tid,
      title: ttitle,
      status: tstatus,
      assignee: asNonEmptyString(t.assignee),
      priority: asSafeInt(t.priority) ?? 2,
    })
  }

  const rawCount = asSafeInt(raw.linked_task_count) ?? asSafeInt(raw.task_count)
  const linkedTaskCount: Observed<number> =
    rawCount !== null
      ? { kind: 'value', data: rawCount, stale: false, updatedAt: Date.now() }
      : rawTasks.length > 0
        ? { kind: 'value', data: linkedTasks.length, stale: false, updatedAt: Date.now() }
        : { kind: 'absent' }

  return ok({
    id,
    title,
    phase: phaseRes.value.phase,
    resumePhase: phaseRes.value.resumePhase,
    priority: asSafeInt(raw.priority) ?? 2,
    measure: measureObj,
    measureText,
    procedure: asString(raw.procedure, ''),
    dueDate: asNonEmptyString(raw.due_date),
    criterionRevision: asNonEmptyString(raw.criterion_revision),
    criterionVerdict: decodeCriterionVerdict(raw.criterion_review),
    lastReviewNote: asNonEmptyString(raw.last_review_note),
    verification: raw.verification === undefined ? null : decodeGoalProof(raw.verification, id),
    linkedTaskCount,
    linkedTasks,
    pendingApprovalCount: decodeNonNegativeCount(raw.pending_approval_count),
    activity: decodeGoalActivity(raw),
    createdAt: asNonEmptyString(raw.created_at),
    updatedAt: asNonEmptyString(raw.updated_at),
  })
}

export interface GoalConfirmationEvidence {
  readonly goalId: string
  readonly phase: string
  readonly criterionRevision: string
  readonly requestId: string
  readonly verificationRunId: string
  readonly authorityKind: 'system_llm_agent' | 'human_operator'
  readonly actor: string
  readonly evidence: string
  readonly recordedAt: string
  readonly inspectionOperatorId: string
  readonly runtimeInstanceId: string
  readonly workspace: ExpectedWorkspace
}

/**
 * Strictly decodes `GET /api/v1/goals/confirmation` matching `lib/goal/goal_verification.ml:80-125,212-222`
 * and `lib/server/server_routes_http_routes_verification.ml:170-216`:
 * - Requires non-empty `runtimeInstanceId` from `/health?full=1` (never fabricates `'runtime'`).
 * - Requires `verification.completion.state === 'proof_proven'` (rejects `stale_criterion`, `proof_refuted`, etc.).
 * - Reads proof identity strictly from `verification.completion.verdict` (`request_id`, `verification_run_id`,
 *   `criterion.revision`, `authority.{kind, actor}`, `evidence`, `recorded_at`) + `inspection_operator_id`.
 */
export function decodeGoalConfirmation(
  raw: unknown,
  expectedGoalId: string,
  ws: WorkspacePreconditionSnapshot,
): Result<GoalConfirmationEvidence, string> {
  if (!ws.runtime_instance_id) {
    return err('서버 /health?full=1 응답에서 runtime_instance_id를 확인하지 못해 완료 확정을 진행할 수 없습니다.')
  }
  if (!isRecord(raw)) {
    return err('목표 완료 확인 응답이 JSON 객체가 아닙니다.')
  }
  const inspectionOperatorId = asNonEmptyString(raw.inspection_operator_id)
  if (!inspectionOperatorId) {
    return err('증거를 조회한 운영자 식별자(inspection_operator_id)가 응답에 없습니다.')
  }
  const goalObj = isRecord(raw.goal) ? raw.goal : null
  if (!goalObj || goalObj.id !== expectedGoalId || !asNonEmptyString(goalObj.phase)) {
    return err('목표 완료 확인 응답의 goal 식별자가 일치하지 않습니다.')
  }
  const verif = isRecord(raw.verification) ? raw.verification : null
  if (!verif || verif.goal_id !== expectedGoalId || !isRecord(verif.completion)) {
    return err('목표 완료 확인 응답의 verification 레코드가 유효하지 않습니다.')
  }
  const completion = verif.completion
  if (completion.state === 'stale_criterion') {
    return err('Verifier 증명이 이전 기준(stale_criterion)에 대한 기록입니다. 현재 기준으로 다시 검증해야 합니다.')
  }
  if (completion.state === 'proof_refuted') {
    return err('Verifier 판정이 반증(proof_refuted) 상태이므로 완료 확정할 수 없습니다.')
  }
  if (completion.state !== 'proof_proven') {
    return err(`완료 확정 가능한 증명 상태(proof_proven)가 아닙니다: ${String(completion.state ?? 'unknown')}`)
  }
  const verdict = isRecord(completion.verdict) ? completion.verdict : null
  if (!verdict) {
    return err('proof_proven 상태에 verdict 객체가 누락되었습니다.')
  }
  if (verdict.outcome !== 'proven' || verdict.reason !== null) {
    return err('verdict outcome이 proven(reason=null)이 아닙니다.')
  }
  const requestId = asNonEmptyString(verdict.request_id)
  const verificationRunId = asNonEmptyString(verdict.verification_run_id)
  const evidence = asNonEmptyString(verdict.evidence)
  const recordedAt = asNonEmptyString(verdict.recorded_at)
  const criterion = isRecord(verdict.criterion) ? verdict.criterion : null
  const criterionRevision = criterion ? asNonEmptyString(criterion.revision) : null
  const authority = isRecord(verdict.authority) ? verdict.authority : null
  const authorityKind =
    authority && (authority.kind === 'system_llm_agent' || authority.kind === 'human_operator')
      ? authority.kind
      : null
  const actor = authority ? asNonEmptyString(authority.actor) : null

  if (!requestId || !verificationRunId || !criterionRevision || !evidence || !recordedAt || !authorityKind || !actor) {
    return err('Verifier verdict 필수 필드(request_id, verification_run_id, criterion.revision, authority.actor, evidence, recorded_at)가 누락되었습니다.')
  }
  if (typeof goalObj.criterion_revision === 'string' && goalObj.criterion_revision !== criterionRevision) {
    return err('Goal criterion_revision과 Verifier 증명 criterion.revision이 일치하지 않습니다.')
  }

  return ok({
    goalId: expectedGoalId,
    phase: String(goalObj.phase),
    criterionRevision,
    requestId,
    verificationRunId,
    authorityKind,
    actor,
    evidence,
    recordedAt,
    inspectionOperatorId,
    runtimeInstanceId: ws.runtime_instance_id,
    workspace: toExpectedWorkspaceBody(ws),
  })
}

export interface VerificationRequestItem {
  readonly requestId: string
  readonly taskId: string
  readonly taskTitle: string
  readonly submittedBy: string
  readonly createdAt: string | number | null
  readonly completionContract: readonly string[]
  readonly submittedEvidence: readonly string[]
  readonly reviewState: string | null
  readonly reviewDetail: string | null
}

// ── 2. Tasks & Schedules Closed-Sum Types & Reconciled Counters ───────────

export type TaskStatus =
  | 'Todo'
  | 'Claimed'
  | 'InProgress'
  | 'AwaitingVerification'
  | 'Done'
  | 'Cancelled'

export type TaskFilterChip =
  | 'all'
  | 'active'
  | 'awaiting_verify'
  | 'todo'
  | 'unlinked'
  | 'done'
  | 'schedules'

export interface TaskItem {
  readonly id: string
  readonly title: string
  readonly description: string | null
  readonly priority: number
  readonly status: TaskStatus
  readonly assignee: string | null
  readonly goalId: string | null
  readonly verificationId: string | null
  readonly createdAt: string | null
  readonly updatedAt: string | null
  readonly cancelledBy: string | null
  readonly cancelReason: string | null
  /** The note the last assignee left when it released the task. */
  readonly handoff: StoredHandoff
}

export function parseTaskStatus(raw: unknown): TaskStatus | null {
  if (typeof raw === 'string') {
    switch (raw.trim().toLowerCase()) {
      case 'todo': return 'Todo'
      case 'claimed': return 'Claimed'
      case 'in_progress':
      case 'inprogress': return 'InProgress'
      case 'awaiting_verification':
      case 'awaitingverification': return 'AwaitingVerification'
      case 'done':
      case 'completed': return 'Done'
      case 'cancelled':
      case 'canceled': return 'Cancelled'
      default: return null
    }
  }
  if (isRecord(raw)) {
    const kind = asNonEmptyString(raw.status) ?? asNonEmptyString(raw.kind) ?? asNonEmptyString(raw.state)
    return kind ? parseTaskStatus(kind) : null
  }
  return null
}

export function decodeTaskItem(raw: unknown): TaskItem | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw.id)
  const title = asNonEmptyString(raw.title)
  const status = parseTaskStatus(raw.status)
  if (!id || !title || !status) return null
  const statusObj = isRecord(raw.status) ? raw.status : null
  const assignee = asNonEmptyString(raw.assignee) ?? (statusObj ? asNonEmptyString(statusObj.assignee) : null)
  const verificationId =
    asNonEmptyString(raw.verification_id) ?? (statusObj ? asNonEmptyString(statusObj.verification_id) : null)
  const cancelledBy =
    asNonEmptyString(raw.cancelled_by) ?? (statusObj ? asNonEmptyString(statusObj.cancelled_by) : null)
  const cancelReason =
    asNonEmptyString(raw.reason) ?? (statusObj ? asNonEmptyString(statusObj.reason) : null)

  return {
    id,
    title,
    description: asNonEmptyString(raw.description),
    priority: asSafeInt(raw.priority) ?? 2,
    status,
    assignee,
    goalId: asNonEmptyString(raw.goal_id),
    verificationId,
    createdAt: asNonEmptyString(raw.created_at),
    updatedAt: asNonEmptyString(raw.updated_at),
    cancelledBy,
    cancelReason,
    handoff: parseStoredHandoff(raw.handoff_context),
  }
}

export interface TaskFilterCounts {
  readonly all: number
  readonly active: number
  readonly awaiting_verify: number
  readonly todo: number
  readonly unlinked: number
  readonly done: number
  readonly cancelled: number
}

export function computeTaskFilterCounts(tasks: readonly TaskItem[]): TaskFilterCounts {
  let active = 0
  let awaitingVerify = 0
  let todo = 0
  let unlinked = 0
  let done = 0
  let cancelled = 0

  for (const t of tasks) {
    if (t.status === 'Claimed' || t.status === 'InProgress') active += 1
    else if (t.status === 'AwaitingVerification') awaitingVerify += 1
    else if (t.status === 'Todo') todo += 1
    else if (t.status === 'Done') done += 1
    else if (t.status === 'Cancelled') cancelled += 1

    if (t.goalId === null && t.status !== 'Done' && t.status !== 'Cancelled') {
      unlinked += 1
    }
  }

  return {
    all: tasks.length,
    active,
    awaiting_verify: awaitingVerify,
    todo,
    unlinked,
    done,
    cancelled,
  }
}

export function filterTasksByChip(tasks: readonly TaskItem[], chip: TaskFilterChip): readonly TaskItem[] {
  switch (chip) {
    case 'all':
      return tasks
    case 'active':
      return tasks.filter((t) => t.status === 'Claimed' || t.status === 'InProgress')
    case 'awaiting_verify':
      return tasks.filter((t) => t.status === 'AwaitingVerification')
    case 'todo':
      return tasks.filter((t) => t.status === 'Todo')
    case 'unlinked':
      return tasks.filter((t) => t.goalId === null && t.status !== 'Done' && t.status !== 'Cancelled')
    case 'done':
      return tasks.filter((t) => t.status === 'Done' || t.status === 'Cancelled')
    case 'schedules':
      return []
  }
}

export function checkTaskGoalLinkable(
  task: TaskItem,
): Result<true, 'Already_assigned' | 'Task_finished'> {
  if (task.status === 'Done' || task.status === 'Cancelled') {
    return err('Task_finished')
  }
  if (task.goalId !== null) {
    return err('Already_assigned')
  }
  return ok(true)
}

export interface TaskHistoryEvent {
  readonly source: string
  readonly file: string
  readonly offset: number
  readonly event: unknown
}

export interface TaskHistoryPageData {
  readonly schema: string
  readonly task_id: string
  readonly cursor: string | null
  readonly sources: readonly { readonly source: string; readonly state: 'observed' | 'not-created' }[]
  readonly events: readonly TaskHistoryEvent[]
  readonly next_cursor: string | null
}

export interface ScheduleRow {
  readonly scheduleId: string
  readonly scheduleInstanceId: string
  readonly status: string
  readonly source: string
  readonly dueAt: string | null
  readonly nextDueAt: string | null
  readonly recurrenceKind: string
  readonly recurrenceSummary: string
  readonly keeperName: string | null
  readonly summary: string | null
  readonly message: string | null
  readonly lastWakeStatus: string | null
  readonly lastWakeError: string | null
}

export type ScheduleProjection =
  | { readonly state: 'available'; readonly rows: readonly ScheduleRow[]; readonly totalCount: number; readonly truncated: boolean }
  | { readonly state: 'unavailable'; readonly reason: string }

// ── 3. Unified HITL Inbox Types ───────────────────────────────────────────

export interface ToolApprovalWait {
  readonly approvalId: string
  readonly toolCallId: string
  readonly keeper: string
  readonly tool: string
  readonly argsPreview: string
  readonly question: string
  readonly because: string | null
  /** Unix seconds; null when the row carries no readable time. */
  readonly askedAt: number | null
  readonly timeoutSec: number | null
  readonly revision: string
}

export type ToolApprovalTimeout =
  | { readonly kind: 'unknown' }
  | { readonly kind: 'pending'; readonly timeoutSec: number; readonly remainingSec: number }
  | { readonly kind: 'expired'; readonly timeoutSec: number; readonly overdueSec: number }

/** When the held call stops waiting. The registry times a wait out
 *  `timeout_sec` after it registers it, and `asked_at` is that moment. */
export function toolApprovalTimeout(
  wait: Pick<ToolApprovalWait, 'askedAt' | 'timeoutSec'>,
  nowMs: number,
): ToolApprovalTimeout {
  if (wait.askedAt === null || wait.timeoutSec === null || wait.timeoutSec < 0) return { kind: 'unknown' }
  const leftSec = wait.askedAt + wait.timeoutSec - nowMs / 1000
  return leftSec > 0
    ? { kind: 'pending', timeoutSec: wait.timeoutSec, remainingSec: leftSec }
    : { kind: 'expired', timeoutSec: wait.timeoutSec, overdueSec: -leftSec }
}

export interface AskChoiceItem {
  readonly choiceId: string
  readonly label: string
  readonly description: string | null
}

export interface AskQuestionItem {
  readonly questionId: string
  readonly header: string
  readonly prompt: string
  readonly mode: 'single' | 'multi'
  readonly allowFreeText: boolean
  readonly freeTextHint: string | null
  readonly choices: readonly AskChoiceItem[]
}

export interface KeeperAskItem {
  readonly askId: string
  readonly keeper: string
  readonly context: string | null
  readonly questions: readonly AskQuestionItem[]
  readonly revision: string
}

export interface GatePendingItem {
  readonly id: string
  readonly keeper: string
  readonly toolName: string
  readonly inputPreview: string | null
  readonly waitingSec: number | null
  /** Null when the row's phase is missing or not a current variant. */
  readonly phase: ApprovalQueuePhase | null
  readonly disposition: KeeperSummaryAttemptDisposition | null
  readonly sequence: number
  readonly taskId: string | null
  readonly goalId: string | null
  readonly summaryText: string | null
  readonly rationale: string | null
  readonly keyQuestions: readonly string[]
}

export interface GateResolvedAuditRow {
  readonly id: string
  readonly keeper: string
  readonly toolName: string
  readonly decision: 'approve' | 'reject'
  /** Null when the row does not say who decided. */
  readonly decisionSource: GateDecisionSource | null
  readonly reason: string | null
  readonly actor: string | null
  readonly resolvedAt: string
}

export type InboxEntry =
  | { readonly kind: 'tool_approval'; readonly key: string; readonly item: ToolApprovalWait }
  | { readonly kind: 'keeper_ask'; readonly key: string; readonly item: KeeperAskItem }
  | { readonly kind: 'channel_gate'; readonly key: string; readonly item: GatePendingItem }
  | { readonly kind: 'goal_confirmation'; readonly key: string; readonly goal: GoalItem }

// ── 4. Candle Ledger & Decimal-String Milli Parsers (`#36`) ───────────────

export function parseCandleMilli(raw: unknown): number | null {
  if (typeof raw === 'number') {
    return Number.isFinite(raw) ? raw : null
  }
  if (typeof raw === 'string') {
    const trimmed = raw.trim()
    if (!trimmed || !/^-?\d+(?:\.\d+)?$/.test(trimmed)) return null
    const parsed = Number(trimmed)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

export function formatMilliCandles(raw: unknown): string {
  const input = typeof raw === 'string' || typeof raw === 'number' ? raw : null
  const obs = formatMilliCandleObserved(input)
  return obs.kind === 'value' ? obs.data : '없음'
}

export interface CandleBalanceRow {
  readonly keeper: string
  readonly balanceMilli: number
  readonly decayedMilli: number | null
  readonly decayedMilliRaw: string
  readonly lastEventUnix: number | null
  readonly ownedItems: readonly string[]
  readonly equipped: Readonly<Record<'face' | 'neck' | 'head' | 'hand' | 'base', string | null>>
}

export interface CandleDiagnosticItem {
  readonly goalId: string
  readonly title: string | null
  readonly kind: string
  readonly reason: string | null
  readonly observation: string
  readonly linkedTaskCount: number
  readonly candidateTaskCount: number | null
  readonly candidateKeeperCount: number | null
  readonly atUnix: number
  readonly diagnosticHint: string
}

export interface CandleEventRow {
  readonly seq: number
  readonly atUnix: number
  readonly atRfc3339: string
  readonly kind: string
  readonly raw: Record<string, unknown>
}

export interface CandleLedgerData {
  readonly ledgerState: 'missing' | 'present'
  readonly totalEvents: number
  readonly balanceError: string | null
  readonly policy: {
    readonly configuration: string
    readonly disabledReason: string | null
    readonly pricingMode: string
    readonly halfLifeMode: 'off' | 'decay'
    readonly halfLifeHours: number | null
    readonly halfLifeSec: number | null
  }
  readonly supply: {
    readonly issuedMilli: number | null
    readonly burnedMilli: number | null
    readonly circulatingMilli: number | null
    readonly totalSupplyMilli: number | null
    readonly activeKeepers: number
  }
  readonly balances: readonly CandleBalanceRow[]
  readonly diagnostics: {
    readonly unattributedCount: number
    readonly backlogFencedCount: number
    readonly zeroLinkedTasksGoals: number
    readonly heldWindowsCount: number
    readonly items: readonly CandleDiagnosticItem[]
  }
  readonly recentEvents: readonly CandleEventRow[]
}

export function decodeCandleLedger(raw: unknown): Result<CandleLedgerData, string> {
  if (!isRecord(raw)) return err('Candle 원장 응답이 객체가 아닙니다.')
  const ledgerState = raw.ledger_state === 'missing' ? 'missing' : raw.ledger_state === 'present' ? 'present' : null
  if (!ledgerState) return err(`알 수 없는 ledger_state: ${String(raw.ledger_state)}`)

  const policyObj = isRecord(raw.policy) ? raw.policy : {}
  const hlObj = isRecord(policyObj.half_life) ? policyObj.half_life : {}
  const halfLifeMode = hlObj.mode === 'decay' ? 'decay' : 'off'
  const halfLifeHours = asFiniteNumber(hlObj.half_life_hours)
  const halfLifeSec = asFiniteNumber(hlObj.half_life_sec) ?? asFiniteNumber(policyObj.half_life_sec)

  const supplyObj = isRecord(raw.supply) ? raw.supply : {}
  const balancesRaw = Array.isArray(raw.balances) ? raw.balances : []
  const balances: CandleBalanceRow[] = []
  for (const row of balancesRaw) {
    if (!isRecord(row)) continue
    const keeper = asNonEmptyString(row.keeper)
    if (!keeper) continue
    const balanceMilli = parseCandleMilli(row.balance_milli) ?? 0
    const decayedRaw = typeof row.decayed_milli === 'string'
      ? row.decayed_milli
      : typeof row.decayed_milli === 'number'
        ? String(row.decayed_milli)
        : ''
    const eqRaw = isRecord(row.equipped) ? row.equipped : {}
    balances.push({
      keeper,
      balanceMilli,
      decayedMilli: parseCandleMilli(row.decayed_milli),
      decayedMilliRaw: decayedRaw,
      lastEventUnix: asFiniteNumber(row.last_event_unix),
      ownedItems: asStringArray(row.owned_items),
      equipped: {
        face: asNonEmptyString(eqRaw.face),
        neck: asNonEmptyString(eqRaw.neck),
        head: asNonEmptyString(eqRaw.head),
        hand: asNonEmptyString(eqRaw.hand),
        base: asNonEmptyString(eqRaw.base),
      },
    })
  }

  const diagObj = isRecord(raw.diagnostics) ? raw.diagnostics : {}
  const diagItemsRaw = Array.isArray(diagObj.items) ? diagObj.items : []
  const diagItems: CandleDiagnosticItem[] = []
  for (const d of diagItemsRaw) {
    if (!isRecord(d)) continue
    const goalId = asNonEmptyString(d.goal_id)
    if (!goalId) continue
    diagItems.push({
      goalId,
      title: asNonEmptyString(d.title),
      kind: asString(d.kind, 'unattributed'),
      reason: asNonEmptyString(d.reason),
      observation: asString(d.observation, ''),
      linkedTaskCount: asSafeInt(d.linked_task_count) ?? 0,
      candidateTaskCount: asSafeInt(d.candidate_task_count),
      candidateKeeperCount: asSafeInt(d.candidate_keeper_count),
      atUnix: asFiniteNumber(d.at_unix) ?? 0,
      diagnosticHint: asString(d.diagnostic_hint, ''),
    })
  }

  const eventsRaw = Array.isArray(raw.recent_events) ? raw.recent_events : []
  const recentEvents: CandleEventRow[] = []
  for (const ev of eventsRaw) {
    if (!isRecord(ev)) continue
    const seq = asSafeInt(ev.seq)
    const atUnix = asFiniteNumber(ev.at_unix)
    const kind = asNonEmptyString(ev.kind)
    if (seq === null || atUnix === null || !kind) continue
    recentEvents.push({
      seq,
      atUnix,
      atRfc3339: asString(ev.at_rfc3339, ''),
      kind,
      raw: ev,
    })
  }

  return ok({
    ledgerState,
    totalEvents: asSafeInt(raw.total_events) ?? 0,
    balanceError: asNonEmptyString(raw.balance_error),
    policy: {
      configuration: asString(policyObj.configuration, 'off'),
      disabledReason: asNonEmptyString(policyObj.disabled_reason),
      pricingMode: asString(policyObj.pricing_mode, 'off'),
      halfLifeMode,
      halfLifeHours,
      halfLifeSec,
    },
    supply: {
      issuedMilli: parseCandleMilli(supplyObj.issued_milli),
      burnedMilli: parseCandleMilli(supplyObj.burned_milli),
      circulatingMilli: parseCandleMilli(supplyObj.circulating_milli),
      totalSupplyMilli: parseCandleMilli(supplyObj.total_supply_milli),
      activeKeepers: asSafeInt(supplyObj.active_keepers) ?? balances.length,
    },
    balances,
    diagnostics: {
      unattributedCount: asSafeInt(diagObj.unattributed_count) ?? 0,
      backlogFencedCount: asSafeInt(diagObj.backlog_fenced_count) ?? 0,
      zeroLinkedTasksGoals: asSafeInt(diagObj.zero_linked_tasks_goals) ?? 0,
      heldWindowsCount: asSafeInt(diagObj.held_windows_count) ?? 0,
      items: diagItems,
    },
    recentEvents,
  })
}

export interface CandleTrendSeries {
  readonly timestamps: number[]
  readonly cumulativeIssued: number[]
  readonly decayedSupply: number[]
}

export function buildCandleTrendSeries(ledger: CandleLedgerData): CandleTrendSeries {
  const ordered = [...ledger.recentEvents].sort((a, b) => a.atUnix - b.atUnix || a.seq - b.seq)
  if (ordered.length === 0) {
    return { timestamps: [], cumulativeIssued: [], decayedSupply: [] }
  }
  const halfLifeSec = ledger.policy.halfLifeMode === 'decay' ? ledger.policy.halfLifeSec : null
  const timestamps: number[] = []
  const cumulativeIssued: number[] = []
  const decayedSupply: number[] = []

  let cumIssuedMilli = 0
  let decayedMilli = 0
  let prevUnix = ordered[0]!.atUnix

  for (const ev of ordered) {
    const dt = Math.max(0, ev.atUnix - prevUnix)
    if (halfLifeSec && halfLifeSec > 0 && dt > 0) {
      decayedMilli *= Math.pow(0.5, dt / halfLifeSec)
    }
    prevUnix = ev.atUnix

    const kind = ev.kind.toLowerCase()
    const totalMilli =
      parseCandleMilli(ev.raw.total_milli)
      ?? parseCandleMilli(ev.raw.amount_milli)
      ?? (Array.isArray(ev.raw.allocations)
        ? ev.raw.allocations.reduce<number>((sum, item) => {
            if (!isRecord(item)) return sum
            return sum + (parseCandleMilli(item.amount_milli) ?? 0)
          }, 0)
        : 0)

    if (kind === 'paid' || kind === 'candle_paid' || kind === 'granted' || kind === 'candle_granted') {
      cumIssuedMilli += totalMilli
      decayedMilli += totalMilli
    } else if (kind === 'purchased' || kind === 'candle_purchased' || kind === 'burned') {
      decayedMilli = Math.max(0, decayedMilli - totalMilli)
    }

    const lastIdx = timestamps.length - 1
    if (lastIdx >= 0 && timestamps[lastIdx] === ev.atUnix) {
      cumulativeIssued[lastIdx] = Number((cumIssuedMilli / 1000).toFixed(3))
      decayedSupply[lastIdx] = Number((decayedMilli / 1000).toFixed(3))
    } else {
      timestamps.push(ev.atUnix)
      cumulativeIssued.push(Number((cumIssuedMilli / 1000).toFixed(3)))
      decayedSupply.push(Number((decayedMilli / 1000).toFixed(3)))
    }
  }

  return { timestamps, cumulativeIssued, decayedSupply }
}
