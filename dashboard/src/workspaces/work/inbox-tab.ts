/**
 * `2 Work > Unified Inbox` Tab (`inbox-tab.ts`)
 *
 * - Single authoritative HITL surface combining:
 *   1. Tool Approvals (`GET /api/v1/keepers/tool-approvals`, `POST /api/v1/keepers/tool-approval`)
 *   2. Keeper Asks (`GET /api/v1/keepers/asks`, `POST /api/v1/keepers/ask-answer`)
 *   3. Channel Gate (`GET /api/v1/dashboard/gate`, `POST /api/v1/dashboard/gate/resolve`)
 *   4. Goal Confirmations (`Awaiting_confirmation` goals -> `GET/POST /api/v1/goals/confirmation`)
 *   5. 24h Decisions Audit Log (`recent_resolved` from `/api/v1/dashboard/gate` via `DataTable`)
 * - EVERY Approve / Deny / Answer / Confirm mutation is strictly wrapped in `TargetLockedAction`
 *   displaying `(workspace_id, keeper, request_id, revision)` and auto-locking immediately when
 *   SSE updates the target or `sessionEpoch` changes (`#28` K4)!
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { activeWorkspaceId, currentSessionEpoch } from '../../core/auth'
import { markViewSynced, subscribeObserverFrames } from '../../core/observer'
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
  decodeGoalItem,
  formatRelativeTime,
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

function decodeGatePayload(raw: unknown): {
  pending: GatePendingItem[]
  resolved: GateResolvedAuditRow[]
} {
  if (!isRecord(raw)) return { pending: [], resolved: [] }
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
  return { pending, resolved }
}

export function InboxTab(props: WorkspaceViewProps) {
  const [snap, setSnap] = useState<InboxSnapshot>({
    toolApprovals: [],
    keeperAsks: [],
    gatePending: [],
    awaitingGoals: [],
    audit24h: [],
  })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [filter, setFilter] = useState<InboxFilter>('all')
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [capturedEpoch, setCapturedEpoch] = useState<number>(currentSessionEpoch())

  // Tracks SSE-reported revision drift per inbox item key so TargetLockedAction auto-locks!
  const [liveRevisionByKey, setLiveRevisionByKey] = useState<Record<string, string | number>>({})

  // Action states
  const [gateRejectReason, setGateRejectReason] = useState('')
  const [gateRememberRule, setGateRememberRule] = useState(false)
  const [askDrafts, setAskDrafts] = useState<Record<string, Record<string, AskAnswerDraft>>>({})
  const [goalConfEvidence, setGoalConfEvidence] = useState<GoalConfirmationEvidence | null>(null)
  const [goalConfError, setGoalConfError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [feedback, setFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)

  const loadInbox = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const obs = await resourceCache.fetch<InboxSnapshot>(
      'work:inbox:snapshot',
      async (signal) => {
        const [approvalsRes, asksRes, gateRes, planRes] = await Promise.all([
          apiGet<unknown>('/api/v1/keepers/tool-approvals', { signal }),
          apiGet<unknown>('/api/v1/keepers/asks?include_resolved=false', { signal }),
          apiGet<unknown>('/api/v1/dashboard/gate', { signal }),
          apiGet<unknown>('/api/v1/dashboard/planning', { signal }),
        ])
        const toolApprovals = approvalsRes.ok ? decodeToolApprovals(approvalsRes.value) : []
        const keeperAsks = asksRes.ok ? decodeKeeperAsks(asksRes.value) : []
        const gateDecoded = gateRes.ok ? decodeGatePayload(gateRes.value) : { pending: [], resolved: [] }
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
        })
      },
      { ttlMs: 8_000, topics: ['approval', 'ask', 'gate', 'goals', 'tool_approval'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setSnap(obs.data)
      setCapturedEpoch(currentSessionEpoch())
      setLiveRevisionByKey({})
      markViewSynced()
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [])

  useEffect(() => {
    void loadInbox('mount')
  }, [loadInbox])

  // Auto-lock TargetLockedAction whenever an SSE frame mutates a pending HITL item!
  useEffect(() => {
    return subscribeObserverFrames((frame) => {
      if (!isRecord(frame.data)) return
      const targetId =
        asNonEmptyString(frame.data.approval_id)
        ?? asNonEmptyString(frame.data.tool_call_id)
        ?? asNonEmptyString(frame.data.ask_id)
        ?? asNonEmptyString(frame.data.goal_id)
        ?? asNonEmptyString(frame.data.id)
      if (!targetId) return
      const nextRev =
        asNonEmptyString(frame.data.revision)
        ?? asSafeInt(frame.data.sequence)
        ?? asNonEmptyString(frame.data.criterion_revision)
        ?? `sse-${Date.now()}`
      setLiveRevisionByKey((prev) => ({
        ...prev,
        [`tool:${targetId}`]: nextRev,
        [`ask:${targetId}`]: nextRev,
        [`gate:${targetId}`]: nextRev,
        [`goal:${targetId}`]: nextRev,
      }))
    })
  }, [])

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

  const loadGoalConf = useCallback(async (goal: GoalItem) => {
    setGoalConfEvidence(null)
    setGoalConfError(null)
    const wsRes = await readWorkspacePrecondition()
    if (!wsRes.ok) {
      setGoalConfError(wsRes.error.message)
      return
    }
    const params = new URLSearchParams({
      goal_id: goal.id,
      expected_base_path: wsRes.value.base_path,
      expected_masc_root: wsRes.value.masc_root,
    })
    const res = await apiGet<Record<string, unknown>>(`/api/v1/goals/confirmation?${params.toString()}`)
    if (!res.ok) {
      setGoalConfError(res.error.message)
      return
    }
    const raw = res.value
    const verif = isRecord(raw.verification) ? raw.verification : null
    const comp = verif && isRecord(verif.completion) ? verif.completion : null
    const crit = comp && isRecord(comp.criterion) ? comp.criterion : null
    setGoalConfEvidence({
      goalId: goal.id,
      phase: goal.phase,
      criterionRevision: (crit ? asNonEmptyString(crit.revision) : null) ?? goal.criterionRevision ?? 'rev-1',
      requestId: (comp ? asNonEmptyString(comp.request_id) : null) ?? `confirm-${goal.id}`,
      verificationRunId: (comp ? asNonEmptyString(comp.run_id) : null) ?? 'run-1',
      actor: (comp ? asNonEmptyString(comp.actor) : null) ?? 'verifier',
      evidence: (comp ? asString(comp.evidence, '') : '') || '증거 없음',
      recordedAt: comp ? asString(comp.recorded_at, '') : '',
      inspectionOperatorId: asString(raw.inspection_operator_id, 'operator'),
      runtimeInstanceId: asString(raw.runtime_instance_id, 'runtime'),
      workspace: wsRes.value,
    })
  }, [])

  useEffect(() => {
    if (selectedEntry?.kind === 'goal_confirmation') {
      void loadGoalConf(selectedEntry.goal)
    }
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
    const missing = ask.questions.filter((q) => draft[q.questionId] === undefined)
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
        return { question_id: q.questionId, response: { kind: 'wrote', text: resp.text } }
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

  const setQuestionDraft = (askId: string, questionId: string, next: AskAnswerDraft) => {
    setAskDrafts((prev) => ({
      ...prev,
      [askId]: { ...(prev[askId] ?? {}), [questionId]: next },
    }))
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

  if (filter === 'audit') {
    return html`
      <div class="wk-scroll-body">
        ${chipsBar}
        ${loadError && html`<div class="wk-notice wk-notice--err" role="alert">${loadError}</div>`}
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
    <div style=${{ display: 'flex', flexDirection: 'column', height: '100%', minWidth: 0 }}>
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Unified HITL Queue <span class="wk-chip-count">(${filteredEntries.length})</span></h2>
      </div>
      ${loadError && html`<div class="wk-notice wk-notice--err" style=${{ margin: 'var(--sp-2)' }} role="alert">${loadError}</div>`}
      ${loading && entries.length === 0
        ? html`<div class="wk-detail-pad"><span class="dtable-absent">승인 대기열 불러오는 중…</span></div>`
        : html`
            <${VirtualList}
              items=${filteredEntries}
              estimateSize=${76}
              height="100%"
              ariaLabel="통합 HITL 대기열"
              getItemKey=${(e: InboxEntry) => e.key}
              empty=${html`<div class="wk-detail-pad"><span class="dtable-absent">처리가 필요한 항목이 없습니다.</span></div>`}
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
              <div>
                <span class="wk-badge wk-badge--warn">Tool Approval</span>
                <h2 style=${{ margin: '4px 0 0', fontSize: 'var(--fs-16)' }}>${selectedEntry.item.tool}</h2>
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
              <div>
                <span class="wk-badge wk-badge--info">Keeper Ask</span>
                <h2 style=${{ margin: '4px 0 0', fontSize: 'var(--fs-16)' }}>${selectedEntry.item.askId}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.context && html`<div class="wk-notice">${selectedEntry.item.context}</div>`}
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
                  <div style=${{ fontSize: 'var(--fs-13)' }}>${q.prompt}</div>
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
                                ? [c.choiceId]
                                : active
                                  ? chosenIds.filter((id) => id !== c.choiceId)
                                  : [...chosenIds, c.choiceId]
                              if (nextIds.length > 0) {
                                setQuestionDraft(selectedEntry.item.askId, q.questionId, { kind: 'chose', choiceIds: nextIds })
                              }
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
                        if (val.trim()) {
                          setQuestionDraft(selectedEntry.item.askId, q.questionId, { kind: 'wrote', text: val })
                        }
                      }}
                    />
                  </div>
                  <div>
                    <button
                      type="button"
                      class="btn-ghost"
                      aria-pressed=${cur?.kind === 'skipped'}
                      onClick=${() => setQuestionDraft(selectedEntry.item.askId, q.questionId, { kind: 'skipped' })}
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
              <div>
                <span class="wk-badge wk-badge--warn">Channel Gate · ${selectedEntry.item.phase}</span>
                <h2 style=${{ margin: '4px 0 0', fontSize: 'var(--fs-16)' }}>${selectedEntry.item.toolName}</h2>
              </div>
              <${KeeperBadge} id=${selectedEntry.item.keeper} portrait=${true} />
            </div>
            ${selectedEntry.item.summaryText && html`<div class="wk-notice">${selectedEntry.item.summaryText}</div>`}
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
            <label style=${{ display: 'inline-flex', alignItems: 'center', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
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
              <div>
                <span class="wk-badge wk-badge--warn">Goal Confirmation</span>
                <h2 style=${{ margin: '4px 0 0', fontSize: 'var(--fs-16)' }}>${selectedEntry.goal.title}</h2>
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
              <pre class="wk-code-preview">${goalConfEvidence.evidence}</pre>
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
    <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', height: '100%', minWidth: 0 }}>
      ${chipsBar}
      <div style=${{ flex: '1 1 auto', minHeight: 0, minWidth: 0 }}>
        <${MasterDetail}
          master=${masterPane}
          detail=${detailPane}
          hasSelection=${selectedEntry !== null}
          masterLabel="HITL 대기열"
          detailLabel="HITL 승인 상세"
          emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">승인할 항목을 선택하세요. 모든 결정은 TargetLockedAction으로 보호됩니다.</span></div>`}
        />
      </div>
    </div>
  `
}
