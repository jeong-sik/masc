import { html } from 'htm/preact'
import type { UnifiedDiffRow } from '../../api/workspace'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import { lspDiagnosticSnapshot } from './ide-lsp-client'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { focusIdeContextAnchor, normalizeIdeContextFilePath } from './ide-state'
import { setIdeReplayUntilMs } from './ide-replay-state'
import { routeLinksForContext } from './ide-context-lens'
import type { KeeperTraceEvent } from './keeper-trace-store'

export interface CurrentFileSignal {
  readonly id: string
  readonly label: string
  readonly count: number
  readonly title: string
}

export function buildCurrentFileSignals({
  filePath,
  annotations,
  diffRows,
  activeKeeperCount,
  traceEvents,
}: {
  readonly filePath: string
  readonly annotations: ReadonlyArray<IdeAnnotation>
  readonly diffRows: ReadonlyArray<UnifiedDiffRow>
  readonly activeKeeperCount: number
  readonly traceEvents: ReadonlyArray<KeeperTraceEvent>
}): ReadonlyArray<CurrentFileSignal> {
  const normalizedFile = normalizeIdeContextFilePath(filePath)
  const matchesCurrentFile = (value: string | null): boolean => {
    if (value === null) return false
    return normalizedFile !== null && normalizeIdeContextFilePath(value) === normalizedFile
  }
  const diagnosticCount = normalizedFile
    ? lspDiagnosticSnapshot.value.get(normalizedFile)?.length ?? 0
    : 0
  const annotationCount = annotations.filter(annotation =>
    matchesCurrentFile(annotation.file_path),
  ).length
  const threadSnapshot = ideConversationThreadSnapshot.value
  const threadCount = matchesCurrentFile(threadSnapshot.filePath)
    ? threadSnapshot.threads.length
    : 0
  const changedRows = diffRows.filter(row => row.kind === 'add' || row.kind === 'delete')
  const fileTraceEvents = traceEvents.filter(event => {
    const traceFilePath = traceEventFilePath(event)
    return traceFilePath !== null && matchesCurrentFile(traceFilePath)
  })
  const traceHitCount = fileTraceEvents.reduce((sum, event) => sum + event.count, 0)
  const operationalTraceCount = fileTraceEvents.reduce((sum, event) => {
    if (event.source !== 'activity-event') return sum
    const surface = event.surface.trim().toLowerCase()
    return surface !== '' && surface !== 'activity' ? sum + event.count : sum
  }, 0)
  return [
    {
      id: 'lsp',
      label: 'LSP',
      count: diagnosticCount,
      title: `${diagnosticCount} current-file diagnostic${diagnosticCount === 1 ? '' : 's'}`,
    },
    {
      id: 'notes',
      label: 'Notes',
      count: annotationCount,
      title: `${annotationCount} current-file annotation${annotationCount === 1 ? '' : 's'}`,
    },
    {
      id: 'threads',
      label: 'Threads',
      count: threadCount,
      title: `${threadCount} current-file anchored thread${threadCount === 1 ? '' : 's'}`,
    },
    {
      id: 'trace',
      label: 'Trace',
      count: traceHitCount,
      title: `${traceHitCount} current-file trace event${traceHitCount === 1 ? '' : 's'}`,
    },
    {
      id: 'ops',
      label: 'Ops',
      count: operationalTraceCount,
      title: `${operationalTraceCount} current-file operational surface link${operationalTraceCount === 1 ? '' : 's'}`,
    },
    {
      id: 'diff',
      label: 'Diff',
      count: changedRows.length,
      title: `${changedRows.length} current-file changed row${changedRows.length === 1 ? '' : 's'}`,
    },
    {
      id: 'keepers',
      label: 'Keepers',
      count: activeKeeperCount,
      title: `${activeKeeperCount} keeper${activeKeeperCount === 1 ? '' : 's'} active in this file`,
    },
  ]
}

export function traceEventFilePath(event: KeeperTraceEvent): string | null {
  if (event.source === 'anchored-thread') return event.filePath ?? null
  if (event.source === 'activity-event') return event.filePath
  return null
}

export function traceLineFocusSurface(event: { source: string; surface?: string }): string {
  if (event.source === 'activity-event') return event.surface?.trim() || 'Activity'
  if (event.source === 'anchored-thread') return 'Thread'
  if (event.source === 'runtime-hop') return 'Runtime'
  return 'Decision'
}

export function traceLineFocusLabel(event: { source: string; surface?: string; eventId?: string; threadId?: string }): string {
  if (event.source === 'activity-event') {
    const surface = traceLineFocusSurface(event)
    return event.eventId ? `${surface} activity ${event.eventId}` : surface
  }
  if (event.source === 'anchored-thread') {
    return event.threadId ? `thread ${event.threadId}` : 'thread'
  }
  return traceLineFocusSurface(event)
}

export interface TraceLineFocusEvent {
  readonly id?: string
  readonly source: string
  readonly keeperName: string
  readonly tsMs: number
  readonly surface?: string
  readonly eventId?: string
  readonly threadId?: string
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
}

export function focusTraceLineContext(
  filePath: string,
  event: TraceLineFocusEvent,
  line: number,
): void {
  setIdeReplayUntilMs(event.tsMs)
  const surface = traceLineFocusSurface(event)
  const label = traceLineFocusLabel(event)
  const sourceId = event.id ? `trace:${event.id}` : `trace:${event.source}:${line}:${event.tsMs}`
  focusIdeContextAnchor({
    file_path: filePath,
    line,
    surface,
    label,
    source_id: sourceId,
    keeper_id: event.keeperName,
    route_links: routeLinksForContext({
      filePath,
      line,
      surface,
      label,
      sourceId,
      taskId: event.taskId,
      boardPostId: event.boardPostId ?? event.threadId,
      commentId: event.commentId,
      prId: event.prId,
      gitRef: event.gitRef,
      logId: event.logId,
      sessionId: event.sessionId,
      operationId: event.operationId,
      workerRunId: event.workerRunId,
      telemetryQuery: event.logId ?? event.eventId,
      keeperId: event.keeperName,
      telemetry: Boolean(event.logId || event.sessionId || event.operationId || event.workerRunId),
    }),
  }, 'operator')
}

export function EditorCurrentFileSignals({
  signals,
}: {
  readonly signals: ReadonlyArray<CurrentFileSignal>
}) {
  return html`
    <ul
      class="ide-editor-file-signals v2-ide-panel"
      role="list"
      aria-label="Current file operational signals"
    >
      ${signals.map(signal => html`
        <li
          class="v2-ide-row"
          key=${signal.id}
          role="listitem"
          data-active=${signal.count > 0 ? 'true' : 'false'}
          title=${signal.title}
        >
          <span>${signal.label}</span>
          <strong>${signal.count}</strong>
        </li>
      `)}
    </ul>
  `
}
