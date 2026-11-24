/**
 * `2 Work > Goals` Tab (`goals-tab.ts`)
 *
 * - `MasterDetail` (42%/58%) + `VirtualList` for bounded DOM (<1,200 nodes).
 * - Strict closed-sum `goal_phase` badges (rejecting legacy `status` field).
 * - Strict `decodeGoalConfirmation()` reading `verification.completion.verdict` + `/health?full=1` `runtime_instance_id`.
 * - Capability-gated in `multi_account_signed_in` mode (skips unbridged `/api/v1/verification/requests`).
 * - Per-effect `AbortController` guards detail confirmation fetches against selection races.
 * - Verification verdicts strictly scoped to the selected Goal's linked tasks (zero unrelated fallback).
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { activeWorkspaceId, currentSessionEpoch } from '../../core/auth'
import { markViewSynced, subscribeObserverFrames } from '../../core/observer'
import { formatObserved, resourceCache } from '../../core/resource-cache'
import { apiGet, apiMutate } from '../../core/transport'
import { ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, TargetLockedAction, VirtualList } from '../../components/primitives'
import {
  GOAL_PHASES,
  asNonEmptyString,
  asString,
  asStringArray,
  availableGoalActions,
  callMcpToolViaCore,
  decodeGoalConfirmation,
  decodeGoalItem,
  formatRelativeTime,
  goalPhaseLabel,
  goalPhaseTone,
  isMultiAccountSession,
  isRecord,
  readWorkspacePrecondition,
  toExpectedWorkspaceBody,
  validateNewGoalInput,
  type GoalAction,
  type GoalConfirmationEvidence,
  type GoalItem,
  type GoalPhase,
  type VerificationRequestItem,
  type WorkspaceViewProps,
} from './types'

interface GoalsLoadBundle {
  readonly goals: readonly GoalItem[]
  readonly rejectedCount: number
  readonly verifications: readonly VerificationRequestItem[]
  readonly verificationsSupported: boolean
}

function flattenGoalTree(nodes: unknown[], out: GoalItem[], rejected: { count: number }): void {
  for (const node of nodes) {
    const decoded = decodeGoalItem(node)
    if (decoded.ok) {
      out.push(decoded.value)
    } else {
      rejected.count += 1
    }
    if (isRecord(node) && Array.isArray(node.children)) {
      flattenGoalTree(node.children, out, rejected)
    }
  }
}

function decodeVerificationList(raw: unknown): VerificationRequestItem[] {
  if (!isRecord(raw) || !Array.isArray(raw.requests)) return []
  const items: VerificationRequestItem[] = []
  for (const r of raw.requests) {
    if (!isRecord(r)) continue
    const requestId = asNonEmptyString(r.request_id)
    const taskId = asNonEmptyString(r.task_id)
    if (!requestId || !taskId) continue
    const obs = isRecord(r.review_observation) ? r.review_observation : null
    items.push({
      requestId,
      taskId,
      taskTitle: asString(r.task_title, taskId),
      submittedBy: asString(r.submitted_by, 'unknown'),
      createdAt: typeof r.created_at === 'string' || typeof r.created_at === 'number' ? r.created_at : null,
      completionContract: asStringArray(r.completion_contract),
      submittedEvidence: asStringArray(r.submitted_evidence),
      reviewState: obs ? asNonEmptyString(obs.state) : null,
      reviewDetail: obs ? asNonEmptyString(obs.detail) : null,
    })
  }
  return items
}

function actionLabel(action: GoalAction): string {
  switch (action) {
    case 'request_complete': return '완료 검증 요청'
    case 'pause': return '일시정지'
    case 'resume': return '재개'
    case 'block': return '차단'
    case 'unblock': return '차단 해제'
    case 'drop': return '중단(Drop)'
    case 'reopen': return '다시 열기'
  }
}

export function GoalsTab(props: WorkspaceViewProps) {
  const [bundle, setBundle] = useState<GoalsLoadBundle>({
    goals: [],
    rejectedCount: 0,
    verifications: [],
    verificationsSupported: true,
  })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [phaseFilter, setPhaseFilter] = useState<GoalPhase | 'ALL'>('ALL')
  const [query, setQuery] = useState('')
  const [selectedGoalId, setSelectedGoalId] = useState<string | null>(props.entityId ?? null)

  // Create Goal form state
  const [showCreate, setShowCreate] = useState(false)
  const [title, setTitle] = useState('')
  const [measureKind, setMeasureKind] = useState<'done_when' | 'count' | 'quantity'>('done_when')
  const [condition, setCondition] = useState('')
  const [noun, setNoun] = useState('')
  const [total, setTotal] = useState('1')
  const [unit, setUnit] = useState('')
  const [direction, setDirection] = useState<'at_least' | 'at_most'>('at_least')
  const [target, setTarget] = useState('1')
  const [procedure, setProcedure] = useState('')
  const [priority, setPriority] = useState(2)
  const [createError, setCreateError] = useState<string | null>(null)
  const [createSuccess, setCreateSuccess] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  // Transition & Confirmation state
  const [transitionNote, setTransitionNote] = useState('')
  const [actionBusy, setActionBusy] = useState<string | null>(null)
  const [actionFeedback, setActionFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)

  const [confirmation, setConfirmation] = useState<GoalConfirmationEvidence | null>(null)
  const [confirmationError, setConfirmationError] = useState<string | null>(null)
  const [confirmationLoading, setConfirmationLoading] = useState(false)
  const [confirmationLockedEpoch, setConfirmationLockedEpoch] = useState<number>(currentSessionEpoch())
  const [liveConfirmRev, setLiveConfirmRev] = useState<string | null>(null)
  const confirmAbortRef = useRef<AbortController | null>(null)

  // Verification verdict state
  const [verdictReasonByReq, setVerdictReasonByReq] = useState<Record<string, string>>({})

  const loadData = useCallback(async (reason: 'mount' | 'manual' | 'sse' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const multiAccount = isMultiAccountSession()
    const obs = await resourceCache.fetch<GoalsLoadBundle>(
      `work:goals:bundle:${multiAccount ? 'ma' : 'su'}`,
      async (signal) => {
        const goalsPromise = apiGet<unknown>('/api/v1/dashboard/goals', { signal })
        const verifPromise = multiAccount
          ? Promise.resolve(null)
          : apiGet<unknown>('/api/v1/verification/requests?view=awaiting&limit=50&offset=0', { signal })
        const [goalsRes, verifRes] = await Promise.all([goalsPromise, verifPromise])

        let goalsRaw: unknown[] = []
        if (goalsRes.ok && isRecord(goalsRes.value) && Array.isArray(goalsRes.value.tree)) {
          goalsRaw = goalsRes.value.tree
        } else {
          const planRes = await apiGet<unknown>('/api/v1/dashboard/planning', { signal })
          if (!planRes.ok) {
            return goalsRes.ok ? planRes : goalsRes
          }
          if (isRecord(planRes.value) && Array.isArray(planRes.value.goals)) {
            goalsRaw = planRes.value.goals
          }
        }
        const goals: GoalItem[] = []
        const rejected = { count: 0 }
        flattenGoalTree(goalsRaw, goals, rejected)
        const verifications = verifRes && verifRes.ok ? decodeVerificationList(verifRes.value) : []
        return ok({
          goals,
          rejectedCount: rejected.count,
          verifications,
          verificationsSupported: !multiAccount,
        })
      },
      { ttlMs: 10_000, topics: ['goals', 'goal_updated', 'verification', 'planning'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setBundle(obs.data)
      markViewSynced()
      setSelectedGoalId((prev) => {
        if (props.entityId && obs.data.goals.some((g) => g.id === props.entityId)) return props.entityId
        if (prev && obs.data.goals.some((g) => g.id === prev)) return prev
        return obs.data.goals[0]?.id ?? null
      })
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [props.entityId])

  useEffect(() => {
    void loadData('mount')
  }, [loadData])

  // Subscribe to SSE updates to lock active confirmation targets on revision drift
  useEffect(() => {
    return subscribeObserverFrames((frame) => {
      if (!isRecord(frame.data)) return
      const kind = asString(frame.data.type, frame.event).toLowerCase()
      if (kind.includes('goal') || kind.includes('verification')) {
        const goalId = asNonEmptyString(frame.data.goal_id)
        const nextRev = asNonEmptyString(frame.data.criterion_revision) ?? asNonEmptyString(frame.data.revision)
        if (confirmation && (!goalId || goalId === confirmation.goalId)) {
          setLiveConfirmRev(nextRev ?? `${confirmation.criterionRevision}:sse-${Date.now()}`)
        }
      }
    })
  }, [confirmation])

  const filteredGoals = useMemo(() => {
    const q = query.trim().toLowerCase()
    return bundle.goals.filter((g) => {
      if (phaseFilter !== 'ALL' && g.phase !== phaseFilter) return false
      if (q && !g.title.toLowerCase().includes(q) && !g.id.toLowerCase().includes(q) && !g.measureText.toLowerCase().includes(q)) {
        return false
      }
      return true
    })
  }, [bundle.goals, phaseFilter, query])

  const phaseCounts = useMemo(() => {
    const counts: Record<string, number> = { ALL: bundle.goals.length }
    for (const p of GOAL_PHASES) counts[p] = 0
    for (const g of bundle.goals) counts[g.phase] = (counts[g.phase] ?? 0) + 1
    return counts
  }, [bundle.goals])

  const selectedGoal = useMemo(
    () => bundle.goals.find((g) => g.id === selectedGoalId) ?? null,
    [bundle.goals, selectedGoalId],
  )

  const loadConfirmation = useCallback(async (goal: GoalItem, externalSignal?: AbortSignal) => {
    confirmAbortRef.current?.abort()
    const controller = new AbortController()
    confirmAbortRef.current = controller
    const signal = externalSignal ?? controller.signal

    setConfirmationLoading(true)
    setConfirmationError(null)
    setConfirmation(null)

    const wsRes = await readWorkspacePrecondition(signal)
    if (signal.aborted) return
    if (!wsRes.ok) {
      setConfirmationLoading(false)
      setConfirmationError(wsRes.error.message)
      return
    }
    const params = new URLSearchParams({
      goal_id: goal.id,
      expected_base_path: wsRes.value.base_path,
      expected_masc_root: wsRes.value.masc_root,
    })
    const res = await apiGet<unknown>(`/api/v1/goals/confirmation?${params.toString()}`, { signal })
    if (signal.aborted) return
    setConfirmationLoading(false)
    if (!res.ok) {
      setConfirmationError(res.error.message)
      return
    }
    const decoded = decodeGoalConfirmation(res.value, goal.id, wsRes.value)
    if (!decoded.ok) {
      setConfirmationError(decoded.error)
      return
    }
    setConfirmation(decoded.value)
    setConfirmationLockedEpoch(currentSessionEpoch())
    setLiveConfirmRev(decoded.value.criterionRevision)
  }, [])

  useEffect(() => {
    if (selectedGoal && selectedGoal.phase === 'Awaiting_confirmation') {
      const controller = new AbortController()
      void loadConfirmation(selectedGoal, controller.signal)
      return () => {
        controller.abort()
      }
    }
    confirmAbortRef.current?.abort()
    setConfirmation(null)
    setConfirmationError(null)
    setLiveConfirmRev(null)
    return undefined
  }, [selectedGoal?.id, selectedGoal?.phase, loadConfirmation])

  const handleCreateGoal = async (e: Event) => {
    e.preventDefault()
    setCreateError(null)
    setCreateSuccess(null)
    const validated = validateNewGoalInput({
      title,
      measureKind,
      condition,
      noun,
      total,
      unit,
      direction,
      target,
      procedure,
      priority,
    })
    if (!validated.ok) {
      setCreateError(validated.error)
      return
    }
    setCreating(true)
    const wsRes = await readWorkspacePrecondition()
    if (!wsRes.ok) {
      setCreating(false)
      setCreateError(wsRes.error.message)
      return
    }
    const goalId = `goal-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    const callRes = await callMcpToolViaCore('masc_goal_upsert', {
      id: goalId,
      if_absent: true,
      expected_workspace: toExpectedWorkspaceBody(wsRes.value),
      title: validated.value.title,
      measure: validated.value.measure,
      procedure: validated.value.procedure,
      priority: validated.value.priority,
    })
    setCreating(false)
    if (!callRes.ok) {
      setCreateError(callRes.error.message)
      return
    }
    setCreateSuccess(`목표 "${validated.value.title}" 생성 완료`)
    setTitle('')
    setCondition('')
    setNoun('')
    setProcedure('')
    setShowCreate(false)
    resourceCache.invalidateTopic('goals')
    await loadData('manual')
  }

  const handleTransition = async (goal: GoalItem, action: GoalAction) => {
    setActionBusy(action)
    setActionFeedback(null)
    const wsRes = await readWorkspacePrecondition()
    if (!wsRes.ok) {
      setActionBusy(null)
      setActionFeedback({ kind: 'err', message: wsRes.error.message })
      return
    }
    const body: Record<string, unknown> = {
      goal_id: goal.id,
      action,
      expected_workspace: toExpectedWorkspaceBody(wsRes.value),
    }
    if (transitionNote.trim()) body.note = transitionNote.trim()
    const res = await apiMutate<unknown>('POST', '/api/v1/tools/masc_goal_transition', body)
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `전이 실패 (${action}): ${res.error.message}` })
      return
    }
    setTransitionNote('')
    setActionFeedback({ kind: 'ok', message: `${goal.id} → ${action} 전이 적용됨` })
    resourceCache.invalidateTopic('goals')
    await loadData('manual')
  }

  const handleConfirmCompletion = async () => {
    if (!confirmation) return
    setActionBusy('confirm')
    setActionFeedback(null)
    const res = await apiMutate<unknown>('POST', '/api/v1/goals/confirmation', {
      goal_id: confirmation.goalId,
      criterion_revision: confirmation.criterionRevision,
      request_id: confirmation.requestId,
      verification_run_id: confirmation.verificationRunId,
      expected_workspace: confirmation.workspace,
      expected_operator_id: confirmation.inspectionOperatorId,
      expected_runtime_instance_id: confirmation.runtimeInstanceId,
    })
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `완료 확정 실패: ${res.error.message}` })
      return
    }
    setActionFeedback({ kind: 'ok', message: `목표 ${confirmation.goalId} 최종 완료 확정됨` })
    resourceCache.invalidateTopic('goals')
    await loadData('manual')
  }

  const handleVerificationVerdict = async (
    req: VerificationRequestItem,
    verdict: 'approve' | 'reject',
  ) => {
    const reason = (verdictReasonByReq[req.requestId] ?? '').trim()
    if (verdict === 'reject' && !reason) {
      setActionFeedback({ kind: 'err', message: '반려(reject) 시 사유를 반드시 입력해야 합니다.' })
      return
    }
    setActionBusy(`verif:${req.requestId}`)
    setActionFeedback(null)
    const body: Record<string, unknown> = {
      task_id: req.taskId,
      verification_id: req.requestId,
      verdict,
    }
    if (verdict === 'reject') body.reason = reason
    const res = await apiMutate<unknown>('POST', '/api/v1/verification/verdict', body)
    setActionBusy(null)
    if (!res.ok) {
      setActionFeedback({ kind: 'err', message: `검증 판정 실패: ${res.error.message}` })
      return
    }
    setActionFeedback({
      kind: 'ok',
      message: `검증 ${req.requestId} (${req.taskId}) ${verdict === 'approve' ? '승인' : '반려'} 완료`,
    })
    resourceCache.invalidateTopic('verification')
    await loadData('manual')
  }

  // Strictly scope verifications to the selected goal's linked tasks (zero cross-goal fallback!)
  const relatedVerifications = useMemo(() => {
    if (!selectedGoal) return []
    const linkedIds = new Set(selectedGoal.linkedTasks.map((t) => t.id))
    return bundle.verifications.filter((v) => linkedIds.has(v.taskId))
  }, [bundle.verifications, selectedGoal])

  const masterPane = html`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Goals <span class="wk-chip-count">(${filteredGoals.length})</span></h2>
        <div class="wk-actions">
          <button type="button" class="btn-primary" onClick=${() => setShowCreate((v) => !v)}>
            ${showCreate ? '닫기' : '+ 새 목표'}
          </button>
          <button type="button" class="btn-ghost" onClick=${() => void loadData('manual')}>
            새로고침
          </button>
        </div>
      </div>

      <div class="wk-filter-bar">
        <input
          type="search"
          class="wk-input"
          placeholder="목표 제목, ID, 측정 조건 검색…"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          aria-label="목표 검색"
        />
        <div class="wk-chips" role="group" aria-label="목표 단계 필터">
          <button
            type="button"
            class="wk-chip"
            aria-pressed=${phaseFilter === 'ALL'}
            onClick=${() => setPhaseFilter('ALL')}
          >
            All <span class="wk-chip-count">${phaseCounts.ALL ?? 0}</span>
          </button>
          ${GOAL_PHASES.map((phase) => html`
            <button
              key=${phase}
              type="button"
              class="wk-chip"
              aria-pressed=${phaseFilter === phase}
              onClick=${() => setPhaseFilter(phase)}
            >
              ${goalPhaseLabel(phase)}
              <span class="wk-chip-count">${phaseCounts[phase] ?? 0}</span>
            </button>
          `)}
        </div>
        ${bundle.rejectedCount > 0 && html`
          <div class="wk-notice wk-notice--warn" role="status">
            레거시 status 필드 또는 스키마 위반 Goal ${bundle.rejectedCount}건이 엄격 파서에 의해 거부되었습니다.
          </div>
        `}
      </div>

      ${showCreate && html`
        <form class="wk-form wk-inset" onSubmit=${handleCreateGoal}>
          <div class="wk-section-title">새 목표 생성 (measure + procedure 필수)</div>
          <div class="wk-field">
            <label for="goal-title">제목</label>
            <input
              id="goal-title"
              class="wk-input"
              required
              value=${title}
              onInput=${(e: Event) => setTitle((e.target as HTMLInputElement).value)}
              placeholder="예: 대시보드 DOM 1,200 이하 달성"
            />
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="goal-measure-kind">성공 조건 유형 (measure)</label>
              <select
                id="goal-measure-kind"
                class="wk-select"
                value=${measureKind}
                onChange=${(e: Event) => setMeasureKind((e.target as HTMLSelectElement).value as 'done_when' | 'count' | 'quantity')}
              >
                <option value="done_when">완료 조건 (done_when)</option>
                <option value="count">개수 달성 (count)</option>
                <option value="quantity">수량 기준 (quantity)</option>
              </select>
            </div>
            <div class="wk-field">
              <label for="goal-priority">우선순위 (1=최고)</label>
              <input
                id="goal-priority"
                type="number"
                min="1"
                max="5"
                class="wk-input tnum"
                value=${priority}
                onInput=${(e: Event) => setPriority(Number((e.target as HTMLInputElement).value))}
              />
            </div>
          </div>

          ${measureKind === 'done_when' && html`
            <div class="wk-field">
              <label for="goal-measure-cond">완료 조건</label>
              <input
                id="goal-measure-cond"
                class="wk-input"
                value=${condition}
                onInput=${(e: Event) => setCondition((e.target as HTMLInputElement).value)}
                placeholder="참/거짓으로 판정 가능한 한 줄 조건"
              />
            </div>
          `}
          ${measureKind === 'count' && html`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-noun">단위 명사 (noun)</label>
                <input id="goal-measure-noun" class="wk-input" value=${noun} onInput=${(e: Event) => setNoun((e.target as HTMLInputElement).value)} placeholder="예: PR" />
              </div>
              <div class="wk-field">
                <label for="goal-measure-total">목표 개수 (total)</label>
                <input id="goal-measure-total" type="number" min="1" class="wk-input tnum" value=${total} onInput=${(e: Event) => setTotal((e.target as HTMLInputElement).value)} />
              </div>
            </div>
          `}
          ${measureKind === 'quantity' && html`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-dir">방향</label>
                <select id="goal-measure-dir" class="wk-select" value=${direction} onChange=${(e: Event) => setDirection((e.target as HTMLSelectElement).value as 'at_least' | 'at_most')}>
                  <option value="at_least">이상 (≥)</option>
                  <option value="at_most">이하 (≤)</option>
                </select>
              </div>
              <div class="wk-field">
                <label for="goal-measure-target">목표 수치</label>
                <input id="goal-measure-target" type="number" step="any" class="wk-input tnum" value=${target} onInput=${(e: Event) => setTarget((e.target as HTMLInputElement).value)} />
              </div>
              <div class="wk-field">
                <label for="goal-measure-unit">단위 (unit)</label>
                <input id="goal-measure-unit" class="wk-input" value=${unit} onInput=${(e: Event) => setUnit((e.target as HTMLInputElement).value)} placeholder="예: ms, KB" />
              </div>
            </div>
          `}

          <div class="wk-field">
            <label for="goal-procedure">측정 절차 (procedure — 필수)</label>
            <textarea
              id="goal-procedure"
              class="wk-textarea"
              value=${procedure}
              onInput=${(e: Event) => setProcedure((e.target as HTMLTextAreaElement).value)}
              placeholder="Verifier가 실재성·도달 가능성을 검증할 수 있는 구체적 측정 절차"
            />
          </div>
          ${createError && html`<div class="wk-notice wk-notice--err" role="alert">${createError}</div>`}
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${creating}>
              ${creating ? '생성 중…' : '목표 저장'}
            </button>
            <button type="button" class="btn-ghost" onClick=${() => setShowCreate(false)}>취소</button>
          </div>
        </form>
      `}

      ${createSuccess && html`<div class="wk-notice wk-notice--ok wk-inset">${createSuccess}</div>`}
      ${loadError && html`<div class="wk-notice wk-notice--err wk-inset" role="alert">${loadError}</div>`}

      ${loading && bundle.goals.length === 0
        ? html`<div class="wk-detail-pad"><span class="dtable-absent">목표 목록 불러오는 중…</span></div>`
        : html`
            <${VirtualList}
              items=${filteredGoals}
              estimateSize=${76}
              height="100%"
              ariaLabel="목표 목록"
              getItemKey=${(g: GoalItem) => g.id}
              empty=${html`<div class="wk-detail-pad"><span class="dtable-absent">표시할 목표가 없습니다.</span></div>`}
              renderItem=${(g: GoalItem) => html`
                <button
                  type="button"
                  class="wk-row-btn"
                  data-selected=${selectedGoal?.id === g.id ? 'true' : 'false'}
                  onClick=${() => setSelectedGoalId(g.id)}
                >
                  <div class="wk-row-top">
                    <span class="wk-row-title">${g.title}</span>
                    <span class=${`wk-badge wk-badge--${goalPhaseTone(g.phase)}`}>
                      ${goalPhaseLabel(g.phase)}
                      ${g.resumePhase ? ` ↩ ${g.resumePhase}` : ''}
                    </span>
                  </div>
                  <div class="wk-row-meta">
                    <span class="mono">P${g.priority}</span>
                    <span>${g.measureText}</span>
                    <span class="tnum">Tasks: ${formatObserved(g.linkedTaskCount)}</span>
                    ${g.criterionVerdict.kind === 'viable' && html`<span class="wk-badge wk-badge--ok">기준 적합</span>`}
                    ${g.criterionVerdict.kind === 'needs_revision' && html`<span class="wk-badge wk-badge--err">기준 수정 필요</span>`}
                  </div>
                </button>
              `}
            />
          `}
    </div>
  `

  const detailPane = selectedGoal
    ? html`
        <div class="wk-detail-pad">
          <div class="wk-section-head">
            <div class="wk-min-w-0">
              <div class="mono wk-sub-id">${selectedGoal.id}</div>
              <h2 class="wk-heading">${selectedGoal.title}</h2>
            </div>
            <div class="wk-actions">
              <span class=${`wk-badge wk-badge--${goalPhaseTone(selectedGoal.phase)}`}>
                ${goalPhaseLabel(selectedGoal.phase)}
                ${selectedGoal.resumePhase ? ` (보존: ${selectedGoal.resumePhase})` : ''}
              </span>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate(`/work/candle/${encodeURIComponent(selectedGoal.id)}`)}
              >
                Candle 지급 보기 →
              </button>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onInspect({
                  title: `Goal: ${selectedGoal.title}`,
                  subtitle: `${selectedGoal.id} · ${selectedGoal.phase}`,
                  kind: 'goal',
                  data: selectedGoal,
                })}
              >
                원본 검사
              </button>
            </div>
          </div>

          ${actionFeedback && html`
            <div class=${`wk-notice wk-notice--${actionFeedback.kind}`} role="status">
              ${actionFeedback.message}
            </div>
          `}

          <div class="wk-kv-grid">
            <div class="wk-kv">
              <span class="wk-kv-k">성공 조건 (measure)</span>
              <span class="wk-kv-v">${selectedGoal.measureText}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">우선순위 / 마감</span>
              <span class="wk-kv-v tnum">P${selectedGoal.priority} · ${selectedGoal.dueDate ?? '없음'}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">연결 태스크</span>
              <span class="wk-kv-v tnum">${formatObserved(selectedGoal.linkedTaskCount)}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">기준 리비전</span>
              <span class="wk-kv-v mono">${selectedGoal.criterionRevision ?? '없음'}</span>
            </div>
          </div>

          <section class="wk-section" aria-label="측정 절차 및 기준 심사">
            <div class="wk-section-head">
              <h3 class="wk-section-title">측정 절차 (procedure) & Criterion Review</h3>
              ${selectedGoal.criterionVerdict.kind === 'viable' && html`<span class="wk-badge wk-badge--ok">Viable</span>`}
              ${selectedGoal.criterionVerdict.kind === 'needs_revision' && html`<span class="wk-badge wk-badge--err">Needs Revision</span>`}
              ${selectedGoal.criterionVerdict.kind === 'pending' && html`<span class="wk-badge wk-badge--idle">${selectedGoal.criterionVerdict.state}</span>`}
              ${selectedGoal.criterionVerdict.kind === 'unavailable' && html`<span class="wk-badge wk-badge--warn">Unavailable</span>`}
            </div>
            <div class="wk-body-pre">
              ${selectedGoal.procedure || '측정 절차 없음'}
            </div>
            <div class="wk-muted-sm">
              ${selectedGoal.criterionVerdict.kind === 'viable' || selectedGoal.criterionVerdict.kind === 'needs_revision'
                ? selectedGoal.criterionVerdict.reason
                : selectedGoal.criterionVerdict.kind === 'unavailable'
                  ? selectedGoal.criterionVerdict.detail
                  : (selectedGoal.criterionVerdict.detail ?? 'Verifier 기준 심사 대기 중')}
            </div>
            ${selectedGoal.lastReviewNote && html`
              <div class="wk-notice">최근 전환 메모: ${selectedGoal.lastReviewNote}</div>
            `}
          </section>

          <section class="wk-section" aria-label="목표 단계 전환">
            <h3 class="wk-section-title">Phase Transition (POST /api/v1/tools/masc_goal_transition)</h3>
            <input
              type="text"
              class="wk-input"
              placeholder="전환 사유/메모 (선택, Drop 등 취소 사유는 last_review_note에 기록)"
              value=${transitionNote}
              onInput=${(e: Event) => setTransitionNote((e.target as HTMLInputElement).value)}
              aria-label="단계 전환 메모"
            />
            <div class="wk-actions">
              ${availableGoalActions(selectedGoal.phase).map((act) => html`
                <button
                  key=${act}
                  type="button"
                  class=${act === 'drop' || act === 'block' ? 'wk-btn-danger' : act === 'request_complete' ? 'btn-primary' : 'btn-ghost'}
                  disabled=${actionBusy !== null}
                  onClick=${() => void handleTransition(selectedGoal, act)}
                >
                  ${actionBusy === act ? '처리 중…' : actionLabel(act)}
                </button>
              `)}
            </div>
          </section>

          ${selectedGoal.phase === 'Awaiting_confirmation' && html`
            <section class="wk-section" aria-label="목표 최종 완료 확인">
              <div class="wk-section-head">
                <h3 class="wk-section-title">Goal Completion Confirmation</h3>
                <button type="button" class="btn-ghost" onClick=${() => void loadConfirmation(selectedGoal)}>
                  증거 다시 읽기
                </button>
              </div>
              ${confirmationLoading && html`<span class="dtable-absent">Verifier 증명 증거 불러오는 중…</span>`}
              ${confirmationError && html`<div class="wk-notice wk-notice--err" role="alert">${confirmationError}</div>`}
              ${confirmation && html`
                <div class="wk-muted-sm">
                  증명 주체: <strong>${confirmation.actor}</strong> (${confirmation.authorityKind}) · 기록: ${formatRelativeTime(confirmation.recordedAt)}
                </div>
                <pre class="wk-code-preview">${confirmation.evidence}</pre>
                <${TargetLockedAction}
                  target=${{
                    workspaceId: activeWorkspaceId.peek(),
                    keeper: confirmation.actor,
                    requestId: confirmation.requestId,
                    revision: confirmation.criterionRevision,
                  }}
                  currentRevision=${liveConfirmRev ?? confirmation.criterionRevision}
                  lockedEpoch=${confirmationLockedEpoch}
                  onRefresh=${() => void loadConfirmation(selectedGoal)}
                >
                  <button
                    type="button"
                    class="wk-btn-ok"
                    disabled=${actionBusy !== null}
                    onClick=${() => void handleConfirmCompletion()}
                  >
                    ${actionBusy === 'confirm' ? '확정 중…' : '최종 완료 확정 (Confirm Completion)'}
                  </button>
                <//>
              `}
            </section>
          `}

          <section class="wk-section" aria-label="연결된 태스크">
            <div class="wk-section-head">
              <h3 class="wk-section-title">연결된 태스크 (${selectedGoal.linkedTasks.length})</h3>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onNavigate('/work/tasks')}
              >
                전체 태스크 보기 →
              </button>
            </div>
            ${selectedGoal.linkedTasks.length === 0
              ? html`<span class="dtable-absent">연결된 태스크가 없습니다.</span>`
              : html`
                  <div class="wk-stack-1">
                    ${selectedGoal.linkedTasks.map((t) => html`
                      <button
                        key=${t.id}
                        type="button"
                        class="wk-row-btn wk-linked-row"
                        onClick=${() => props.onNavigate(`/work/tasks/${encodeURIComponent(t.id)}`)}
                      >
                        <div class="wk-row-top">
                          <span class="wk-row-title">${t.title}</span>
                          <span class="wk-badge">${t.status}</span>
                        </div>
                        <div class="wk-row-meta">
                          <span class="mono">${t.id}</span>
                          ${t.assignee ? html`<${KeeperBadge} id=${t.assignee} size="sm" />` : html`<span>미배정</span>`}
                        </div>
                      </button>
                    `)}
                  </div>
                `}
          </section>

          <section class="wk-section" aria-label="연결 태스크 검증 판정">
            <h3 class="wk-section-title">Verification Verdicts (${relatedVerifications.length})</h3>
            ${!bundle.verificationsSupported
              ? html`
                  <div class="wk-notice wk-notice--info">
                    멀티 계정 세션에서는 단일 워크스페이스 검증 대기열(/api/v1/verification/requests) 조회가 브리지되지 않아 생략되었습니다.
                  </div>
                `
              : relatedVerifications.length === 0
                ? html`<span class="dtable-absent">이 목표에 연결된 태스크의 대기 중인 검증 제출이 없습니다.</span>`
                : relatedVerifications.map((req) => html`
                    <div key=${req.requestId} class="wk-subcard">
                      <div class="wk-row-top">
                        <strong>${req.taskTitle}</strong>
                        <span class="mono wk-sub-id">${req.requestId}</span>
                      </div>
                      <div class="wk-row-meta">
                        <span>제출: <${KeeperBadge} id=${req.submittedBy} size="sm" /></span>
                        <span>태스크: <span class="mono">${req.taskId}</span></span>
                        ${req.reviewState && html`<span class="wk-badge">${req.reviewState}</span>`}
                      </div>
                      ${req.submittedEvidence.length > 0 && html`
                        <div class="wk-muted-sm">
                          증거: ${req.submittedEvidence.join(' · ')}
                        </div>
                      `}
                      <input
                        type="text"
                        class="wk-input"
                        placeholder="반려 사유 (reject 시 필수)"
                        value=${verdictReasonByReq[req.requestId] ?? ''}
                        onInput=${(e: Event) => setVerdictReasonByReq((prev) => ({
                          ...prev,
                          [req.requestId]: (e.target as HTMLInputElement).value,
                        }))}
                        aria-label=${`검증 ${req.requestId} 반려 사유`}
                      />
                      <div class="wk-actions">
                        <button
                          type="button"
                          class="wk-btn-ok"
                          disabled=${actionBusy !== null}
                          onClick=${() => void handleVerificationVerdict(req, 'approve')}
                        >
                          검증 승인
                        </button>
                        <button
                          type="button"
                          class="wk-btn-danger"
                          disabled=${actionBusy !== null}
                          onClick=${() => void handleVerificationVerdict(req, 'reject')}
                        >
                          검증 반려
                        </button>
                      </div>
                    </div>
                  `)}
          </section>
        </div>
      `
    : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${selectedGoal !== null}
      masterLabel="목표 목록"
      detailLabel="목표 상세"
      emptyDetail=${html`<div class="wk-detail-pad"><span class="dtable-absent">목표를 선택하면 단계 전환, 기준 심사, 검증 판정 및 연결 태스크를 확인할 수 있습니다.</span></div>`}
    />
  `
}
