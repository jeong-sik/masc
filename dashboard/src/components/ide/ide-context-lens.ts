import { html } from 'htm/preact'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { navigate } from '../../router'
import type { TabId } from '../../types'
import { KeeperBadge } from '../keeper-badge'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperCursorOverlay } from './keeper-cursor-overlay'
import type { RunActivityEvent } from './run-activity-store'
import { focusIdeContextAnchor } from './ide-state'

type SurfaceStatus = 'linked' | 'quiet'

export type IdeContextSurfaceId =
  | 'lsp'
  | 'line'
  | 'keeper'
  | 'goal'
  | 'task'
  | 'board'
  | 'git'
  | 'pr'
  | 'comment'
  | 'log'
  | 'telemetry'

export interface IdeContextSurface {
  readonly id: IdeContextSurfaceId
  readonly label: string
  readonly status: SurfaceStatus
  readonly count: number
  readonly evidence: string
}

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

export interface IdeContextRouteLink {
  readonly id: string
  readonly label: string
  readonly tab: TabId
  readonly params: Record<string, string>
  readonly evidence: string
}

export interface IdeContextRouteContext {
  readonly goalId?: string
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly keeperId?: string
  readonly telemetry?: boolean
}

export interface IdeContextLensModel {
  readonly linkedCount: number
  readonly surfaces: ReadonlyArray<IdeContextSurface>
  readonly anchors: ReadonlyArray<IdeContextAnchor>
  readonly changedLineCount: number
  readonly activeLineCount: number
}

export interface IdeContextLensInput {
  readonly filePath: string
  readonly annotations: ReadonlyArray<IdeAnnotation>
  readonly diffRows: ReadonlyArray<UnifiedDiffRow>
  readonly events: ReadonlyArray<RunActivityEvent>
  readonly threads?: ReadonlyArray<AnchoredThread>
  readonly overlay: KeeperCursorOverlay
}

type EventSearchTextMap = ReadonlyMap<RunActivityEvent, string>

export interface IdeContextLensProps extends IdeContextLensInput {
  readonly onAnchorActivate?: (anchor: IdeContextAnchor) => void
  readonly onRouteLinkActivate?: (link: IdeContextRouteLink) => void
}

const SURFACE_LABELS: Readonly<Record<IdeContextSurfaceId, string>> = {
  lsp: 'LSP',
  line: 'Line',
  keeper: 'Keeper',
  goal: 'Goal',
  task: 'Task',
  board: 'Board',
  git: 'Git',
  pr: 'PR',
  comment: 'Comment',
  log: 'Log',
  telemetry: 'Telemetry',
}

const SURFACE_ORDER: ReadonlyArray<IdeContextSurfaceId> = [
  'lsp',
  'line',
  'keeper',
  'goal',
  'task',
  'board',
  'git',
  'pr',
  'comment',
  'log',
  'telemetry',
]
const MAX_CONTEXT_ROUTE_LINKS = 9

export function deriveIdeContextLens(input: IdeContextLensInput): IdeContextLensModel {
  const fileAnnotations = input.annotations.filter(annotation =>
    annotation.file_path === input.filePath,
  )
  const activeCursors = [...input.overlay.cursors.values()]
    .filter(cursor => cursor.file_path === input.filePath && cursor.line >= 1)
  const fileThreads = (input.threads ?? []).filter(thread =>
    thread.anchor.file_path === input.filePath,
  )
  const fileEvents = input.events.filter(event => {
    const eventFile = event.context?.file_path
    const eventLine = event.context?.line
    if (eventLine !== undefined && eventFile === undefined) return false
    return eventFile === undefined || eventFile === input.filePath
  })
  const eventSearchTextByEvent = new Map<RunActivityEvent, string>(
    fileEvents.map(event => [event, eventSearchText(event)]),
  )
  const changedRows = input.diffRows.filter(row => row.kind === 'add' || row.kind === 'delete')
  const changedLineCount = changedRows.length
  const activeLines = new Set<number>()

  for (const annotation of fileAnnotations) {
    if (annotation.line_start >= 1) activeLines.add(annotation.line_start)
  }
  for (const cursor of activeCursors) activeLines.add(cursor.line)
  for (const row of changedRows) {
    if (row.newLine !== null && row.newLine >= 1) activeLines.add(row.newLine)
  }
  for (const thread of fileThreads) {
    const start = thread.anchor.line_start
    const end = thread.anchor.line_end
    if (start !== null && start >= 1) activeLines.add(start)
    if (end !== null && end >= 1) activeLines.add(end)
  }
  for (const event of fileEvents) {
    const line = eventLineForFile(event, input.filePath)
    if (line !== undefined) activeLines.add(line)
  }

  const surfaces = SURFACE_ORDER.map(id => {
    const count = surfaceCount(id, {
      annotations: fileAnnotations,
      activeCursors,
      threads: fileThreads,
      changedLineCount,
      activeLineCount: activeLines.size,
      events: fileEvents,
      eventSearchTextByEvent,
    })
    const status: SurfaceStatus = count > 0 ? 'linked' : 'quiet'
    return {
      id,
      label: SURFACE_LABELS[id],
      status,
      count,
      evidence: surfaceEvidence(id, count),
    }
  })

  return {
    linkedCount: surfaces.filter(surface => surface.status === 'linked').length,
    surfaces,
    anchors: buildAnchors(
      input.filePath,
      fileAnnotations,
      activeCursors,
      fileThreads,
      changedRows,
      fileEvents,
      eventSearchTextByEvent,
    ),
    changedLineCount,
    activeLineCount: activeLines.size,
  }
}

export function IdeContextLens({
  filePath,
  annotations,
  diffRows,
  events,
  threads = [],
  overlay,
  onAnchorActivate,
  onRouteLinkActivate,
}: IdeContextLensProps) {
  const model = deriveIdeContextLens({ filePath, annotations, diffRows, events, threads, overlay })
  const fileLabel = filePath.split('/').pop() || filePath || 'workspace'
  const activateAnchor = onAnchorActivate ?? activateIdeContextAnchor
  const activateRouteLink = onRouteLinkActivate ?? openIdeContextRouteLink

  return html`
    <section
      class="ide-context-lens"
      data-testid="ide-context-lens"
      aria-label="IDE context lens"
    >
      <div class="ide-context-lens-summary">
        <div class="ide-context-lens-title">
          <span>CONTEXT LENS</span>
          <span>${model.linkedCount}/${model.surfaces.length} linked</span>
        </div>
        <div class="ide-context-lens-meta">
          <span title=${filePath}>${fileLabel}</span>
          <span>${model.activeLineCount} line anchors</span>
          <span>${model.changedLineCount} changed rows</span>
        </div>
      </div>
      <div class="ide-context-surface-grid" role="list" aria-label="Linked surfaces">
        ${model.surfaces.map(surface => html`
          <span
            role="listitem"
            class="ide-context-surface"
            data-status=${surface.status}
            title=${surface.evidence}
          >
            <span>${surface.label}</span>
            <span>${surface.count}</span>
          </span>
        `)}
      </div>
      <ol class="ide-context-anchor-list" aria-label="Current file anchors">
        ${model.anchors.length === 0
          ? html`<li class="ide-context-anchor-empty">no linked anchors on this file yet</li>`
          : model.anchors.map(anchor => ContextAnchorRow(anchor, activateAnchor, activateRouteLink))}
      </ol>
    </section>
  `
}

function ContextAnchorRow(
  anchor: IdeContextAnchor,
  onAnchorActivate: (anchor: IdeContextAnchor) => void,
  onRouteLinkActivate: (link: IdeContextRouteLink) => void,
) {
  return html`
    <li class="ide-context-anchor-row">
      <span class="ide-context-anchor-surface">${anchor.surface}</span>
      <div class="ide-context-anchor-content">
        <button
          type="button"
          class="ide-context-anchor-main ide-context-anchor-action"
          aria-label=${contextAnchorAriaLabel(anchor)}
          title=${contextAnchorTitle(anchor)}
          onClick=${() => onAnchorActivate(anchor)}
        >
          <span class="ide-context-anchor-label">
            ${anchor.line !== undefined ? html`<span>L${anchor.line}</span>` : null}
            <span>${anchor.label}</span>
          </span>
          <span class="ide-context-anchor-meta">${anchor.meta}</span>
        </button>
        ${anchor.route_links && anchor.route_links.length > 0 ? html`
          <div class="ide-context-route-links" aria-label="Operational links">
            ${anchor.route_links.map(link => html`
              <button
                key=${link.id}
                type="button"
                class="ide-context-route-link"
                title=${link.evidence}
                aria-label=${`Open ${link.evidence}`}
                onClick=${() => onRouteLinkActivate(link)}
              >
                ${link.label}
              </button>
            `)}
          </div>
        ` : null}
      </div>
      ${anchor.keeper_id
        ? html`<${KeeperBadge} id=${anchor.keeper_id} variant="sigil" size="sm" />`
        : null}
    </li>
  `
}

function activateIdeContextAnchor(anchor: IdeContextAnchor): void {
  focusIdeContextAnchor({
    file_path: anchor.file_path,
    line: anchor.line,
    surface: anchor.surface,
    label: anchor.label,
    source_id: anchor.id,
    keeper_id: anchor.keeper_id,
    route_links: anchor.route_links,
  })
}

export function openIdeContextRouteLink(link: IdeContextRouteLink): void {
  navigate(link.tab, link.params)
}

function contextAnchorAriaLabel(anchor: IdeContextAnchor): string {
  const line = anchor.line !== undefined ? ` line ${anchor.line}` : ''
  return `Focus ${anchor.surface}${line}: ${anchor.label}`
}

function contextAnchorTitle(anchor: IdeContextAnchor): string {
  const line = anchor.line !== undefined ? `:${anchor.line}` : ''
  return `${anchor.file_path}${line}`
}

function surfaceCount(
  id: IdeContextSurfaceId,
  state: {
    readonly annotations: ReadonlyArray<IdeAnnotation>
    readonly activeCursors: ReadonlyArray<{ readonly keeper_id: string }>
    readonly threads: ReadonlyArray<AnchoredThread>
    readonly changedLineCount: number
    readonly activeLineCount: number
    readonly events: ReadonlyArray<RunActivityEvent>
    readonly eventSearchTextByEvent: EventSearchTextMap
  },
): number {
  if (id === 'lsp') return state.annotations.length
  if (id === 'line') return state.activeLineCount
  if (id === 'keeper') {
    const keepers = new Set(state.events.map(event => event.keeper_id))
    for (const cursor of state.activeCursors) keepers.add(cursor.keeper_id)
    for (const annotation of state.annotations) keepers.add(annotation.keeper_id)
    for (const thread of state.threads) keepers.add(thread.author_keeper_id)
    return keepers.size
  }
  if (id === 'goal') {
    return state.annotations.filter(annotation => annotation.goal_id).length
      + state.events.filter(event => event.context?.goal_id).length
      + countUnstructuredEventText(
        state.events,
        /\bgoal[:#/\s-]/,
        event => !!event.context?.goal_id,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'task') {
    return state.annotations.filter(annotation => annotation.task_id).length
      + state.events.filter(event => event.context?.task_id).length
      + countUnstructuredEventText(
        state.events,
        /\btask[:#/\s-]/,
        event => !!event.context?.task_id,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'board') {
    return state.threads.length
      + state.events.filter(event => event.context?.board_post_id).length
      + countUnstructuredEventText(
        state.events,
        /\b(board|post)[:#/\s-]/,
        event => !!event.context?.board_post_id,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'git') {
    return state.changedLineCount
      + state.events.filter(event => event.context?.git_ref).length
      + countUnstructuredEventText(
        state.events,
        /\b(git|commit|branch|diff)[:#/\s-]/,
        event => !!event.context?.git_ref,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'pr') {
    return state.events.filter(event => event.context?.pr_id).length
      + countUnstructuredEventText(
        state.events,
        /\b(pr|pull[_\s-]?request|review)[:#/\s-]/,
        event => !!event.context?.pr_id,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'comment') {
    return state.annotations.filter(annotation =>
      annotation.kind === 'Comment' || annotation.kind === 'Question',
    ).length
      + state.threads.length
      + state.events.filter(event => event.context?.comment_id).length
      + countUnstructuredEventText(
        state.events,
        /\b(comment|note|question)[:#/\s-]/,
        event => !!event.context?.comment_id,
        state.eventSearchTextByEvent,
      )
  }
  if (id === 'log') {
    return state.events.length
  }
  if (id === 'telemetry') return state.events.length + state.changedLineCount + state.annotations.length
  return 0
}

function surfaceEvidence(id: IdeContextSurfaceId, count: number): string {
  if (count <= 0) return `${SURFACE_LABELS[id]} has no current anchor`
  if (id === 'lsp') return `${count} annotation code lens anchor${plural(count)}`
  if (id === 'line') return `${count} line-level anchor${plural(count)}`
  if (id === 'keeper') return `${count} keeper identity link${plural(count)}`
  if (id === 'goal') return `${count} goal reference${plural(count)}`
  if (id === 'task') return `${count} task reference${plural(count)}`
  if (id === 'board') return `${count} board/post reference${plural(count)}`
  if (id === 'git') return `${count} git or diff signal${plural(count)}`
  if (id === 'pr') return `${count} PR/review signal${plural(count)}`
  if (id === 'comment') return `${count} comment/question anchor${plural(count)}`
  if (id === 'log') return `${count} activity log event${plural(count)}`
  return `${count} telemetry signal${plural(count)}`
}

function plural(count: number): string {
  return count === 1 ? '' : 's'
}

function buildAnchors(
  filePath: string,
  annotations: ReadonlyArray<IdeAnnotation>,
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
  eventSearchTextByEvent: EventSearchTextMap,
): ReadonlyArray<IdeContextAnchor> {
  const anchors: IdeContextAnchor[] = []

  for (const annotation of annotations.slice(0, 3)) {
    anchors.push({
      id: `annotation-${annotation.id}`,
      file_path: annotation.file_path,
      surface: annotation.kind,
      label: truncate(annotation.content || 'annotation', 48),
      meta: compactMeta([
        annotation.goal_id ? `goal ${annotation.goal_id}` : null,
        annotation.task_id ? `task ${annotation.task_id}` : null,
        `keeper ${annotation.keeper_id}`,
      ]),
      line: positiveLine(annotation.line_start),
      keeper_id: annotation.keeper_id,
      route_links: routeLinksForContext({
        goalId: annotation.goal_id ?? undefined,
        taskId: annotation.task_id ?? undefined,
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
      route_links: routeLinksForContext({ keeperId: cursor.keeper_id }),
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
      route_links: routeLinksForContext({ gitRef: 'HEAD' }),
    })
  }

  for (const event of events.slice(0, 3)) {
    const contextMeta = eventContextMeta(event)
    anchors.push({
      id: `event-${event.id}`,
      file_path: event.context?.file_path ?? filePath,
      surface: surfaceFromEvent(event, eventSearchTextByEvent),
      label: truncate(`${event.verb} ${event.target}`, 48),
      meta: truncate(contextMeta || event.detail || `keeper ${event.keeper_id}`, 60),
      line: eventLineForFile(event, filePath),
      keeper_id: event.keeper_id,
      route_links: routeLinksForContext({
        goalId: event.context?.goal_id,
        taskId: event.context?.task_id,
        boardPostId: event.context?.board_post_id,
        commentId: event.context?.comment_id,
        prId: event.context?.pr_id,
        gitRef: event.context?.git_ref,
        logId: event.context?.log_id,
        keeperId: event.keeper_id,
        telemetry: true,
      }),
    })
  }

  return anchors.slice(0, 6)
}

function eventSearchText(event: RunActivityEvent): string {
  return [
    event.kind,
    event.verb,
    event.target,
    event.detail,
    event.context?.file_path,
    event.context?.line !== undefined ? `line:${event.context.line}` : undefined,
    event.context?.goal_id ? `goal:${event.context.goal_id}` : undefined,
    event.context?.task_id ? `task:${event.context.task_id}` : undefined,
    event.context?.board_post_id ? `board:${event.context.board_post_id}` : undefined,
    event.context?.comment_id ? `comment:${event.context.comment_id}` : undefined,
    event.context?.pr_id ? `pr:${event.context.pr_id}` : undefined,
    event.context?.git_ref ? `git:${event.context.git_ref}` : undefined,
    event.context?.log_id ? `log:${event.context.log_id}` : undefined,
    ...(event.tags ?? []),
  ]
    .filter((part): part is string => typeof part === 'string' && part.trim() !== '')
    .join(' ')
    .toLowerCase()
}

function countUnstructuredEventText(
  events: ReadonlyArray<RunActivityEvent>,
  pattern: RegExp,
  hasStructuredLink: (event: RunActivityEvent) => boolean,
  eventSearchTextByEvent: EventSearchTextMap,
): number {
  return events.filter(event =>
    !hasStructuredLink(event) && pattern.test(cachedEventSearchText(event, eventSearchTextByEvent)),
  ).length
}

function surfaceFromEvent(
  event: RunActivityEvent,
  eventSearchTextByEvent?: EventSearchTextMap,
): string {
  if (event.context?.comment_id) return 'Comment'
  if (event.context?.pr_id) return 'PR'
  if (event.context?.board_post_id) return 'Board'
  if (event.context?.goal_id) return 'Goal'
  if (event.context?.task_id) return 'Task'
  if (event.context?.git_ref) return 'Git'
  if (event.context?.log_id) return 'Log'
  const text = eventSearchTextByEvent
    ? cachedEventSearchText(event, eventSearchTextByEvent)
    : eventSearchText(event)
  if (/\b(pr|pull[_\s-]?request|review)[:#/\s-]/.test(text)) return 'PR'
  if (/\b(board|post)[:#/\s-]/.test(text)) return 'Board'
  if (/\bgoal[:#/\s-]/.test(text)) return 'Goal'
  if (/\btask[:#/\s-]/.test(text)) return 'Task'
  if (/\b(git|commit|branch|diff)[:#/\s-]/.test(text)) return 'Git'
  if (/\b(comment|note|question)[:#/\s-]/.test(text)) return 'Comment'
  return 'Log'
}

function eventLineForFile(event: RunActivityEvent, filePath: string): number | undefined {
  const line = event.context?.line
  if (line === undefined) return undefined
  const eventFile = event.context?.file_path
  return eventFile === filePath ? positiveLine(line) : undefined
}

function cachedEventSearchText(event: RunActivityEvent, values: EventSearchTextMap): string {
  return values.get(event) ?? eventSearchText(event)
}

function positiveLine(value: number | null | undefined): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? value
    : undefined
}

function eventContextMeta(event: RunActivityEvent): string {
  const context = event.context
  if (!context) return ''
  return compactMeta([
    context.goal_id ? `goal ${context.goal_id}` : null,
    context.task_id ? `task ${context.task_id}` : null,
    context.pr_id ? `PR ${context.pr_id}` : null,
    context.board_post_id ? `board ${context.board_post_id}` : null,
    context.comment_id ? `comment ${context.comment_id}` : null,
    context.git_ref ? `git ${context.git_ref}` : null,
    context.log_id ? `log ${context.log_id}` : null,
    context.file_path ?? null,
  ])
}

function firstChangedLine(rows: ReadonlyArray<UnifiedDiffRow>): number | undefined {
  const row = rows.find(candidate => candidate.newLine !== null && candidate.newLine >= 1)
  return row?.newLine ?? undefined
}

function compactMeta(values: ReadonlyArray<string | null>): string {
  return values.filter((value): value is string => Boolean(value)).join(' / ')
}

export function routeLinksForContext(
  context: IdeContextRouteContext,
): ReadonlyArray<IdeContextRouteLink> {
  const links: IdeContextRouteLink[] = []
  const add = (link: IdeContextRouteLink): void => {
    if (links.some(existing => existing.id === link.id)) return
    links.push(link)
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
      params: { section: 'repositories', view: 'graph', pr: prId },
      evidence: `PR ${prId}`,
    })
  }
  const gitRef = cleanId(context.gitRef)
  if (gitRef) {
    add({
      id: `git:${gitRef}`,
      label: 'Git',
      tab: 'workspace',
      params: { section: 'repositories', view: 'graph', ref: gitRef },
      evidence: `Git ${gitRef}`,
    })
  }
  const logId = cleanId(context.logId)
  if (logId) {
    add({
      id: `log:${logId}`,
      label: 'Log',
      tab: 'monitoring',
      params: { section: 'runtime', view: 'audit' },
      evidence: `Log ${logId}`,
    })
  }
  if (context.telemetry) {
    add({
      id: 'telemetry:event-log',
      label: 'Telemetry',
      tab: 'monitoring',
      params: { section: 'fleet-health', view: 'event-log' },
      evidence: 'Fleet telemetry event log',
    })
  }
  const keeperId = cleanId(context.keeperId)
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

function cleanId(value: string | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  return `${value.slice(0, Math.max(0, maxLength - 3))}...`
}
