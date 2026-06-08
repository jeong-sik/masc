import { html } from 'htm/preact'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { navigate } from '../../router'
import { KeeperBadge } from '../keeper-badge'
import {
  routeLinksForContext,
  type IdeContextRouteLink,
  type IdeContextRouteContext,
} from './ide-context-route-links'
import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperCursorOverlay } from './keeper-cursor-overlay'
import type { RunActivityEvent } from './run-activity-store'
import { focusIdeContextAnchor, normalizeIdeContextFilePath } from './ide-state'
import {
  buildAnchors,
  annotationHasTelemetry,
  annotationHasRuntimeScope,
  eventLineForFile,
  type IdeContextAnchor,
  type IdeContextDiagnostic,
} from './ide-context-anchor-builder'
import { routeRefsFromText, eventRouteRefs, type IdeContextTextRouteRefs } from './ide-context-route-refs'

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
      class="ide-context-lens"
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
          ? html`<li class="ide-context-anchor-empty">no linked anchors on this file yet</li>`
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
      class="ide-context-surface"
      data-status=${surface.status}
      data-actionable=${actionable ? 'true' : 'false'}
      title=${title}
    >
      ${actionable
        ? html`
          <button
            type="button"
            class="ide-context-surface-action"
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
            <${ContextRouteCount} count=${anchor.route_links.length} />
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

export { routeLinksForContext, type IdeContextRouteLink, type IdeContextRouteContext } from './ide-context-route-links'
export { routeRefsFromText, type IdeContextTextRouteRefs } from './ide-context-route-refs'
export {
  buildAnchors,
  eventLineForFile,
  annotationHasTelemetry,
  annotationHasRuntimeScope,
  type IdeContextAnchor,
  type IdeContextDiagnostic,
} from './ide-context-anchor-builder'
