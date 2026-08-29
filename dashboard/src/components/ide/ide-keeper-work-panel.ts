import { html } from 'htm/preact'
import type { Goal, Keeper, Task } from '../../types'
import { goals, keepers, tasks } from '../../store'
import { firstNonEmptyString } from '../../lib/format-string'
import { normalizeKeeperBlockerText } from '../../lib/keeper-runtime-display'
import { KeeperBadge } from '../keeper-badge'
import {
  formatProgressPct,
  goalPhaseLabel,
  goalProgressFor,
  type GoalProgress,
} from '../goals/goal-helpers'
import {
  canonicalKeeperName,
  keeperIdentityKeys,
} from '../common/keeper-identity'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { buildCompositeByKeeperKey, fleetCompositeSnapshot } from '../../composite-signals'
import { compositeSnapshotForKeeper } from '../../lib/keeper-composite-lookup'
import type { KeeperCompositeSnapshot } from '../../api/schemas/keeper-composite'

interface IdeKeeperWorkPanelProps {
  readonly keeperName: string
}

interface KeeperWorkSummary {
  readonly displayName: string
  readonly keeper: Keeper | null
  readonly currentTaskId: string | null
  readonly currentGoalId: string | null
  readonly currentTask: Task | null
  readonly activeTasks: ReadonlyArray<Task>
  readonly activeTaskCount: number
  readonly terminalCode: string | null
  readonly terminalSummary: string | null
  readonly nextAction: string | null
  readonly recentOutput: string | null
  readonly recentTools: ReadonlyArray<string>
  readonly runtimeBlocker: string | null
}

const EMPTY_TOOLS: ReadonlyArray<string> = []
const QUEUED_TASK_STYLE = {
  display: 'grid',
  gap: 'var(--sp-1)',
  minWidth: 0,
  paddingTop: 'var(--sp-2)',
  borderTop: '1px solid var(--color-border-divider)',
}
export function IdeKeeperWorkPanel({ keeperName }: IdeKeeperWorkPanelProps) {
  const summary = keeperWorkSummary(keeperName, keepers.value, tasks.value)
  const keeper = summary.keeper
  const currentTask = summary.currentTask
  const currentGoal = summary.currentGoalId
    ? goals.value.find(goal => goal.id === summary.currentGoalId) ?? null
    : null
  const currentGoalProgress = summary.currentGoalId
    ? goalProgressFor(summary.currentGoalId)
    : null
  const queuedTasks = queuedActiveTasks(summary.activeTasks, currentTask)
  const attention = Boolean(
    keeper?.needs_attention
    || keeper?.trust?.needs_attention
    || summary.terminalCode
    || summary.runtimeBlocker,
  )

  // task-1740 C3: the live-turn fields (model / in-flight tools / last
  // skip / turn attempts / board cursor) are read from the composite snapshot
  // SSOT (`/api/v1/keepers/:name/composite` via `fleetCompositeSnapshot`),
  // not re-derived from the global keepers/tasks store. `.value` access
  // auto-subscribes this component to composite freshness, mirroring the
  // `keepers.value` / `tasks.value` reads above.
  const composite = compositeSnapshotForKeeper(
    keeper,
    buildCompositeByKeeperKey(fleetCompositeSnapshot.value),
  )

  return html`
    <section
      class="ide-keeper-work"
      role="region"
      aria-label="KEEPER WORK"
      data-attention=${attention ? 'true' : 'false'}
    >
      <div class="ide-keeper-work-head">
        <span>KEEPER WORK</span>
        <span>
          ${summary.displayName
            ? html`<${KeeperBadge} id=${summary.displayName} variant="full" size="sm" />`
            : 'all keepers'}
        </span>
      </div>
      <div class="ide-keeper-work-body">
        <div class="ide-keeper-work-strip">
          ${WorkMetric('phase', keeper?.phase ?? keeper?.status ?? 'unknown')}
          ${WorkMetric('task', summary.currentTaskId ?? 'none')}
          ${WorkMetric('goal', summary.currentGoalId ?? 'none')}
          ${WorkMetric('active', String(summary.activeTaskCount))}
        </div>
        ${LiveTurnStrip(composite)}
        ${currentTask
          ? html`
            <div class="ide-keeper-work-card v2-ide-card">
              <div class="ide-keeper-work-card-top">
                <span>${currentTask.id}</span>
                <span>${currentTask.status ?? 'unknown'}</span>
              </div>
              <strong title=${currentTask.title}>${currentTask.title}</strong>
              ${TaskRouteLinks(currentTask, summary.currentGoalId, summary.displayName)}
            </div>
          `
          : html`<div class="ide-keeper-work-empty">no active keeper task in dashboard state</div>`}
        ${QueuedTaskCards(queuedTasks, summary.currentGoalId, summary.displayName)}
        ${currentGoal
          ? GoalProgressCard(currentGoal, currentGoalProgress, summary.currentTaskId)
          : summary.currentGoalId
            ? html`
              <div class="ide-keeper-work-goal v2-ide-card" role="status">
                <div class="ide-keeper-work-card-top">
                  <span>GOAL PROGRESS</span>
                  <span>${summary.currentGoalId}</span>
                </div>
                <strong>goal row not present in dashboard state</strong>
                ${GoalRouteLinks(summary.currentGoalId, summary.currentTaskId)}
              </div>
            `
            : null}
        ${RuntimeBlock(summary)}
        ${summary.recentOutput
          ? html`<p class="ide-keeper-work-output">${summary.recentOutput}</p>`
          : null}
        ${summary.recentTools.length > 0
          ? html`
            <div class="ide-keeper-work-tools" aria-label="Recent keeper tools">
              ${summary.recentTools.slice(0, 5).map(tool => html`<span>${tool}</span>`)}
            </div>
          `
          : null}
      </div>
    </section>
  `
}

function QueuedTaskCards(
  tasks: ReadonlyArray<Task>,
  fallbackGoalId: string | null,
  keeperId: string,
) {
  if (tasks.length === 0) return null
  const shownTasks = tasks.slice(0, 3)
  const hiddenCount = Math.max(0, tasks.length - shownTasks.length)
  return html`
    <div class="ide-keeper-work-card v2-ide-card" aria-label="Keeper active task queue">
      <div class="ide-keeper-work-card-top">
        <span>ACTIVE QUEUE</span>
        <span>${tasks.length} queued</span>
      </div>
      ${shownTasks.map(task => html`
        <div key=${task.id} style=${QUEUED_TASK_STYLE}>
          <div class="ide-keeper-work-card-top">
            <span>${task.id}</span>
            <span>${task.status ?? 'unknown'}</span>
          </div>
          <strong title=${task.title}>${task.title}</strong>
          ${TaskRouteLinks(task, fallbackGoalId, keeperId)}
        </div>
      `)}
      ${hiddenCount > 0
        ? html`<span>${hiddenCount} more active ${hiddenCount === 1 ? 'task' : 'tasks'}</span>`
        : null}
    </div>
  `
}

function GoalProgressCard(
  goal: Goal,
  progress: GoalProgress | null,
  taskId: string | null,
) {
  const taskCountLabel = progress ? formatProgressPct(progress) : 'no linked tasks'
  const pctValue = progress ? Math.round(progress.ratio * 100) : 0
  return html`
    <div class="ide-keeper-work-goal v2-ide-card" role="status" aria-label=${`Goal ${goal.id} linked task count ${taskCountLabel}`}>
      <div class="ide-keeper-work-card-top">
        <span>GOAL TASKS</span>
        <span>${goalPhaseLabel(goal.phase)}</span>
      </div>
      <strong title=${goal.title}>${goal.title}</strong>
      <div class="ide-keeper-work-goal-bar" aria-hidden="true" title="끝난 하위 작업 수. 목표 지표를 잰 값이 아닙니다.">
        <span style=${{ width: `${pctValue}%` }} />
      </div>
      <div class="ide-keeper-work-goal-meta">
        <span>${taskCountLabel}</span>
        ${goal.metric ? html`<span title=${goal.metric}>${goal.metric}</span>` : null}
        ${goal.target_value ? html`<span title=${goal.target_value}>target ${goal.target_value}</span>` : null}
      </div>
      ${GoalRouteLinks(goal.id, taskId)}
    </div>
  `
}

function GoalRouteLinks(goalId: string, taskId: string | null) {
  return KeeperWorkRouteLinks(routeLinksForContext({
    goalId,
    taskId: taskId ?? undefined,
  }), 'Keeper work planning links')
}

function TaskRouteLinks(task: Task, fallbackGoalId: string | null, keeperId: string) {
  const execution = taskExecutionRouteContext(task)
  return KeeperWorkRouteLinks(routeLinksForContext({
    goalId: task.goal_id ?? fallbackGoalId ?? undefined,
    taskId: task.id,
    sessionId: execution.sessionId ?? undefined,
    operationId: execution.operationId ?? undefined,
    telemetryQuery: execution.telemetryQuery ?? undefined,
    telemetry: execution.hasTelemetry,
    keeperId,
  }), 'Keeper task operational links')
}

function KeeperWorkRouteLinks(
  links: ReadonlyArray<IdeContextRouteLink>,
  label: string,
) {
  if (links.length === 0) return null
  return html`
    <div class="ide-keeper-work-links" aria-label=${label}>
      <span
        class="ide-keeper-work-route-count"
        title=${`${links.length} linked keeper work context routes`}
        aria-label=${`${links.length} linked keeper work context routes`}
      >
        CTX ${links.length}
      </span>
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          class="v2-ide-action"
          title=${link.evidence}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    </div>
  `
}

function taskExecutionRouteContext(task: Task): {
  readonly sessionId: string | null
  readonly operationId: string | null
  readonly telemetryQuery: string | null
  readonly hasTelemetry: boolean
} {
  const sessionId = firstNonEmptyString(task.execution_links?.session_id)
  const operationId = firstNonEmptyString(task.execution_links?.operation_id)
  return {
    sessionId,
    operationId,
    telemetryQuery: firstNonEmptyString(operationId, sessionId),
    hasTelemetry: Boolean(sessionId || operationId),
  }
}

function WorkMetric(label: string, value: string) {
  return html`
    <span class="ide-keeper-work-metric">
      <span>${label}</span>
      <strong title=${value}>${value}</strong>
    </span>
  `
}

// task-1740 C3: render the keeper's live-turn state from the composite
// snapshot SSOT. Every value below is read from `KeeperCompositeSnapshot`
// (the drift-guarded schema), never re-derived from the global store.
// When no snapshot resolves (pinned backend that predates these fields,
// or fleet composite not yet hydrated) the strip is omitted rather than
// falling back to a store-derived guess, keeping the source singular.
function LiveTurnStrip(composite: KeeperCompositeSnapshot | null) {
  if (!composite) return null
  const liveTurn = composite.live_turn ?? null
  const lastSkip = composite.last_skip ?? null
  const turnAttempt = composite.turn_attempt ?? null
  const boardCursor = composite.board_cursor ?? null
  const toolCount = liveTurn?.active_tool_count
  const firstSkipReason = lastSkip?.reasons[0] ?? null
  return html`
    <div class="ide-keeper-work-strip" aria-label="Keeper live turn">
      ${WorkMetric('model', liveTurn?.selected_model ?? '—')}
      ${WorkMetric('tools', toolCount != null ? String(toolCount) : '—')}
      ${WorkMetric('skip', firstSkipReason ?? 'none')}
      ${WorkMetric('attempts', turnAttempt ? String(turnAttempt.attempts) : 'none')}
      ${WorkMetric('board', boardCursor?.post_id ?? 'none')}
    </div>
  `
}

function RuntimeBlock(summary: KeeperWorkSummary) {
  const headline = summary.terminalSummary ?? summary.runtimeBlocker
  const action = summary.nextAction
  if (!headline && !action) return null
  return html`
    <div class="ide-keeper-work-runtime" role="status">
      <div>
        <span>${summary.terminalCode ?? '(unknown terminal code)'}</span>
        <strong>${headline ?? action}</strong>
      </div>
      ${action ? html`<span>${action}</span>` : null}
    </div>
  `
}

export function keeperWorkSummary(
  keeperName: string,
  keeperList: ReadonlyArray<Keeper>,
  taskList: ReadonlyArray<Task>,
): KeeperWorkSummary {
  const displayName = normalizedKeeperName(keeperName)
  const keeper = findKeeper(displayName, keeperList)
  const assigneeTasks = taskList
    .filter(task => taskMatchesKeeper(task, displayName, keeper))
    .filter(task => task.status !== 'done' && task.status !== 'cancelled')
  const activeTasks = uniqTasks(assigneeTasks)
  const currentTaskId = firstNonEmptyString(activeTasks[0]?.id)
  const currentTask = currentTaskId
    ? activeTasks.find(task => task.id === currentTaskId) ?? null
    : activeTasks[0] ?? null
  const currentGoalId = firstNonEmptyString(
    currentTask?.goal_id,
    activeTasks.find(task => task.goal_id)?.goal_id,
  )
  const trust = keeper?.trust ?? null
  const latestTerminal = trust?.latest_terminal_reason ?? null
  const terminalSummary = normalizeKeeperBlockerText(
    firstNonEmptyString(
      latestTerminal?.summary,
      keeper?.runtime_blocker_summary,
      trust?.attention_reason,
      keeper?.attention_reason,
    ),
  )
  const runtimeBlocker = normalizeKeeperBlockerText(
    keeper?.runtime_blocker_summary,
  )
  return {
    displayName,
    keeper,
    currentTaskId,
    currentGoalId,
    currentTask,
    activeTasks,
    activeTaskCount: currentTaskId && activeTasks.length === 0 ? 1 : activeTasks.length,
    terminalCode: firstNonEmptyString(latestTerminal?.code, keeper?.runtime_blocker_class),
    terminalSummary,
    nextAction: firstNonEmptyString(
      latestTerminal?.next_action,
      trust?.latest_next_action,
      trust?.next_human_action,
      keeper?.next_human_action,
    ),
    recentOutput: firstNonEmptyString(
      keeper?.recent_output_preview,
      keeper?.recent_input_preview,
      keeper?.last_proactive_preview,
    ),
    recentTools: keeper?.recent_tool_names ?? keeper?.latest_tool_names ?? EMPTY_TOOLS,
    runtimeBlocker,
  }
}

function findKeeper(name: string, keeperList: ReadonlyArray<Keeper>): Keeper | null {
  const target = name.toLowerCase()
  if (!target) return keeperList[0] ?? null
  return keeperList.find(keeper => {
    const keys = keeperIdentityKeys(keeper.keeper_id, keeper.name)
    return keys.includes(target) || keys.includes(`keeper:${target}`)
  }) ?? null
}

function taskMatchesKeeper(task: Task, keeperName: string, keeper: Keeper | null): boolean {
  if (!task.assignee) return false
  const taskKeys = assigneeKeys(task.assignee)
  const keeperKeys = new Set([
    ...keeperIdentityKeys(keeper?.keeper_id, keeper?.name ?? keeperName),
    ...assigneeKeys(keeperName),
  ])
  return taskKeys.some(key => keeperKeys.has(key))
}

function assigneeKeys(value: string): string[] {
  const raw = value.trim().toLowerCase()
  const canonical = canonicalKeeperName(value)?.toLowerCase() ?? null
  return [
    raw,
    canonical,
    canonical ? `keeper:${canonical}` : null,
  ].filter((item): item is string => Boolean(item))
}

function uniqTasks(taskList: ReadonlyArray<Task>): Task[] {
  const seen = new Set<string>()
  const result: Task[] = []
  for (const task of taskList) {
    if (task.status === 'done' || task.status === 'cancelled' || seen.has(task.id)) continue
    seen.add(task.id)
    result.push(task)
  }
  return result
}

function queuedActiveTasks(
  taskList: ReadonlyArray<Task>,
  currentTask: Task | null,
): ReadonlyArray<Task> {
  if (!currentTask) return taskList
  return taskList.filter(task => task.id !== currentTask.id)
}

function normalizedKeeperName(value: string): string {
  return canonicalKeeperName(value) ?? value.trim()
}

