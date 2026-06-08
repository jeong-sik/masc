import type { TabId } from '../../types'
import { auditLogRouteParams } from '../cost/cost-types'
import {
  normalizeIdeContextFilePath,
  normalizeIdeContextLine,
} from './ide-state'

export interface IdeContextRouteLink {
  readonly id: string
  readonly label: string
  readonly tab: TabId
  readonly params: Record<string, string>
  readonly evidence: string
}

export interface IdeContextRouteContext {
  readonly filePath?: string
  readonly line?: number
  readonly surface?: string
  readonly label?: string
  readonly sourceId?: string
  readonly goalId?: string
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
  readonly telemetryQuery?: string
  readonly keeperId?: string
  readonly telemetry?: boolean
}

const MAX_CONTEXT_ROUTE_LINKS = 10

export function routeLinksForContext(
  context: IdeContextRouteContext,
): ReadonlyArray<IdeContextRouteLink> {
  const links: IdeContextRouteLink[] = []
  const add = (link: IdeContextRouteLink): void => {
    if (links.some(existing => existing.id === link.id)) return
    links.push(link)
  }
  const keeperId = cleanId(context.keeperId)
  const filePath = context.filePath ? normalizeIdeContextFilePath(context.filePath) : null
  if (filePath) {
    const line = normalizeIdeContextLine(context.line)
    const params: Record<string, string> = {
      section: 'ide-shell',
      view: 'source',
      file: filePath,
    }
    if (line !== undefined) params.line = String(line)
    const surface = cleanId(context.surface)
    if (surface) params.surface = surface
    const label = cleanId(context.label)
    if (label) params.label = label
    const sourceId = cleanId(context.sourceId)
    if (sourceId) params.source_id = sourceId
    if (keeperId && keeperId !== 'system') params.keeper = keeperId
    add({
      id: `code:${filePath}${line !== undefined ? `:${line}` : ''}`,
      label: 'Code',
      tab: 'code',
      params,
      evidence: `Code ${filePath}${line !== undefined ? `:${line}` : ''}`,
    })
  }
  const goalId = cleanId(context.goalId)
  if (goalId) {
    add({
      id: `goal:${goalId}`,
      label: 'Goal',
      tab: 'workspace',
      params: { section: 'planning', goal: goalId },
      evidence: `Goal ${goalId}`,
    })
  }
  const taskId = cleanId(context.taskId)
  if (taskId) {
    add({
      id: `task:${taskId}`,
      label: 'Task',
      tab: 'workspace',
      params: { section: 'planning', view: 'default', task: taskId },
      evidence: `Task ${taskId}`,
    })
  }
  const boardPostId = cleanId(context.boardPostId)
  if (boardPostId) {
    add({
      id: `board:${boardPostId}`,
      label: 'Board',
      tab: 'workspace',
      params: { section: 'board', post: boardPostId },
      evidence: `Board post ${boardPostId}`,
    })
  }
  const commentId = cleanId(context.commentId)
  if (commentId) {
    add({
      id: `comment:${commentId}`,
      label: 'Comment',
      tab: 'workspace',
      params: {
        section: 'board',
        ...(boardPostId ? { post: boardPostId } : {}),
        comment: commentId,
      },
      evidence: `Comment ${commentId}`,
    })
  }
  const prId = cleanId(context.prId)
  if (prId) {
    add({
      id: `pr:${prId}`,
      label: 'PR',
      tab: 'workspace',
      params: { section: 'repositories', pr: prId },
      evidence: `PR ${prId}`,
    })
  }
  const gitRef = cleanId(context.gitRef)
  if (gitRef) {
    add({
      id: `git:${gitRef}`,
      label: 'Git',
      tab: 'workspace',
      params: { section: 'repositories', ref: gitRef },
      evidence: `Git ${gitRef}`,
    })
  }
  const logId = cleanId(context.logId)
  if (logId) {
    add({
      id: `log:${logId}`,
      label: 'Log',
      tab: 'monitoring',
      params: auditLogRouteParams(logId),
      evidence: `Log ${logId}`,
    })
  }
  if (context.telemetry) {
    const sessionId = cleanId(context.sessionId)
    const operationId = cleanId(context.operationId)
    const workerRunId = cleanId(context.workerRunId)
    const telemetryQuery = cleanId(context.telemetryQuery ?? context.logId)
    const telemetryParams: Record<string, string> = {
      section: 'fleet-health',
      view: 'event-log',
    }
    if (sessionId) telemetryParams.session_id = sessionId
    if (operationId) telemetryParams.operation_id = operationId
    if (workerRunId) telemetryParams.worker_run_id = workerRunId
    if (telemetryQuery) telemetryParams.q = telemetryQuery
    const telemetryScope = [
      sessionId ? `session ${sessionId}` : null,
      operationId ? `operation ${operationId}` : null,
      workerRunId ? `worker ${workerRunId}` : null,
      telemetryQuery ? `query ${telemetryQuery}` : null,
    ].filter((value): value is string => value !== null)
    add({
      id: `telemetry:${sessionId ?? operationId ?? workerRunId ?? telemetryQuery ?? 'event-log'}`,
      label: 'Telemetry',
      tab: 'monitoring',
      params: telemetryParams,
      evidence: telemetryScope.length > 0
        ? `Fleet telemetry event log · ${telemetryScope.join(' · ')}`
        : 'Fleet telemetry event log',
    })
  }
  if (keeperId && keeperId !== 'system') {
    add({
      id: `keeper:${keeperId}`,
      label: 'Keeper',
      tab: 'monitoring',
      params: { section: 'agents', view: 'keepers', keeper: keeperId },
      evidence: `Keeper ${keeperId}`,
    })
  }
  return links.slice(0, MAX_CONTEXT_ROUTE_LINKS)
}

function cleanId(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}
