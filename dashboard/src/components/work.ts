// MASC Dashboard — Work Tab (keeper-v2 goal/task layout)
// Surface: horizon buckets, Task terminology, inline expandable gate detail,
// claimable backlog, and the 5 KPI strip from the reference design.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { route, navigate } from '../router'
import { goals, tasks, keepers } from '../store'
import { BoardModerationSurface } from './board/board-moderation-surface'
import { BoardSurface } from './board/board-surface'
import { SubBoardSurface } from './board/sub-board-surface'
import { PlanningPanel } from './planning-panel'
import { VerificationRequestsPanel } from './verification-requests-panel'
import { ErrorBoundary } from './common/error-boundary'
import { LoadingState } from './common/feedback-state'
import { KeeperBadge } from './keeper-badge'
import type { Goal, Task, Keeper } from '../types'

type WorkSection = 'work' | 'board' | 'sub-boards' | 'moderation' | 'planning' | 'repositories' | 'verification'

const LazyRepositoryManagement = lazy(async () => ({
  default: (await import('./repository-management')).RepositoryManagement,
}))

function isWorkSection(v: string | undefined): v is WorkSection {
  return v === 'work' || v === 'board' || v === 'sub-boards' || v === 'moderation' || v === 'planning' || v === 'repositories' || v === 'verification'
}

// ── Task state mapping ──────────────────────────────────────────────────────

// Bucket = progress-aggregation axis (done/wip/verify/blocked/todo).
// cls    = the prototype's CSS modifier on .wk-task-dot/.wk-task-state.
// They differ on purpose: the vendored v2.css defines dot/state variants
// `done|wip|verify|claimed|cancelled|todo` (v2.css:832-850) but NOT
// `review` or `blocked`, so emitting the prototype's exact class names is
// what gets the row styled. `claimed` keeps its own (info-blue) color
// instead of folding into wip; `cancelled` keeps the struck-through grey.
type JobBucket = 'done' | 'wip' | 'verify' | 'blocked' | 'todo'
type JobStateCls = 'done' | 'wip' | 'verify' | 'claimed' | 'cancelled' | 'todo'

interface JobState {
  label: string
  bucket: JobBucket
  cls: JobStateCls
}

function jobStateForTask(task: Task): JobState {
  switch (task.status) {
    case 'done': return { label: '완료', bucket: 'done', cls: 'done' }
    case 'in_progress': return { label: '진행 중', bucket: 'wip', cls: 'wip' }
    case 'claimed': return { label: '클레임', bucket: 'wip', cls: 'claimed' }
    case 'awaiting_verification': return { label: '검증 대기', bucket: 'verify', cls: 'verify' }
    case 'cancelled': return { label: '취소', bucket: 'blocked', cls: 'cancelled' }
    case 'todo':
    default: return { label: '대기', bucket: 'todo', cls: 'todo' }
  }
}

function blockerNoteForTask(task: Task): string | null {
  if (task.status === 'cancelled') {
    return task.handoff_context?.reason
      ?? task.handoff_context?.failure_mode
      ?? 'cancelled'
  }
  if (task.status === 'awaiting_verification') {
    return task.handoff_context?.reason ?? '검증 대기'
  }
  return task.handoff_context?.failure_mode ?? null
}

function taskGateRows(task: Task): Array<{ label: string; outcome: 'satisfied' | 'missing' | 'failed'; detail: string }> {
  const rows: Array<{ label: string; outcome: 'satisfied' | 'missing' | 'failed'; detail: string }> = []
  const addEvaluation = (label: string, evaluation: NonNullable<Task['gate']>['done'] | null | undefined) => {
    if (!evaluation) return
    const outcome = evaluation.status === 'ready'
      ? 'satisfied'
      : evaluation.status === 'blocked'
        ? 'failed'
        : 'missing'
    const check = evaluation.checks?.[0]
    const detail = check?.evidence
      ?? evaluation.reasons?.[0]
      ?? check?.detail
      ?? evaluation.status
    rows.push({ label, outcome, detail })
  }
  addEvaluation('done gate', task.gate?.done)
  addEvaluation('inspect gate', task.gate?.inspect_to_implement)
  addEvaluation('verify gate', task.gate?.verify_to_review)
  return rows
}

const GOAL_STATUS_LABEL: Record<string, string> = {
  active: '진행 중',
  completed: '완료',
  paused: '일시정지',
  cancelled: '취소',
}

function goalStatusLabel(status: string): string {
  return GOAL_STATUS_LABEL[status] ?? status
}

// Goal status → semantic css class for .wk-gstatus variants.
// Prototype data.jsx:355 maps active→ok, at_risk→warn, blocked→bad, verifying→volt
// (default cls 'ok'). Repo statuses (active/completed/paused/cancelled) folded in.
const GOAL_STATUS_CLASS: Record<string, 'ok' | 'warn' | 'bad' | 'volt'> = {
  active: 'ok',
  completed: 'ok',
  at_risk: 'warn',
  paused: 'warn',
  blocked: 'bad',
  cancelled: 'bad',
  verifying: 'volt',
}

function goalStatusClass(status: string): 'ok' | 'warn' | 'bad' | 'volt' {
  return GOAL_STATUS_CLASS[status] ?? 'ok'
}

// Gate evidence outcome → Korean outcome word for the right-aligned
// .wk-gate-out column. Mirrors the prototype GATE_OUTCOME map
// (data.jsx:369): satisfied 충족 / missing 누락 / failed 실패.
const GATE_OUTCOME_LABEL: Record<'satisfied' | 'missing' | 'failed', string> = {
  satisfied: '충족',
  missing: '누락',
  failed: '실패',
}

// ── Goal horizon mapping ────────────────────────────────────────────────────

interface HorizonMeta {
  key: Goal['horizon']
  label: string
  sub: string
}

const LONG_HORIZON_META: HorizonMeta = { key: 'long', label: '장기', sub: '방향' }

const HORIZON_META: HorizonMeta[] = [
  { key: 'short', label: '단기', sub: '매 사이클 · 즉시' },
  { key: 'mid', label: '중기', sub: '이번 분기' },
  LONG_HORIZON_META,
]

function horizonKeyForGoal(goal: Goal): Goal['horizon'] {
  return HORIZON_META.some(h => h.key === goal.horizon) ? goal.horizon : 'long'
}

// ── Keeper lookup ───────────────────────────────────────────────────────────

function keeperByName(name: string | null | undefined): Keeper | undefined {
  if (!name) return undefined
  return keepers.value.find(k => k.name === name)
}

function leadKeeperForGoal(goal: Goal): Keeper | undefined {
  const active = keepers.value.find(k => k.active_goal_ids?.includes(goal.id))
  if (active) return active

  const goalTasks = tasks.value.filter(t => t.goal_id === goal.id)
  const counts = new Map<string, number>()
  for (const t of goalTasks) {
    if (t.assignee) counts.set(t.assignee, (counts.get(t.assignee) ?? 0) + 1)
  }
  let topName: string | undefined
  let topCount = 0
  for (const [name, count] of counts) {
    if (count > topCount) {
      topName = name
      topCount = count
    }
  }
  return topName ? keeperByName(topName) : undefined
}

function openKeeperWorkspace(name: string): void {
  navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

// ── Progress aggregation ────────────────────────────────────────────────────

interface GoalProgressCounts {
  done: number
  wip: number
  verify: number
  blocked: number
  total: number
}

function hasTaskAssignee(task: Task): boolean {
  return (task.assignee ?? '').trim().length > 0
}

function isClaimableBacklogTask(task: Task): boolean {
  return (task.status ?? 'todo') === 'todo' && !hasTaskAssignee(task)
}

function goalProgressCounts(goalTasks: Task[]): GoalProgressCounts {
  const counts: GoalProgressCounts = { done: 0, wip: 0, verify: 0, blocked: 0, total: goalTasks.length }
  for (const t of goalTasks) {
    if (t.status === 'cancelled') continue
    const bucket = jobStateForTask(t).bucket
    if (bucket === 'done') counts.done++
    else if (bucket === 'blocked') counts.blocked++
    else if (bucket === 'verify') counts.verify++
    else if (bucket === 'wip') counts.wip++
  }
  return counts
}

// ── Sub-components ──────────────────────────────────────────────────────────

function GoalProgressBar({ counts }: { counts: GoalProgressCounts }) {
  const n = Math.max(counts.total, 1)
  const pct = (x: number) => (x / n) * 100
  return html`
    <div class="wk-prog" aria-hidden="true">
      ${counts.done > 0 ? html`<span class="wk-seg done" style=${{ width: `${pct(counts.done)}%` }}></span>` : null}
      ${counts.verify > 0 ? html`<span class="wk-seg verify" style=${{ width: `${pct(counts.verify)}%` }}></span>` : null}
      ${counts.wip > 0 ? html`<span class="wk-seg wip" style=${{ width: `${pct(counts.wip)}%` }}></span>` : null}
      ${counts.blocked > 0 ? html`<span class="wk-seg blocked" style=${{ width: `${pct(counts.blocked)}%` }}></span>` : null}
    </div>
  `
}

function TaskGate({ rows }: { rows: ReturnType<typeof taskGateRows> }) {
  const open = rows.filter(g => g.outcome !== 'satisfied').length
  return html`
    <div class="wk-gate">
      <div class="wk-gate-h">
        완료 계약 · 게이트 증거
        ${open > 0
          ? html`<span class="wk-gate-open">${open} 미충족</span>`
          : html`<span class="wk-gate-ok">전부 충족</span>`}
      </div>
      ${rows.map((g, i) => html`
        <div key=${i} class=${`wk-gate-row ${g.outcome}`}>
          <span class="wk-gate-mark">
            ${g.outcome === 'satisfied' ? '✓' : g.outcome === 'failed' ? '✕' : '○'}
          </span>
          <span class="wk-gate-ev"><span class="mono">${g.label}</span> · ${g.detail}</span>
          <span class="wk-gate-out">${GATE_OUTCOME_LABEL[g.outcome]}</span>
        </div>
      `)}
    </div>
  `
}

function TaskRow({ task, onClaim }: { task: Task; onClaim: (id: string) => void }) {
  const state = jobStateForTask(task)
  const keeper = keeperByName(task.assignee)
  const blocker = blockerNoteForTask(task)
  const gateRows = taskGateRows(task)
  const handoff = task.handoff_context
  const hasDetail = gateRows.length > 0 || !!handoff?.summary || !!handoff?.next_step || !!handoff?.failure_mode
  const [open, setOpen] = useState(false)

  const toggle = () => {
    if (hasDetail) setOpen(o => !o)
  }

  return html`
    <div class=${`wk-task ${state.cls}`} data-testid="job-row" data-job-id=${task.id}>
      <div class="wk-task-main" onClick=${toggle} style=${hasDetail ? { cursor: 'pointer' } : undefined}>
        <span class=${`wk-task-dot ${state.cls}`} aria-hidden="true"></span>
        <span class="wk-task-id mono">${task.id}</span>
        <span class="wk-task-title">
          ${task.title}
          ${blocker ? html`<span class="wk-task-block" data-testid="job-blocker">⚠ ${blocker}</span>` : null}
          ${hasDetail ? html`<span class="wk-task-chev">${open ? '\u25BE' : '\u25B8'}</span>` : null}
        </span>
        <span class="wk-spacer"></span>
        <span class=${`wk-task-state ${state.cls}`}>${state.label}</span>
        ${keeper
          ? html`
            <button
              type="button"
              class="wk-task-kp"
              data-testid="job-keeper"
              onClick=${(e: Event) => { e.stopPropagation(); openKeeperWorkspace(keeper.name) }}
              title=${`${keeper.name} 대화 열기`}
            >
              <${KeeperBadge} id=${keeper.name} size="sm" variant="sigil" />
              <span class="mono">${keeper.name}</span>
            </button>
          `
          : task.status === 'todo'
            ? html`
              <button
                type="button"
                class="wk-task-claim"
                data-testid="job-claim"
                onClick=${(e: Event) => { e.stopPropagation(); onClaim(task.id) }}
                title="keeper_task_claim — 백로그에서 클레임"
              >
                ＋ claim
              </button>
            `
            : html`<span class="wk-task-kp none mono">미배정</span>`}
      </div>
      ${open && hasDetail ? html`
        <div class="wk-task-detail">
          ${gateRows.length > 0 ? html`<${TaskGate} rows=${gateRows} />` : null}
          ${handoff ? html`
            <div class="wk-handoff">
              <div class="wk-handoff-h">핸드오프 컨텍스트</div>
              ${handoff.summary ? html`<div class="wk-handoff-row"><span class="k">요약</span>${handoff.summary}</div>` : null}
              ${handoff.next_step ? html`<div class="wk-handoff-row"><span class="k">다음</span>${handoff.next_step}</div>` : null}
              ${handoff.failure_mode ? html`<div class="wk-handoff-row"><span class="k">실패</span>${handoff.failure_mode}</div>` : null}
            </div>
          ` : null}
        </div>
      ` : null}
    </div>
  `
}

function GoalCard({
  goal,
  open,
  onToggle,
  goalTasks,
  onClaim,
}: {
  goal: Goal
  open: boolean
  onToggle: () => void
  goalTasks: Task[]
  onClaim: (id: string) => void
}) {
  const progress = goalProgressCounts(goalTasks)
  const lead = leadKeeperForGoal(goal)

  // Border tint by goal status (prototype .wk-goal.st-warn/.st-bad/.st-volt,
  // v2.css:812-814): at_risk→amber, blocked→bad, verifying→volt. `st-ok`
  // has no rule (neutral border) which matches the prototype default.
  return html`
    <div class=${`wk-goal ${open ? 'open' : ''} st-${goalStatusClass(goal.status)}`} data-testid="goal-card" data-goal-id=${goal.id}>
      <button type="button" class="wk-goal-h" onClick=${onToggle} aria-expanded=${open}>
        <span class="wk-caret" aria-hidden="true">${open ? '\u25BE' : '\u25B8'}</span>
        <span class="wk-prio mono" title=${`우선순위 ${goal.priority}`}>P${goal.priority}</span>
        <span class=${`wk-gstatus ${goalStatusClass(goal.status)}`}>${goalStatusLabel(goal.status)}</span>
        <span class="wk-goal-title">${goal.title}</span>
        <!-- Prototype shows a namespace pill (.wk-goal-ns) here from g.ns.
             The live Goal type has no namespace/ns field (types/core.ts:603),
             so rather than fake it with the redundant horizon label (the card
             already sits under a horizon section header), the pill is dropped
             until a backend namespace field exists. Audit workspace.md #3. -->
        <span class="wk-spacer"></span>
        ${goal.require_completion_approval || goal.active_verification_request_id
          ? html`<span class="wk-approval" title="완료 승인 필요">✓ 완료 승인</span>`
          : null}
        ${goal.due_date ? html`<span class="wk-due mono">${goal.due_date}</span>` : null}
        ${lead ? html`
          <span class="wk-lead" title=${`리드 · ${lead.name}`}>
            <${KeeperBadge} id=${lead.name} size="md" variant="sigil" />
          </span>
        ` : null}
      </button>
      <div class="wk-goal-sub">
        <${GoalProgressBar} counts=${progress} />
        <span class="wk-prog-lbl mono">
          ${progress.done}/${progress.total}${progress.verify > 0 ? ` · 검증 ${progress.verify}` : ''}${progress.blocked > 0 ? ` · 막힘 ${progress.blocked}` : ''}
        </span>
        ${goal.phase ? html`<span class="wk-goal-phase mono" title="goal phase">${goal.phase}</span>` : null}
        ${goal.metric ? html`<span class="wk-metric mono" title="목표 지표">${goal.metric}</span>` : null}
      </div>
      ${open ? html`
        <div class="wk-jobs">
          ${goal.last_review_note ? html`<div class="wk-note">${goal.last_review_note}</div>` : null}
          ${goal.require_completion_approval && goal.verifier_policy?.principals.length ? html`
            <div class="wk-verifier">
              완료 승인 정책 · 검증자
              ${goal.verifier_policy.principals.map(v => html`<span key=${v.id} class="wk-vchip mono">${v.id}</span>`)}
            </div>
          ` : null}
          ${goalTasks.map(t => html`<${TaskRow} key=${t.id} task=${t} onClaim=${onClaim} />`)}
        </div>
      ` : null}
    </div>
  `
}

function WorkSurfaceV2() {
  const goalList = goals.value
  const allTasks = tasks.value

  const [openSet, setOpenSet] = useState<Set<string>>(new Set())
  const [claimed, setClaimed] = useState<Set<string>>(new Set())

  useEffect(() => {
    setOpenSet(prev => {
      const next = new Set(prev)
      for (const g of goalList) {
        const progress = goalProgressCounts(allTasks.filter(t => t.goal_id === g.id))
        // Prototype auto-expands attention goals (priority >= 7 || at_risk ||
        // verifying, work.jsx:138). The live priority scale (1=top vs 9=top)
        // is not confirmed against the backend, so the priority trigger is
        // left as-is and only the unambiguous status triggers are aligned:
        // at_risk / verifying / any blocked task. Audit workspace.md #7.
        if (g.priority === 1 || g.status === 'at_risk' || g.status === 'verifying' || progress.blocked > 0) next.add(g.id)
      }
      return next
    })
  }, [goalList, allTasks])

  const claimTask = (taskId: string) => {
    setClaimed(prev => {
      const next = new Set(prev)
      next.add(taskId)
      return next
    })
  }

  const claimedTasks = useMemo(() => {
    if (claimed.size === 0) return allTasks
    return allTasks.map(t => {
      if (claimed.has(t.id) && !t.assignee && t.status === 'todo') {
        return { ...t, assignee: 'operator', status: 'claimed' as const }
      }
      return t
    })
  }, [allTasks, claimed])

  const liveTasks = claimedTasks.filter(t => t.status !== 'cancelled')
  const totals = useMemo(() => ({
    goals: goalList.length,
    tasks: liveTasks.length,
    wip: liveTasks.filter(t => t.status === 'in_progress' || t.status === 'claimed').length,
    verify: liveTasks.filter(t => t.status === 'awaiting_verification').length,
    backlog: claimedTasks.filter(t => isClaimableBacklogTask(t)).length,
  }), [goalList, liveTasks, claimedTasks])

  const horizonGroups = useMemo(() => HORIZON_META.map(meta => ({
    ...meta,
    goals: goalList.filter(goal => horizonKeyForGoal(goal) === meta.key),
  })).filter(group => group.goals.length > 0), [goalList])

  const backlogTasks = useMemo(() => {
    return claimedTasks
      .filter(t => isClaimableBacklogTask(t))
      .map(t => ({
        ...t,
        goalTitle: t.goal_id ? goalList.find(g => g.id === t.goal_id)?.title : undefined,
      }))
  }, [claimedTasks, goalList])

  const toggleGoal = (id: string) => {
    setOpenSet(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const tasksByGoalId = useMemo(() => {
    const map = new Map<string, Task[]>()
    for (const g of goalList) map.set(g.id, [])
    for (const t of claimedTasks) {
      if (t.goal_id) {
        const list = map.get(t.goal_id)
        if (list) list.push(t)
      }
    }
    return map
  }, [goalList, claimedTasks])

  return html`
    <main class="ov">
      <div class="ov-scroll">
        <header class="ov-head">
            <div>
              <span class="ov-eyebrow">Goal Store</span>
              <h1>작업 · 목표</h1>
              <p class="ov-sub">Goal → Task → keeper · horizon으로 묶고 게이트 증거로 검증</p>
            </div>
            <button
              type="button"
              class="set-add wk-newgoal"
              data-testid="work-new-goal"
              title="새 목표 생성 — 다음 단계에서 설계"
              disabled=${true}
            >
              ＋ 새 목표
            </button>
          </header>

          <section class="ov-kpis" data-testid="work-kpis" style=${{ gridTemplateColumns: 'repeat(5, 1fr)' }}>
            <div class="ov-kpi">
              <div class="ov-kpi-k">활성 목표</div>
              <div class="ov-kpi-v volt" data-testid="kpi-goals">${totals.goals}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">전체 Task</div>
              <div class="ov-kpi-v" data-testid="kpi-tasks">${totals.tasks}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">진행 중</div>
              <div class=${`ov-kpi-v ${totals.wip > 0 ? 'volt' : ''}`} data-testid="kpi-wip">${totals.wip}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">검증 대기</div>
              <div class=${`ov-kpi-v ${totals.verify > 0 ? 'volt' : ''}`} data-testid="kpi-verify">${totals.verify}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">백로그</div>
              <div class=${`ov-kpi-v ${totals.backlog > 0 ? 'warn' : ''}`} data-testid="kpi-backlog">${totals.backlog}</div>
            </div>
          </section>

          ${backlogTasks.length > 0 ? html`
            <section class="wk-backlog" data-testid="work-backlog">
              <div class="wk-backlog-h">
                <span class="wk-backlog-glyph" aria-hidden="true">⊕</span>
                클레임 가능 백로그
                <span class="n">${backlogTasks.length}</span>
                <span class="wk-backlog-sub mono">keeper_task_claim — 미배정 task</span>
              </div>
              <div class="wk-backlog-list">
                ${backlogTasks.map(t => html`
                  <div key=${t.id} class="wk-bl-row">
                    <span class="wk-task-id mono">${t.id}</span>
                    <span class="wk-bl-title">
                      ${t.title}
                      ${t.goalTitle ? html`<span class="wk-bl-goal mono">${t.goalTitle}</span>` : null}
                    </span>
                    <span class="wk-spacer"></span>
                    <span class="wk-bl-prio mono">P${t.priority ?? 0}</span>
                    <button type="button" class="wk-task-claim" onClick=${() => claimTask(t.id)}>＋ claim</button>
                  </div>
                `)}
              </div>
            </section>
          ` : null}

          ${horizonGroups.map(group => html`
            <div class="wk-horizon" data-testid="work-horizon" data-horizon=${group.key}>
              <div class="wk-hz-head">
                <span class="wk-hz-lbl">${group.label}</span>
                <span class="wk-hz-sub">${group.sub}</span>
                <span class="wk-hz-n mono">${group.goals.length}</span>
              </div>
              <div class="wk-list">
                ${group.goals.map(g => html`
                  <${GoalCard}
                    key=${g.id}
                    goal=${g}
                    open=${openSet.has(g.id)}
                    onToggle=${() => toggleGoal(g.id)}
                    goalTasks=${tasksByGoalId.get(g.id) ?? []}
                    onClaim=${claimTask}
                  />
                `)}
              </div>
            </div>
          `)}

          <div class="wk-foot mono">Goal → Task → keeper · horizon(단기·중기·장기) · 완료는 게이트 증거 충족 후 done · 미배정 task 는 백로그에서 claim</div>
      </div>
    </main>
  `
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'work'

  return html`
    <div class="v2-workspace-surface flex min-w-0 flex-col gap-3">
      <div class="min-w-0 transition-opacity duration-[var(--t-slow)]">
        <${ErrorBoundary} label=${current}>
          ${current === 'work' ? html`<${WorkSurfaceV2} />`
            : current === 'board' ? html`<${BoardSurface} />`
            : current === 'sub-boards' ? html`<${SubBoardSurface} />`
            : current === 'moderation' ? html`<${BoardModerationSurface} />`
            : current === 'planning' ? html`<${PlanningPanel} />`
            : current === 'repositories' ? html`
              <${Suspense} fallback=${html`<${LoadingState}>저장소 화면 불러오는 중...<//>`}>
                <${LazyRepositoryManagement} />
              <//>
            `
            : html`<${VerificationRequestsPanel} />`
          }
        <//>
      </div>
    </div>
  `
}
