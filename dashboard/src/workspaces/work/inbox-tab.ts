/**
 * `2 Work > Unified Inbox` Tab (`inbox-tab.ts`)
 *
 * - Single authoritative HITL surface combining Tool Approvals, Keeper Asks,
 *   Channel Gate, Goal Confirmations, and 24h Decisions Audit Log (`DataTable`).
 * - Capability-gated in `multi_account_signed_in` mode (zero speculative 404s on single-user-only HITL endpoints).
 * - Strict `decodeGoalConfirmation()` + per-effect `AbortController` race guard.
 * - Full Keeper Ask draft clearing (text clear + deselecting last multi-choice cleanly clears the question draft).
 * - EVERY Approve / Deny / Answer / Confirm mutation strictly wrapped in `TargetLockedAction`.
 */

import { html } from 'htm/preact'
import { InlineSpinner } from '../../components/common/inline-spinner'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { activeWorkspaceId, isEpochCurrent, sessionEpoch } from '../../core/auth'
import {
  extractObserverTopics,
  markViewSynced,
  observerConnected,
  subscribeObserverFrames,
  subscribeObserverReconnect,
  subscribeObserverResync,
} from '../../core/observer'
import { resourceCache, type FetchReason, type Observed } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { decodeToolApprovalsWire, isOpenKeeperAskRow } from '../../api/hitl-decoders'
import { decodeApprovalQueuePhase, normalizeKeeperSummaryAttemptDisposition } from '../../api/board'
import { decodeGateJudgeLane, normalizeGateDecisionSource } from '../../api/dashboard-gate'
import { approvalPhaseView, decisionSourceLabel, judgeLaneText } from '../../lib/gate-approval-labels'
import { formatDuration } from '../../lib/format-time'
import type { ApprovalQueuePhase, GateJudgeLane } from '../../types/gate'
import { KeeperBadge } from '../../components/keeper-badge'
import {
  DataTable,
  MasterDetail,
  TargetLockedAction,
  VirtualList,
  type DataTableColumn,
} from '../../components/primitives'
import {
  asFiniteNumber,
  asNonEmptyString,
  asSafeInt,
  asString,
  decodeGoalConfirmation,
  decodeGoalItem,
  formatRelativeTime,
  isMultiAccountSession,
  isRecord,
  readWorkspacePrecondition,
  type AskChoiceItem,
  type AskQuestionItem,
  type GatePendingItem,
  type GateResolvedAuditRow,
  type GoalConfirmationEvidence,
  type GoalItem,
  type InboxEntry,
  type KeeperAskItem,
  toolApprovalTimeout,
  type ToolApprovalWait,
  type WorkspaceViewProps,
} from './types'

type InboxSource = InboxEntry['kind']
type InboxFilter = 'all' | InboxSource | 'audit'
const singleUserSources: readonly InboxSource[] = ['tool_approval', 'keeper_ask', 'channel_gate', 'goal_confirmation']
const multiAccountSources: readonly InboxSource[] = ['goal_confirmation']
const emptyRows: readonly never[] = []

type AskAnswerDraft =
  | { readonly kind: 'chose'; readonly choiceIds: readonly string[] }
  | { readonly kind: 'wrote'; readonly text: string }
  | { readonly kind: 'skipped' }

type GoalEvidenceRead = {
  readonly epoch: number
  readonly goalId: string
  readonly planning: Observed<readonly GoalItem[]>
} & (
  | { readonly kind: 'loading' }
  | { readonly kind: 'value'; readonly evidence: GoalConfirmationEvidence }
  | { readonly kind: 'failed'; readonly reason: string }
)

export function decodeToolApprovals(raw: unknown): ToolApprovalWait[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) {
    throw new Error('도구 승인 응답에서 대기 목록을 확인할 수 없습니다.')
  }
  const out: ToolApprovalWait[] = []
  for (const row of decodeToolApprovalsWire(raw)) {
    if (!row.toolCallId) continue
    out.push({
      approvalId: row.approvalId,
      toolCallId: row.toolCallId,
      keeper: row.keeper,
      tool: row.tool || 'tool',
      argsPreview: row.args || '{}',
      question: row.question,
      because: row.because || null,
      askedAt: row.askedAt,
      timeoutSec: row.timeoutSec,
      revision: row.revision,
    })
  }
  return out
}

function decodeKeeperAsks(raw: unknown): KeeperAskItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.asks)) {
    throw new Error('Keeper 질문 응답에서 질문 목록을 확인할 수 없습니다.')
  }
  const out: KeeperAskItem[] = []
  for (const row of raw.asks) {
    if (!isRecord(row)) continue
    if (!isOpenKeeperAskRow(row)) continue
    const askId = asNonEmptyString(row.ask_id)
    const keeper = asNonEmptyString(row.keeper)
    if (!askId || !keeper || !Array.isArray(row.questions)) continue
    const questions: AskQuestionItem[] = []
    for (const q of row.questions) {
      if (!isRecord(q)) continue
      const qid = asNonEmptyString(q.question_id)
      const prompt = asNonEmptyString(q.prompt)
      if (!qid || !prompt) continue
      const mode = q.mode === 'multi' ? 'multi' : 'single'
      const ft = isRecord(q.free_text) ? q.free_text : null
      const choices: AskChoiceItem[] = []
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
        header: asString(q.header, qid),
        prompt,
        mode,
        allowFreeText: ft?.allowed === true,
        freeTextHint: ft ? asNonEmptyString(ft.hint) : null,
        choices,
      })
    }
    if (questions.length === 0) continue
    const askedAt = asFiniteNumber(row.asked_at) ?? 0
    out.push({
      askId,
      keeper,
      askedAt,
      context: asNonEmptyString(row.context),
      questions,
      revision: asNonEmptyString(row.revision) ?? `a-${askedAt}`,
    })
  }
  return out
}

function readGateUnavailableReason(stateObj: unknown): string | null {
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

export function decodeGatePayload(raw: unknown): {
  pending: GatePendingItem[]
  resolved: GateResolvedAuditRow[]
  queueError: string | null
  auditError: string | null
  auditPartial: boolean
  /** Null when the payload has no readable `hitl.judge_lane`. */
  judgeLane: GateJudgeLane | null
} {
  if (!isRecord(raw)) throw new Error('Channel Gate 응답 형식이 잘못되었습니다.')
  const queueError = readGateUnavailableReason(raw.approval_queue_state)
    ?? (Array.isArray(raw.approval_queue) ? null : '응답에서 대기 목록을 확인할 수 없습니다.')
  const auditError = readGateUnavailableReason(raw.recent_resolved_state)
    ?? (Array.isArray(raw.recent_resolved) ? null : '응답에서 결정 이력을 확인할 수 없습니다.')
  const pending: GatePendingItem[] = []
  if (Array.isArray(raw.approval_queue)) {
    for (const row of raw.approval_queue) {
      if (!isRecord(row)) continue
      const id = asNonEmptyString(row.id)
      const keeper = asNonEmptyString(row.keeper_name)
      const toolName = asNonEmptyString(row.tool_name)
      if (!id || !keeper || !toolName) continue
      const sumStatus = isRecord(row.summary_status) ? row.summary_status : null
      const sumObj = sumStatus && isRecord(sumStatus.summary) ? sumStatus.summary : null
      pending.push({
        id,
        keeper,
        toolName,
        inputPreview: asNonEmptyString(row.input_preview) ?? (row.input ? JSON.stringify(row.input) : null),
        waitingSec: asFiniteNumber(row.waiting_s),
        phase: decodeApprovalQueuePhase(row.phase),
        disposition: normalizeKeeperSummaryAttemptDisposition(row.summary_attempt_disposition),
        sequence: asSafeInt(row.sequence) ?? 1,
        taskId: asNonEmptyString(row.task_id),
        goalId: asNonEmptyString(row.goal_id),
        summaryText: sumObj ? asNonEmptyString(sumObj.context_summary) : null,
        rationale: sumObj ? asNonEmptyString(sumObj.rationale) : null,
        keyQuestions: Array.isArray(sumObj?.key_questions)
          ? sumObj.key_questions.flatMap((question) => typeof question === 'string' && question.trim() ? [question] : [])
          : [],
      })
    }
  }
  const resolved: GateResolvedAuditRow[] = []
  if (Array.isArray(raw.recent_resolved)) {
    for (const row of raw.recent_resolved) {
      if (!isRecord(row)) continue
      const id = asNonEmptyString(row.id)
      const keeper = asNonEmptyString(row.keeper_name)
      if (!id || !keeper) continue
      const seconds = asFiniteNumber(row.resolved_at)
      const date = seconds === null ? null : new Date(seconds * 1000)
      resolved.push({
        id,
        keeper,
        toolName: asString(row.tool_name, ''),
        decision: asString(row.decision_kind ?? row.decision, ''),
        decisionSource: normalizeGateDecisionSource(row.decision_source),
        reason: asNonEmptyString(row.decision_reason),
        actor: asNonEmptyString(row.actor),
        resolvedAt: date !== null && Number.isFinite(date.getTime())
          ? date.toISOString()
          : asString(row.resolved_at, ''),
      })
    }
  }
  const page = isRecord(raw.recent_resolved_page) ? raw.recent_resolved_page : null
  const auditPartial = page?.truncated === true || page?.scan_exhausted === true
  const lane = isRecord(raw.hitl) ? decodeGateJudgeLane(raw.hitl.judge_lane) : null
  const judgeLane = lane?.ok ? lane.lane : null
  return { pending, resolved, queueError, auditError, auditPartial, judgeLane }
}

function decodeAwaitingGoals(raw: unknown): GoalItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.goals)) {
    const reason = isRecord(raw) && raw.ok === false ? asNonEmptyString(raw.reason) : null
    throw new Error(reason ?? '계획 응답에서 Goal 목록을 확인할 수 없습니다.')
  }
  const goals: GoalItem[] = []
  for (const row of raw.goals) {
    const goal = decodeGoalItem(row)
    if (goal.ok && goal.value.phase === 'Awaiting_confirmation') goals.push(goal.value)
  }
  return goals
}

const inboxReads = {
  tool_approval: {
    key: 'work:inbox:tool-approvals',
    label: '도구 승인',
    path: '/api/v1/keepers/tool-approvals',
    topics: ['approval', 'tool_approval', 'keeper_tool_approval_waits_changed', 'keeper_waiting_inventory_changed'],
    decode: decodeToolApprovals,
  },
  keeper_ask: {
    key: 'work:inbox:keeper-asks',
    label: 'Keeper 질문',
    path: '/api/v1/keepers/asks?include_resolved=false',
    topics: ['ask', 'keeper_ask', 'keeper_asks_changed', 'keeper_waiting_inventory_changed'],
    decode: decodeKeeperAsks,
  },
  channel_gate: {
    key: 'work:inbox:channel-gate',
    label: 'Channel Gate 대기열',
    path: '/api/v1/dashboard/gate',
    topics: ['gate', 'approval:pending', 'approval:resolved', 'approval:summary_updated'],
    decode: decodeGatePayload,
  },
  goal_confirmation: {
    key: 'work:inbox:goal-confirmations',
    label: 'Goal 완료 확인',
    path: '/api/v1/dashboard/planning',
    topics: ['goal', 'goals', 'planning', 'goal_projection_changed', 'pending_confirms_changed'],
    decode: decodeAwaitingGoals,
  },
}

export function gatePhaseLabel(phase: ApprovalQueuePhase | null): string {
  return phase === null ? '● 단계 확인 불가' : approvalPhaseView(phase).label
}

export function gateDispositionText(disposition: GatePendingItem['disposition']): string {
  if (disposition === null) return '확인 불가'
  return 'operator_detail' in disposition ? `${disposition.code} · ${disposition.operator_detail}` : disposition.code
}

export function toolApprovalTimeoutText(wait: Pick<ToolApprovalWait, 'askedAt' | 'timeoutSec'>, nowMs: number): string {
  const timeout = toolApprovalTimeout(wait, nowMs)
  switch (timeout.kind) {
    case 'unknown':
      return '대기 한도 확인 불가'
    case 'pending':
      return `${formatDuration(timeout.remainingSec)} 뒤 시간 초과 (대기 한도 ${formatDuration(timeout.timeoutSec)})`
    case 'expired':
      return `${formatDuration(timeout.overdueSec)} 전에 대기 한도 지남 (대기 한도 ${formatDuration(timeout.timeoutSec)})`
  }
}

const keyPrefixBySource: Readonly<Record<InboxSource, string>> = {
  tool_approval: 'tool', keeper_ask: 'ask', channel_gate: 'gate', goal_confirmation: 'goal',
}

function inboxEventTarget(source: InboxSource, payload: Record<string, unknown>): string | null {
  switch (source) {
    case 'tool_approval':
      return asNonEmptyString(payload.approval_id) ?? asNonEmptyString(payload.tool_call_id)
    case 'keeper_ask':
      return asNonEmptyString(payload.ask_id)
    case 'channel_gate':
      return asNonEmptyString(payload.id)
    case 'goal_confirmation':
      return asNonEmptyString(payload.goal_id) ?? asNonEmptyString(payload.id)
  }
}

function refreshInboxSource(source: InboxSource, reason: FetchReason) {
  const read = inboxReads[source]
  return resourceCache.fetch<unknown>(read.key, (signal) =>
    apiGet<unknown>(read.path, { signal, decode: read.decode }),
  { ttlMs: 8_000, topics: read.topics, reason })
}

function isCurrent(observation: Observed<unknown>, problem?: string | null): boolean {
  return observation.kind === 'value' && !observation.stale && problem == null
}

function renderSourceNotice(label: string, observation: Observed<unknown>, problem?: string | null) {
  if (observation.kind === 'loading') {
    return html`<div class="wk-notice wk-notice--info wk-inset" role="status"><${InlineSpinner} /> ${label} 불러오는 중…</div>`
  }
  const reason = observation.kind === 'failed' ? observation.error.message
    : observation.kind === 'absent' || observation.kind === 'unreported' ? observation.reason : problem
  if (reason || observation.kind !== 'value') {
    return html`<div class="wk-notice wk-notice--err wk-inset" role="alert">${label} 조회 불가${reason ? ` · ${reason}` : ''}</div>`
  }
  return observation.stale
    ? html`<div class="wk-notice wk-notice--warn wk-inset" role="status">${label} · 마지막 조회 결과</div>`
    : null
}

export function InboxTab(props: WorkspaceViewProps) {
  const epoch = sessionEpoch.value
  const multiAccount = isMultiAccountSession()
  const availableSources = multiAccount ? multiAccountSources : singleUserSources
  const approvalsObs = resourceCache.observe<ReturnType<typeof decodeToolApprovals>>(inboxReads.tool_approval.key).value
  const asksObs = resourceCache.observe<ReturnType<typeof decodeKeeperAsks>>(inboxReads.keeper_ask.key).value
  const gateObs = resourceCache.observe<ReturnType<typeof decodeGatePayload>>(inboxReads.channel_gate.key).value
  const goalsObs = resourceCache.observe<ReturnType<typeof decodeAwaitingGoals>>(inboxReads.goal_confirmation.key).value
  const observations = { tool_approval: approvalsObs, keeper_ask: asksObs, channel_gate: gateObs, goal_confirmation: goalsObs }
  const gate = !multiAccount && gateObs.kind === 'value' ? gateObs.data : null
  const approvals = !multiAccount && approvalsObs.kind === 'value' ? approvalsObs.data : emptyRows
  const asks = !multiAccount && asksObs.kind === 'value' ? asksObs.data : emptyRows
  const gates = gate?.pending ?? emptyRows
  const audit = gate?.resolved ?? emptyRows
  const goals = goalsObs.kind === 'value' ? goalsObs.data : emptyRows
  const current: Record<InboxSource | 'audit', boolean> = {
    tool_approval: !multiAccount && isCurrent(approvalsObs),
    keeper_ask: !multiAccount && isCurrent(asksObs),
    channel_gate: !multiAccount && isCurrent(gateObs, gate?.queueError),
    goal_confirmation: isCurrent(goalsObs),
    audit: !multiAccount && isCurrent(gateObs, gate?.auditError),
  }
  const [requestedFilter, setFilter] = useState<InboxFilter>('all')
  const filter = multiAccount && requestedFilter !== 'goal_confirmation' ? 'all' : requestedFilter
  const filterCurrent = filter === 'all' ? availableSources.every((source) => current[source]) : current[filter]
  const [selectedKey, setSelectedKey] = useState<string | null>(null)

  const [liveRevisionByKey, setLiveRevisionByKey] = useState<Record<string, string | number>>({})
  const liveRevisionRef = useRef(liveRevisionByKey)
  liveRevisionRef.current = liveRevisionByKey

  const [gateRejectReason, setGateRejectReason] = useState('')
  const [gateRememberRule, setGateRememberRule] = useState(false)
  const [askDrafts, setAskDrafts] = useState<Record<string, Record<string, AskAnswerDraft>>>({})
  const [goalRead, setGoalRead] = useState<GoalEvidenceRead | null>(null)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)
  const goalConfAbortRef = useRef<AbortController | null>(null)
  const entryKeysRef = useRef<ReadonlySet<string>>(new Set())

  const loadInbox = useCallback(async (reason: FetchReason, sources = availableSources) => {
    if (!isEpochCurrent(epoch)) return
    const revisionsAtStart = liveRevisionRef.current
    await Promise.all(sources.map(async (source) => {
      const result = await refreshInboxSource(source, reason)
      if (reason === 'sse' || source === 'goal_confirmation' || !isEpochCurrent(epoch) || !isCurrent(result)) return
      if (source === 'channel_gate' && result.kind === 'value'
        && isRecord(result.data) && result.data.queueError !== null) return

      // An explicit successful read may unlock just its own rows.
      // Drift observed while that read was in flight still requires review.
      setLiveRevisionByKey((previous) => {
        const next = { ...previous }
        let changed = false
        for (const key of Object.keys(previous)) {
          if (!key.startsWith(`${keyPrefixBySource[source]}:`) || previous[key] !== revisionsAtStart[key]) continue
          delete next[key]
          changed = true
        }
        return changed ? next : previous
      })
    }))
  }, [availableSources, epoch])

  useEffect(() => {
    setLiveRevisionByKey({})
    setBusy(false)
    setFeedback(null)
    setAskDrafts({})
    setSelectedKey(null)
    void loadInbox('mount')
  }, [loadInbox])
  useEffect(() => {
    if (filterCurrent) markViewSynced()
  }, [filter, filterCurrent, approvalsObs, asksObs, gateObs, goalsObs])

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null
    const pending = new Set<InboxSource>()
    const queueRefresh = (sources: readonly InboxSource[]) => {
      for (const source of sources) pending.add(source)
      if (timer !== null || pending.size === 0) return
      timer = setTimeout(() => {
        timer = null
        const sources = [...pending]
        pending.clear()
        void loadInbox('sse', sources)
      }, 450)
    }
    const invalidateSources = () => {
      if (!isEpochCurrent(epoch)) return
      for (const source of availableSources) resourceCache.invalidateKey(inboxReads[source].key)
    }
    const unsub = subscribeObserverFrames((frame) => {
      if (!isEpochCurrent(epoch)) return
      const topics = extractObserverTopics(frame)
      const sources = availableSources.filter((source) => topics.some((topic) => inboxReads[source].topics.includes(topic)))
      const data = isRecord(frame.data) ? frame.data : null
      const payload = isRecord(data?.payload) ? data.payload : data
      if (payload !== null) {
        const revision = asNonEmptyString(payload.revision)
          ?? asSafeInt(payload.sequence)
          ?? asNonEmptyString(payload.criterion_revision)
          ?? `sse-${Date.now()}`
        const drift: Record<string, string | number> = {}
        for (const source of sources) {
          const targetId = inboxEventTarget(source, payload)
          if (targetId === null) continue
          const key = `${keyPrefixBySource[source]}:${targetId}`
          if (entryKeysRef.current.has(key)) drift[key] = revision
        }
        if (Object.keys(drift).length > 0) setLiveRevisionByKey((prev) => ({ ...prev, ...drift }))
      }
      queueRefresh(sources)
    })
    const unsubResync = subscribeObserverResync((reason) => {
      invalidateSources()
      if (reason === 'observer_resync_required') queueRefresh(availableSources)
    })
    const unsubReconnect = subscribeObserverReconnect(() => queueRefresh(availableSources))
    let connectedBefore = observerConnected.peek()
    const unsubConnection = observerConnected.subscribe((connected) => {
      if (connected && !connectedBefore) {
        invalidateSources()
        queueRefresh(availableSources)
      }
      connectedBefore = connected
    })
    return () => {
      unsub()
      unsubResync()
      unsubReconnect()
      unsubConnection()
      if (timer !== null) clearTimeout(timer)
    }
  }, [availableSources, epoch, loadInbox])

  const entries = useMemo<readonly InboxEntry[]>(() => {
    const list: InboxEntry[] = []
    for (const item of approvals) {
      list.push({ kind: 'tool_approval', key: `tool:${item.approvalId}`, sortTs: item.askedAt ?? 0, item })
    }
    for (const item of asks) {
      list.push({ kind: 'keeper_ask', key: `ask:${item.askId}`, sortTs: item.askedAt, item })
    }
    for (const item of gates) {
      list.push({ kind: 'channel_gate', key: `gate:${item.id}`, sortTs: -(item.waitingSec ?? 0), item })
    }
    for (const goal of goals) {
      list.push({ kind: 'goal_confirmation', key: `goal:${goal.id}`, sortTs: Date.parse(goal.updatedAt ?? '') || 0, goal })
    }
    return list
  }, [approvals, asks, gates, goals])
  entryKeysRef.current = new Set(entries.map((e) => e.key))

  const filteredEntries = useMemo(() => {
    if (filter === 'all') return entries
    if (filter === 'audit') return []
    return entries.filter((e) => e.kind === filter)
  }, [entries, filter])

  useEffect(() => {
    if (filter !== 'audit') {
      setSelectedKey((prev) => {
        if (prev && filteredEntries.some((e) => e.key === prev)) return prev
        return filteredEntries[0]?.key ?? null
      })
    }
  }, [filter, filteredEntries])

  const selectedEntry = useMemo(
    () => filteredEntries.find((e) => e.key === selectedKey) ?? null,
    [filteredEntries, selectedKey],
  )
  const selectedGoal = selectedEntry?.kind === 'goal_confirmation' ? selectedEntry.goal : null
  const selectedGoalRead = goalRead?.epoch === epoch && goalRead.goalId === selectedGoal?.id
    && goalRead.planning === goalsObs ? goalRead : null
  const goalConfEvidence = selectedGoalRead?.kind === 'value' ? selectedGoalRead.evidence : null

  const loadGoalConf = useCallback(async (goalId: string, planning: Observed<readonly GoalItem[]>, explicit = false) => {
    if (multiAccount || !isEpochCurrent(epoch) || !isCurrent(planning)) return
    goalConfAbortRef.current?.abort()
    const controller = new AbortController()
    goalConfAbortRef.current = controller
    const signal = controller.signal
    const owner = { epoch, goalId, planning }
    const key = `goal:${goalId}`
    const revisionAtStart = liveRevisionRef.current[key]

    setGoalRead({ ...owner, kind: 'loading' })
    const wsRes = await readWorkspacePrecondition()
    if (signal.aborted || !isEpochCurrent(epoch)) return
    if (!wsRes.ok) {
      setGoalRead({ ...owner, kind: 'failed', reason: wsRes.error.message })
      return
    }
    const params = new URLSearchParams({
      goal_id: goalId,
      expected_base_path: wsRes.value.base_path,
      expected_masc_root: wsRes.value.masc_root,
    })
    const res = await apiGet<unknown>(`/api/v1/goals/confirmation?${params.toString()}`, { signal })
    if (signal.aborted || !isEpochCurrent(epoch)) return
    if (!res.ok) {
      setGoalRead({ ...owner, kind: 'failed', reason: res.error.message })
      return
    }
    const decoded = decodeGoalConfirmation(res.value, goalId, wsRes.value)
    if (!decoded.ok) {
      setGoalRead({ ...owner, kind: 'failed', reason: decoded.error })
      return
    }
    setGoalRead({ ...owner, kind: 'value', evidence: decoded.value })
    if (explicit && resourceCache.peek(inboxReads.goal_confirmation.key) === planning) {
      setLiveRevisionByKey((previous) => {
        if (previous[key] === undefined || previous[key] !== revisionAtStart) return previous
        const next = { ...previous }
        delete next[key]
        return next
      })
    }
  }, [epoch, multiAccount])

  useEffect(() => {
    setGateRejectReason('')
    setGateRememberRule(false)
  }, [selectedKey])

  useEffect(() => {
    if (!selectedGoal?.id || filter === 'audit' || multiAccount || !isCurrent(goalsObs)) return undefined
    void loadGoalConf(selectedGoal.id, goalsObs)
    return () => goalConfAbortRef.current?.abort()
  }, [selectedGoal?.id, goalsObs, filter === 'audit', loadGoalConf, multiAccount])

  const canDecide = (source: InboxSource) => {
    if (busy || !isEpochCurrent(epoch)) return false
    const observation = resourceCache.peek(inboxReads[source].key)
    if (!observation || !isCurrent(observation)) return false
    return source !== 'channel_gate'
      || (observation.kind === 'value' && isRecord(observation.data) && observation.data.queueError === null)
  }

  const handleToolApproval = async (item: ToolApprovalWait, decision: 'approve' | 'deny') => {
    if (!canDecide('tool_approval')) return
    setBusy(true)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/keepers/tool-approval', {
      name: item.keeper,
      tool_call_id: item.toolCallId,
      approval_id: item.approvalId,
      decision,
    })
    if (!isEpochCurrent(epoch)) return
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `도구 승인 처리 실패: ${res.error.message}` })
      return
    }
    const receipt = isRecord(res.value) ? res.value : null
    const label = `${item.keeper} / ${item.tool}`
    if (receipt?.settled === true) {
      setFeedback({ kind: 'ok', message: `${label} → ${decision === 'approve' ? '승인됨' : '거부됨'}` })
    } else if (receipt?.remembered === true) {
      setFeedback({ kind: 'ok', message: `${label} · 같은 호출이 재시도될 때 적용할 결정으로 저장했습니다.` })
    } else {
      setFeedback({ kind: 'err', message: `${label} · 결정 접수를 확인하지 못했습니다.` })
    }
    resourceCache.invalidateTopic('tool_approval')
    await loadInbox('manual', ['tool_approval'])
  }

  const handleGateResolve = async (item: GatePendingItem, decision: 'approve' | 'reject') => {
    if (!canDecide('channel_gate')) return
    if (decision === 'reject' && !gateRejectReason.trim()) {
      setFeedback({ kind: 'err', message: 'Gate 거절(reject) 시 사유를 입력하세요.' })
      return
    }
    setBusy(true)
    setFeedback(null)
    const body: Record<string, unknown> = {
      id: item.id,
      decision,
      remember_rule: decision === 'approve' ? gateRememberRule : false,
    }
    if (decision === 'reject') body.reason = gateRejectReason.trim()
    const res = await apiMutate<unknown>('POST', '/api/v1/dashboard/gate/resolve', body)
    if (!isEpochCurrent(epoch)) return
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Gate 결정 실패: ${res.error.message}` })
      return
    }
    setGateRejectReason('')
    setGateRememberRule(false)
    setFeedback({ kind: 'ok', message: `Gate ${item.id} (${item.toolName}) → ${decision}` })
    resourceCache.invalidateTopic('gate')
    await loadInbox('manual', ['channel_gate'])
  }

  const handleAnswerAsk = async (ask: KeeperAskItem) => {
    if (!canDecide('keeper_ask')) return
    const draft = askDrafts[ask.askId] ?? {}
    const missing = ask.questions.filter((q) => {
      const resp = draft[q.questionId]
      if (!resp) return true
      if (resp.kind === 'wrote') return resp.text.trim() === ''
      if (resp.kind === 'chose') return resp.choiceIds.length === 0
      return false
    })
    if (missing.length > 0) {
      setFeedback({ kind: 'err', message: `미응답 질문이 ${missing.length}개 있습니다.` })
      return
    }
    const answers = ask.questions.map((q) => {
      const resp = draft[q.questionId]!
      if (resp.kind === 'chose') {
        return { question_id: q.questionId, response: { kind: 'chose', choice_ids: resp.choiceIds } }
      }
      if (resp.kind === 'wrote') {
        return { question_id: q.questionId, response: { kind: 'wrote', text: resp.text.trim() } }
      }
      return { question_id: q.questionId, response: { kind: 'skipped' } }
    })
    setBusy(true)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/keepers/ask-answer', {
      name: ask.keeper,
      ask_id: ask.askId,
      answers,
    })
    if (!isEpochCurrent(epoch)) return
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Ask 답변 제출 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `${ask.keeper} 질문(${ask.askId})에 답변을 전달했습니다.` })
    resourceCache.invalidateTopic('ask')
    await loadInbox('manual', ['keeper_ask'])
  }

  const handleConfirmGoal = async (ev: GoalConfirmationEvidence) => {
    if (!canDecide('goal_confirmation') || selectedGoalRead?.kind !== 'value'
      || resourceCache.peek(inboxReads.goal_confirmation.key) !== selectedGoalRead.planning) return
    setBusy(true)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/goals/confirmation', {
      goal_id: ev.goalId,
      criterion_revision: ev.criterionRevision,
      request_id: ev.requestId,
      verification_run_id: ev.verificationRunId,
      expected_workspace: ev.workspace,
      expected_operator_id: ev.inspectionOperatorId,
      expected_runtime_instance_id: ev.runtimeInstanceId,
    })
    if (!isEpochCurrent(epoch)) return
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `목표 완료 확정 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `목표 ${ev.goalId} 완료 확정됨` })
    resourceCache.invalidateTopic('goals')
    await loadInbox('manual', ['goal_confirmation'])
  }

  const setQuestionDraft = (askId: string, questionId: string, next: AskAnswerDraft | null) => {
    setAskDrafts((prev) => {
      const currentAsk = { ...(prev[askId] ?? {}) }
      if (next === null) {
        delete currentAsk[questionId]
      } else {
        currentAsk[questionId] = next
      }
      return { ...prev, [askId]: currentAsk }
    })
  }

  const auditColumns = useMemo<readonly DataTableColumn<GateResolvedAuditRow>[]>(() => [
    { id: 'resolvedAt', header: '시각', accessor: (r) => formatRelativeTime(r.resolvedAt), sortable: true },
    { id: 'keeper', header: 'Keeper', cell: (r) => html`<${KeeperBadge} id=${r.keeper} size="sm" />` },
    { id: 'tool', header: 'Tool', accessor: (r) => r.toolName },
    {
      id: 'decision',
      header: '판정',
      cell: (r) => html`
        <span class=${`wk-badge ${r.decision === 'approve' ? 'wk-badge--ok' : 'wk-badge--err'}`}>
          ${r.decision}
        </span>
      `,
    },
    { id: 'source', header: '출처', accessor: (r) => decisionSourceLabel(r.decisionSource) },
    { id: 'actor', header: '처리자', accessor: (r) => r.actor },
    { id: 'reason', header: '사유', accessor: (r) => r.reason },
  ], [])

  const wsId = activeWorkspaceId.value
  const actionDisabled = busy || (selectedEntry !== null && !current[selectedEntry.kind])
  const refreshVisibleSources = () => {
    if (filter === 'all') return loadInbox('manual')
    return loadInbox('manual', [filter === 'audit' ? 'channel_gate' : filter])
  }
  const chips: readonly { id: InboxFilter; label: string; count: number; ready: boolean }[] = [
    { id: 'all', label: 'All Open', count: entries.length, ready: availableSources.every((source) => current[source]) },
    ...(!multiAccount ? [
      { id: 'tool_approval' as const, label: 'Tool Approvals', count: approvals.length, ready: current.tool_approval },
      { id: 'keeper_ask' as const, label: 'Keeper Asks', count: asks.length, ready: current.keeper_ask },
      { id: 'channel_gate' as const, label: 'Channel Gate', count: gates.length, ready: current.channel_gate },
    ] : []),
    { id: 'goal_confirmation', label: 'Goal Confirm', count: goals.length, ready: current.goal_confirmation },
    ...(!multiAccount ? [{ id: 'audit' as const, label: '24h Decisions', count: audit.length, ready: current.audit && !gate?.auditPartial }] : []),
  ]
  const chipsBar = html`
    <div class="wk-toolbar">
      <div class="wk-chips" role="group" aria-label="인박스 필터">
        ${chips.map((chip) => html`
          <button key=${chip.id} type="button" class="wk-chip" aria-pressed=${filter === chip.id} onClick=${() => setFilter(chip.id)}>
            ${chip.label} <span class="wk-chip-count">${chip.ready ? chip.count : '—'}</span>
          </button>
        `)}
      </div>
      <button type="button" class="btn-ghost" onClick=${() => void refreshVisibleSources()}>새로고침</button>
    </div>
  `

  const multiAccountNotice = multiAccount
    ? html`<div class="wk-notice wk-notice--info" role="note">멀티 계정 모드의 Inbox에는 Goal 완료 확인이 표시됩니다.</div>`
    : null
  const decisionNotice = busy
    ? html`<div class="wk-notice wk-notice--info wk-inset" role="status"><${InlineSpinner} /> 결정 응답을 기다리는 중…</div>`
    : feedback && html`<div class=${`wk-notice wk-notice--${feedback.kind} wk-inset`} role="status">${feedback.message}</div>`

  if (filter === 'audit') {
    return html`
      <div class="wk-scroll-body">
        ${chipsBar}
        ${decisionNotice}
        ${renderSourceNotice('Channel Gate 결정 이력', gateObs, gate?.auditError)}
        ${gate?.auditPartial && html`
          <div class="wk-notice wk-notice--warn wk-inset" role="note">조회 범위 제한으로 최근 24시간의 결정 이력이 일부만 표시됩니다.</div>
        `}
        ${(current.audit || audit.length > 0) && html`
          <${DataTable}
            data=${audit}
            columns=${auditColumns}
            getRowId=${(r: GateResolvedAuditRow) => `${r.id}-${r.resolvedAt}`}
            caption="최근 24시간 HITL 결정 감사 로그"
            emptyLabel=${gate?.auditPartial ? '조회된 범위에 결정 기록이 없습니다.' : '최근 24시간 내 처리된 결정 기록이 없습니다.'}
          />
        `}
      </div>
    `
  }

  const shownSources = filter === 'all' ? availableSources : [filter]
  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Unified HITL Queue
          ${filterCurrent && html`<span class="wk-chip-count">(${filteredEntries.length})</span>`}
        </h2>
      </div>
      ${shownSources.map((source) => renderSourceNotice(inboxReads[source].label,
        observations[source], source === 'channel_gate' ? gate?.queueError : null))}
      <${VirtualList}
        items=${filteredEntries}
        estimateSize=${76}
        height="100%"
        ariaLabel="통합 HITL 대기열"
        getItemKey=${(e: InboxEntry) => e.key}
        empty=${filterCurrent
          ? html`<div class="wk-detail-pad"><span class="dtable-absent">처리가 필요한 항목이 없습니다.</span></div>`
          : null}
        renderItem=${(entry: InboxEntry) => {
          const badgeLabel = entry.kind === 'tool_approval'
            ? 'Tool Approval'
            : entry.kind === 'keeper_ask'
              ? 'Keeper Ask'
              : entry.kind === 'channel_gate'
                ? 'Channel Gate'
                : 'Goal Confirm'
          const title = entry.kind === 'tool_approval'
            ? `${entry.item.tool} — ${entry.item.question || '도구 실행 승인'}`
            : entry.kind === 'keeper_ask'
              ? entry.item.questions[0]?.header ?? entry.item.askId
              : entry.kind === 'channel_gate'
                ? `${entry.item.toolName} · ${gatePhaseLabel(entry.item.phase)}`
                : entry.goal.title
          const keeper = entry.kind === 'tool_approval'
            ? entry.item.keeper
            : entry.kind === 'keeper_ask'
              ? entry.item.keeper
              : entry.kind === 'channel_gate'
                ? entry.item.keeper
                : 'verifier'
          return html`
            <button
              type="button"
              class="wk-row-btn"
              data-selected=${selectedKey === entry.key ? 'true' : 'false'}
              onClick=${() => setSelectedKey(entry.key)}
            >
              <div class="wk-row-top">
                <span class="wk-row-title">${title}</span>
                <span class="wk-badge wk-badge--warn">${badgeLabel}</span>
              </div>
              <div class="wk-row-meta">
                <${KeeperBadge} id=${keeper} size="sm" />
                ${liveRevisionByKey[entry.key] !== undefined && html`<span class="wk-badge wk-badge--err">SSE 변경 감지됨</span>`}
              </div>
            </button>
          `
        }}
      />
    </div>
  `

  const detailPane = selectedEntry
    ? html`
        <div class="wk-detail-pad">
          ${selectedEntry.kind === 'tool_approval' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Tool Approval</span>
                <h2 class="wk-heading">${selectedEntry.item.tool}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.question && html`<${MarkdownContent} class="wk-prose" text=${selectedEntry.item.question} />`}
            ${selectedEntry.item.because && html`
              <div class="wk-notice">
                <strong>정책 사유</strong>
                <${MarkdownContent} text=${selectedEntry.item.because} />
              </div>
            `}
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">응답 기한</span>
                <span class="wk-kv-v tnum">${toolApprovalTimeoutText(selectedEntry.item, Date.now())}</span>
              </div>
            </div>
            <pre class="wk-code-preview">${selectedEntry.item.argsPreview}</pre>
            <${TargetLockedAction}
              target=${{
                workspaceId: wsId,
                keeper: selectedEntry.item.keeper,
                requestId: selectedEntry.item.approvalId,
                revision: selectedEntry.item.revision,
              }}
              currentRevision=${liveRevisionByKey[selectedEntry.key] ?? selectedEntry.item.revision}
              lockedEpoch=${epoch}
              onRefresh=${() => void loadInbox('manual', ['tool_approval'])}
            >
              <button type="button" class="wk-btn-ok" disabled=${actionDisabled} onClick=${() => void handleToolApproval(selectedEntry.item, 'approve')}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${actionDisabled} onClick=${() => void handleToolApproval(selectedEntry.item, 'deny')}>
                거부 (Deny)
              </button>
            <//>
          `}

          ${selectedEntry.kind === 'keeper_ask' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--info">Keeper Ask</span>
                <h2 class="wk-heading">${selectedEntry.item.askId}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.context && html`<${MarkdownContent} class="wk-notice" text=${selectedEntry.item.context} />`}
            ${selectedEntry.item.questions.map((q) => {
              const cur = askDrafts[selectedEntry.item.askId]?.[q.questionId]
              const chosenIds = cur?.kind === 'chose' ? cur.choiceIds : []
              const wroteText = cur?.kind === 'wrote' ? cur.text : ''
              return html`
                <section key=${q.questionId} class="wk-section">
                  <div class="wk-section-head">
                    <strong>${q.header}</strong>
                    <span class="wk-badge">${q.mode === 'multi' ? '복수 선택' : '단일 선택'}</span>
                  </div>
                  <${MarkdownContent} class="wk-prose" text=${q.prompt} />
                  ${q.choices.length > 0 && html`
                    <div class="wk-chips">
                      ${q.choices.map((c) => {
                        const active = chosenIds.includes(c.choiceId)
                        return html`
                          <div key=${c.choiceId}>
                            <button
                              type="button"
                              class="wk-chip"
                              aria-pressed=${active}
                              onClick=${() => {
                                const nextIds = q.mode === 'single'
                                  ? (active ? [] : [c.choiceId])
                                  : active
                                    ? chosenIds.filter((id) => id !== c.choiceId)
                                    : [...chosenIds, c.choiceId]
                                setQuestionDraft(
                                  selectedEntry.item.askId,
                                  q.questionId,
                                  nextIds.length === 0 ? null : { kind: 'chose', choiceIds: nextIds },
                                )
                              }}
                            >
                              ${c.label}
                            </button>
                            ${c.description && html`<${MarkdownContent} class="wk-prose" text=${c.description} />`}
                          </div>
                        `
                      })}
                    </div>
                  `}
                  <div class="wk-field">
                    <label for=${`ask-text-${q.questionId}`}>직접 입력 ${q.freeTextHint ? `(${q.freeTextHint})` : '(선택)'}</label>
                    <input
                      id=${`ask-text-${q.questionId}`}
                      type="text"
                      class="wk-input"
                      value=${wroteText}
                      onInput=${(e: Event) => {
                        const val = (e.target as HTMLInputElement).value
                        setQuestionDraft(
                          selectedEntry.item.askId,
                          q.questionId,
                          val === '' ? null : { kind: 'wrote', text: val },
                        )
                      }}
                    />
                  </div>
                  <div>
                    <button
                      type="button"
                      class="btn-ghost"
                      aria-pressed=${cur?.kind === 'skipped'}
                      onClick=${() => setQuestionDraft(
                        selectedEntry.item.askId,
                        q.questionId,
                        cur?.kind === 'skipped' ? null : { kind: 'skipped' },
                      )}
                    >
                      ${cur?.kind === 'skipped' ? '건너뛰기 선택됨' : '이 질문 건너뛰기'}
                    </button>
                  </div>
                </section>
              `
            })}
            <${TargetLockedAction}
              target=${{
                workspaceId: wsId,
                keeper: selectedEntry.item.keeper,
                requestId: selectedEntry.item.askId,
                revision: selectedEntry.item.revision,
              }}
              currentRevision=${liveRevisionByKey[selectedEntry.key] ?? selectedEntry.item.revision}
              lockedEpoch=${epoch}
              onRefresh=${() => void loadInbox('manual', ['keeper_ask'])}
            >
              <button type="button" class="btn-primary" disabled=${actionDisabled} onClick=${() => void handleAnswerAsk(selectedEntry.item)}>
                답변 제출 (Submit Answer)
              </button>
            <//>
          `}

          ${selectedEntry.kind === 'channel_gate' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Channel Gate · ${gatePhaseLabel(selectedEntry.item.phase)}</span>
                <h2 class="wk-heading">${selectedEntry.item.toolName}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">상태</span>
                <span class="wk-kv-v">${selectedEntry.item.phase === null ? '서버 응답에서 단계를 읽을 수 없음' : approvalPhaseView(selectedEntry.item.phase).detail}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">Auto Judge</span>
                <span class="wk-kv-v mono">${gateDispositionText(selectedEntry.item.disposition)}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">판정 lane</span>
                <span class="wk-kv-v mono">${gate?.judgeLane ? judgeLaneText(gate.judgeLane) : '판정 lane 확인 불가'}</span>
              </div>
            </div>
            ${selectedEntry.item.summaryText && html`<${MarkdownContent} class="wk-notice" text=${selectedEntry.item.summaryText} />`}
            ${selectedEntry.item.keyQuestions.length > 0 && html`
              <ul class="wk-prose">
                ${selectedEntry.item.keyQuestions.map((question, index) => html`
                  <li key=${index}><${MarkdownContent} text=${question} /></li>
                `)}
              </ul>
            `}
            ${selectedEntry.item.rationale && html`<${MarkdownContent} class="wk-prose" text=${selectedEntry.item.rationale} />`}
            ${selectedEntry.item.inputPreview && html`<pre class="wk-code-preview">${selectedEntry.item.inputPreview}</pre>`}
            <div class="wk-field">
              <label for="gate-reject-reason">거절 사유 (Reject 시 필수)</label>
              <input
                id="gate-reject-reason"
                type="text"
                class="wk-input"
                value=${gateRejectReason}
                onInput=${(e: Event) => setGateRejectReason((e.target as HTMLInputElement).value)}
              />
            </div>
            <label class="wk-check-label">
              <input
                type="checkbox"
                checked=${gateRememberRule}
                onChange=${(e: Event) => setGateRememberRule((e.target as HTMLInputElement).checked)}
              />
              동일 요청 규칙 기억하기 (remember_rule)
            </label>
            <${TargetLockedAction}
              target=${{
                workspaceId: wsId,
                keeper: selectedEntry.item.keeper,
                requestId: selectedEntry.item.id,
                revision: selectedEntry.item.sequence,
              }}
              currentRevision=${liveRevisionByKey[selectedEntry.key] ?? selectedEntry.item.sequence}
              lockedEpoch=${epoch}
              onRefresh=${() => void loadInbox('manual', ['channel_gate'])}
            >
              <button type="button" class="wk-btn-ok" disabled=${actionDisabled} onClick=${() => void handleGateResolve(selectedEntry.item, 'approve')}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${actionDisabled} onClick=${() => void handleGateResolve(selectedEntry.item, 'reject')}>
                거절 (Reject)
              </button>
            <//>
          `}

          ${selectedEntry.kind === 'goal_confirmation' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Goal Confirmation</span>
                <h2 class="wk-heading">${selectedEntry.goal.title}</h2>
              </div>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate(`/work/goals/${encodeURIComponent(selectedEntry.goal.id)}`)}
              >
                목표 상세로 이동 →
              </button>
            </div>
            ${multiAccount && html`<div class="wk-notice" role="note">이 연결에서는 Goal 목록과 상세를 열 수 있습니다.</div>`}
            ${selectedGoalRead?.kind === 'loading' && html`
              <div class="wk-notice wk-notice--info" role="status"><${InlineSpinner} /> 확인 근거 불러오는 중…</div>
            `}
            ${selectedGoalRead?.kind === 'failed' && html`
              <div class="wk-notice wk-notice--err" role="alert">${selectedGoalRead.reason}</div>
            `}
            ${goalConfEvidence && html`
              <${MarkdownContent} class="wk-prose" text=${goalConfEvidence.evidence} />
              <${TargetLockedAction}
                target=${{
                  workspaceId: wsId,
                  keeper: goalConfEvidence.actor,
                  requestId: goalConfEvidence.requestId,
                  revision: goalConfEvidence.criterionRevision,
                }}
                currentRevision=${liveRevisionByKey[selectedEntry.key] ?? goalConfEvidence.criterionRevision}
                lockedEpoch=${epoch}
                onRefresh=${() => void loadGoalConf(selectedEntry.goal.id, goalsObs, true)}
              >
                <button type="button" class="wk-btn-ok" disabled=${actionDisabled} onClick=${() => void handleConfirmGoal(goalConfEvidence)}>
                  목표 완료 최종 확정 (Confirm)
                </button>
              <//>
            `}
          `}
        </div>
      `
    : null

  return html`
    <div class="wk-inbox-shell">
      ${chipsBar}
      ${multiAccountNotice}
      ${decisionNotice}
      <div class="wk-pane-grow">
        <${MasterDetail}
          master=${masterPane}
          detail=${detailPane}
          hasSelection=${selectedEntry !== null}
          selectionKey=${selectedKey}
          masterLabel="HITL 대기열"
          detailLabel="HITL 승인 상세"
          emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">승인할 항목을 선택하세요. 모든 결정은 TargetLockedAction으로 보호됩니다.</span></div>`}
        />
      </div>
    </div>
  `
}
