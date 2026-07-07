// MASC Dashboard — Work Tab (keeper-v2 goal/task layout)
// Surface: Goal list (priority-sorted), Task terminology, inline expandable gate detail,
// claimable backlog, the 5 KPI strip, and WorkAside operator triage panel.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { route, navigate } from '../router'
import { goals, tasks, keepers } from '../store'
import { goalTreeData } from '../goal-tree-state'
import { normalizeTask } from '../store-normalizers'
import { WORK_UNLINKED_GOAL_TITLE } from '../lib/work-copy'
import { BoardModerationSurface } from './board/board-moderation-surface'
import { BoardSurface } from './board/board-surface'
import { SubBoardSurface } from './board/sub-board-surface'
import { PlanningPanel } from './planning-panel'
import { VerificationRequestsPanel } from './verification-requests-panel'
import { ErrorBoundary } from './common/error-boundary'
import { LoadingState } from './common/feedback-state'
import { KeeperBadge } from './keeper-badge'
import { openTaskDetail } from './goals/task-detail-state'
import { GoalCreateForm } from './goals/goal-create-form'
import { showGoalCreate, GOAL_PRIORITY_MAX } from './goals/goal-create-state'
import type { Goal, GoalTreeNode, GoalTreeTask, Task, Keeper } from '../types'

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

// ── Kanban view columns ─────────────────────────────────────────────────────
// Closed tuple — cancelled is excluded by design (it has its own aside panel).
// Each entry: [task.status value, Korean column label, CSS modifier cls].
// The cls values come directly from JobStateCls so KanbanCard can reuse the
// same .wk-kcard.<cls> and .wk-kcol-dot.<cls> rules without extra mapping.
type KanbanStatus = 'todo' | 'claimed' | 'in_progress' | 'awaiting_verification' | 'done'
type KanbanColumn = readonly [status: KanbanStatus, label: string, cls: JobStateCls]

const KANBAN_COLUMNS: ReadonlyArray<KanbanColumn> = [
  ['todo',                  '미배정',   'todo'],
  ['claimed',               '클레임됨', 'claimed'],
  ['in_progress',           '진행 중',  'wip'],
  ['awaiting_verification', '검증 대기', 'verify'],
  ['done',                  '완료',     'done'],
] as const

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

// ── Keeper lookup ───────────────────────────────────────────────────────────

function keeperByName(name: string | null | undefined): Keeper | undefined {
  if (!name) return undefined
  return keepers.value.find(k => k.name === name)
}

function leadNameForGoal(goal: Goal): string | undefined {
  const active = keepers.value.find(k => k.active_goal_ids?.includes(goal.id))
  if (active) return active.name

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
  return topName
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

const GOAL_STORE_TASK_STATUS: Readonly<Record<string, NonNullable<Task['status']>>> = {
  pending: 'todo',
  todo: 'todo',
  claimed: 'claimed',
  in_progress: 'in_progress',
  inprogress: 'in_progress',
  awaiting_verification: 'awaiting_verification',
  completed: 'done',
  done: 'done',
  cancelled: 'cancelled',
  blocked: 'in_progress',
  paused: 'in_progress',
}

function normalizeGoalStoreTaskStatus(value: unknown): Task['status'] {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : ''
  return GOAL_STORE_TASK_STATUS[raw]
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

function taskFromGoalTreeTask(task: GoalTreeTask): Task | null {
  let status = normalizeGoalStoreTaskStatus(task.status)
  if (!status) {
    console.warn('[Work] unknown Goal Store task status, falling back to todo', {
      id: task.id,
      status: task.status,
    })
    status = 'todo'
  }
  const normalized = normalizeTask({
    ...task,
    status,
  })
  if (!normalized) {
    console.warn('[Work] dropped Goal Store task', {
      id: task.id,
      status: task.status,
    })
    return null
  }
  // Goal Store tasks do not always carry completed_at; derive it from the
  // latest update timestamp when the task is done.
  const completedAt = normalized.status === 'done' && !normalized.completed_at
    ? (normalized.updated_at ?? task.updated_at)
    : normalized.completed_at
  return { ...normalized, completed_at: completedAt }
}

function collectGoalTreeTasks(
  nodes: ReadonlyArray<GoalTreeNode>,
  seen = new Set<string>(),
): Task[] {
  return nodes.flatMap(node => {
    if (seen.has(node.id)) return []
    seen.add(node.id)
    return [
      ...node.tasks
        .map(taskFromGoalTreeTask)
        .filter((task): task is Task => task !== null),
      ...collectGoalTreeTasks(node.children, seen),
    ]
  })
}

function flattenGoalTreeNodes(nodes: readonly GoalTreeNode[]): GoalTreeNode[] {
  const acc: GoalTreeNode[] = []
  const walk = (items: readonly GoalTreeNode[]) => {
    for (const item of items) {
      acc.push(item)
      if (item.children.length > 0) walk(item.children)
    }
  }
  walk(nodes)
  return acc
}

function mergeTaskRecord(goalStoreTask: Task, executionTask: Task): Task {
  return {
    ...goalStoreTask,
    ...executionTask,
    title: executionTask.title?.trim() ? executionTask.title : goalStoreTask.title,
    goal_id: executionTask.goal_id ?? goalStoreTask.goal_id,
    status: executionTask.status || goalStoreTask.status,
    priority: executionTask.priority ?? goalStoreTask.priority,
    assignee: executionTask.assignee?.trim() ? executionTask.assignee : goalStoreTask.assignee,
    assignee_kind: executionTask.assignee_kind ?? goalStoreTask.assignee_kind,
    description: executionTask.description?.trim() ? executionTask.description : goalStoreTask.description,
    created_at: executionTask.created_at || goalStoreTask.created_at,
    updated_at: executionTask.updated_at || goalStoreTask.updated_at,
    completed_at: executionTask.completed_at || goalStoreTask.completed_at,
    contract: executionTask.contract ?? goalStoreTask.contract,
    handoff_context: executionTask.handoff_context ?? goalStoreTask.handoff_context,
    gate: executionTask.gate ?? goalStoreTask.gate,
    execution_links: executionTask.execution_links ?? goalStoreTask.execution_links,
  }
}

function mergeTaskSnapshot(goalStoreTasks: ReadonlyArray<Task>, executionTasks: ReadonlyArray<Task>): Task[] {
  const byId = new Map<string, Task>()
  for (const task of goalStoreTasks) byId.set(task.id, task)
  for (const task of executionTasks) {
    const previous = byId.get(task.id)
    byId.set(task.id, previous ? mergeTaskRecord(previous, task) : task)
  }
  return Array.from(byId.values())
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
        ${task.assignee
          ? html`
            <button
              type="button"
              class=${`wk-task-kp${keeper ? '' : ' offline'}`}
              data-testid="job-keeper"
              onClick=${(e: Event) => { e.stopPropagation(); openKeeperWorkspace(task.assignee!) }}
              title=${`${task.assignee} 대화 열기${keeper ? '' : ' (Offline)'}`}
            >
              <${KeeperBadge} id=${task.assignee} size="sm" variant="sigil" />
              <span class="mono">${task.assignee}</span>
            </button>
          `
          : task.status === 'todo'
            ? html`
              <button
                type="button"
                class="wk-task-claim"
                data-testid="job-claim"
                onClick=${(e: Event) => { e.stopPropagation(); onClaim(task.id) }}
                title="keeper_task_claim — 미배정 task claim"
              >
                ＋ claim
              </button>
            `
            : html`<span class="wk-task-kp none mono">담당 없음</span>`}
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
  const leadName = leadNameForGoal(goal)

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
             the card's goal-status pill is dropped here to avoid duplication
             until a backend namespace field exists. Audit workspace.md #3. -->
        <span class="wk-spacer"></span>
        ${goal.require_completion_approval || goal.active_verification_request_id
          ? html`<span class="wk-approval" title="완료 승인 필요">✓ 완료 승인</span>`
          : null}
        ${goal.due_date ? html`<span class="wk-due mono">${goal.due_date}</span>` : null}
        ${leadName ? html`
          <span class=${`wk-lead${keeperByName(leadName) ? '' : ' offline'}`} title=${`리드 · ${leadName}${keeperByName(leadName) ? '' : ' (Offline)'}`}>
            <${KeeperBadge} id=${leadName} size="md" variant="sigil" />
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

// ── WorkAside — operator triage panel (right column) ──────────────────────
//
// Phase → "flagged" mapping rationale:
//   Prototype uses `status !== 'active'`.  The live Goal type has no `status`
//   separate from `phase` for the operator triage purpose.  We classify by
//   `phase` enum — never by substring.
//
//   • "flagged" (지금 상황):  phases that need operator attention:
//       awaiting_verification | awaiting_approval | blocked | paused
//     `executing` = normal active flow — not flagged.
//     `completed` | `dropped` = terminal — excluded (already closed out).
//
//   • "approvals" (완료 승인): goals with require_completion_approval=true
//     AND phase=awaiting_approval (final sign-off pending).
//
//   • "verifyTasks" (게이트): tasks with status=awaiting_verification.
//     open-gate count from taskGateRows().
//
//   • "blockers": tasks where handoff_context.failure_mode or handoff_context.reason
//     indicates blockage (status=cancelled OR explicit blocker via blockerNoteForTask).
//     IMPORTANT: status === 'cancelled' in the live model means "blocked/failed"
//     (prototype `t.blocker` field does not exist in live Task type; we use
//     blockerNoteForTask() which reads handoff_context fields).
//
//   • "backlog": tasks that isClaimableBacklogTask() returns true for.
//
//   • "recent": tasks with status === 'done'.

// Phase semantic class for the .wka-flag border tint.
// Mirrors prototype goalMeta() / STATUS_COLS cls (data.jsx:340-350).
// Using the existing GOAL_STATUS_CLASS mapping which covers these phases.
type WkaFlagCls = 'ok' | 'warn' | 'bad' | 'volt'

const GOAL_PHASE_FLAG_CLS: Record<string, WkaFlagCls> = {
  executing: 'ok',
  awaiting_verification: 'volt',
  awaiting_approval: 'volt',
  blocked: 'bad',
  paused: 'warn',
  completed: 'ok',
  dropped: 'bad',
}

const GOAL_PHASE_FLAG_LBL: Record<string, string> = {
  executing: '진행 중',
  awaiting_verification: '검증 대기',
  awaiting_approval: '승인 대기',
  blocked: '차단',
  paused: '일시정지',
  completed: '완료',
  dropped: '폐기',
}

function goalPhaseFlagCls(phase: string): WkaFlagCls {
  return GOAL_PHASE_FLAG_CLS[phase] ?? 'warn'
}

function goalPhaseFlagLbl(phase: string): string {
  return GOAL_PHASE_FLAG_LBL[phase] ?? phase
}

// Goals needing operator attention — positive enumeration of the triage
// phases only. `executing` (normal active flow) and the terminal phases
// (`completed` / `dropped`) are deliberately excluded: a closed-out goal is
// not part of "지금 상황". Exact membership on the phase enum, never a
// substring match. (Adding a new Goal phase requires deciding here whether it
// needs triage.)
const GOAL_ATTENTION_PHASES: ReadonlySet<string> = new Set([
  'awaiting_verification',
  'awaiting_approval',
  'blocked',
  'paused',
])

function isGoalFlagged(goal: Goal): boolean {
  return GOAL_ATTENTION_PHASES.has(goal.phase)
}

// WorkAside derived data shapes — immutable, computed from signals.
interface WkaFlaggedGoal {
  readonly id: string
  readonly cls: WkaFlagCls
  readonly lbl: string
  readonly title: string
  readonly reason: string | null | undefined
}

interface WkaApprovalGoal {
  readonly id: string
  readonly title: string
  readonly verifiers: ReadonlyArray<string>
}

interface WkaVerifyTask {
  readonly id: string
  readonly title: string
  readonly goalId: string
  readonly open: number // unsatisfied gates
}

interface WkaBlockerTask {
  readonly id: string
  readonly title: string
  readonly blocker: string
  readonly goalId: string
}

interface WkaBacklogTask {
  readonly id: string
  readonly title: string
  readonly goal: string
  readonly goalId: string
  readonly priority: number
}

interface WkaRecentTask {
  readonly id: string
  readonly title: string
  readonly goalId: string
}

interface WkaCounts {
  readonly active: number
  readonly wip: number
  readonly verify: number
  readonly backlog: number
}

interface WorkAsideProps {
  flagged: ReadonlyArray<WkaFlaggedGoal>
  approvals: ReadonlyArray<WkaApprovalGoal>
  verifyTasks: ReadonlyArray<WkaVerifyTask>
  blockers: ReadonlyArray<WkaBlockerTask>
  backlog: ReadonlyArray<WkaBacklogTask>
  recent: ReadonlyArray<WkaRecentTask>
  counts: WkaCounts
  onJump: (goalId: string) => void
  onOpenKeeper?: (name: string) => void
}

// ── View mode persistence ───────────────────────────────────────────────────
type WorkView = 'list' | 'kanban'
const WK_VIEW_KEY = 'v2.workView'

function readStoredWorkView(): WorkView {
  try {
    const v = localStorage.getItem(WK_VIEW_KEY)
    if (v === 'kanban') return 'kanban'
  } catch (_) { /* storage unavailable */ }
  return 'list'
}

function writeStoredWorkView(v: WorkView): void {
  try { localStorage.setItem(WK_VIEW_KEY, v) } catch (_) { /* noop */ }
}

// Aside width persistence — min 312, max 520, default 360.
const WKA_ASIDE_W_KEY = 'v2.wkAsideW'
const WKA_ASIDE_COLLAPSED_KEY = 'v2.wkAsideCollapsed'
const WKA_ASIDE_DEFAULT_W = 360
const WKA_ASIDE_MIN_W = 312
const WKA_ASIDE_MAX_W = 520

function readStoredAsideW(): number {
  try {
    const v = localStorage.getItem(WKA_ASIDE_W_KEY)
    if (v) {
      const n = parseInt(v, 10)
      if (!isNaN(n)) return Math.max(WKA_ASIDE_MIN_W, Math.min(WKA_ASIDE_MAX_W, n))
    }
  } catch (_) { /* storage unavailable */ }
  return WKA_ASIDE_DEFAULT_W
}

function readStoredAsideCollapsed(): boolean {
  try { return localStorage.getItem(WKA_ASIDE_COLLAPSED_KEY) === '1' } catch (_) { return false }
}

// ── Kanban sub-components ───────────────────────────────────────────────────

// KanbanTask enriches a Task with goal context for the board view.
// Goal id/title are needed because kanban tasks are flattened across goals.
interface KanbanTask extends Task {
  readonly _goalId: string
  readonly _goalTitle: string
}

// Task priorities share the goal 1–5 scale (1 = highest). The prototype only
// accents P1–P3 in the kanban card chip; P4+ render with the muted base style.
const TASK_PRIORITY_DEFAULT = GOAL_PRIORITY_MAX
const KANBAN_ACCENT_PRIORITY_MAX = 3
const KANBAN_MUTED_PRIORITY_BUCKET = 4

function KanbanCard({
  task,
  onClaim,
  onJumpGoal,
}: {
  task: KanbanTask
  onClaim: (id: string) => void
  onJumpGoal: (goalId: string) => void
}) {
  const state = jobStateForTask(task)
  const keeper = keeperByName(task.assignee)
  const blocker = blockerNoteForTask(task)
  const p = task.priority ?? TASK_PRIORITY_DEFAULT
  const normalizedPrio = p <= KANBAN_ACCENT_PRIORITY_MAX ? p : KANBAN_MUTED_PRIORITY_BUCKET
  const description = task.description ?? ''
  const hasDescription = description.length > 0

  return html`
    <article
      class=${`wk-kcard ${state.cls}`}
      role="button"
      tabIndex=${0}
      data-testid="kanban-card"
      data-kanban-task-id=${task.id}
      aria-label=${`${task.title} 상세 열기`}
      onClick=${() => openTaskDetail(task)}
      onKeyDown=${(e: KeyboardEvent) => {
        // Kanban cards have no inline expansion (unlike TaskRow); Enter/Space
        // opens the shared TaskDetailOverlay (app.ts-mounted) via openTaskDetail,
        // which also loads the task's real trace events.
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          openTaskDetail(task)
        }
      }}
    >
      <div class="wk-kcard-top">
        <span class="wk-kcard-id mono">${task.id}</span>
        <span class=${`wk-kcard-prio prio-${normalizedPrio}`}>P${p}</span>
      </div>
      <div class="wk-kcard-title">${task.title}</div>
      ${blocker ? html`<div class="wk-kcard-block">⚠ ${blocker}</div>` : null}
      ${hasDescription ? html`<p class="wk-kcard-desc">${description}</p>` : null}
      ${task._goalId
        ? html`
          <button
            type="button"
            class="wk-kcard-goal"
            data-kanban-goal-jump=${task._goalId}
            title=${`소속 목표로 이동 · ${task._goalTitle}`}
            onClick=${(e: Event) => { e.stopPropagation(); onJumpGoal(task._goalId) }}
          >↳ ${task._goalTitle}</button>
        `
        : null}
      <div class="wk-kcard-foot">
        ${task.assignee
          ? html`
            <button
              type="button"
              class=${`wk-kcard-kp${keeper ? '' : ' offline'}`}
              title=${`${task.assignee} 대화 열기${keeper ? '' : ' (Offline)'}`}
              onClick=${(e: Event) => { e.stopPropagation(); openKeeperWorkspace(task.assignee!) }}
            >
              <${KeeperBadge} id=${task.assignee} size="sm" variant="sigil" />
            </button>
          `
          : task.status === 'todo'
            ? html`
              <button
                type="button"
                class="wk-kcard-claim"
                title="keeper_task_claim"
                onClick=${(e: Event) => { e.stopPropagation(); onClaim(task.id) }}
              >＋</button>
            `
            : html`<span class="wk-kcard-kp none mono">담당 없음</span>`}
      </div>
    </article>
  `
}

function KanbanView({
  kanbanTasks,
  onClaim,
  onJumpGoal,
}: {
  kanbanTasks: ReadonlyArray<KanbanTask>
  onClaim: (id: string) => void
  onJumpGoal: (goalId: string) => void
}) {
  return html`
    <div class="wk-kanban" data-testid="work-kanban">
      ${KANBAN_COLUMNS.map(([status, label, cls]) => {
        const col = kanbanTasks.filter(t => t.status === status)
        return html`
          <div key=${status} class=${`wk-kcol ${cls}`} data-testid=${`kanban-col-${status}`}>
            <div class="wk-kcol-h">
              <span class="wk-kcol-title">${label}</span>
              <span class="wk-kcol-count">${col.length}</span>
            </div>
            <div class="wk-kcol-body">
              ${col.length === 0
                ? html`<div class="wk-kcol-empty mono">—</div>`
                : col.map(t => html`
                  <${KanbanCard}
                    key=${t.id}
                    task=${t}
                    onClaim=${onClaim}
                    onJumpGoal=${onJumpGoal}
                  />
                `)}
            </div>
          </div>
        `
      })}
    </div>
  `
}

function WorkAside({
  flagged, approvals, verifyTasks, blockers, backlog, recent, counts, onJump,
}: WorkAsideProps) {
  const needTotal = approvals.length + verifyTasks.length + blockers.length + backlog.length

  const [collapsed, setCollapsed] = useState<boolean>(readStoredAsideCollapsed)
  const [w, setW] = useState<number>(readStoredAsideW)
  const wRef = useRef(w)
  wRef.current = w

  const setCol = useCallback((v: boolean) => {
    setCollapsed(v)
    try { localStorage.setItem(WKA_ASIDE_COLLAPSED_KEY, v ? '1' : '0') } catch (_) { /* noop */ }
  }, [])

  const persistW = useCallback((next: number) => {
    setW(next)
    try { localStorage.setItem(WKA_ASIDE_W_KEY, String(next)) } catch (_) { /* noop */ }
  }, [])

  const startResize = useCallback((e: PointerEvent) => {
    e.preventDefault()
    const startX = e.clientX
    const startW = wRef.current
    document.body.classList.add('rail-resizing')
    const move = (ev: PointerEvent) => {
      // Dragging the LEFT edge of the right aside: moving left → wider
      persistW(Math.max(WKA_ASIDE_MIN_W, Math.min(WKA_ASIDE_MAX_W, startW - (ev.clientX - startX))))
    }
    const up = () => {
      document.body.classList.remove('rail-resizing')
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }, [persistW])

  if (collapsed) {
    return html`
      <aside
        class="ov-aside wka collapsed"
        role="button"
        tabIndex=${0}
        title="클릭하여 운영 상태 패널 펼치기"
        aria-expanded=${false}
        aria-label="운영 상태 패널 펼치기"
        onClick=${() => setCol(false)}
        onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setCol(false) } }}
        data-testid="work-aside-collapsed"
      >
        <button
          type="button"
          class="wka-railbtn"
          aria-label="운영 상태 패널 펼치기"
          onClick=${(e: Event) => { e.stopPropagation(); setCol(false) }}
        >«</button>
        <div class="wka-rail-stats" aria-hidden="true">
          <div class="wka-rail-stat">
            <b class="mono">${counts.wip}</b>
            <span>진행</span>
          </div>
          <div class=${`wka-rail-stat ${counts.verify ? 'volt' : ''}`}>
            <b class="mono">${counts.verify}</b>
            <span>검증</span>
          </div>
          <div class=${`wka-rail-stat ${needTotal ? 'volt' : ''}`}>
            <b class="mono">${needTotal}</b>
            <span>할일</span>
          </div>
          <div class=${`wka-rail-stat ${flagged.length ? 'bad' : ''}`}>
            <b class="mono">${flagged.length}</b>
            <span>주의</span>
          </div>
        </div>
        <div class="wka-rail-lbl" aria-hidden="true">운영 상태</div>
        <div class="wka-rail-hint" aria-hidden="true">펼치기</div>
      </aside>
    `
  }

  return html`
    <aside
      class="ov-aside wka"
      style=${{ width: `${w}px` }}
      aria-label="운영 상태 패널"
      data-testid="work-aside"
    >
      <div
        class="wka-resizer"
        role="separator"
        aria-orientation="vertical"
        aria-label="패널 폭 조절 — 드래그"
        tabIndex=${0}
        onPointerDown=${startResize}
        onKeyDown=${(e: KeyboardEvent) => {
          if (e.key === 'ArrowLeft') { e.preventDefault(); persistW(Math.max(WKA_ASIDE_MIN_W, wRef.current + 8)) }
          if (e.key === 'ArrowRight') { e.preventDefault(); persistW(Math.min(WKA_ASIDE_MAX_W, wRef.current - 8)) }
        }}
      ></div>

      <div class="wka-bar">
        <span class="wka-bar-t">운영 상태</span>
        <span class="wka-bar-live">
          <span class="wka-livedot" aria-hidden="true"></span>
          ${counts.active} active
        </span>
        <button
          type="button"
          class="wka-collapse"
          aria-label="운영 상태 패널 접기"
          aria-expanded=${true}
          onClick=${() => setCol(true)}
          title="접기 — Chat 열 때 공간 확보"
        >»</button>
      </div>

      <div class="wka-hud" aria-label="작업 현황 요약">
        <div class="wka-hud-c">
          <span class="wka-hud-k">진행</span>
          <span class="wka-hud-v">${counts.wip}</span>
        </div>
        <div class="wka-hud-c">
          <span class="wka-hud-k">검증</span>
          <span class=${`wka-hud-v ${counts.verify ? 'volt' : ''}`}>${counts.verify}</span>
        </div>
        <div class="wka-hud-c">
          <span class="wka-hud-k">미배정</span>
          <span class=${`wka-hud-v ${counts.backlog ? 'warn' : ''}`}>${counts.backlog}</span>
        </div>
        <div class="wka-hud-c">
          <span class="wka-hud-k">할 일</span>
          <span class=${`wka-hud-v ${needTotal ? 'volt' : ''}`}>${needTotal}</span>
        </div>
      </div>

      <div class="wka-scroll">

        <section class="wka-sec" aria-labelledby="wka-h-flagged">
          <div class="wka-h" id="wka-h-flagged" role="heading" aria-level=${3}>
            지금 상황
            ${flagged.length > 0 ? html`<span class="wka-h-n bad">${flagged.length}</span>` : null}
          </div>
          ${flagged.length === 0
            ? html`<div class="wka-calm mono" data-testid="wka-flagged-calm">주의 목표 없음 · 정상 순환</div>`
            : html`
              <div class="wka-list" data-testid="wka-flagged-list">
                ${flagged.map(g => html`
                  <button
                    key=${g.id}
                    type="button"
                    class=${`wka-flag st-${g.cls}`}
                    onClick=${() => onJump(g.id)}
                    data-testid="wka-flagged-item"
                  >
                    <span class=${`wka-flag-tag ${g.cls}`}>${g.lbl}</span>
                    <span class="wka-flag-title">${g.title}</span>
                    ${g.reason ? html`<span class="wka-flag-reason">${g.reason}</span>` : null}
                  </button>
                `)}
              </div>
            `}
        </section>

        <section class="wka-sec" aria-labelledby="wka-h-todo">
          <div class="wka-h" id="wka-h-todo" role="heading" aria-level=${3}>
            해야 할 일
            ${needTotal > 0 ? html`<span class="wka-h-n">${needTotal}</span>` : null}
          </div>
          <div class="wka-list" data-testid="wka-todo-list">
            ${approvals.map(g => html`
              <button
                key=${g.id}
                type="button"
                class="wka-todo approve"
                onClick=${() => onJump(g.id)}
                data-testid="wka-approval-item"
              >
                <span class="wka-todo-k">완료 승인</span>
                <span class="wka-todo-t">${g.title}</span>
                ${g.verifiers.length > 0
                  ? html`<span class="wka-todo-m mono">${g.verifiers.join(' · ')}</span>`
                  : null}
              </button>
            `)}
            ${verifyTasks.map(t => html`
              <button
                key=${t.id}
                type="button"
                class="wka-todo verify"
                onClick=${() => onJump(t.goalId)}
                data-testid="wka-verify-item"
              >
                <span class="wka-todo-k">게이트</span>
                <span class="wka-todo-t">${t.title}</span>
                <span class="wka-todo-m mono">${t.open > 0 ? `${t.open} 미충족` : '검증 대기'}</span>
              </button>
            `)}
            ${blockers.map(t => html`
              <button
                key=${t.id}
                type="button"
                class="wka-todo block"
                onClick=${() => onJump(t.goalId)}
                data-testid="wka-blocker-item"
              >
                <span class="wka-todo-k">차단</span>
                <span class="wka-todo-t">${t.title}</span>
                <span class="wka-todo-m">${t.blocker}</span>
              </button>
            `)}
            ${backlog.length > 0 ? (() => {
              // backlog[0] is safe here: length > 0 is checked above, but
              // TypeScript can't narrow through html`` template literals.
              const firstGoalId = backlog[0]?.goalId ?? ''
              return html`
                <button
                  type="button"
                  class="wka-todo claim"
                  onClick=${() => onJump(firstGoalId)}
                  data-testid="wka-backlog-item"
                >
                  <span class="wka-todo-k">클레임</span>
                  <span class="wka-todo-t">미배정 task ${backlog.length}건</span>
                  <span class="wka-todo-m mono">keeper_task_claim</span>
                </button>
              `
            })() : null}
            ${needTotal === 0
              ? html`<div class="wka-calm mono" data-testid="wka-todo-calm">대기 중인 작업 없음</div>`
              : null}
          </div>
        </section>

        <section class="wka-sec" aria-labelledby="wka-h-recent">
          <div class="wka-h" id="wka-h-recent" role="heading" aria-level=${3}>
            최근 한 일
            ${recent.length > 0 ? html`<span class="wka-h-n dim">${recent.length}</span>` : null}
          </div>
          <div class="wka-list">
            ${recent.length === 0
              ? html`<div class="wka-calm mono" data-testid="wka-recent-calm">완료된 task 없음</div>`
              : recent.map(t => html`
                <button
                  key=${t.id}
                  type="button"
                  class="wka-done"
                  onClick=${() => onJump(t.goalId)}
                  data-testid="wka-recent-item"
                >
                  <span class="wka-done-mark">✓</span>
                  <span class="wka-done-t">${t.title}</span>
                </button>
              `)}
          </div>
        </section>

      </div>
    </aside>
  `
}

function WorkSurfaceV2() {
  // Read showGoalCreate at the top so this component re-renders when the
  // side-panel toggle changes.
  const goalCreateOpen = showGoalCreate.value
  const goalList = goals.value
  const executionTasks = tasks.value
  const goalTreeSnapshot = goalTreeData.value
  const goalStoreTasks = useMemo(
    () => collectGoalTreeTasks(goalTreeSnapshot?.tree ?? []),
    [goalTreeSnapshot],
  )
  const allTasks = useMemo(
    () => mergeTaskSnapshot(goalStoreTasks, executionTasks),
    [goalStoreTasks, executionTasks],
  )
  const treeGoals = useMemo(
    () => flattenGoalTreeNodes(goalTreeSnapshot?.tree ?? []),
    [goalTreeSnapshot],
  )

  const [view, setView] = useState<WorkView>(readStoredWorkView)
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
  // KPI semantics: when a Goal Store tree summary is present, use its active
  // goal count; otherwise fall back to the execution goal list. Task counts are
  // always derived from the merged live task set so execution and tree tasks
  // are counted consistently.
  const totals = useMemo(() => ({
    goals: goalTreeSnapshot?.summary.active_goals ?? goalList.length,
    tasks: liveTasks.length,
    wip: liveTasks.filter(t => t.status === 'in_progress' || t.status === 'claimed').length,
    verify: liveTasks.filter(t => t.status === 'awaiting_verification').length,
    backlog: claimedTasks.filter(t => isClaimableBacklogTask(t)).length,
  }), [goalTreeSnapshot, goalList, liveTasks, claimedTasks])

  // Goal title lookup: prefer execution-side goalList titles, but fall back
  // to Goal Store tree titles so tree-only goals still render context.
  const goalTitleById = useMemo(() => {
    const map = new Map<string, string>()
    for (const g of treeGoals) map.set(g.id, g.title)
    for (const g of goalList) map.set(g.id, g.title)
    return map
  }, [goalList, treeGoals])

  const tasksByGoalId = useMemo(() => {
    const map = new Map<string, Task[]>()
    for (const g of goalList) map.set(g.id, [])
    for (const g of treeGoals) {
      if (!map.has(g.id)) map.set(g.id, [])
    }
    for (const t of claimedTasks) {
      if (t.goal_id) {
        const list = map.get(t.goal_id)
        if (list) list.push(t)
      }
    }
    return map
  }, [goalList, treeGoals, claimedTasks])

  const backlogTasks = useMemo(() => {
    return claimedTasks
      .filter(t => isClaimableBacklogTask(t))
      .map(t => ({
        ...t,
        goalTitle: t.goal_id ? goalTitleById.get(t.goal_id) : undefined,
      }))
  }, [claimedTasks, goalTitleById])

  const toggleGoal = (id: string) => {
    setOpenSet(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // Expand a goal and scroll its card into view in the left column.
  // GoalCard renders with data-goal-id so this selector is stable.
  const jumpToGoal = useCallback((id: string) => {
    setOpenSet(prev => {
      const next = new Set(prev)
      next.add(id)
      return next
    })
    requestAnimationFrame(() => {
      const scroll = document.querySelector('.ov-2col .ov-scroll')
      const card = document.querySelector(`[data-goal-id="${id}"]`)
      if (scroll && card) {
        const r = card.getBoundingClientRect()
        const sr = scroll.getBoundingClientRect()
        scroll.scrollTo({ top: (scroll as HTMLElement).scrollTop + r.top - sr.top - 80, behavior: 'smooth' })
      } else if (card) {
        card.scrollIntoView({ block: 'center', behavior: 'smooth' })
      }
    })
  }, [])

  // ── WorkAside derivations (immutable, phase-enum based) ──────────────────
  // All computed from the same claimedTasks / goalList signals.
  // See WorkAside phase-mapping comment for rationale.

  const wkaFlagged = useMemo((): ReadonlyArray<WkaFlaggedGoal> =>
    goalList
      .filter(isGoalFlagged)
      .map(g => ({
        id: g.id,
        cls: goalPhaseFlagCls(g.phase),
        lbl: goalPhaseFlagLbl(g.phase),
        title: g.title,
        reason: g.last_review_note,
      })),
  [goalList])

  const wkaApprovals = useMemo((): ReadonlyArray<WkaApprovalGoal> =>
    goalList
      .filter(g => g.require_completion_approval === true && g.phase === 'awaiting_approval')
      .map(g => ({
        id: g.id,
        title: g.title,
        verifiers: g.verifier_policy?.principals.map(p => p.id) ?? [],
      })),
  [goalList])

  const wkaVerifyTasks = useMemo((): ReadonlyArray<WkaVerifyTask> =>
    claimedTasks
      .filter(t => t.status === 'awaiting_verification')
      .map(t => ({
        id: t.id,
        title: t.title,
        goalId: t.goal_id ?? '',
        open: taskGateRows(t).filter(r => r.outcome !== 'satisfied').length,
      })),
  [claimedTasks])

  // Live Task has no freeform `blocker` string field; blockerNoteForTask()
  // reads handoff_context.failure_mode / reason.  We surface tasks where
  // that note is non-null (excluding done/awaiting_verification which have
  // their own sections).
  const wkaBlockers = useMemo((): ReadonlyArray<WkaBlockerTask> =>
    claimedTasks
      .filter(t => {
        if (t.status === 'done' || t.status === 'awaiting_verification') return false
        return blockerNoteForTask(t) !== null
      })
      .map(t => ({
        id: t.id,
        title: t.title,
        blocker: blockerNoteForTask(t) ?? '',
        goalId: t.goal_id ?? '',
      })),
  [claimedTasks])

  const wkaBacklog = useMemo((): ReadonlyArray<WkaBacklogTask> =>
    claimedTasks
      .filter(isClaimableBacklogTask)
      .map(t => ({
        id: t.id,
        title: t.title,
        goal: t.goal_id ? (goalTitleById.get(t.goal_id) ?? '') : '',
        goalId: t.goal_id ?? '',
        priority: t.priority ?? 0,
      })),
  [claimedTasks, goalTitleById])

  const wkaRecent = useMemo((): ReadonlyArray<WkaRecentTask> =>
    claimedTasks
      .filter(t => t.status === 'done')
      .map(t => ({
        id: t.id,
        title: t.title,
        goalId: t.goal_id ?? '',
      })),
  [claimedTasks])

  const wkaCounts = useMemo((): WkaCounts => ({
    active: totals.goals,
    wip: totals.wip,
    verify: totals.verify,
    backlog: totals.backlog,
  }), [totals])

  // Flat list of all non-cancelled tasks with goal context injected.
  // Used by KanbanView to group by status column.
  const kanbanTasks = useMemo((): ReadonlyArray<KanbanTask> =>
    claimedTasks
      .filter(t => t.status !== 'cancelled')
      .map(t => ({
        ...t,
        _goalId: t.goal_id ?? '',
        _goalTitle: t.goal_id ? (goalTitleById.get(t.goal_id) ?? WORK_UNLINKED_GOAL_TITLE) : WORK_UNLINKED_GOAL_TITLE,
      })),
  [claimedTasks, goalTitleById])

  const switchView = useCallback((next: WorkView) => {
    setView(next)
    writeStoredWorkView(next)
  }, [])

  // Kanban card → owning goal. Goal cards only render in the list view, so the
  // jump switches to list first, expands the goal, then scrolls once the list
  // has painted (double rAF: view switch + expansion both flush before scroll).
  const jumpToGoalFromKanban = useCallback((id: string) => {
    if (!id) return
    setView('list')
    writeStoredWorkView('list')
    setOpenSet(prev => {
      const next = new Set(prev)
      next.add(id)
      return next
    })
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const scroll = document.querySelector('.ov-2col .ov-scroll')
      const card = document.querySelector(`[data-goal-id="${id}"]`)
      if (scroll && card) {
        const r = card.getBoundingClientRect()
        const sr = scroll.getBoundingClientRect()
        scroll.scrollTo({ top: (scroll as HTMLElement).scrollTop + r.top - sr.top - 80, behavior: 'smooth' })
      } else if (card) {
        card.scrollIntoView({ block: 'center', behavior: 'smooth' })
      }
    }))
  }, [])

  return html`
    <main class=${`ov ov-2col ${goalCreateOpen ? 'ov-with-panel' : ''}`}>
      <div class="ov-scroll">
        <header class="ov-head wk-head">
          <div>
            <span class="ov-eyebrow">GOAL STORE</span>
            <h1>작업 · 목표</h1>
            <p class="ov-sub">Goals · Tasks · Keepers · 우선순위와 검증 상태</p>
          </div>
          <div class="wk-head-r">
            <div class="wk-viewseg" role="tablist" data-testid="work-viewseg">
              <button
                type="button"
                class=${view === 'list' ? 'on' : ''}
                role="tab"
                aria-selected=${view === 'list'}
                data-testid="work-view-list"
                onClick=${() => switchView('list')}
              >리스트</button>
              <button
                type="button"
                class=${view === 'kanban' ? 'on' : ''}
                role="tab"
                aria-selected=${view === 'kanban'}
                data-testid="work-view-kanban"
                onClick=${() => switchView('kanban')}
              >칸반</button>
            </div>
            <button
              type="button"
              class="wk-newgoal"
              data-testid="work-new-goal"
              title="새 목표 생성"
              onClick=${() => { showGoalCreate.value = true }}
            >
              ＋ 새 목표
            </button>
          </div>
        </header>

          <section class="wk-kpis" data-testid="work-kpis">
            <div class="wk-kpi primary">
              <div class="wk-kpi-k">활성 목표</div>
              <div class="wk-kpi-v brass" data-testid="kpi-goals">${totals.goals}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">전체 Task</div>
              <div class="wk-kpi-v" data-testid="kpi-tasks">${totals.tasks}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">진행 중</div>
              <div class=${`wk-kpi-v ${totals.wip > 0 ? 'volt' : ''}`} data-testid="kpi-wip">${totals.wip}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">검증 대기</div>
              <div class=${`wk-kpi-v ${totals.verify > 0 ? 'volt' : ''}`} data-testid="kpi-verify">${totals.verify}</div>
            </div>
            <div class="wk-kpi">
              <div class="wk-kpi-k">미배정</div>
              <div class=${`wk-kpi-v ${totals.backlog > 0 ? 'warn' : ''}`} data-testid="kpi-backlog">${totals.backlog}</div>
            </div>
          </section>

          ${view === 'list' && backlogTasks.length > 0 ? html`
            <section class="wk-backlog" data-testid="work-backlog">
              <div class="wk-backlog-h">
                <span class="wk-backlog-glyph" aria-hidden="true">⊕</span>
                미배정 Task
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

          ${view === 'list'
            ? /* RFC-0294: flat priority-sorted list replaces horizon grouping */
              goalList.length > 0 ? html`
                <div class="wk-list" data-testid="work-goal-list">
                  ${[...goalList]
                    .sort((a, b) => (a.priority ?? GOAL_PRIORITY_MAX) - (b.priority ?? GOAL_PRIORITY_MAX) || (b.updated_at ?? b.created_at ?? '').localeCompare(a.updated_at ?? a.created_at ?? ''))
                    .map(g => html`
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
              ` : null
            : html`
              <${KanbanView}
                kanbanTasks=${kanbanTasks}
                onClaim=${claimTask}
                onJumpGoal=${jumpToGoalFromKanban}
              />
            `}

          <div class="wk-foot mono">목표 지표 · Task 상태 흐름 · keeper 배정 · done은 gate 증거 후 완료 · 미배정 task는 claim</div>
      </div>
      ${goalCreateOpen ? html`<${GoalCreateForm} />` : html`
        <${WorkAside}
          flagged=${wkaFlagged}
          approvals=${wkaApprovals}
          verifyTasks=${wkaVerifyTasks}
          blockers=${wkaBlockers}
          backlog=${wkaBacklog}
          recent=${wkaRecent}
          counts=${wkaCounts}
          onJump=${jumpToGoal}
          onOpenKeeper=${openKeeperWorkspace}
        />
      `}
    </main>
  `
}

export function Work() {
  const current: WorkSection = isWorkSection(route.value.params.section)
    ? route.value.params.section
    : 'work'

  return html`
    <div class="v2-workspace-surface flex min-w-0 flex-col gap-3">
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
  `
}
