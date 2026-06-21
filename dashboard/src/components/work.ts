// MASC Dashboard — Work Tab (keeper-v2 goal/task layout)
// Surface: KPI header + horizon buckets + collapsible goal cards + segmented progress + task rows.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useMemo, useState } from 'preact/hooks'
import { route, navigate } from '../router'
import { goals, tasks, keepers } from '../store'
import { assignTaskToGoal } from './task-manage/task-manage-state'
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

type JobStateKey = 'done' | 'wip' | 'review' | 'blocked' | 'todo'

interface JobState {
  label: string
  cls: JobStateKey
}

const JOB_STATE: Record<JobStateKey, JobState> = {
  done: { label: '완료', cls: 'done' },
  wip: { label: '진행 중', cls: 'wip' },
  review: { label: '리뷰', cls: 'review' },
  blocked: { label: '막힘', cls: 'blocked' },
  todo: { label: '대기', cls: 'todo' },
}

function jobStateForTask(task: Task): JobState {
  switch (task.status) {
    case 'done': return JOB_STATE.done
    case 'in_progress':
    case 'claimed': return JOB_STATE.wip
    case 'awaiting_verification': return JOB_STATE.review
    case 'cancelled': return JOB_STATE.blocked
    case 'todo':
    default: return JOB_STATE.todo
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

// ── Goal horizon mapping ────────────────────────────────────────────────────

interface HorizonMeta {
  key: Goal['horizon']
  label: string
  sub: string
}

const LONG_HORIZON_META: HorizonMeta = { key: 'long', label: 'Later', sub: '장기 목표 / 대기열' }

const HORIZON_META: HorizonMeta[] = [
  { key: 'short', label: 'Now', sub: '즉시 실행 / 이번 주' },
  { key: 'mid', label: 'Next', sub: '조정 중 / 이번 사이클' },
  LONG_HORIZON_META,
]

function horizonMetaForGoal(goal: Goal): HorizonMeta {
  return HORIZON_META.find(h => h.key === goal.horizon) ?? LONG_HORIZON_META
}

// ── Priority mapping ────────────────────────────────────────────────────────

interface PriorityState {
  label: string
  cls: 'high' | 'normal' | 'low'
}

const HIGH_PRIORITY: PriorityState = { label: '높음', cls: 'high' }
const NORMAL_PRIORITY: PriorityState = { label: '보통', cls: 'normal' }
const LOW_PRIORITY: PriorityState = { label: '낮음', cls: 'low' }

function priorityStateForGoal(goal: Goal): PriorityState {
  if (goal.priority === 1) return HIGH_PRIORITY
  if (goal.priority === 2) return NORMAL_PRIORITY
  return LOW_PRIORITY
}

// ── Keeper lookup ───────────────────────────────────────────────────────────

function keeperByName(name: string | null | undefined): Keeper | undefined {
  if (!name) return undefined
  return keepers.value.find(k => k.name === name)
}

function leadKeeperForGoal(goal: Goal): Keeper | undefined {
  // Prefer a keeper that lists this goal as active.
  const active = keepers.value.find(k => k.active_goal_ids?.includes(goal.id))
  if (active) return active

  // Fall back to the most frequent task assignee for this goal.
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

function goalProgressCounts(goal: Goal): GoalProgressCounts {
  const goalTasks = tasks.value.filter(t => t.goal_id === goal.id)
  const counts: GoalProgressCounts = { done: 0, wip: 0, verify: 0, blocked: 0, total: goalTasks.length }
  for (const t of goalTasks) {
    const state = jobStateForTask(t).cls
    if (state === 'done') counts.done++
    else if (state === 'blocked') counts.blocked++
    else if (state === 'review') counts.verify++
    else if (state === 'wip') counts.wip++
  }
  return counts
}

function workspaceNamespace(): string {
  return 'masc-mcp'
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

function taskGateRows(task: Task): Array<{ label: string; outcome: 'satisfied' | 'missing' | 'failed'; detail: string }> {
  const rows: Array<{ label: string; outcome: 'satisfied' | 'missing' | 'failed'; detail: string }> = []
  const addEvaluation = (label: string, evaluation: NonNullable<Task['gate']>['done'] | null | undefined) => {
    if (!evaluation) return
    const outcome = evaluation.status === 'ready'
      ? 'satisfied'
      : evaluation.status === 'blocked'
        ? 'failed'
        : 'missing'
    const detail = evaluation.reasons?.[0]
      ?? evaluation.checks?.[0]?.detail
      ?? evaluation.status
    rows.push({ label, outcome, detail })
  }
  addEvaluation('done gate', task.gate?.done)
  addEvaluation('inspect gate', task.gate?.inspect_to_implement)
  return rows.slice(0, 2)
}

function JobRow({ task, allowAssign = false }: { task: Task; allowAssign?: boolean }) {
  const state = jobStateForTask(task)
  const keeper = keeperByName(task.assignee)
  const blocker = blockerNoteForTask(task)
  const gateRows = taskGateRows(task)
  const handoff = task.handoff_context?.summary || task.handoff_context?.next_step

  return html`
    <div class=${`wk-job wk-task ${state.cls}`} data-testid="job-row" data-job-id=${task.id}>
      <div class="wk-task-main">
        <span class=${`wk-job-dot wk-task-dot ${state.cls}`} aria-hidden="true"></span>
        <span class="wk-job-id wk-task-id mono">${task.id}</span>
        <span class="wk-job-title wk-task-title">
          ${task.title}
          ${blocker ? html`<span class="wk-job-block wk-task-block" data-testid="job-blocker">⚠ ${blocker}</span>` : null}
        </span>
        <span class="wk-spacer"></span>
        <span class=${`wk-job-state wk-task-state ${state.cls}`}>${state.label}</span>
        ${keeper
          ? html`
            <button
              type="button"
              class="wk-job-kp wk-task-kp"
              data-testid="job-keeper"
              onClick=${() => openKeeperWorkspace(keeper.name)}
              title=${`${keeper.name} 대화 열기`}
            >
              <${KeeperBadge} id=${keeper.name} size="sm" variant="sigil" />
              <span class="mono">${keeper.name}</span>
            </button>
          `
          : html`<span class="wk-job-kp wk-task-kp none mono">미배정</span>`}
        ${allowAssign
          ? html`
            <select
              class="wk-job-assign wk-task-claim mono"
              data-testid="job-assign"
              aria-label=${`${task.id} 목표에 배정`}
              onChange=${(e: Event) => {
                const goalId = (e.currentTarget as HTMLSelectElement).value
                if (goalId) void assignTaskToGoal(task.id, goalId)
              }}
            >
              <option value="" selected hidden>목표에 배정…</option>
              ${goals.value.map(g => html`<option value=${g.id}>${g.title || g.id}</option>`)}
            </select>
          `
          : null}
      </div>
      ${gateRows.length > 0 ? html`
        <div class="wk-gate" data-testid="task-gate">
          ${gateRows.map(row => html`
            <span class=${`wk-gate-row ${row.outcome}`}>
              <span class="mono">${row.label}</span>
              <span>${row.detail}</span>
            </span>
          `)}
        </div>
      ` : null}
      ${handoff ? html`<div class="wk-handoff">${handoff}</div>` : null}
    </div>
  `
}

function GoalCard({
  goal,
  open,
  onToggle,
}: {
  goal: Goal
  open: boolean
  onToggle: () => void
}) {
  const progress = goalProgressCounts(goal)
  const lead = leadKeeperForGoal(goal)
  const priority = priorityStateForGoal(goal)
  const goalTasks = tasks.value.filter(t => t.goal_id === goal.id)
  const hasBlock = progress.blocked > 0
  const horizon = horizonMetaForGoal(goal)

  return html`
    <div class=${`wk-goal ss-card ${open ? 'open' : ''} ${hasBlock ? 'has-block' : ''}`} data-testid="goal-card" data-goal-id=${goal.id}>
      <button type="button" class="wk-goal-h" onClick=${onToggle} aria-expanded=${open}>
        <span class="wk-caret" aria-hidden="true">${open ? '\u25BE' : '\u25B8'}</span>
        <span class=${`wk-pri wk-prio ${priority.cls}`}>${priority.label}</span>
        <span class="wk-gstatus">${goal.status}</span>
        <span class="wk-goal-id mono">${goal.id}</span>
        <span class="wk-goal-title">${goal.title}</span>
        <span class="wk-goal-ns mono">${horizon.label}</span>
        <span class="wk-spacer"></span>
        ${goal.require_completion_approval || goal.active_verification_request_id
          ? html`<span class="wk-approval">approval</span>`
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
        ${goal.metric ? html`<span class="wk-metric mono" title="목표 지표">${goal.metric}</span>` : null}
      </div>
      ${open ? html`
        <div class="wk-jobs">
          ${goal.last_review_note ? html`<div class="wk-note">${goal.last_review_note}</div>` : null}
          ${goalTasks.map(task => html`<${JobRow} key=${task.id} task=${task} />`)}
        </div>
      ` : null}
    </div>
  `
}

function WorkSurfaceV2() {
  const goalList = goals.value
  const allTasks = tasks.value

  const [openSet, setOpenSet] = useState<Set<string>>(() => {
    const initial = new Set<string>()
    for (const g of goalList) {
      const progress = goalProgressCounts(g)
      if (g.priority === 1 || progress.blocked > 0) initial.add(g.id)
    }
    return initial
  })

  const toggleGoal = (id: string) => {
    setOpenSet(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // KPI counts span ALL tasks, not only goal-linked ones. goal↔task linkage is
  // optional (tasks frequently carry no goal_id), so a goal-only sum would read
  // 0 tasks even with a full backlog.
  const totals = useMemo(() => {
    let doneJobs = 0
    let wipJobs = 0
    let verifyJobs = 0
    let blockedJobs = 0
    for (const t of allTasks) {
      const state = jobStateForTask(t).cls
      if (state === 'done') doneJobs++
      else if (state === 'wip') wipJobs++
      else if (state === 'review') verifyJobs++
      else if (state === 'blocked') blockedJobs++
    }
    return {
      goals: goalList.length,
      tasks: allTasks.length,
      done: doneJobs,
      wip: wipJobs,
      verify: verifyJobs,
      blocked: blockedJobs,
    }
  }, [goalList, allTasks])

  // Tasks with no goal_id have no place in the goal→task tree. Surface them in a
  // dedicated section instead of dropping them from the board.
  const unassignedTasks = allTasks.filter(task => !task.goal_id)
  const horizonGroups = HORIZON_META.map(meta => ({
    ...meta,
    goals: goalList.filter(goal => horizonMetaForGoal(goal).key === meta.key),
  })).filter(group => group.goals.length > 0)

  return html`
    <main class="wk-surface ss-surface bg-surface-page text-text-primary">
      <div class="wk-scroll">
        <div class="wk-inner space-y-6">
          <header class="wk-head">
            <div>
              <h1 class="text-[18px] font-bold text-text-secondary">작업 · 목표</h1>
              <p class="wk-sub">
                <span title="최상위 조정 범위">namespace <span class="mono">${workspaceNamespace()}</span></span>
                · <span>목표 ${totals.goals}</span>
                · <span>Task ${totals.tasks}</span>
                · <span>완료 ${totals.done}</span>
                ${totals.verify > 0 ? html`<span> · <span class="wk-ver-n">검증 ${totals.verify}</span></span>` : null}
                ${totals.blocked > 0 ? html`<span> · <span class="wk-blk-n">막힘 ${totals.blocked}</span></span>` : null}
              </p>
            </div>
            <button type="button" class="wk-newgoal" title="새 목표 생성 — 다음 단계에서 설계">＋ 새 목표</button>
          </header>

          <section class="wk-kpis ss-card mx-6" data-testid="work-kpis">
            <div class="wk-kpi">
              <div class="wk-kpi-k">활성 목표</div>
              <div class="wk-kpi-v volt" data-testid="kpi-goals">${totals.goals}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">전체 Task</div>
              <div class="wk-kpi-v" data-testid="kpi-jobs">${totals.tasks}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">진행 중</div>
              <div class=${`wk-kpi-v ${totals.wip > 0 ? 'volt' : ''}`} data-testid="kpi-wip">${totals.wip}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">검증 대기</div>
              <div class=${`wk-kpi-v ${totals.verify > 0 ? 'warn' : ''}`} data-testid="kpi-verify">${totals.verify}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">백로그</div>
              <div class=${`wk-kpi-v ${unassignedTasks.length > 0 ? 'bad' : 'ok'}`} data-testid="kpi-backlog">${unassignedTasks.length}</div>
            </div>
          </section>

          <div class="wk-horizons px-6">
            ${horizonGroups.map(group => html`
              <section class="wk-horizon" data-testid="work-horizon" data-horizon=${group.key}>
                <div class="wk-hz-head">
                  <span class="wk-hz-lbl">${group.label}</span>
                  <span class="wk-hz-sub">${group.sub}</span>
                  <span class="wk-spacer"></span>
                  <span class="wk-hz-n mono">${group.goals.length} goals</span>
                </div>
                <div class="wk-list">
                  ${group.goals.map(g => html`
                    <${GoalCard}
                      key=${g.id}
                      goal=${g}
                      open=${openSet.has(g.id)}
                      onToggle=${() => toggleGoal(g.id)}
                    />
                  `)}
                </div>
              </section>
            `)}
          </div>

          ${unassignedTasks.length > 0 ? html`
            <section class="wk-unassigned wk-backlog ss-card mx-6" data-testid="work-unassigned">
              <div class="wk-unassigned-h wk-backlog-h">
                <span class="wk-unassigned-dot" aria-hidden="true"></span>
                클레임 가능 백로그
                <span class="wk-unassigned-n mono">(${unassignedTasks.length})</span>
              </div>
              <div class="wk-jobs wk-backlog-list">
                ${unassignedTasks.map(task => html`<${JobRow} key=${task.id} task=${task} allowAssign=${true} />`)}
              </div>
            </section>
          ` : null}

          <div class="wk-foot mono">Goal → Task → keeper · goal 없는 Task 는 백로그 · Task 의 keeper 를 누르면 해당 keeper 대화로 이동</div>
        </div>
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
