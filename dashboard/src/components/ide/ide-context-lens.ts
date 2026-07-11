import { html } from 'htm/preact'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { navigate } from '../../router'
import type { TabId } from '../../types'
import { auditLogRouteParams } from '../cost/cost-types'
import { KeeperBadge } from '../keeper-badge'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperCursorOverlay } from './keeper-cursor-overlay'
import type { RunActivityEvent } from './run-activity-store'
import { focusIdeContextAnchor, normalizeIdeContextFilePath, normalizeIdeContextLine } from './ide-state'
import { truncate } from '../../lib/truncate'
import { isPositiveSafeInteger } from '../common/normalize'

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
  | 'runtime'
  | 'telemetry'

export interface IdeContextSurface {
  readonly id: IdeContextSurfaceId
  readonly label: string
  readonly status: SurfaceStatus
  readonly count: number
  readonly evidence: string
  readonly routeLink: IdeContextRouteLink | null
  readonly focusAnchor: IdeContextAnchor | null
  readonly actionEvidence: string | null
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

export interface IdeContextDiagnostic {
  readonly file_path: string
  readonly line: number
  readonly severity?: number
  readonly code?: number | string
  readonly source?: string
  readonly message: string
}

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

export interface IdeContextLensModel {
  readonly linkedCount: number
  readonly surfaces: ReadonlyArray<IdeContextSurface>
  readonly anchors: ReadonlyArray<IdeContextAnchor>
  readonly anchorTotalCount: number
  readonly changedLineCount: number
  readonly activeLineCount: number
}

export interface IdeContextLensInput {
  readonly filePath: string
  readonly annotations: ReadonlyArray<IdeAnnotation>
  readonly diffRows: ReadonlyArray<UnifiedDiffRow>
  readonly events: ReadonlyArray<RunActivityEvent>
  readonly threads?: ReadonlyArray<AnchoredThread>
  readonly diagnostics?: ReadonlyArray<IdeContextDiagnostic>
  readonly overlay: KeeperCursorOverlay
}


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
  runtime: 'Runtime',
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
  'runtime',
  'telemetry',
]

function isIdeContextSurfaceId(value: string): value is IdeContextSurfaceId {
  return (SURFACE_ORDER as readonly string[]).includes(value)
}

const MAX_CONTEXT_ANCHORS = 6
const MAX_CONTEXT_ROUTE_LINKS = 10
const CONTEXT_ANCHOR_BUCKET_ORDER = [
  'lsp',
  'pr',
  'git',
  'task',
  'board',
  'log',
  'runtime',
  'goal',
  'comment',
  'telemetry',
  'line',
  'keeper',
  'other',
] as const
type ContextAnchorBucket = (typeof CONTEXT_ANCHOR_BUCKET_ORDER)[number]
const SURFACE_ROUTE_LABELS: Readonly<Record<IdeContextSurfaceId, ReadonlyArray<string>>> = {
  lsp: ['Code'],
  line: ['Code'],
  keeper: ['Keeper'],
  goal: ['Goal'],
  task: ['Task'],
  board: ['Board'],
  git: ['Git'],
  pr: ['PR'],
  comment: ['Comment', 'Board'],
  log: ['Log'],
  runtime: ['Telemetry'],
  telemetry: ['Telemetry'],
}

export function deriveIdeContextLens(input: IdeContextLensInput): IdeContextLensModel {
  const filePath = normalizeIdeContextFilePath(input.filePath)
  const matchesFilePath = (value: string): boolean =>
    filePath !== null && normalizeIdeContextFilePath(value) === filePath
  const fileAnnotations = input.annotations.filter(annotation =>
    matchesFilePath(annotation.file_path),
  )
  const fileDiagnostics = (input.diagnostics ?? []).filter(diagnostic =>
    matchesFilePath(diagnostic.file_path),
  )
  const activeCursors = [...input.overlay.cursors.values()]
    .filter(cursor => matchesFilePath(cursor.file_path) && cursor.line >= 1)
  const fileThreads = (input.threads ?? []).filter(thread =>
    matchesFilePath(thread.anchor.file_path),
  )
  const fileEvents = input.events.filter(event => {
    const eventFile = event.context?.file_path
    const eventLine = event.context?.line
    if (eventLine !== undefined && eventFile === undefined) return false
    return eventFile === undefined || matchesFilePath(eventFile)
  })
  const changedRows = input.diffRows.filter(row => row.kind === 'add' || row.kind === 'delete')
  const changedLineCount = changedRows.length
  const activeLines = new Set<number>()

  for (const annotation of fileAnnotations) {
    if (annotation.line_start >= 1) activeLines.add(annotation.line_start)
  }
  for (const diagnostic of fileDiagnostics) {
    if (diagnostic.line >= 1) activeLines.add(diagnostic.line)
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
    const line = eventLineForFile(event, filePath ?? input.filePath)
      ?? eventRouteRefs(event).line
    if (line !== undefined) activeLines.add(line)
  }

  const anchorCandidates = buildAnchors(
    filePath ?? input.filePath,
    fileAnnotations,
    fileDiagnostics,
    activeCursors,
    fileThreads,
    changedRows,
    fileEvents,
  )

  const surfaces = SURFACE_ORDER.map(id => {
    const count = surfaceCount(id, {
      annotations: fileAnnotations,
      diagnostics: fileDiagnostics,
      activeCursors,
      threads: fileThreads,
      changedLineCount,
      activeLineCount: activeLines.size,
      events: fileEvents,
    })
    const status: SurfaceStatus = count > 0 ? 'linked' : 'quiet'
    const action = count > 0 ? contextSurfaceAction(id, anchorCandidates) : null
    return {
      id,
      label: SURFACE_LABELS[id],
      status,
      count,
      evidence: surfaceEvidence(id, count),
      routeLink: action?.routeLink ?? null,
      focusAnchor: action?.focusAnchor ?? null,
      actionEvidence: action?.evidence ?? null,
    }
  })
  const anchors = selectVisibleContextAnchors(anchorCandidates, MAX_CONTEXT_ANCHORS)

  return {
    linkedCount: surfaces.filter(surface => surface.status === 'linked').length,
    surfaces,
    anchors,
    anchorTotalCount: anchorCandidates.length,
    changedLineCount,
    activeLineCount: activeLines.size,
  }
}

function selectVisibleContextAnchors(
  anchors: ReadonlyArray<IdeContextAnchor>,
  limit: number,
): ReadonlyArray<IdeContextAnchor> {
  if (anchors.length <= limit) return anchors
  const selected: IdeContextAnchor[] = []
  const selectedIds = new Set<string>()
  const add = (anchor: IdeContextAnchor): boolean => {
    if (selectedIds.has(anchor.id)) return false
    selected.push(anchor)
    selectedIds.add(anchor.id)
    return selected.length >= limit
  }

  for (const bucket of CONTEXT_ANCHOR_BUCKET_ORDER) {
    const anchor = anchors.find(candidate =>
      !selectedIds.has(candidate.id)
      && contextAnchorBuckets(candidate).has(bucket),
    )
    if (anchor && add(anchor)) return selected
  }
  for (const anchor of anchors) {
    if (add(anchor)) return selected
  }
  return selected
}

function contextAnchorBuckets(anchor: IdeContextAnchor): ReadonlySet<ContextAnchorBucket> {
  const buckets = new Set<ContextAnchorBucket>()
  for (const link of anchor.route_links ?? []) {
    // WORKAROUND: link.label TS 타입은 string (non-nullable) 이지만 SSE schema drift
    // 시 stale store 가 null 을 통과시켜 .trim() 폭발 (dashboard IDE crash 사고
    // 2026-05-17 console). 근본 해결: RFC-0004 Phase A0.4 (Zod payload nested 검증)
    // 도입 시 null 자체가 표면에 못 들어옴 → 본 guard 제거.
    const label = (link.label ?? '').trim().toLowerCase()
    if (isIdeContextSurfaceId(label)) {
      buckets.add(label)
      if (
        label === 'telemetry'
        && (
          link.params.session_id !== undefined
          || link.params.operation_id !== undefined
          || link.params.worker_run_id !== undefined
        )
      ) {
        buckets.add('runtime')
      }
    }
  }

  // WORKAROUND: 같은 사유 (link.label null guard 위 참조). RFC-0004 Phase A0.4 도입 시 제거.
  const surface = (anchor.surface ?? '').trim().toLowerCase()
  if (isIdeContextSurfaceId(surface)) {
    buckets.add(surface)
  } else if (surface === 'question' || surface === 'note' || surface === 'suggest') {
    buckets.add('comment')
  }

  if (anchor.keeper_id) buckets.add('keeper')
  if (anchor.line !== undefined) buckets.add('line')
  if (anchor.id.startsWith('event-')) buckets.add('log')
  if (buckets.size === 0) buckets.add('other')
  return buckets
}

function contextSurfaceAction(
  id: IdeContextSurfaceId,
  anchors: ReadonlyArray<IdeContextAnchor>,
): { readonly routeLink: IdeContextRouteLink | null; readonly focusAnchor: IdeContextAnchor; readonly evidence: string } | null {
  const matchingAnchors = anchors.filter(anchor => contextAnchorBuckets(anchor).has(id))
  for (const anchor of matchingAnchors) {
    for (const label of SURFACE_ROUTE_LABELS[id]) {
      const routeLink = anchor.route_links?.find(link => link.label === label)
      if (routeLink) {
        return { routeLink, focusAnchor: anchor, evidence: routeLink.evidence }
      }
    }
  }
  const focusAnchor = matchingAnchors[0]
  return focusAnchor
    ? { routeLink: null, focusAnchor, evidence: contextAnchorTitle(focusAnchor) }
    : null
}

export function IdeContextLens({
  filePath,
  annotations,
  diffRows,
  events,
  threads = [],
  diagnostics = [],
  overlay,
  onAnchorActivate,
  onRouteLinkActivate,
}: IdeContextLensProps) {
  const model = deriveIdeContextLens({ filePath, annotations, diffRows, events, threads, diagnostics, overlay })
  const fileLabel = filePath.split('/').pop() || filePath || '(no file)'
  const activateAnchor = onAnchorActivate ?? activateIdeContextAnchor
  const activateRouteLink = onRouteLinkActivate ?? openIdeContextRouteLink

  return html`
    <section
      class="ide-context-lens v2-ide-panel"
      data-testid="ide-context-lens"
      data-visible-anchors=${model.anchors.length}
      data-total-anchors=${model.anchorTotalCount}
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
          <span>${anchorCountLabel(model)}</span>
          <span>${model.changedLineCount} changed rows</span>
        </div>
      </div>
      <div class="ide-context-surface-grid" role="list" aria-label="Linked surfaces">
        ${model.surfaces.map(surface => ContextSurfaceChip(surface, activateAnchor, activateRouteLink))}
      </div>
      <ol class="ide-context-anchor-list" aria-label="Current file anchors">
        ${model.anchors.length === 0
          ? html`<li class="ide-context-anchor-empty v2-ide-row">no linked anchors on this file yet</li>`
          : model.anchors.map(anchor => ContextAnchorRow(anchor, activateAnchor, activateRouteLink))}
      </ol>
    </section>
  `
}

function ContextSurfaceChip(
  surface: IdeContextSurface,
  onAnchorActivate: (anchor: IdeContextAnchor) => void,
  onRouteLinkActivate: (link: IdeContextRouteLink) => void,
) {
  const actionable = surface.routeLink !== null || surface.focusAnchor !== null
  const title = surface.actionEvidence ?? surface.evidence
  const activate = () => {
    if (surface.routeLink) {
      onRouteLinkActivate(surface.routeLink)
    } else if (surface.focusAnchor) {
      onAnchorActivate(surface.focusAnchor)
    }
  }
  return html`
    <span
      role="listitem"
      class="ide-context-surface v2-ide-row"
      data-status=${surface.status}
      data-actionable=${actionable ? 'true' : 'false'}
      title=${title}
    >
      ${actionable
        ? html`
          <button
            type="button"
            class="ide-context-surface-action v2-ide-action"
            aria-label=${`Open ${title}`}
            onClick=${activate}
          >
            <span>${surface.label}</span>
            <span>${surface.count}</span>
          </button>
        `
        : html`
          <span>${surface.label}</span>
          <span>${surface.count}</span>
        `}
    </span>
  `
}

function ContextAnchorRow(
  anchor: IdeContextAnchor,
  onAnchorActivate: (anchor: IdeContextAnchor) => void,
  onRouteLinkActivate: (link: IdeContextRouteLink) => void,
) {
  return html`
    <li class="ide-context-anchor-row v2-ide-row">
      <span class="ide-context-anchor-surface">${anchor.surface}</span>
      <div class="ide-context-anchor-content">
        <button
          type="button"
          class="ide-context-anchor-main ide-context-anchor-action v2-ide-action"
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
            <${ContextRouteCount} count=${anchor.route_links.length} />
            ${anchor.route_links.map(link => html`
              <button
                key=${link.id}
                type="button"
                class="ide-context-route-link v2-ide-action"
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

function ContextRouteCount({ count }: { count: number }) {
  return html`
    <span
      class="ide-context-route-count"
      title=${`${count} linked context routes`}
      aria-label=${`${count} linked context routes`}
    >
      CTX ${count}
    </span>
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
  }, 'operator')
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
    readonly diagnostics: ReadonlyArray<IdeContextDiagnostic>
    readonly activeCursors: ReadonlyArray<{ readonly keeper_id: string }>
    readonly threads: ReadonlyArray<AnchoredThread>
    readonly changedLineCount: number
    readonly activeLineCount: number
    readonly events: ReadonlyArray<RunActivityEvent>
  },
): number {
  if (id === 'lsp') return state.annotations.length + state.diagnostics.length
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
  }
  if (id === 'task') {
    return state.annotations.filter(annotation => annotation.task_id).length
      + state.events.filter(event => event.context?.task_id).length
  }
  if (id === 'board') {
    return state.threads.length
      + state.annotations.filter(annotation => annotation.board_post_id).length
      + state.events.filter(event => event.context?.board_post_id).length
  }
  if (id === 'git') {
    return state.changedLineCount
      + state.annotations.filter(annotation => annotation.git_ref).length
      + state.events.filter(event => event.context?.git_ref).length
  }
  if (id === 'pr') {
    return state.annotations.filter(annotation => annotation.pr_id).length
      + state.events.filter(event => event.context?.pr_id).length
  }
  if (id === 'comment') {
    return state.annotations.filter(annotation =>
      annotation.kind === 'Comment' || annotation.kind === 'Question' || annotation.comment_id,
    ).length
      + state.threads.length
      + state.events.filter(event => event.context?.comment_id).length
  }
  if (id === 'log') {
    return state.events.length + state.annotations.filter(annotation => annotation.log_id).length
  }
  if (id === 'runtime') {
    return state.annotations.filter(annotationHasRuntimeScope).length
      + state.events.filter(event =>
        event.context?.session_id
        || event.context?.operation_id
        || event.context?.worker_run_id,
      ).length
  }
  if (id === 'telemetry') {
    return state.events.length + state.annotations.filter(annotationHasTelemetry).length
  }
  return 0
}

function surfaceEvidence(id: IdeContextSurfaceId, count: number): string {
  if (count <= 0) return `${SURFACE_LABELS[id]} has no current anchor`
  if (id === 'lsp') return `${count} LSP annotation or diagnostic anchor${plural(count)}`
  if (id === 'line') return `${count} line-level anchor${plural(count)}`
  if (id === 'keeper') return `${count} keeper identity link${plural(count)}`
  if (id === 'goal') return `${count} goal reference${plural(count)}`
  if (id === 'task') return `${count} task reference${plural(count)}`
  if (id === 'board') return `${count} board/post reference${plural(count)}`
  if (id === 'git') return `${count} git or diff signal${plural(count)}`
  if (id === 'pr') return `${count} PR/review signal${plural(count)}`
  if (id === 'comment') return `${count} comment/question anchor${plural(count)}`
  if (id === 'log') return `${count} activity log event${plural(count)}`
  if (id === 'runtime') return `${count} runtime scope signal${plural(count)}`
  return `${count} telemetry signal${plural(count)}`
}

function plural(count: number): string {
  return count === 1 ? '' : 's'
}

function anchorCountLabel(model: IdeContextLensModel): string {
  return model.anchorTotalCount > model.anchors.length
    ? `${model.anchors.length}/${model.anchorTotalCount} anchors`
    : `${model.anchorTotalCount} anchor${plural(model.anchorTotalCount)}`
}

function buildAnchors(
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

function eventLineForFile(event: RunActivityEvent, filePath: string): number | undefined {
  const line = event.context?.line
  if (line === undefined) return undefined
  const eventFile = event.context?.file_path
  if (eventFile === undefined) return undefined
  const normalizedFilePath = normalizeIdeContextFilePath(filePath)
  return normalizedFilePath !== null && normalizeIdeContextFilePath(eventFile) === normalizedFilePath
    ? positiveLine(line)
    : undefined
}

function positiveLine(value: number | null | undefined): number | undefined {
  return isPositiveSafeInteger(value) ? value : undefined
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

export interface IdeContextTextRouteRefs {
  readonly line?: number
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
}

const REF_VALUE_PATTERN = '([A-Za-z0-9][A-Za-z0-9._/@:-]*)'
const EVENT_REF_PATTERNS = {
  goalId: new RegExp(`\\bgoal[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  taskId: new RegExp(`\\btask[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  boardPostId: new RegExp(`\\b(?:board|post)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  commentId: new RegExp(`\\bcomment[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  prId: /\b(?:pr|pull[_\s-]?request)\s*[:#/]?\s*#?(\d{1,10})\b/i,
  gitRef: new RegExp(`\\b(?:git|commit|branch|ref)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  logId: new RegExp(`\\b(?:log|turn)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  sessionId: new RegExp(`\\bsession[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  operationId: new RegExp(`\\b(?:operation|op)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  workerRunId: new RegExp(`\\b(?:worker_run|worker|wr)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
} as const

function eventRouteRefs(event: RunActivityEvent): IdeContextTextRouteRefs {
  return routeRefsFromText(eventRawText(event))
}

export function routeRefsFromText(text: string): IdeContextTextRouteRefs {
  return {
    line: eventLineRef(text),
    goalId: firstEventRef(text, EVENT_REF_PATTERNS.goalId),
    taskId: firstEventRef(text, EVENT_REF_PATTERNS.taskId),
    boardPostId: firstEventRef(text, EVENT_REF_PATTERNS.boardPostId),
    commentId: firstEventRef(text, EVENT_REF_PATTERNS.commentId),
    prId: firstEventRef(text, EVENT_REF_PATTERNS.prId),
    gitRef: firstEventRef(text, EVENT_REF_PATTERNS.gitRef),
    logId: firstEventRef(text, EVENT_REF_PATTERNS.logId),
    sessionId: firstEventRef(text, EVENT_REF_PATTERNS.sessionId),
    operationId: firstEventRef(text, EVENT_REF_PATTERNS.operationId),
    workerRunId: firstEventRef(text, EVENT_REF_PATTERNS.workerRunId),
  }
}

function eventRawText(event: RunActivityEvent): string {
  return [
    event.kind,
    event.verb,
    event.target,
    event.detail,
    ...(event.tags ?? []),
  ]
    .filter((part): part is string => typeof part === 'string' && part.trim() !== '')
    .join(' ')
}

function firstEventRef(text: string, pattern: RegExp): string | undefined {
  return cleanParsedRef(pattern.exec(text)?.[1])
}

function cleanParsedRef(value: string | undefined): string | undefined {
  const cleaned = value?.trim().replace(/[),.;\]}]+$/u, '')
  return cleaned ? cleaned : undefined
}

function eventLineRef(text: string): number | undefined {
  const explicit = /\b(?:line|l)[:#]+(\d{1,7})\b/i.exec(text)?.[1]
  const compact = explicit ?? /\bL(\d{1,7})\b/.exec(text)?.[1]
  return compact ? positiveLine(Number(compact)) : undefined
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

function annotationHasTelemetry(annotation: IdeAnnotation): boolean {
  return Boolean(
    annotation.log_id
    || annotation.session_id
    || annotation.operation_id
    || annotation.worker_run_id,
  )
}

function annotationHasRuntimeScope(annotation: IdeAnnotation): boolean {
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
      tab: 'board',
      params: { post: boardPostId },
      evidence: `Board post ${boardPostId}`,
    })
  }
  const commentId = cleanId(context.commentId)
  if (commentId) {
    add({
      id: `comment:${commentId}`,
      label: 'Comment',
      tab: 'board',
      params: {
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
