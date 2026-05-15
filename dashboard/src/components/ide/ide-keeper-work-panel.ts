import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { Goal, Keeper, Task } from '../../types'
import { goals, keepers, tasks } from '../../store'
import { KeeperBadge } from '../keeper-badge'
import {
  formatProgressPct,
  goalPhaseLabel,
  goalProgressFor,
  horizonLabel,
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
import { cursorOverlaySignal, getKeeperColor, type KeeperCursor } from './keeper-cursor-overlay'

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
const QUEUED_TASK_META_STYLE = {
  overflow: 'hidden',
  color: 'var(--color-fg-muted)',
  fontSize: 'var(--fs-11)',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
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

  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  const cursor = resolveKeeperCursor(keeperName, overlay.cursors)

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
        ${currentTask
          ? html`
            <div class="ide-keeper-work-card">
              <div class="ide-keeper-work-card-top">
                <span>${currentTask.id}</span>
                <span>${currentTask.status ?? 'unknown'}</span>
              </div>
              <strong title=${currentTask.title}>${currentTask.title}</strong>
              ${currentTask.worktree
                ? html`<span title=${currentTask.worktree.path}>${currentTask.worktree.branch} · ${currentTask.worktree.repo_name}</span>`
                : null}
              ${TaskRouteLinks(currentTask, summary.currentGoalId, summary.displayName)}
            </div>
          `
          : summary.currentTaskId
            ? html`
              <div class="ide-keeper-work-card">
                <div class="ide-keeper-work-card-top">
                  <span>${summary.currentTaskId}</span>
                  <span>runtime</span>
                </div>
                <strong>keeper runtime current task</strong>
                <span>task row not present in execution projection</span>
                ${RuntimeTaskRouteLinks(summary.currentTaskId, summary.currentGoalId, summary.displayName)}
              </div>
            `
          : html`<div class="ide-keeper-work-empty">no active keeper task in dashboard state</div>`}
        ${QueuedTaskCards(queuedTasks, summary.currentGoalId, summary.displayName)}
        ${currentGoal
          ? GoalProgressCard(currentGoal, currentGoalProgress, summary.currentTaskId)
          : summary.currentGoalId
            ? html`
              <div class="ide-keeper-work-goal" role="status">
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
        ${PresenceIndicator(cursor)}
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
    <div class="ide-keeper-work-card" aria-label="Keeper active task queue">
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
          ${task.worktree
            ? html`<span style=${QUEUED_TASK_META_STYLE} title=${task.worktree.path}>${task.worktree.branch} · ${task.worktree.repo_name}</span>`
            : null}
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
  const pctLabel = progress ? formatProgressPct(progress) : '0%'
  const pctValue = progress ? Math.round(progress.ratio * 100) : 0
  return html`
    <div class="ide-keeper-work-goal" role="status" aria-label=${`Goal ${goal.id} progress ${pctLabel}`}>
      <div class="ide-keeper-work-card-top">
        <span>GOAL PROGRESS</span>
        <span>${horizonLabel(goal.horizon)} · ${goalPhaseLabel(goal.phase)}</span>
      </div>
      <strong title=${goal.title}>${goal.title}</strong>
      <div class="ide-keeper-work-goal-bar" aria-hidden="true">
        <span style=${{ width: `${pctValue}%` }} />
      </div>
      <div class="ide-keeper-work-goal-meta">
        <span>${progress ? `${progress.done}/${progress.total} tasks` : '0/0 tasks'}</span>
        <span>${pctLabel}</span>
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
    gitRef: task.worktree?.branch,
    sessionId: execution.sessionId ?? undefined,
    operationId: execution.operationId ?? undefined,
    telemetryQuery: execution.telemetryQuery ?? undefined,
    telemetry: execution.hasTelemetry,
    keeperId,
  }), 'Keeper task operational links')
}

function RuntimeTaskRouteLinks(taskId: string, goalId: string | null, keeperId: string) {
  return KeeperWorkRouteLinks(routeLinksForContext({
    goalId: goalId ?? undefined,
    taskId,
    keeperId,
  }), 'Keeper runtime task links')
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
  const sessionId = firstNonEmpty(
    task.execution_links?.session_id,
    task.contract?.links?.session_id,
  )
  const operationId = firstNonEmpty(
    task.execution_links?.operation_id,
    task.contract?.links?.operation_id,
  )
  const autoresearchLoopId = firstNonEmpty(
    task.execution_links?.autoresearch_loop_id,
    task.contract?.links?.autoresearch_loop_id,
  )
  return {
    sessionId,
    operationId,
    telemetryQuery: firstNonEmpty(operationId, sessionId, autoresearchLoopId),
    hasTelemetry: Boolean(sessionId || operationId || autoresearchLoopId),
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
  const explicitCurrentTaskId = firstNonEmpty(keeper?.agent?.current_task)
  const assigneeTasks = taskList
    .filter(task => taskMatchesKeeper(task, displayName, keeper))
    .filter(task => task.status !== 'done' && task.status !== 'cancelled')
  const currentTaskById = explicitCurrentTaskId
    ? taskList.find(task => task.id === explicitCurrentTaskId) ?? null
    : null
  const activeTasks = uniqTasks(currentTaskById ? [currentTaskById, ...assigneeTasks] : assigneeTasks)
  const currentTaskId = firstNonEmpty(
    explicitCurrentTaskId,
    activeTasks[0]?.id,
  )
  const currentTask = currentTaskId
    ? activeTasks.find(task => task.id === currentTaskId) ?? null
    : activeTasks[0] ?? null
  const currentGoalId = firstNonEmpty(
    currentTask?.goal_id,
    activeTasks.find(task => task.goal_id)?.goal_id,
  )
  const trust = keeper?.trust ?? null
  const latestTerminal = trust?.latest_terminal_reason ?? null
  return {
    displayName,
    keeper,
    currentTaskId,
    currentGoalId,
    currentTask,
    activeTasks,
    activeTaskCount: currentTaskId && activeTasks.length === 0 ? 1 : activeTasks.length,
    terminalCode: firstNonEmpty(latestTerminal?.code, keeper?.runtime_blocker_class),
    terminalSummary: firstNonEmpty(
      latestTerminal?.summary,
      keeper?.runtime_blocker_summary,
      trust?.attention_reason,
      keeper?.attention_reason,
    ),
    nextAction: firstNonEmpty(
      latestTerminal?.next_action,
      trust?.latest_next_action,
      trust?.next_human_action,
      keeper?.next_human_action,
    ),
    recentOutput: firstNonEmpty(keeper?.recent_output_preview, keeper?.recent_input_preview),
    recentTools: keeper?.recent_tool_names ?? keeper?.latest_tool_names ?? EMPTY_TOOLS,
    runtimeBlocker: firstNonEmpty(keeper?.runtime_blocker_summary, keeper?.last_blocker),
  }
}

function findKeeper(name: string, keeperList: ReadonlyArray<Keeper>): Keeper | null {
  const target = name.toLowerCase()
  if (!target) return keeperList[0] ?? null
  return keeperList.find(keeper => {
    const keys = keeperIdentityKeys(keeper.keeper_id, keeper.name, keeper.agent_name)
    return keys.includes(target) || keys.includes(`keeper:${target}`)
  }) ?? null
}

function taskMatchesKeeper(task: Task, keeperName: string, keeper: Keeper | null): boolean {
  if (!task.assignee) return false
  const taskKeys = assigneeKeys(task.assignee)
  const keeperKeys = new Set([
    ...keeperIdentityKeys(keeper?.keeper_id, keeper?.name ?? keeperName, keeper?.agent_name),
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

function firstNonEmpty(...values: ReadonlyArray<string | null | undefined>): string | null {
  for (const value of values) {
    const trimmed = value?.trim()
    if (trimmed) return trimmed
  }
  return null
}

function resolveKeeperCursor(
  keeperName: string,
  cursors: Map<string, KeeperCursor>,
): KeeperCursor | null {
  if (!keeperName) return null
  const target = keeperName.toLowerCase().trim()
  // 1. Exact key match (cursorOverlaySignal map keys are canonical keeper ids).
  // 2. Cursor payload's own keeper_id (server-emitted identity, may differ
  //    from the map key when the SSE source key is e.g. a session id).
  // Substring/includes fallbacks were removed because they pick the wrong
  // cursor when ids share prefixes/suffixes (e.g. "kim" matches "kimchi").
  for (const [id, cursor] of cursors) {
    if (id.toLowerCase() === target) return cursor
    if (cursor.keeper_id && cursor.keeper_id.toLowerCase() === target) return cursor
  }
  return null
}

function PresenceIndicator(cursor: KeeperCursor | null) {
  if (!cursor) return null
  // Defensive: SSE parser can emit file_path='' (not-yet-set) and
  // last_update timestamps that are 0 or in the future. Without these
  // guards the card renders ":<line>" with no filename and "-99m ago".
  if (!cursor.file_path) return null
  const color = getKeeperColor(cursor.keeper_id)
  const fileName = cursor.file_path.split('/').pop() ?? cursor.file_path
  const rawAge = Math.round((Date.now() - cursor.last_update) / 1000)
  const ageSec = Math.max(0, rawAge)
  const isEditing = cursor.focus_mode === 'editing'
  return html`
    <div
      class="ide-keeper-presence"
      role="status"
      aria-label="Keeper presence"
      style=${{
        display: 'grid',
        gap: 'var(--sp-1)',
        padding: 'var(--sp-2)',
        background: 'var(--color-bg-surface)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
      }}
    >
      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}>
        <span
          aria-hidden="true"
          style=${{
            width: '6px',
            height: '6px',
            borderRadius: '50%',
            background: color.cursor,
            display: 'inline-block',
            boxShadow: isEditing ? `0 0 4px ${color.cursor}` : 'none',
          }}
        />
        <span style=${{
          fontSize: 'var(--fs-11)',
          letterSpacing: '0.05em',
          color: isEditing ? 'var(--color-status-err)' : 'var(--color-fg-muted)',
          fontWeight: 600,
        }}>${cursor.focus_mode.toUpperCase()}</span>
        ${cursor.tool_name
          ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-secondary)', marginLeft: 'auto' }}>${cursor.tool_name}</span>`
          : null}
      </div>
      <div style=${{
        fontSize: 'var(--fs-11)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-fg-secondary)',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      }} title=${cursor.file_path}>
        ${fileName}:${cursor.line}${cursor.selection_end ? `-${cursor.selection_end.line}` : ''}
      </div>
      ${cursor.turn != null
        ? html`
          <div style=${{ display: 'flex', gap: 'var(--sp-2)', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
            <span>turn ${cursor.turn}</span>
            <span style=${{ marginLeft: 'auto' }}>${ageSec < 60 ? `${ageSec}s ago` : `${Math.round(ageSec / 60)}m ago`}</span>
          </div>
        `
        : null}
    </div>
  `
}
