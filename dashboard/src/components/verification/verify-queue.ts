// VerifyQueue — keeper-v2 verify-queue surface (검증 요청 큐).
//
// Design: prototypes/keeper-v2/verify-queue.jsx + styles/keeper-v2/verify.css.
// Queue: store `tasks` rows in `awaiting_verification`, enriched per task_id
// from GET /api/v1/verification/requests (submitted_by / created_at /
// request_summary / evidence_projection_error). Mutations go through
// POST /api/v1/verification/verdict (승인 · 통과 / 반려).
//
// Gate checklist rows are the task's completion-contract clauses. The backend
// exposes no per-clause probe outcome, so every clause renders the design's
// `unsupported`(미지원) chip and waits for explicit operator confirmation —
// only `evidence_projection_error` (a real failure signal) renders `failed`.
// No live signal exists for the design's 보류 defer, the verifier-reassign
// keeper picker, the verifier policy chips, or verdict undo; those
// sub-components are intentionally not rendered.

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  fetchVerificationRequests,
  type VerificationRequest,
  type VerificationRequestsResponse,
} from '../../api/dashboard-misc'
import {
  submitVerificationVerdict,
  type VerificationVerdictDecision,
} from '../../api/dashboard-verification-verdict'
import { goals, keepers as keeperRoster, tasks } from '../../store'
import type { Task } from '../../types'
import { KeeperBadge } from '../keeper-badge'
import { ErrorState } from '../common/feedback-state'
import { relativeTime } from '../../lib/format-time'
import { navigate } from '../../router'
import { useManagedAsyncResource } from '../../lib/use-managed-async-resource'

const AUTO_REFRESH_MS = 15_000
const REQUESTS_LIMIT = 100

type VqLayout = 'stack' | 'split' | 'triage'
type VqGateOutcome = 'satisfied' | 'missing' | 'failed' | 'unsupported'

const VQ_GATE_LBL: Record<VqGateOutcome, string> = {
  satisfied: '충족',
  missing: '누락',
  failed: '실패',
  unsupported: '미지원',
}

const VQ_REASONS = [
  '게이트 증거 미충족',
  '회귀 테스트 부족',
  '측정치 재현 필요',
  '범위 벗어남 · 분할 필요',
]

const VQ_LAYOUTS: Array<[VqLayout, string]> = [
  ['stack', '검토 스택'],
  ['split', '분할 검토'],
  ['triage', '트리아지'],
]

interface VqGateRow {
  evidence: string
  outcome: VqGateOutcome
}

interface VqQueueItem {
  task: Task
  goalId: string | null
  goalTitle: string | null
  gateRows: VqGateRow[]
  submitActor: string | null
  submitAt: string | null
  submitNote: string | null
  projectionError: string | null
}

interface VqSessionVerdict {
  item: VqQueueItem
  decision: VerificationVerdictDecision
  reason: string | null
}

// ── queue assembly ────────────────────────────────────────────

function contractClauses(task: Task, request: VerificationRequest | undefined): string[] {
  const fromTask = task.contract?.completion_contract ?? []
  if (fromTask.length > 0) return fromTask
  return request?.completion_contract ?? []
}

function buildQueueItem(
  task: Task,
  goalTitle: string | null,
  request: VerificationRequest | undefined,
): VqQueueItem {
  const rows: VqGateRow[] = contractClauses(task, request).map(evidence => ({
    evidence,
    outcome: 'unsupported',
  }))
  const projectionError = request?.evidence_projection_error ?? null
  if (projectionError) {
    rows.unshift({ evidence: `증거 투영 오류 — ${projectionError}`, outcome: 'failed' })
  }
  const submitActor = request?.submitted_by?.trim() || task.assignee || null
  const submitNote = request && request.request_summary.trim() !== ''
    ? request.request_summary
    : null
  return {
    task,
    goalId: task.goal_id ?? null,
    goalTitle,
    gateRows: rows,
    submitActor,
    submitAt: request?.created_at ?? null,
    submitNote,
    projectionError,
  }
}

// ── gate confirmation state (operator session state, per design) ──

type VqChecks = Record<string, Record<number, boolean>>

function vqConfirmed(checks: VqChecks, taskId: string, idx: number, outcome: VqGateOutcome): boolean {
  const c = checks[taskId]
  if (c && idx in c) return c[idx] ?? outcome === 'satisfied'
  return outcome === 'satisfied'
}

function vqGateStats(item: VqQueueItem, checks: VqChecks) {
  const total = item.gateRows.length
  const confirmed = item.gateRows.filter((g, i) => vqConfirmed(checks, item.task.id, i, g.outcome)).length
  return { total, confirmed, allConfirmed: total > 0 && confirmed === total }
}

// ── gate checklist ────────────────────────────────────────────

function VqGate({
  item,
  checks,
  onToggleGate,
}: {
  item: VqQueueItem
  checks: VqChecks
  onToggleGate: (taskId: string, idx: number, next: boolean) => void
}) {
  const st = vqGateStats(item, checks)
  const openN = st.total - st.confirmed
  const taskId = item.task.id
  return html`
    <div class="vq-gate">
      <div class="vq-gate-h">
        완료 계약 · 게이트 증거
        <span class="n ${openN > 0 ? 'open' : 'ok'}">${st.confirmed}/${st.total} 확인</span>
      </div>
      ${item.gateRows.map((g, i) => {
        const conf = vqConfirmed(checks, taskId, i, g.outcome)
        const auto = !(checks[taskId] && i in checks[taskId]) && g.outcome === 'satisfied'
        const title = conf
          ? 'operator 확인됨 — 클릭하여 해제'
          : g.outcome === 'satisfied'
            ? '클릭하여 확인'
            : 'operator 판단으로 강제 확인 (미충족 증거)'
        const toggle = () => onToggleGate(taskId, i, !conf)
        return html`
          <div
            key=${i}
            class="vq-gate-row ${conf ? 'confirmed' : ''} ${auto ? 'auto' : ''}"
            role="checkbox"
            aria-checked=${conf}
            tabIndex=${0}
            title=${title}
            onClick=${toggle}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault()
                toggle()
              }
            }}
          >
            <span class="vq-gate-box">✓</span>
            <span class="vq-gate-ev">${g.evidence}</span>
            <span class="vq-gate-out ${g.outcome}">${VQ_GATE_LBL[g.outcome]}</span>
          </div>
        `
      })}
    </div>
  `
}

// ── action bar (승인 / 반려) ──────────────────────────────────
// Design also has 보류(defer) and 검증자 재배정; neither has a backend
// endpoint, so only the two verdict-backed actions render.

function VqActions({
  item,
  checks,
  pending,
  error,
  compact = false,
  onResolve,
}: {
  item: VqQueueItem
  checks: VqChecks
  pending: boolean
  error: string | null
  compact?: boolean
  onResolve: (item: VqQueueItem, decision: VerificationVerdictDecision, reason: string | null) => void
}) {
  const [rejectOpen, setRejectOpen] = useState(false)
  const [reason, setReason] = useState('')
  const st = vqGateStats(item, checks)
  const doReject = () => {
    onResolve(item, 'reject', reason.trim() || '사유 미기재')
    setRejectOpen(false)
    setReason('')
  }
  return html`
    <div class="vq-actions">
      <button
        class="vq-act approve"
        disabled=${!st.allConfirmed || pending}
        title=${st.allConfirmed
          ? '모든 게이트 확인됨 — 통과 처리 (task → done)'
          : `게이트 ${st.total - st.confirmed}건 미확인 — 통과 불가`}
        onClick=${() => onResolve(item, 'approve', null)}
      >✓ 승인 · 통과</button>
      <button
        class="vq-act reject ${compact ? 'mini' : ''}"
        disabled=${pending}
        onClick=${() => setRejectOpen(v => !v)}
      >✕ 반려</button>
    </div>

    ${error ? html`<div role="alert" class="text-2xs text-[var(--text-bad)]">${error}</div>` : null}

    ${rejectOpen ? html`
      <div class="vq-form">
        <div class="vq-form-h">반려 사유 · keeper 에게 반송됩니다</div>
        <div class="vq-reasons">
          ${VQ_REASONS.map(r => html`
            <button
              key=${r}
              class="vq-reason-chip"
              onClick=${() => setReason(p => (p ? p + ' · ' + r : r))}
            >${r}</button>
          `)}
        </div>
        <textarea
          value=${reason}
          placeholder="무엇이 부족한지, 무엇을 다시 해야 하는지…"
          onInput=${(e: Event) => setReason((e.target as HTMLTextAreaElement).value)}
        ></textarea>
        <div class="vq-form-row">
          <button class="vq-act reject mini" disabled=${pending} onClick=${doReject}>✕ 반려하고 반송</button>
          <button class="vq-act mini" onClick=${() => { setRejectOpen(false); setReason('') }}>취소</button>
        </div>
      </div>
    ` : null}
  `
}

// ── submitter badge ───────────────────────────────────────────

function keeperKnown(id: string | null): boolean {
  return id != null && keeperRoster.value.some(k => k.name === id)
}

function VqSubmitter({ item }: { item: VqQueueItem }) {
  const actor = item.submitActor
  return html`
    ${actor && keeperKnown(actor)
      ? html`
          <button
            class="vq-sub"
            title="${actor} 대화 열기"
            onClick=${() => navigate('monitoring', { section: 'agents', view: 'keepers', keeper: actor })}
          >
            <${KeeperBadge} id=${actor} variant="sigil" size="sm" />
            <span class="mono">${actor}</span>
          </button>
        `
      : html`<span class="vq-submitted mono">${actor || '미배정'}</span>`}
    ${item.submitAt ? html`<span class="vq-submitted">${relativeTime(item.submitAt)} 제출</span>` : null}
  `
}

// ── shared review body ────────────────────────────────────────

function VqReview(props: {
  item: VqQueueItem
  checks: VqChecks
  pending: boolean
  error: string | null
  compact?: boolean
  onToggleGate: (taskId: string, idx: number, next: boolean) => void
  onResolve: (item: VqQueueItem, decision: VerificationVerdictDecision, reason: string | null) => void
}) {
  const { item } = props
  const task = item.task
  const handoff = task.handoff_context
  return html`
    ${task.predecessor_task_id
      ? html`<div class="vq-note rerun">↻ 재실행 제출 · predecessor <b>${task.predecessor_task_id}</b> — 반려 후 재검증</div>`
      : null}
    ${item.submitNote ? html`<div class="vq-note"><b>제출 메모</b> · ${item.submitNote}</div>` : null}
    <${VqGate} item=${item} checks=${props.checks} onToggleGate=${props.onToggleGate} />
    ${handoff && handoff.summary
      ? html`<div class="vq-note"><b>핸드오프</b> · ${handoff.summary}${handoff.next_step ? ` → ${handoff.next_step}` : ''}</div>`
      : null}
    <${VqActions}
      item=${item}
      checks=${props.checks}
      pending=${props.pending}
      error=${props.error}
      compact=${props.compact ?? false}
      onResolve=${props.onResolve}
    />
  `
}

function VqGoalLink({ item }: { item: VqQueueItem }) {
  if (!item.goalId) return null
  const label = item.goalTitle ?? item.goalId
  return html`
    <button
      class="vq-req-goal"
      title="소속 목표로 이동"
      onClick=${() => navigate('workspace', { section: 'planning', goal: item.goalId ?? '' })}
    >↳ ${label}</button>
  `
}

// ── LAYOUT A: stack ───────────────────────────────────────────

function VqStack(props: VqBodyProps) {
  return html`
    <div class="vq-list">
      ${props.queue.map(item => {
        const st = vqGateStats(item, props.checks)
        return html`
          <article key=${item.task.id} class="vq-card ${st.allConfirmed ? 'pinned' : ''}">
            <div class="vq-card-top">
              <div class="grow">
                <div class="vq-req-id mono">${item.task.id}${item.task.priority != null ? ` · P${item.task.priority}` : ''}</div>
                <div class="vq-req-title">${item.task.title}</div>
                <${VqGoalLink} item=${item} />
              </div>
              <div class="vq-card-meta"><${VqSubmitter} item=${item} /></div>
            </div>
            <${VqReview}
              item=${item}
              checks=${props.checks}
              pending=${props.pendingFor(item.task.id)}
              error=${props.errorFor(item.task.id)}
              onToggleGate=${props.onToggleGate}
              onResolve=${props.onResolve}
            />
          </article>
        `
      })}
    </div>
  `
}

// ── LAYOUT B: split (master-detail) ───────────────────────────

function VqSplit(props: VqBodyProps) {
  const { queue } = props
  const [selId, setSel] = useState<string | null>(queue[0]?.task.id ?? null)
  useEffect(() => {
    const first = queue[0]?.task.id
    if (first && !queue.some(i => i.task.id === selId)) {
      setSel(first)
    }
  }, [queue.map(i => i.task.id).join(','), selId])
  const sel = queue.find(i => i.task.id === selId) ?? queue[0] ?? null
  return html`
    <div class="vq-split">
      <div class="vq-splitlist">
        ${queue.map(item => {
          const st = vqGateStats(item, props.checks)
          const actor = item.submitActor
          const pct = st.total ? (st.confirmed / st.total) * 100 : 0
          return html`
            <button
              key=${item.task.id}
              class="vq-splitrow ${sel && item.task.id === sel.task.id ? 'on' : ''}"
              onClick=${() => setSel(item.task.id)}
            >
              <span class="vq-splitrow-t">${item.task.title}</span>
              <span class="vq-splitrow-b">
                ${actor && keeperKnown(actor)
                  ? html`<${KeeperBadge} id=${actor} variant="sigil" size="sm" />`
                  : null}
                <span class="vq-mini-prog"><span style=${{ width: `${pct}%` }}></span></span>
                <span class="mono">${st.confirmed}/${st.total}</span>
              </span>
            </button>
          `
        })}
      </div>
      <div class="vq-detail">
        ${sel ? html`
          <div class="vq-req-head">
            <div style=${{ flex: 1 }}>
              <div class="vq-req-id mono">${sel.task.id}${sel.task.priority != null ? ` · P${sel.task.priority}` : ''}</div>
              <div class="vq-req-title">${sel.task.title}</div>
              <${VqGoalLink} item=${sel} />
            </div>
            <${VqSubmitter} item=${sel} />
          </div>
          <${VqReview}
            item=${sel}
            checks=${props.checks}
            pending=${props.pendingFor(sel.task.id)}
            error=${props.errorFor(sel.task.id)}
            onToggleGate=${props.onToggleGate}
            onResolve=${props.onResolve}
          />
        ` : html`<div class="vq-detail-empty">검토할 요청을 선택하세요</div>`}
      </div>
    </div>
  `
}

// ── LAYOUT C: triage board ────────────────────────────────────

function VqTriage(props: VqBodyProps) {
  const [expandId, setExpand] = useState<string | null>(null)
  return html`
    <div class="vq-grid">
      ${props.queue.map(item => {
        const st = vqGateStats(item, props.checks)
        const actor = item.submitActor
        const open = st.total - st.confirmed
        const expanded = expandId === item.task.id
        const pct = st.total ? (st.confirmed / st.total) * 100 : 0
        return html`
          <article key=${item.task.id} class="vq-tri">
            <div class="vq-tri-top">
              <span class="vq-req-id mono">${item.task.id}</span>
              ${item.task.priority != null
                ? html`<span class="vq-req-prio mono" style=${{ marginLeft: 'auto' }}>P${item.task.priority}</span>`
                : null}
              ${actor && keeperKnown(actor)
                ? html`<${KeeperBadge} id=${actor} variant="sigil" size="sm" />`
                : null}
            </div>
            <div
              class="vq-tri-title"
              onClick=${() => setExpand(id => (id === item.task.id ? null : item.task.id))}
            >${item.task.title}</div>
            <div class="vq-tri-meta"><${VqGoalLink} item=${item} /></div>
            <div class="vq-tri-gate">
              <span class="vq-tri-gate-bar"><span style=${{ width: `${pct}%` }}></span></span>
              <span class="vq-tri-gate-n ${open ? 'open' : ''}">${st.confirmed}/${st.total}</span>
            </div>
            ${!expanded ? html`
              <div class="vq-tri-actions">
                <button
                  class="vq-act approve mini"
                  disabled=${!st.allConfirmed || props.pendingFor(item.task.id)}
                  onClick=${() => props.onResolve(item, 'approve', null)}
                >✓ 통과</button>
                <button class="vq-act reject mini" onClick=${() => setExpand(item.task.id)}>✕ 반려</button>
              </div>
              <button class="vq-tri-more" onClick=${() => setExpand(item.task.id)}>게이트 증거 검토 →</button>
            ` : html`
              <${VqGate} item=${item} checks=${props.checks} onToggleGate=${props.onToggleGate} />
              <${VqActions}
                item=${item}
                checks=${props.checks}
                pending=${props.pendingFor(item.task.id)}
                error=${props.errorFor(item.task.id)}
                compact=${true}
                onResolve=${props.onResolve}
              />
              <button class="vq-tri-more" onClick=${() => setExpand(null)}>↑ 접기</button>
            `}
          </article>
        `
      })}
    </div>
  `
}

interface VqBodyProps {
  queue: VqQueueItem[]
  checks: VqChecks
  pendingFor: (taskId: string) => boolean
  errorFor: (taskId: string) => string | null
  onToggleGate: (taskId: string, idx: number, next: boolean) => void
  onResolve: (item: VqQueueItem, decision: VerificationVerdictDecision, reason: string | null) => void
}

// ── verdict banner (resolved-this-session) ────────────────────

const VQ_VERDICT_META: Record<VerificationVerdictDecision, { cls: string; mark: string; lbl: string; tail: string }> = {
  approve: { cls: 'approved', mark: '✓', lbl: '승인 · 통과', tail: 'task → done' },
  reject: { cls: 'rejected', mark: '✕', lbl: '반려', tail: 'keeper 에게 반송 · in_progress' },
}
// verify.css styles a third `deferred` variant; no backend defer endpoint
// exists, so this session list never produces it.

function VqVerdictRow({ verdict }: { verdict: VqSessionVerdict }) {
  const m = VQ_VERDICT_META[verdict.decision]
  return html`
    <div class="vq-verdict ${m.cls}">
      <span class="vq-verdict-mark">${m.mark}</span>
      <span class="vq-verdict-body">
        <b>${verdict.item.task.id}</b> ${verdict.item.task.title} — ${m.lbl} · ${m.tail}${verdict.reason ? ` · “${verdict.reason}”` : ''}
      </span>
    </div>
  `
}

// ── root ──────────────────────────────────────────────────────

export function VerifyQueue() {
  const resource = useManagedAsyncResource<VerificationRequestsResponse>()

  useEffect(() => {
    const load = () => resource.load(signal => fetchVerificationRequests({ limit: REQUESTS_LIMIT, signal }))
    void load()
    const id = setInterval(() => void load(), AUTO_REFRESH_MS)
    return () => {
      clearInterval(id)
      resource.cancel()
    }
  }, [resource])

  const [layout, setLayout] = useState<VqLayout>('stack')
  const [checks, setChecks] = useState<VqChecks>({})
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [errors, setErrors] = useState<Record<string, string | null>>({})
  const [verdicts, setVerdicts] = useState<VqSessionVerdict[]>([])

  const current = resource.state.value
  const requests = current.data?.requests ?? []
  const requestsByTaskId = useMemo(() => {
    const map = new Map<string, VerificationRequest>()
    for (const r of requests) {
      if (!map.has(r.task_id)) map.set(r.task_id, r)
    }
    return map
  }, [requests])

  const goalTitles = useMemo(() => {
    const map = new Map<string, string>()
    for (const g of goals.value) map.set(g.id, g.title)
    return map
  }, [goals.value])

  const resolvedIds = useMemo(() => new Set(verdicts.map(v => v.item.task.id)), [verdicts])

  const queue = useMemo(() => {
    return tasks.value
      .filter(t => t.status === 'awaiting_verification' && !resolvedIds.has(t.id))
      .map(t => buildQueueItem(t, (t.goal_id && goalTitles.get(t.goal_id)) || null, requestsByTaskId.get(t.id)))
      .sort((a, b) => (b.task.priority ?? 0) - (a.task.priority ?? 0) || a.task.id.localeCompare(b.task.id))
  }, [tasks.value, goalTitles, requestsByTaskId, resolvedIds])

  const onToggleGate = (taskId: string, idx: number, next: boolean) => {
    setChecks(prev => ({
      ...prev,
      [taskId]: { ...(prev[taskId] ?? {}), [idx]: next },
    }))
  }

  const onResolve = (item: VqQueueItem, decision: VerificationVerdictDecision, reason: string | null) => {
    const taskId = item.task.id
    if (pending[taskId]) return
    setPending(prev => ({ ...prev, [taskId]: true }))
    setErrors(prev => ({ ...prev, [taskId]: null }))
    void submitVerificationVerdict(
      decision === 'reject'
        ? { taskId, decision, reason: reason ?? '사유 미기재' }
        : { taskId, decision },
    )
      .then(() => {
        setVerdicts(prev => [...prev, { item, decision, reason }])
      })
      .catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err)
        setErrors(prev => ({ ...prev, [taskId]: message }))
      })
      .finally(() => {
        setPending(prev => ({ ...prev, [taskId]: false }))
      })
  }

  const ready = queue.filter(i => vqGateStats(i, checks).allConfirmed).length
  const bad = queue.filter(i => i.projectionError != null).length

  const bodyProps: VqBodyProps = {
    queue,
    checks,
    pendingFor: id => pending[id] === true,
    errorFor: id => errors[id] ?? null,
    onToggleGate,
    onResolve,
  }

  return html`
    <div class="vq vq-lay-${layout}">
      <div class="vq-bar">
        <span class="vq-bar-t">검증 요청 큐</span>
        <span
          class="vq-bar-lane mono"
          title="done 은 검증 레인(probe)을 통과해야 확정됩니다 (state-keyed done)"
        >검증 레인</span>
        <div class="vq-bar-stats">
          <span class="vq-bar-stat volt"><b>${queue.length}</b> 대기</span>
          <span class="vq-bar-stat"><b>${ready}</b> 통과 준비</span>
          ${bad > 0 ? html`<span class="vq-bar-stat bad"><b>${bad}</b> 증거 실패</span>` : null}
        </div>
        <span class="vq-bar-spacer"></span>
        <div class="vq-layseg" role="tablist" aria-label="레이아웃">
          ${VQ_LAYOUTS.map(([v, lbl]) => html`
            <button
              key=${v}
              class=${layout === v ? 'on' : ''}
              onClick=${() => setLayout(v)}
            >${lbl}</button>
          `)}
        </div>
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${verdicts.length > 0 ? html`
        <div class="vq-list">
          ${verdicts.map(v => html`<${VqVerdictRow} key=${v.item.task.id} verdict=${v} />`)}
        </div>
      ` : null}

      ${queue.length === 0 ? html`
        <div class="vq-clear">
          <div class="ico">✓</div>
          <h3>검증 대기 요청이 없습니다</h3>
          <div class="vq-clear-sub">
            keeper 가 task 를 <span class="mono">awaiting_verification</span> 으로 제출하면 여기에 모입니다 — 트리·칸반에서 진행 중 task 의 <b>검증 요청</b> 으로도 올릴 수 있습니다.
          </div>
        </div>
      ` : layout === 'split'
        ? html`<${VqSplit} ...${bodyProps} />`
        : layout === 'triage'
          ? html`<${VqTriage} ...${bodyProps} />`
          : html`<${VqStack} ...${bodyProps} />`}
    </div>
  `
}
