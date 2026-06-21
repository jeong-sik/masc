// MASC Dashboard — Work Tab (keeper-v2 goal/job layout)
// Surface: KPI header + collapsible goal cards + segmented progress + job rows.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { ListTree, PanelRightOpen, X } from 'lucide-preact'
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
import { TimeAgo } from './common/time-ago'
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

function openWorkTask(taskId: string): void {
  navigate('workspace', { section: 'work', task: taskId })
}

function closeWorkTask(): void {
  navigate('workspace', { section: 'work' })
}

function openPlanningSurface(): void {
  navigate('workspace', { section: 'planning' })
}

// ── Progress aggregation ────────────────────────────────────────────────────

interface GoalProgressCounts {
  done: number
  wip: number
  blocked: number
  total: number
}

function hasTaskAssignee(task: Task): boolean {
  return (task.assignee ?? '').trim().length > 0
}

function isClaimableBacklogTask(task: Task): boolean {
  return (task.status ?? 'todo') === 'todo' && !hasTaskAssignee(task)
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

function JobRow({
  task,
  allowAssign = false,
  selected = false,
}: {
  task: Task
  allowAssign?: boolean
  selected?: boolean
}) {
  const state = jobStateForTask(task)
  const keeper = keeperByName(task.assignee)
  const blocker = blockerNoteForTask(task)

  return html`
    <div class=${`wk-job ${state.cls} ${selected ? 'selected' : ''}`} data-testid="job-row" data-job-id=${task.id}>
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
      <button
        type="button"
        class="wk-job-detail"
        data-testid="job-detail"
        aria-label=${`${task.id} 상세 열기`}
        title="태스크 상세 열기"
        onClick=${() => openWorkTask(task.id)}
      >
        <${PanelRightOpen} size=${14} aria-hidden="true" />
      </button>
      ${allowAssign
        ? html`
          <select
            class="wk-job-assign mono"
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
  `
}

function GoalCard({
  goal,
  open,
  onToggle,
  selectedTaskId,
}: {
  goal: Goal
  open: boolean
  onToggle: () => void
  selectedTaskId?: string
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
          ${goalTasks.map(task => html`<${JobRow} key=${task.id} task=${task} selected=${selectedTaskId === task.id} />`)}
        </div>
      ` : null}
    </div>
  `
}

function taskGoal(task: Task): Goal | undefined {
  if (!task.goal_id) return undefined
  return goals.value.find(goal => goal.id === task.goal_id)
}

function TaskMetaRow({ label, value }: { label: string; value?: unknown }) {
  if (value === null || value === undefined || value === '') return null
  return html`
    <div class="wk-task-meta-row">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `
}

function TaskStringList({ title, items }: { title: string; items?: string[] }) {
  if (!items || items.length === 0) return null
  return html`
    <div class="wk-task-block">
      <div class="wk-task-block-title">${title}</div>
      <div class="wk-task-chips">
        ${items.map(item => html`<span key=${item} class="wk-task-chip">${item}</span>`)}
      </div>
    </div>
  `
}

function TaskGateChecks({ task }: { task: Task }) {
  const gate = task.gate
  const checks = [
    ...(gate?.done?.checks ?? []),
    ...(gate?.inspect_to_implement?.checks ?? []),
    ...(gate?.verify_to_review?.checks ?? []),
  ]
  if (checks.length === 0 && !gate?.unmet_completion_contract?.length) return null

  return html`
    <div class="wk-task-block">
      <div class="wk-task-block-title">게이트</div>
      ${gate?.unmet_completion_contract?.length ? html`
        <div class="wk-task-warning">
          미충족 ${gate.unmet_completion_contract.length}: ${gate.unmet_completion_contract.join(', ')}
        </div>
      ` : null}
      ${checks.length ? html`
        <div class="wk-task-gates">
          ${checks.slice(0, 6).map(check => html`
            <div key=${`${check.outcome}-${check.evidence}`} class=${`wk-task-gate ${check.outcome}`}>
              <span>${check.outcome}</span>
              <strong>${check.evidence}</strong>
              ${check.detail ? html`<em>${check.detail}</em>` : null}
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}

function TaskDossier({ task }: { task: Task | null }) {
  if (!task) {
    return html`
      <aside class="wk-task-detail empty ss-card" data-testid="work-task-detail-empty">
        <div class="wk-task-detail-kicker">태스크 상세</div>
        <div class="wk-task-empty-title">작업을 선택하세요</div>
        <p>각 job 행의 상세 아이콘을 누르면 계약, handoff, 실행 링크를 여기서 읽을 수 있습니다.</p>
      </aside>
    `
  }

  const state = jobStateForTask(task)
  const goal = taskGoal(task)
  const keeper = keeperByName(task.assignee)
  const contract = task.contract
  const handoff = task.handoff_context
  const execution = task.execution_links
  const isAwaitingVerification = task.status === 'awaiting_verification'

  return html`
    <aside class="wk-task-detail ss-card" data-testid="work-task-detail" data-task-id=${task.id}>
      <div class="wk-task-detail-head">
        <div>
          <div class="wk-task-detail-kicker">태스크 상세</div>
          <h2>${task.title}</h2>
          <div class="wk-task-detail-sub mono">${task.id}</div>
        </div>
        <button
          type="button"
          class="wk-task-close"
          aria-label="태스크 상세 닫기"
          title="닫기"
          onClick=${closeWorkTask}
        >
          <${X} size=${14} aria-hidden="true" />
        </button>
      </div>

      <div class="wk-task-status-line">
        <span class=${`wk-job-state ${state.cls}`}>${state.label}</span>
        ${task.priority ? html`<span class="wk-task-priority">P${task.priority}</span>` : null}
        ${isAwaitingVerification ? html`
          <button
            type="button"
            class="wk-task-verify"
            onClick=${() => navigate('workspace', { section: 'verification', task: task.id })}
          >검증 패널</button>
        ` : null}
      </div>

      <div class="wk-task-meta">
        <${TaskMetaRow} label="목표" value=${goal ? `${goal.id} · ${goal.title}` : task.goal_id ?? '미배정'} />
        <${TaskMetaRow} label="담당" value=${task.assignee ? `${task.assignee}${task.assignee_kind ? ` · ${task.assignee_kind}` : ''}` : '미배정'} />
        ${task.created_at ? html`
          <div class="wk-task-meta-row">
            <span>생성</span>
            <strong><${TimeAgo} timestamp=${task.created_at} mode="both" /></strong>
          </div>
        ` : null}
        ${task.updated_at ? html`
          <div class="wk-task-meta-row">
            <span>갱신</span>
            <strong><${TimeAgo} timestamp=${task.updated_at} mode="both" /></strong>
          </div>
        ` : null}
      </div>

      ${task.description ? html`
        <div class="wk-task-block">
          <div class="wk-task-block-title">설명</div>
          <p>${task.description}</p>
        </div>
      ` : null}

      <${TaskStringList} title="완료 계약" items=${contract?.completion_contract} />
      <${TaskStringList} title="필수 증거" items=${contract?.required_evidence} />
      <${TaskStringList} title="검수 증거" items=${contract?.inspect_gate_evidence} />
      <${TaskStringList} title="검증 증거" items=${contract?.verify_gate_evidence} />
      <${TaskGateChecks} task=${task} />

      ${handoff?.summary ? html`
        <div class="wk-task-block handoff">
          <div class="wk-task-block-title">최근 Handoff</div>
          <p>${handoff.summary}</p>
          ${handoff.reason ? html`<div class="wk-task-note">reason: ${handoff.reason}</div>` : null}
          ${handoff.next_step ? html`<div class="wk-task-note">next: ${handoff.next_step}</div>` : null}
          ${handoff.failure_mode ? html`<div class="wk-task-note">failure: ${handoff.failure_mode}</div>` : null}
          <${TaskStringList} title="증거 참조" items=${handoff.evidence_refs} />
        </div>
      ` : null}

      ${(execution?.session_id || execution?.operation_id || keeper) ? html`
        <div class="wk-task-block">
          <div class="wk-task-block-title">연결</div>
          ${execution?.session_id ? html`<div class="wk-task-link-row"><span>session</span><strong>${execution.session_id}</strong></div>` : null}
          ${execution?.operation_id ? html`<div class="wk-task-link-row"><span>operation</span><strong>${execution.operation_id}</strong></div>` : null}
          ${keeper ? html`
            <button type="button" class="wk-task-keeper" onClick=${() => openKeeperWorkspace(keeper.name)}>
              <${KeeperBadge} id=${keeper.name} size="sm" variant="sigil" />
              <span>${keeper.name} 대화 열기</span>
            </button>
          ` : null}
        </div>
      ` : null}
    </aside>
  `
}

function WorkSurfaceV2() {
  const goalList = goals.value
  const allTasks = tasks.value
  const selectedTaskId = route.value.params.task
  const selectedTask = selectedTaskId
    ? allTasks.find(task => task.id === selectedTaskId) ?? null
    : null

  const [openSet, setOpenSet] = useState<Set<string>>(() => {
    const initial = new Set<string>()
    for (const g of goalList) {
      const progress = goalProgressCounts(g)
      if (g.priority === 1 || progress.blocked > 0) initial.add(g.id)
    }
    if (selectedTask?.goal_id) initial.add(selectedTask.goal_id)
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

  useEffect(() => {
    if (!selectedTask?.goal_id) return
    setOpenSet(prev => {
      if (prev.has(selectedTask.goal_id!)) return prev
      const next = new Set(prev)
      next.add(selectedTask.goal_id!)
      return next
    })
  }, [selectedTask?.goal_id])

  // KPI counts span ALL tasks, not only goal-linked ones. goal↔task linkage is
  // optional (tasks frequently carry no goal_id), so a goal-only sum would read
  // 0 jobs even with a full backlog.
  const totals = useMemo(() => {
    let doneJobs = 0
    let blockedJobs = 0
    let wipJobs = 0
    let reviewJobs = 0
    let claimableBacklog = 0
    for (const t of allTasks) {
      const state = jobStateForTask(t).cls
      if (state === 'done') doneJobs++
      else if (state === 'blocked') blockedJobs++
      else if (state === 'wip') wipJobs++
      else if (state === 'review') reviewJobs++
      if (isClaimableBacklogTask(t)) claimableBacklog++
    }
    return {
      goals: goalList.length,
      jobs: allTasks.length,
      done: doneJobs,
      blocked: blockedJobs,
      wip: wipJobs,
      review: reviewJobs,
      backlog: claimableBacklog,
    }
  }, [goalList, allTasks])

  // Tasks with no goal_id have no place in the goal→job tree. Surface them in a
  // dedicated section instead of dropping them from the board.
  const unassignedTasks = allTasks.filter(task => !task.goal_id)
  const unassignedClaimable = unassignedTasks.filter(isClaimableBacklogTask).length

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
                ${totals.backlog > 0 ? html`<span> · <span class="wk-backlog-n">백로그 ${totals.backlog}</span></span>` : null}
                · <span>완료 ${totals.done}</span>
                ${totals.blocked > 0 ? html`<span> · <span class="wk-blk-n">막힘 ${totals.blocked}</span></span>` : null}
              </p>
            </div>
            <button
              type="button"
              class="wk-newgoal"
              data-testid="work-planning-link"
              title="목표 관리자 열기"
              onClick=${openPlanningSurface}
            >
              <${ListTree} size=${14} aria-hidden="true" />
              <span>목표 관리자</span>
            </button>
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
              <div class="wk-kpi-k">진행 중</div>
              <div class=${`wk-kpi-v ${totals.wip > 0 ? 'volt' : ''}`} data-testid="kpi-wip">${totals.wip}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">검증 대기</div>
              <div class=${`wk-kpi-v ${totals.review > 0 ? 'warn' : ''}`} data-testid="kpi-review">${totals.review}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">완료</div>
              <div class=${`wk-kpi-v ${totals.done > 0 ? 'ok' : ''}`} data-testid="kpi-done">${totals.done}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">백로그</div>
              <div class=${`wk-kpi-v ${totals.backlog > 0 ? 'warn' : ''}`} data-testid="kpi-backlog">${totals.backlog}</div>
            </div>
          </section>

          <div class="wk-workbench px-6">
            <div class="wk-workbench-list">
              <div class="wk-list">
                ${goalList.map(g => html`
                  <${GoalCard}
                    key=${g.id}
                    goal=${g}
                    open=${openSet.has(g.id)}
                    onToggle=${() => toggleGoal(g.id)}
                    selectedTaskId=${selectedTaskId}
                  />
                `)}
              </div>

              ${unassignedTasks.length > 0 ? html`
                <section class="wk-unassigned ss-card" data-testid="work-unassigned">
                  <div class="wk-unassigned-h">
                    <span class="wk-unassigned-dot" aria-hidden="true"></span>
                    미배정 작업
                    <span class="wk-unassigned-n mono">(${unassignedTasks.length})</span>
                    <span class="wk-unassigned-claim mono" data-testid="work-unassigned-claimable">클레임 가능 ${unassignedClaimable}</span>
                  </div>
                  <div class="wk-jobs">
                    ${unassignedTasks.map(task => html`
                      <${JobRow}
                        key=${task.id}
                        task=${task}
                        allowAssign=${true}
                        selected=${selectedTaskId === task.id}
                      />
                    `)}
                  </div>
                </section>
              ` : null}

              <div class="wk-foot mono">Goal → job → keeper · todo + keeper 미배정은 백로그 · job 의 keeper 를 누르면 해당 keeper 대화로 이동</div>
            </div>

            <${TaskDossier} task=${selectedTask} />
          </div>
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
