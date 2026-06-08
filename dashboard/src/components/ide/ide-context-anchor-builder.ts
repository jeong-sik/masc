import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import {
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-route-links'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { RunActivityEvent } from './run-activity-store'
import { normalizeIdeContextFilePath } from './ide-state'
import { truncate } from '../../lib/truncate'
import { eventRouteRefs, positiveLine, type IdeContextTextRouteRefs } from './ide-context-route-refs'

export interface IdeContextAnchor {
  readonly id: string
  readonly file_path: string
  readonly surface: string
  readonly label: string
  readonly meta: string
  readonly line?: number
  readonly keeper_id?: string
  readonly route_links?: ReadonlyArray<IdeContextRouteLink>
}

export interface IdeContextDiagnostic {
  readonly file_path: string
  readonly line: number
  readonly severity?: number
  readonly code?: number | string
  readonly source?: string
  readonly message: string
}

export function buildAnchors(
  filePath: string,
  annotations: ReadonlyArray<IdeAnnotation>,
  diagnostics: ReadonlyArray<IdeContextDiagnostic>,
  cursors: ReadonlyArray<{
    readonly keeper_id: string
    readonly line: number
    readonly focus_mode: string
    readonly tool_name?: string
    readonly turn?: number
  }>,
  threads: ReadonlyArray<AnchoredThread>,
  changedRows: ReadonlyArray<UnifiedDiffRow>,
  events: ReadonlyArray<RunActivityEvent>,
): ReadonlyArray<IdeContextAnchor> {
  const anchors: IdeContextAnchor[] = []

  for (const [index, diagnostic] of diagnostics.slice(0, 2).entries()) {
    const line = positiveLine(diagnostic.line)
    const label = truncate(diagnostic.message || '(no message)', 48)
    const sourceId = `diagnostic-${diagnostic.line}-${diagnostic.source ?? 'lsp'}-${diagnostic.code ?? 'message'}-${index}`
    const telemetryQuery = diagnosticTelemetryQuery(diagnostic)
    anchors.push({
      id: sourceId,
      file_path: diagnostic.file_path,
      surface: 'LSP',
      label,
      meta: compactMeta([
        diagnosticSeverityLabel(diagnostic.severity),
        diagnostic.source ?? null,
        diagnostic.code !== undefined ? `code ${diagnostic.code}` : null,
      ]),
      line,
      route_links: routeLinksForContext({
        filePath: diagnostic.file_path,
        line,
        surface: 'LSP',
        label,
        sourceId,
        telemetry: telemetryQuery !== undefined,
        telemetryQuery,
      }),
    })
  }

  for (const annotation of annotations.slice(0, 3)) {
    const line = positiveLine(annotation.line_start)
    const sourceId = `annotation-${annotation.id}`
    anchors.push({
      id: sourceId,
      file_path: annotation.file_path,
      surface: annotation.kind,
      label: truncate(annotation.content || '(no content)', 48),
      meta: annotationContextMeta(annotation),
      line,
      keeper_id: annotation.keeper_id,
      route_links: routeLinksForContext({
        filePath: annotation.file_path,
        line,
        surface: annotation.kind,
        label: truncate(annotation.content || '(no content)', 48),
        sourceId,
        goalId: annotation.goal_id ?? undefined,
        taskId: annotation.task_id ?? undefined,
        boardPostId: annotation.board_post_id ?? undefined,
        commentId: annotation.comment_id ?? undefined,
        prId: annotation.pr_id ?? undefined,
        gitRef: annotation.git_ref ?? undefined,
        logId: annotation.log_id ?? undefined,
        sessionId: annotation.session_id ?? undefined,
        operationId: annotation.operation_id ?? undefined,
        workerRunId: annotation.worker_run_id ?? undefined,
        telemetryQuery: annotation.log_id ?? undefined,
        telemetry: annotationHasTelemetry(annotation),
        keeperId: annotation.keeper_id,
      }),
    })
  }

  for (const cursor of cursors.slice(0, 2)) {
    anchors.push({
      id: `cursor-${cursor.keeper_id}-${cursor.line}`,
      file_path: filePath,
      surface: 'Line',
      label: cursor.tool_name ?? cursor.focus_mode,
      meta: compactMeta([
        `keeper ${cursor.keeper_id}`,
        cursor.turn !== undefined ? `turn ${cursor.turn}` : null,
      ]),
      line: cursor.line,
      keeper_id: cursor.keeper_id,
      route_links: routeLinksForContext({
        filePath,
        line: cursor.line,
        surface: 'Line',
        label: cursor.tool_name ?? cursor.focus_mode,
        sourceId: `cursor-${cursor.keeper_id}-${cursor.line}`,
        keeperId: cursor.keeper_id,
      }),
    })
  }

  for (const thread of threads.slice(0, 2)) {
    anchors.push({
      id: `thread-${thread.id}`,
      file_path: thread.anchor.file_path,
      surface: thread.kind.toUpperCase(),
      label: truncate(thread.body, 48),
      meta: compactMeta([
        thread.anchor.symbol_hint ?? null,
        thread.reply_count > 0 ? `${thread.reply_count} replies` : null,
        thread.resolved ? 'resolved' : 'open',
      ]),
      line: positiveLine(thread.anchor.line_start),
      keeper_id: thread.author_keeper_id,
      route_links: routeLinksForContext({
        filePath: thread.anchor.file_path,
        line: positiveLine(thread.anchor.line_start),
        surface: thread.kind.toUpperCase(),
        label: truncate(thread.body, 48),
        sourceId: `thread-${thread.id}`,
        boardPostId: thread.id,
        keeperId: thread.author_keeper_id,
      }),
    })
  }

  if (changedRows.length > 0) {
    const additions = changedRows.filter(row => row.kind === 'add').length
    const deletions = changedRows.filter(row => row.kind === 'delete').length
    anchors.push({
      id: 'git-diff-summary',
      file_path: filePath,
      surface: 'Git',
      label: `${additions} add / ${deletions} delete`,
      meta: 'working diff for current file',
      line: positiveLine(firstChangedLine(changedRows)),
      route_links: routeLinksForContext({
        filePath,
        line: positiveLine(firstChangedLine(changedRows)),
        surface: 'Git',
        label: 'working diff for current file',
        sourceId: 'git-diff-summary',
        gitRef: 'HEAD',
      }),
    })
  }

  for (const event of events.slice(0, 3)) {
    const refs = eventRouteRefs(event)
    const contextMeta = eventContextMeta(event, refs)
    const eventLine = eventLineForFile(event, filePath) ?? refs.line
    const eventSurface = surfaceFromEvent(event)
    anchors.push({
      id: `event-${event.id}`,
      file_path: event.context?.file_path ?? filePath,
      surface: eventSurface,
      label: truncate(`${event.verb} ${event.target}`, 48),
      meta: truncate(contextMeta || event.detail || `keeper ${event.keeper_id}`, 60),
      line: eventLine,
      keeper_id: event.keeper_id,
      route_links: routeLinksForContext({
        filePath: event.context?.file_path ?? filePath,
        line: eventLine,
        surface: eventSurface,
        label: truncate(event.detail || `${event.verb} ${event.target}`, 48),
        sourceId: `event-${event.id}`,
        goalId: event.context?.goal_id ?? refs.goalId,
        taskId: event.context?.task_id ?? refs.taskId,
        boardPostId: event.context?.board_post_id ?? refs.boardPostId,
        commentId: event.context?.comment_id ?? refs.commentId,
        prId: event.context?.pr_id ?? refs.prId,
        gitRef: event.context?.git_ref ?? refs.gitRef,
        logId: event.context?.log_id ?? refs.logId,
        sessionId: event.context?.session_id ?? refs.sessionId,
        operationId: event.context?.operation_id ?? refs.operationId,
        workerRunId: event.context?.worker_run_id ?? refs.workerRunId,
        telemetryQuery: event.context?.log_id ?? refs.logId,
        keeperId: event.keeper_id,
        telemetry: true,
      }),
    })
  }

  return anchors
}

function surfaceFromEvent(event: RunActivityEvent): string {
  if (event.context?.comment_id) return 'Comment'
  if (event.context?.pr_id) return 'PR'
  if (event.context?.board_post_id) return 'Board'
  if (event.context?.goal_id) return 'Goal'
  if (event.context?.task_id) return 'Task'
  if (event.context?.git_ref) return 'Git'
  if (event.context?.log_id) return 'Log'
  if (
    event.context?.session_id
    || event.context?.operation_id
    || event.context?.worker_run_id
  ) {
    return 'Runtime'
  }
  return 'Log'
}

export function eventLineForFile(event: RunActivityEvent, filePath: string): number | undefined {
  const line = event.context?.line
  if (line === undefined) return undefined
  const eventFile = event.context?.file_path
  if (eventFile === undefined) return undefined
  const normalizedFilePath = normalizeIdeContextFilePath(filePath)
  return normalizedFilePath !== null && normalizeIdeContextFilePath(eventFile) === normalizedFilePath
    ? positiveLine(line)
    : undefined
}

function diagnosticSeverityLabel(severity: number | undefined): string {
  if (severity === 1) return 'error'
  if (severity === 2) return 'warning'
  if (severity === 3) return 'info'
  if (severity === 4) return 'hint'
  return 'diagnostic'
}

function diagnosticTelemetryQuery(diagnostic: IdeContextDiagnostic): string | undefined {
  const parts = [
    diagnostic.source,
    diagnostic.code === undefined ? undefined : String(diagnostic.code),
  ]
    .map(part => part?.trim())
    .filter((part): part is string => Boolean(part))
  return parts.length > 0 ? parts.join(' ') : undefined
}

export function annotationHasTelemetry(annotation: IdeAnnotation): boolean {
  return Boolean(
    annotation.log_id
    || annotation.session_id
    || annotation.operation_id
    || annotation.worker_run_id,
  )
}

export function annotationHasRuntimeScope(annotation: IdeAnnotation): boolean {
  return Boolean(
    annotation.session_id
    || annotation.operation_id
    || annotation.worker_run_id,
  )
}

function annotationContextMeta(annotation: IdeAnnotation): string {
  return compactMeta([
    annotation.goal_id ? `goal ${annotation.goal_id}` : null,
    annotation.task_id ? `task ${annotation.task_id}` : null,
    annotation.pr_id ? `PR ${annotation.pr_id}` : null,
    annotation.board_post_id ? `board ${annotation.board_post_id}` : null,
    annotation.comment_id ? `comment ${annotation.comment_id}` : null,
    annotation.git_ref ? `git ${annotation.git_ref}` : null,
    annotation.log_id ? `log ${annotation.log_id}` : null,
    annotation.session_id ? `session ${annotation.session_id}` : null,
    annotation.operation_id ? `operation ${annotation.operation_id}` : null,
    annotation.worker_run_id ? `worker ${annotation.worker_run_id}` : null,
    `keeper ${annotation.keeper_id}`,
  ])
}

function eventContextMeta(event: RunActivityEvent, refs: IdeContextTextRouteRefs): string {
  const context = event.context
  const goalId = context?.goal_id ?? refs.goalId
  const taskId = context?.task_id ?? refs.taskId
  const prId = context?.pr_id ?? refs.prId
  const boardPostId = context?.board_post_id ?? refs.boardPostId
  const commentId = context?.comment_id ?? refs.commentId
  const gitRef = context?.git_ref ?? refs.gitRef
  const logId = context?.log_id ?? refs.logId
  const sessionId = context?.session_id ?? refs.sessionId
  const operationId = context?.operation_id ?? refs.operationId
  const workerRunId = context?.worker_run_id ?? refs.workerRunId
  return compactMeta([
    goalId ? `goal ${goalId}` : null,
    taskId ? `task ${taskId}` : null,
    prId ? `PR ${prId}` : null,
    boardPostId ? `board ${boardPostId}` : null,
    commentId ? `comment ${commentId}` : null,
    gitRef ? `git ${gitRef}` : null,
    logId ? `log ${logId}` : null,
    sessionId ? `session ${sessionId}` : null,
    operationId ? `operation ${operationId}` : null,
    workerRunId ? `worker ${workerRunId}` : null,
    context?.file_path ?? null,
  ])
}

function firstChangedLine(rows: ReadonlyArray<UnifiedDiffRow>): number | undefined {
  const row = rows.find(candidate => candidate.newLine !== null && candidate.newLine >= 1)
  return row?.newLine ?? undefined
}

function compactMeta(values: ReadonlyArray<string | null>): string {
  return values.filter((value): value is string => Boolean(value)).join(' / ')
}
