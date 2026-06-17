// MASC Dashboard — Work Tab (keeper-v2 goal/job layout)
// Surface: KPI header + collapsible goal cards + segmented progress + job rows.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useMemo, useState } from 'preact/hooks'
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

// ── Job state mapping ───────────────────────────────────────────────────────

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
  blocked: number
  total: number
}

function goalProgressCounts(goal: Goal): GoalProgressCounts {
  const goalTasks = tasks.value.filter(t => t.goal_id === goal.id)
  const counts: GoalProgressCounts = { done: 0, wip: 0, blocked: 0, total: goalTasks.length }
  for (const t of goalTasks) {
    const state = jobStateForTask(t).cls
    if (state === 'done') counts.done++
    else if (state === 'blocked') counts.blocked++
    else if (state === 'wip' || state === 'review') counts.wip++
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
      ${counts.wip > 0 ? html`<span class="wk-seg wip" style=${{ width: `${pct(counts.wip)}%` }}></span>` : null}
      ${counts.blocked > 0 ? html`<span class="wk-seg blocked" style=${{ width: `${pct(counts.blocked)}%` }}></span>` : null}
    </div>
  `
}

function JobRow({ task }: { task: Task }) {
  const state = jobStateForTask(task)
  const keeper = keeperByName(task.assignee)
  const blocker = blockerNoteForTask(task)

  return html`
    <div class=${`wk-job ${state.cls}`} data-testid="job-row" data-job-id=${task.id}>
      <span class=${`wk-job-dot ${state.cls}`} aria-hidden="true"></span>
      <span class="wk-job-id mono">${task.id}</span>
      <span class="wk-job-title">
        ${task.title}
        ${blocker ? html`<span class="wk-job-block" data-testid="job-blocker">⚠ ${blocker}</span>` : null}
      </span>
      <span class="wk-spacer"></span>
      <span class=${`wk-job-state ${state.cls}`}>${state.label}</span>
      ${keeper
        ? html`
          <button
            type="button"
            class="wk-job-kp"
            data-testid="job-keeper"
            onClick=${() => openKeeperWorkspace(keeper.name)}
            title=${`${keeper.name} 대화 열기`}
          >
            <${KeeperBadge} id=${keeper.name} size="sm" variant="sigil" />
            <span class="mono">${keeper.name}</span>
          </button>
        `
        : html`<span class="wk-job-kp none mono">미배정</span>`}
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

  return html`
    <div class=${`wk-goal ss-card ${open ? 'open' : ''} ${hasBlock ? 'has-block' : ''}`} data-testid="goal-card" data-goal-id=${goal.id}>
      <button type="button" class="wk-goal-h" onClick=${onToggle} aria-expanded=${open}>
        <span class="wk-caret" aria-hidden="true">${open ? '\u25BE' : '\u25B8'}</span>
        <span class=${`wk-pri ${priority.cls}`}>${priority.label}</span>
        <span class="wk-goal-id mono">${goal.id}</span>
        <span class="wk-goal-title">${goal.title}</span>
        <span class="wk-goal-ns mono">${goal.horizon}</span>
        <span class="wk-spacer"></span>
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
          ${progress.done}/${progress.total}${progress.blocked > 0 ? ` · 막힘 ${progress.blocked}` : ''}
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

  const totals = useMemo(() => {
    let totalJobs = 0
    let doneJobs = 0
    let blockedJobs = 0
    for (const g of goalList) {
      const p = goalProgressCounts(g)
      totalJobs += p.total
      doneJobs += p.done
      blockedJobs += p.blocked
    }
    return {
      goals: goalList.length,
      jobs: totalJobs,
      done: doneJobs,
      blocked: blockedJobs,
    }
  }, [goalList, allTasks])

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
                · <span>job ${totals.jobs}</span>
                · <span>완료 ${totals.done}</span>
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
              <div class="wk-kpi-k">전체 job</div>
              <div class="wk-kpi-v" data-testid="kpi-jobs">${totals.jobs}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">완료</div>
              <div class=${`wk-kpi-v ${totals.done > 0 ? 'ok' : ''}`} data-testid="kpi-done">${totals.done}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">막힘</div>
              <div class=${`wk-kpi-v ${totals.blocked > 0 ? 'bad' : ''}`} data-testid="kpi-blocked">${totals.blocked}</div>
            </div>
          </section>

          <div class="wk-list px-6">
            ${goalList.map(g => html`
              <${GoalCard}
                key=${g.id}
                goal=${g}
                open=${openSet.has(g.id)}
                onToggle=${() => toggleGoal(g.id)}
              />
            `)}
          </div>

          <div class="wk-foot mono">Goal → job → keeper · job 의 keeper 를 누른면 해당 keeper 대화로 이동</div>
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
