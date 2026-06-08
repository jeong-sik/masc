import type { Goal, Task } from '../../types'
import { goals, tasks } from '../../store'
import {
  formatProgressPct,
  goalPhaseLabel,
  horizonLabel,
  type GoalProgress,
} from '../goals/goal-helpers'
import {
  routeLinksForContext,
  type IdeContextRouteContext,
  type IdeContextRouteLink,
} from './ide-context-route-links'
import {
  normalizeIdeContextFilePath,
  normalizeIdeContextLine,
} from './ide-state'
import type { RunActivityContext, RunActivityEvent } from './run-activity-store'

interface ProgressSurfaceSpec {
  readonly key: keyof RunActivityContext
  readonly label: string
  readonly routeLabel?: string
}

const PROGRESS_SURFACES: ReadonlyArray<ProgressSurfaceSpec> = [
  { key: 'goal_id', label: 'Goal' },
  { key: 'task_id', label: 'Task' },
  { key: 'board_post_id', label: 'Board' },
  { key: 'comment_id', label: 'Comment' },
  { key: 'pr_id', label: 'PR' },
  { key: 'git_ref', label: 'Git' },
  { key: 'log_id', label: 'Log' },
  { key: 'session_id', label: 'Session', routeLabel: 'Telemetry' },
  { key: 'operation_id', label: 'Operation', routeLabel: 'Telemetry' },
  { key: 'worker_run_id', label: 'Run', routeLabel: 'Telemetry' },
]

export interface IdeRunProgressSummary {
  readonly totalEvents: number
  readonly currentFileEvents: number
  readonly linkedEvents: number
  readonly linkedCoveragePercent: number
  readonly linkedCoverageLabel: string
  readonly keeperTotalCount: number
  readonly latestAgeLabel: string
  readonly surfaceCounts: ReadonlyArray<IdeRunProgressSurfaceCount>
  readonly keeperCounts: ReadonlyArray<IdeRunProgressKeeperCount>
  readonly activeGoal: IdeRunProgressGoal | null
}

export interface IdeRunProgressSurfaceCount {
  readonly label: string
  readonly count: number
  readonly routeLink: IdeContextRouteLink | null
}

export interface IdeRunProgressKeeperCount {
  readonly keeper_id: string
  readonly count: number
  readonly routeLink: IdeContextRouteLink | null
}

export interface IdeRunProgressGoal {
  readonly goalId: string
  readonly taskId: string | null
  readonly title: string
  readonly horizon: string
  readonly phase: string
  readonly progress: GoalProgress
  readonly progressLabel: string
}

export function deriveIdeRunProgressSummary(
  events: ReadonlyArray<RunActivityEvent>,
  activeFile: string,
  goalList: ReadonlyArray<Goal> = goals.value,
  taskList: ReadonlyArray<Task> = tasks.value,
): IdeRunProgressSummary {
  const activeFilePath = normalizeIdeContextFilePath(activeFile)
  const currentFileEvents = activeFilePath === null
    ? 0
    : events.filter(event =>
      event.context?.file_path !== undefined
      && normalizeIdeContextFilePath(event.context.file_path) === activeFilePath,
    ).length
  const linkedEvents = events.filter(event => event.context !== undefined).length
  const linkedCoveragePercent = events.length === 0
    ? 0
    : Math.round((linkedEvents / events.length) * 100)
  const surfaceCounts: IdeRunProgressSurfaceCount[] = PROGRESS_SURFACES.map(surface => {
    const matchingEvents = events.filter(event => event.context?.[surface.key])
    return {
      label: surface.label,
      count: matchingEvents.length,
      routeLink: latestSurfaceRouteLink(surface.routeLabel ?? surface.label, matchingEvents),
    }
  })
  surfaceCounts.push({
    label: 'Telemetry',
    count: events.length,
    routeLink: latestSurfaceRouteLink('Telemetry', events),
  })
  const keeperStats = new Map<string, { count: number; latestEvent: RunActivityEvent }>()
  for (const event of events) {
    const current = keeperStats.get(event.keeper_id)
    if (!current) {
      keeperStats.set(event.keeper_id, { count: 1, latestEvent: event })
      continue
    }
    keeperStats.set(event.keeper_id, {
      count: current.count + 1,
      latestEvent: isLaterRunActivityEvent(event, current.latestEvent) ? event : current.latestEvent,
    })
  }
  const keeperEntries = [...keeperStats.entries()]
    .sort((left, right) => right[1].count - left[1].count || left[0].localeCompare(right[0]))
  const keeperCounts = keeperEntries
    .slice(0, 3)
    .map(([keeper_id, stat]) => ({
      keeper_id,
      count: stat.count,
      routeLink: keeperProgressRouteLink(stat.latestEvent),
    }))
  return {
    totalEvents: events.length,
    currentFileEvents,
    linkedEvents,
    linkedCoveragePercent,
    linkedCoverageLabel: `${linkedCoveragePercent}%`,
    keeperTotalCount: keeperEntries.length,
    latestAgeLabel: latestAgeLabel(events),
    surfaceCounts,
    keeperCounts,
    activeGoal: activeRunGoal(events, goalList, taskList),
  }
}

function activeRunGoal(
  events: ReadonlyArray<RunActivityEvent>,
  goalList: ReadonlyArray<Goal>,
  taskList: ReadonlyArray<Task>,
): IdeRunProgressGoal | null {
  const tasksById = new Map(taskList.map(task => [task.id, task]))
  const goalHits = new Map<string, { count: number; latestMs: number; taskId: string | null }>()

  for (const event of events) {
    const taskId = cleanContextId(event.context?.task_id)
    const taskGoalId = taskId ? cleanContextId(tasksById.get(taskId)?.goal_id) : null
    const goalId = cleanContextId(event.context?.goal_id) ?? taskGoalId
    if (!goalId) continue
    const current = goalHits.get(goalId) ?? { count: 0, latestMs: Number.NEGATIVE_INFINITY, taskId: null }
    goalHits.set(goalId, {
      count: current.count + 1,
      latestMs: Math.max(current.latestMs, event.timestamp_ms),
      taskId: current.taskId ?? taskId,
    })
  }

  const [goalId, hit] = [...goalHits.entries()]
    .sort((left, right) =>
      right[1].count - left[1].count
      || right[1].latestMs - left[1].latestMs
      || left[0].localeCompare(right[0]),
    )[0] ?? []
  if (!goalId || !hit) return null

  const goal = goalList.find(candidate => candidate.id === goalId) ?? null
  const progress = runGoalProgress(goalId, taskList)
  return {
    goalId,
    taskId: hit.taskId,
    title: goal?.title ?? goalId,
    horizon: goal ? horizonLabel(goal.horizon) : 'unknown',
    phase: goal ? goalPhaseLabel(goal.phase) : 'unknown',
    progress,
    progressLabel: formatProgressPct(progress),
  }
}

function runGoalProgress(goalId: string, taskList: ReadonlyArray<Task>): GoalProgress {
  const relevantTasks = taskList.filter(task =>
    task.goal_id === goalId && task.status !== 'cancelled',
  )
  const done = relevantTasks.filter(task => task.status === 'done').length
  const total = relevantTasks.length
  return {
    done,
    total,
    ratio: total > 0 ? done / total : 0,
  }
}

function cleanContextId(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function latestAgeLabel(events: ReadonlyArray<RunActivityEvent>): string {
  const latest = events[0]
  if (!latest) return 'idle'
  const ageMs = Math.max(0, Date.now() - latest.timestamp_ms)
  const seconds = Math.floor(ageMs / 1000)
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ago`
}

function latestSurfaceRouteLink(
  label: string,
  events: ReadonlyArray<RunActivityEvent>,
): IdeContextRouteLink | null {
  const latestEvent = latestRunActivityEvent(events)
  if (!latestEvent) return null
  return activityRouteLinks(latestEvent).find(link => link.label === label) ?? null
}

function keeperProgressRouteLink(event: RunActivityEvent): IdeContextRouteLink | null {
  const links = activityRouteLinks(event)
  return links.find(link => link.label === 'Keeper')
    ?? links.find(link => link.label === 'Telemetry')
    ?? links[0]
    ?? null
}

function latestRunActivityEvent(events: ReadonlyArray<RunActivityEvent>): RunActivityEvent | null {
  let latest: RunActivityEvent | null = null
  for (const event of events) {
    if (latest === null || isLaterRunActivityEvent(event, latest)) {
      latest = event
    }
  }
  return latest
}

function isLaterRunActivityEvent(candidate: RunActivityEvent, current: RunActivityEvent): boolean {
  return candidate.timestamp_ms > current.timestamp_ms
    || (candidate.timestamp_ms === current.timestamp_ms && candidate.id > current.id)
}

export function activityRouteLinks(item: RunActivityEvent): ReadonlyArray<IdeContextRouteLink> {
  return routeLinksForContext(activityRouteContext(item))
}

export function activityRouteContext(item: RunActivityEvent): IdeContextRouteContext {
  const eventContextFile = item.context?.file_path
  const eventFocusFile = eventContextFile === undefined ? null : normalizeIdeContextFilePath(eventContextFile)
  return {
    filePath: eventFocusFile ?? undefined,
    line: normalizeIdeContextLine(item.context?.line),
    surface: activityContextSurface(item),
    label: item.detail ?? `${item.verb} ${item.target}`,
    sourceId: item.id,
    goalId: item.context?.goal_id,
    taskId: item.context?.task_id,
    boardPostId: item.context?.board_post_id,
    commentId: item.context?.comment_id,
    prId: item.context?.pr_id,
    gitRef: item.context?.git_ref,
    logId: item.context?.log_id,
    sessionId: item.context?.session_id,
    operationId: item.context?.operation_id,
    workerRunId: item.context?.worker_run_id,
    keeperId: item.keeper_id,
    telemetry: true,
  }
}

export function activityContextSurface(item: RunActivityEvent): string {
  if (item.context?.pr_id) return 'PR'
  if (item.context?.board_post_id) return 'Board'
  if (item.context?.goal_id) return 'Goal'
  if (item.context?.task_id) return 'Task'
  if (item.context?.git_ref) return 'Git'
  if (item.context?.log_id) return 'Log'
  return 'Activity'
}
