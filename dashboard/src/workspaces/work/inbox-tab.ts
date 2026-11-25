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
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { activeWorkspaceId, currentSessionEpoch } from '../../core/auth'
import {
  extractObserverTopics,
  markViewSynced,
  subscribeObserverFrames,
  subscribeObserverReconnect,
} from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { ok } from '../../lib/result'
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
  type ToolApprovalWait,
  type WorkspaceViewProps,
} from './types'

interface InboxSnapshot {
  readonly toolApprovals: readonly ToolApprovalWait[]
  readonly keeperAsks: readonly KeeperAskItem[]
  readonly gatePending: readonly GatePendingItem[]
  readonly awaitingGoals: readonly GoalItem[]
  readonly audit24h: readonly GateResolvedAuditRow[]
  readonly singleUserHitlBridged: boolean
  readonly sourceErrors: readonly string[]
}

type InboxFilter = 'all' | 'tool_approval' | 'keeper_ask' | 'channel_gate' | 'goal_confirmation' | 'audit'

type AskAnswerDraft =
  | { readonly kind: 'chose'; readonly choiceIds: readonly string[] }
  | { readonly kind: 'wrote'; readonly text: string }
  | { readonly kind: 'skipped' }

function decodeToolApprovals(raw: unknown): ToolApprovalWait[] {
  if (!isRecord(raw) || !Array.isArray(raw.pending)) return []
  const out: ToolApprovalWait[] = []
  for (const row of raw.pending) {
    if (!isRecord(row)) continue
    const toolCallId = asNonEmptyString(row.tool_call_id)
    const keeper = asNonEmptyString(row.keeper)
    if (!toolCallId || !keeper) continue
    const approvalId = asNonEmptyString(row.approval_id) ?? toolCallId
    const askedAt = asFiniteNumber(row.asked_at) ?? 0
    const revision = asNonEmptyString(row.revision) ?? `t-${askedAt}`
    out.push({
      approvalId,
      toolCallId,
      keeper,
      tool: asString(row.tool, 'tool'),
      argsPreview: typeof row.args === 'string' ? row.args : JSON.stringify(row.args ?? {}, null, 2),
      question: asString(row.question, ''),
      because: asNonEmptyString(row.because),
      askedAt,
      timeoutSec: asFiniteNumber(row.timeout_sec),
      revision,
    })
  }
  return out
}

function decodeKeeperAsks(raw: unknown): KeeperAskItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.asks)) return []
  const out: KeeperAskItem[] = []
  for (const row of raw.asks) {
    if (!isRecord(row)) continue
    const res = isRecord(row.resolution) ? row.resolution : null
    if (res && res.state !== 'open') continue
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
    ?? asNonEmptyString(stateObj.title)
    ?? 'unavailable'
  )
}

function decodeGatePayload(raw: unknown): {
  pending: GatePendingItem[]
  resolved: GateResolvedAuditRow[]
  errors: string[]
} {
  if (!isRecord(raw)) return { pending: [], resolved: [], errors: [] }
  const errors: string[] = []
  const queueErr = readGateUnavailableReason(raw.approval_queue_state)
  if (queueErr) errors.push(`Channel Gate 대기열 조회 불가: ${queueErr}`)
  const resolvedErr = readGateUnavailableReason(raw.recent_resolved_state)
  if (resolvedErr) errors.push(`Channel Gate 감사 이력 조회 불가: ${resolvedErr}`)
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
        phase: asString(row.phase, 'human_required'),
        sequence: asSafeInt(row.sequence) ?? 1,
        taskId: asNonEmptyString(row.task_id),
        goalId: asNonEmptyString(row.goal_id),
        summaryText: sumObj ? asNonEmptyString(sumObj.context_summary) : null,
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
      resolved.push({
        id,
        keeper,
        toolName: asString(row.tool_name, ''),
        decision: asString(row.decision_kind ?? row.decision, ''),
        decisionSource: asString(row.decision_source, 'human_operator'),
        reason: asNonEmptyString(row.decision_reason),
        actor: asNonEmptyString(row.actor),
        resolvedAt: asString(row.resolved_at, ''),
      })
    }
  }
  return { pending, resolved, errors }
}

export function InboxTab(props: WorkspaceViewProps) {
  const [snap, setSnap] = useState<InboxSnapshot>({
    toolApprovals: [],
    keeperAsks: [],
    gatePending: [],
    awaitingGoals: [],
    audit24h: [],
    singleUserHitlBridged: true,
    sourceErrors: [],
  })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [filter, setFilter] = useState<InboxFilter>('all')
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [capturedEpoch, setCapturedEpoch] = useState<number>(currentSessionEpoch())

  const [liveRevisionByKey, setLiveRevisionByKey] = useState<Record<string, string | number>>({})

  const [gateRejectReason, setGateRejectReason] = useState('')
  const [gateRememberRule, setGateRememberRule] = useState(false)
  const [askDrafts, setAskDrafts] = useState<Record<string, Record<string, AskAnswerDraft>>>({})
  const [goalConfEvidence, setGoalConfEvidence] = useState<GoalConfirmationEvidence | null>(null)
  const [goalConfError, setGoalConfError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)
  const goalConfAbortRef = useRef<AbortController | null>(null)
  const lastUpdatedAtRef = useRef<number>(0)
  const hasDriftLockRef = useRef<boolean>(false)
  const entryKeysRef = useRef<ReadonlySet<string>>(new Set())
  hasDriftLockRef.current = Object.keys(liveRevisionByKey).length > 0

  const loadInbox = useCallback(async (reason: 'mount' | 'manual' | 'sse' = 'mount') => {
    if (reason !== 'sse') setLoading(true)
    setLoadError(null)
    const multiAccount = isMultiAccountSession()
    const obs = await resourceCache.fetch<InboxSnapshot>(
      `work:inbox:snapshot:${multiAccount ? 'ma' : 'su'}`,
      async (signal) => {
        if (multiAccount) {
          // Multi-account bridge does not expose single-user tool-approvals/asks/gate; skip cleanly (0x 404).
          const planRes = await apiGet<unknown>('/api/v1/dashboard/planning', { signal })
          if (!planRes.ok) return planRes
          const awaitingGoals: GoalItem[] = []
          if (isRecord(planRes.value) && Array.isArray(planRes.value.goals)) {
            for (const g of planRes.value.goals) {
              const dec = decodeGoalItem(g)
              if (dec.ok && dec.value.phase === 'Awaiting_confirmation') {
                awaitingGoals.push(dec.value)
              }
            }
          }
          return ok({
            toolApprovals: [],
            keeperAsks: [],
            gatePending: [],
            awaitingGoals,
            audit24h: [],
            singleUserHitlBridged: false,
            sourceErrors: [],
          })
        }

        const [approvalsRes, asksRes, gateRes, planRes] = await Promise.all([
          apiGet<unknown>('/api/v1/keepers/tool-approvals', { signal }),
          apiGet<unknown>('/api/v1/keepers/asks?include_resolved=false', { signal }),
          apiGet<unknown>('/api/v1/dashboard/gate', { signal }),
          apiGet<unknown>('/api/v1/dashboard/planning', { signal }),
        ])
        if (!approvalsRes.ok && !asksRes.ok && !gateRes.ok && !planRes.ok) {
          return approvalsRes
        }
        const sourceErrors: string[] = []
        if (!approvalsRes.ok) sourceErrors.push(`도구 승인 조회 실패: ${approvalsRes.error.message}`)
        if (!asksRes.ok) sourceErrors.push(`Keeper 질문 조회 실패: ${asksRes.error.message}`)
        if (!gateRes.ok) sourceErrors.push(`Channel Gate 조회 실패: ${gateRes.error.message}`)
        if (!planRes.ok) sourceErrors.push(`Goal 계획 조회 실패: ${planRes.error.message}`)

        const toolApprovals = approvalsRes.ok ? decodeToolApprovals(approvalsRes.value) : []
        const keeperAsks = asksRes.ok ? decodeKeeperAsks(asksRes.value) : []
        const gateDecoded = gateRes.ok
          ? decodeGatePayload(gateRes.value)
          : { pending: [], resolved: [], errors: [] }
        for (const err of gateDecoded.errors) sourceErrors.push(err)
        const awaitingGoals: GoalItem[] = []
        if (planRes.ok && isRecord(planRes.value) && Array.isArray(planRes.value.goals)) {
          for (const g of planRes.value.goals) {
            const dec = decodeGoalItem(g)
            if (dec.ok && dec.value.phase === 'Awaiting_confirmation') {
              awaitingGoals.push(dec.value)
            }
          }
        }
        return ok({
          toolApprovals,
          keeperAsks,
          gatePending: gateDecoded.pending,
          awaitingGoals,
          audit24h: gateDecoded.resolved,
          singleUserHitlBridged: true,
          sourceErrors,
        })
      },
      {
        ttlMs: 8_000,
        topics: [
          'approval',
          'ask',
          'keeper_ask',
          'gate',
          'goals',
          'goal_projection_changed',
          'pending_confirms_changed',
          'tool_approval',
          'keeper_tool_approval_waits_changed',
          'keeper_asks_changed',
          'keeper_waiting_inventory_changed',
        ],
        reason,
      },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      const isFreshPayload = obs.updatedAt !== lastUpdatedAtRef.current
      lastUpdatedAtRef.current = obs.updatedAt
      setSnap(obs.data)
      // Never auto-unlock TargetLockedAction during SSE drift; require explicit manual refresh or mount.
      if (reason !== 'sse') {
        setCapturedEpoch(currentSessionEpoch())
        setLiveRevisionByKey({})
      } else if (isFreshPayload && !hasDriftLockRef.current) {
        setCapturedEpoch(currentSessionEpoch())
      }
      markViewSynced()
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [])

  useEffect(() => {
    void loadInbox('mount')
  }, [loadInbox])

  useEffect(() => {
    const inboxTopics = new Set([
      'approval',
      'tool_approval',
      'ask',
      'keeper_ask',
      'gate',
      'goal',
      'goals',
      'goal_projection_changed',
      'pending_confirms_changed',
      'keeper_tool_approval_waits_changed',
      'keeper_asks_changed',
      'keeper_waiting_inventory_changed',
      'approval:pending',
      'approval:resolved',
      'approval:summary_updated',
    ])
    let sseTimer: ReturnType<typeof setTimeout> | null = null
    const unsub = subscribeObserverFrames((frame) => {
      const matchedInboxTopic = extractObserverTopics(frame).some((t) => inboxTopics.has(t))
      let recordedDrift = false
      if (isRecord(frame.data)) {
        const specificId =
          asNonEmptyString(frame.data.approval_id)
          ?? asNonEmptyString(frame.data.tool_call_id)
          ?? asNonEmptyString(frame.data.ask_id)
          ?? asNonEmptyString(frame.data.goal_id)
        const targetId = specificId ?? (matchedInboxTopic ? asNonEmptyString(frame.data.id) : null)
        if (targetId) {
          const candidates = [
            `tool:${targetId}`,
            `ask:${targetId}`,
            `gate:${targetId}`,
            `goal:${targetId}`,
          ].filter((k) => entryKeysRef.current.has(k))
          if (candidates.length > 0) {
            recordedDrift = true
            const nextRev =
              asNonEmptyString(frame.data.revision)
              ?? asSafeInt(frame.data.sequence)
              ?? asNonEmptyString(frame.data.criterion_revision)
              ?? `sse-${Date.now()}`
            setLiveRevisionByKey((prev) => {
              const next = { ...prev }
              for (const k of candidates) next[k] = nextRev
              return next
            })
          }
        }
      }
      if (!matchedInboxTopic && !recordedDrift) return
      if (!sseTimer) {
        sseTimer = setTimeout(() => {
          sseTimer = null
          void loadInbox('sse')
        }, 450)
      }
    })
    const unsubReconnect = subscribeObserverReconnect(() => {
      void loadInbox('sse')
    })
    return () => {
      unsub()
      unsubReconnect()
      if (sseTimer) clearTimeout(sseTimer)
    }
  }, [loadInbox])

  const entries = useMemo<readonly InboxEntry[]>(() => {
    const list: InboxEntry[] = []
    for (const item of snap.toolApprovals) {
      list.push({ kind: 'tool_approval', key: `tool:${item.approvalId}`, sortTs: item.askedAt, item })
    }
    for (const item of snap.keeperAsks) {
      list.push({ kind: 'keeper_ask', key: `ask:${item.askId}`, sortTs: item.askedAt, item })
    }
    for (const item of snap.gatePending) {
      list.push({ kind: 'channel_gate', key: `gate:${item.id}`, sortTs: -(item.waitingSec ?? 0), item })
    }
    for (const goal of snap.awaitingGoals) {
      list.push({ kind: 'goal_confirmation', key: `goal:${goal.id}`, sortTs: Date.parse(goal.updatedAt ?? '') || 0, goal })
    }
    return list
  }, [snap])
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
    () => entries.find((e) => e.key === selectedKey) ?? null,
    [entries, selectedKey],
  )

  const loadGoalConf = useCallback(async (goal: GoalItem, externalSignal?: AbortSignal) => {
    goalConfAbortRef.current?.abort()
    const controller = new AbortController()
    goalConfAbortRef.current = controller
    const signal = externalSignal ?? controller.signal

    setGoalConfEvidence(null)
    setGoalConfError(null)
    const wsRes = await readWorkspacePrecondition(signal)
    if (signal.aborted) return
    if (!wsRes.ok) {
      setGoalConfError(wsRes.error.message)
      return
    }
    const params = new URLSearchParams({
      goal_id: goal.id,
      expected_base_path: wsRes.value.base_path,
      expected_masc_root: wsRes.value.masc_root,
    })
    const res = await apiGet<unknown>(`/api/v1/goals/confirmation?${params.toString()}`, { signal })
    if (signal.aborted) return
    if (!res.ok) {
      setGoalConfError(res.error.message)
      return
    }
    const decoded = decodeGoalConfirmation(res.value, goal.id, wsRes.value)
    if (!decoded.ok) {
      setGoalConfError(decoded.error)
      return
    }
    setGoalConfEvidence(decoded.value)
  }, [])

  useEffect(() => {
    setGateRejectReason('')
    setGateRememberRule(false)
  }, [selectedKey])

  useEffect(() => {
    if (selectedEntry?.kind === 'goal_confirmation') {
      const controller = new AbortController()
      void loadGoalConf(selectedEntry.goal, controller.signal)
      return () => {
        controller.abort()
      }
    }
    goalConfAbortRef.current?.abort()
    setGoalConfEvidence(null)
    setGoalConfError(null)
    return undefined
  }, [selectedEntry?.key, loadGoalConf])

  const handleToolApproval = async (item: ToolApprovalWait, decision: 'approve' | 'deny') => {
    setBusy(true)
    setFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/keepers/tool-approval', {
      name: item.keeper,
      tool_call_id: item.toolCallId,
      approval_id: item.approvalId,
      decision,
    })
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `도구 승인 처리 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `${item.keeper} / ${item.tool} → ${decision === 'approve' ? '승인됨' : '거부됨'}` })
    resourceCache.invalidateTopic('approval')
    await loadInbox('manual')
  }

  const handleGateResolve = async (item: GatePendingItem, decision: 'approve' | 'reject') => {
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
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Gate 결정 실패: ${res.error.message}` })
      return
    }
    setGateRejectReason('')
    setGateRememberRule(false)
    setFeedback({ kind: 'ok', message: `Gate ${item.id} (${item.toolName}) → ${decision}` })
    resourceCache.invalidateTopic('gate')
    await loadInbox('manual')
  }

  const handleAnswerAsk = async (ask: KeeperAskItem) => {
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
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `Ask 답변 제출 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `${ask.keeper} 질문(${ask.askId})에 답변을 전달했습니다.` })
    resourceCache.invalidateTopic('ask')
    await loadInbox('manual')
  }

  const handleConfirmGoal = async (ev: GoalConfirmationEvidence) => {
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
    setBusy(false)
    if (!res.ok) {
      setFeedback({ kind: 'err', message: `목표 완료 확정 실패: ${res.error.message}` })
      return
    }
    setFeedback({ kind: 'ok', message: `목표 ${ev.goalId} 완료 확정됨` })
    resourceCache.invalidateTopic('goals')
    await loadInbox('manual')
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
    { id: 'source', header: '출처', accessor: (r) => r.decisionSource },
    { id: 'actor', header: '처리자', accessor: (r) => r.actor },
    { id: 'reason', header: '사유', accessor: (r) => r.reason },
  ], [])

  const wsId = activeWorkspaceId.value

  const chipsBar = html`
    <div class="wk-toolbar">
      <div class="wk-chips" role="group" aria-label="인박스 필터">
        <button type="button" class="wk-chip" aria-pressed=${filter === 'all'} onClick=${() => setFilter('all')}>
          All Open <span class="wk-chip-count">${entries.length}</span>
        </button>
        <button type="button" class="wk-chip" aria-pressed=${filter === 'tool_approval'} onClick=${() => setFilter('tool_approval')}>
          Tool Approvals <span class="wk-chip-count">${snap.toolApprovals.length}</span>
        </button>
        <button type="button" class="wk-chip" aria-pressed=${filter === 'keeper_ask'} onClick=${() => setFilter('keeper_ask')}>
          Keeper Asks <span class="wk-chip-count">${snap.keeperAsks.length}</span>
        </button>
        <button type="button" class="wk-chip" aria-pressed=${filter === 'channel_gate'} onClick=${() => setFilter('channel_gate')}>
          Channel Gate <span class="wk-chip-count">${snap.gatePending.length}</span>
        </button>
        <button type="button" class="wk-chip" aria-pressed=${filter === 'goal_confirmation'} onClick=${() => setFilter('goal_confirmation')}>
          Goal Confirm <span class="wk-chip-count">${snap.awaitingGoals.length}</span>
        </button>
        <button type="button" class="wk-chip" aria-pressed=${filter === 'audit'} onClick=${() => setFilter('audit')}>
          24h Decisions <span class="wk-chip-count">${snap.audit24h.length}</span>
        </button>
      </div>
      <button type="button" class="btn-ghost" onClick=${() => void loadInbox('manual')}>새로고침</button>
    </div>
  `

  const multiAccountNotice = !snap.singleUserHitlBridged
    ? html`
        <div class="wk-notice wk-notice--info" role="note">
          멀티 계정 모드에서는 단일 워크스페이스 HITL 엔드포인트(Tool Approvals / Keeper Asks / Channel Gate)가 브리지되지 않아 404 요청을 생략했습니다. Goal 완료 확인 대기열만 표시됩니다.
        </div>
      `
    : null

  if (filter === 'audit') {
    return html`
      <div class="wk-scroll-body">
        ${chipsBar}
        ${multiAccountNotice}
        ${loadError && html`<div class="wk-notice wk-notice--err" role="alert">${loadError}</div>`}
        ${snap.sourceErrors.length > 0 && html`
          <div class="wk-notice wk-notice--err" role="alert">
            일부 대기열 조회 실패: ${snap.sourceErrors.join(' · ')}
          </div>
        `}
        <${DataTable}
          data=${snap.audit24h}
          columns=${auditColumns}
          getRowId=${(r: GateResolvedAuditRow) => `${r.id}-${r.resolvedAt}`}
          caption="최근 24시간 HITL 결정 감사 로그"
          emptyLabel="최근 24시간 내 처리된 결정 기록이 없습니다."
        />
      </div>
    `
  }

  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Unified HITL Queue <span class="wk-chip-count">(${filteredEntries.length})</span></h2>
      </div>
      ${loadError && html`<div class="wk-notice wk-notice--err wk-inset" role="alert">${loadError}</div>`}
      ${snap.sourceErrors.length > 0 && html`
        <div class="wk-notice wk-notice--err wk-inset" role="alert">
          일부 대기열 조회 실패: ${snap.sourceErrors.join(' · ')}
        </div>
      `}
      ${loading && entries.length === 0
        ? html`<div class="wk-detail-pad"><span class="dtable-absent">승인 대기열 불러오는 중…</span></div>`
        : html`
            <${VirtualList}
              items=${filteredEntries}
              estimateSize=${76}
              height="100%"
              ariaLabel="통합 HITL 대기열"
              getItemKey=${(e: InboxEntry) => e.key}
              empty=${html`
                <div class="wk-detail-pad">
                  <span class="dtable-absent">
                    ${snap.sourceErrors.length > 0
                      ? '일부 소스 조회 실패로 대기열이 비어 있는지 확정할 수 없습니다.'
                      : '처리가 필요한 항목이 없습니다.'}
                  </span>
                </div>
              `}
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
                      ? `${entry.item.toolName} (${entry.item.phase})`
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
          `}
    </div>
  `

  const detailPane = selectedEntry
    ? html`
        <div class="wk-detail-pad">
          ${feedback && html`<div class=${`wk-notice wk-notice--${feedback.kind}`} role="status">${feedback.message}</div>`}

          ${selectedEntry.kind === 'tool_approval' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Tool Approval</span>
                <h2 class="wk-heading">${selectedEntry.item.tool}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.question && html`<div>${selectedEntry.item.question}</div>`}
            ${selectedEntry.item.because && html`<div class="wk-notice">정책 사유: ${selectedEntry.item.because}</div>`}
            <pre class="wk-code-preview">${selectedEntry.item.argsPreview}</pre>
            <${TargetLockedAction}
              target=${{
                workspaceId: wsId,
                keeper: selectedEntry.item.keeper,
                requestId: selectedEntry.item.approvalId,
                revision: selectedEntry.item.revision,
              }}
              currentRevision=${liveRevisionByKey[selectedEntry.key] ?? selectedEntry.item.revision}
              lockedEpoch=${capturedEpoch}
              onRefresh=${() => void loadInbox('manual')}
            >
              <button type="button" class="wk-btn-ok" disabled=${busy} onClick=${() => void handleToolApproval(selectedEntry.item, 'approve')}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${busy} onClick=${() => void handleToolApproval(selectedEntry.item, 'deny')}>
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
                          <button
                            key=${c.choiceId}
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
              lockedEpoch=${capturedEpoch}
              onRefresh=${() => void loadInbox('manual')}
            >
              <button type="button" class="btn-primary" disabled=${busy} onClick=${() => void handleAnswerAsk(selectedEntry.item)}>
                답변 제출 (Submit Answer)
              </button>
            <//>
          `}

          ${selectedEntry.kind === 'channel_gate' && html`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Channel Gate · ${selectedEntry.item.phase}</span>
                <h2 class="wk-heading">${selectedEntry.item.toolName}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.summaryText && html`<${MarkdownContent} class="wk-notice" text=${selectedEntry.item.summaryText} />`}
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
              lockedEpoch=${capturedEpoch}
              onRefresh=${() => void loadInbox('manual')}
            >
              <button type="button" class="wk-btn-ok" disabled=${busy} onClick=${() => void handleGateResolve(selectedEntry.item, 'approve')}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${busy} onClick=${() => void handleGateResolve(selectedEntry.item, 'reject')}>
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
            ${goalConfError && html`<div class="wk-notice wk-notice--err" role="alert">${goalConfError}</div>`}
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
                lockedEpoch=${capturedEpoch}
                onRefresh=${() => void loadGoalConf(selectedEntry.goal)}
              >
                <button type="button" class="wk-btn-ok" disabled=${busy} onClick=${() => void handleConfirmGoal(goalConfEvidence)}>
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
