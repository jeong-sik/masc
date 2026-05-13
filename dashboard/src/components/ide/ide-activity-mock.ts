import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { KeeperBadge } from '../keeper-badge'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { globalPresenceSnapshot, PRESENCE_DOT, type KeeperPresenceSnapshot } from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursorOverlay } from './keeper-cursor-overlay'
import {
  IdeContextLens,
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import {
  lspDiagnosticSnapshot,
  type LspDiagnosticAnchor,
} from './ide-lsp-client'
import {
  focusIdeContextAnchor,
  normalizeIdeContextFilePath,
  normalizeIdeContextLine,
} from './ide-state'
import {
  createRunActivityStore,
  type RunActivityContext,
  type RunActivityEvent,
  type RunActivityVerb,
} from './run-activity-store'

const FALLBACK_VERB_MAP: Readonly<Record<string, RunActivityVerb>> = {
  approved: 'approved',
  committed: 'committed',
  flagged: 'flagged',
}
const DEFAULT_VERB: RunActivityVerb = 'noted'

interface ApiActivityEvent {
  readonly seq: number
  readonly ts_ms: number
  readonly ts_iso: string
  readonly room_id: string
  readonly kind: string
  readonly actor?: { readonly kind: string; readonly id: string } | null
  readonly subject?: { readonly kind: string; readonly id: string } | null
  readonly payload?: unknown
  readonly tags?: ReadonlyArray<string>
  readonly context?: RunActivityContext
}

interface ApiActivityResponse {
  readonly events?: ReadonlyArray<ApiActivityEvent>
  readonly latest_seq?: number
}

const EMPTY_ACTIVITY: ReadonlyArray<RunActivityEvent> = []
const EMPTY_ANNOTATIONS: ReadonlyArray<IdeAnnotation> = []
const EMPTY_DIFF_ROWS: ReadonlyArray<UnifiedDiffRow> = []
const EMPTY_DIAGNOSTICS: ReadonlyArray<LspDiagnosticAnchor> = []
const PROGRESS_SURFACES = [
  ['goal_id', 'Goal'],
  ['task_id', 'Task'],
  ['board_post_id', 'Board'],
  ['comment_id', 'Comment'],
  ['pr_id', 'PR'],
  ['git_ref', 'Git'],
  ['log_id', 'Log'],
] as const

const DEFAULT_ROOM_ID = 'run-default'
type MutableRunActivityContext = {
  -readonly [K in keyof RunActivityContext]?: RunActivityContext[K]
}

export interface IdeRunProgressSummary {
  readonly totalEvents: number
  readonly currentFileEvents: number
  readonly linkedEvents: number
  readonly keeperTotalCount: number
  readonly latestAgeLabel: string
  readonly surfaceCounts: ReadonlyArray<{ readonly label: string; readonly count: number }>
  readonly keeperCounts: ReadonlyArray<{ readonly keeper_id: string; readonly count: number }>
}

export interface IdeActivityMockProps {
  readonly activeFile?: string
  readonly annotations?: ReadonlyArray<IdeAnnotation>
  readonly diffRows?: ReadonlyArray<UnifiedDiffRow>
  readonly children?: unknown
}

function verbFromKind(kind: string): RunActivityVerb {
  const tail = kind.includes(".") ? kind.slice(kind.lastIndexOf(".") + 1) : kind
  return FALLBACK_VERB_MAP[tail] ?? DEFAULT_VERB
}

function targetFromSubject(subject: ApiActivityEvent['subject'], kind: string): string {
  if (!subject) return kind
  return `${subject.kind}:${subject.id}`
}

function detailFromPayload(payload: unknown, kind: string): string | undefined {
  if (typeof payload === 'object' && payload !== null && !Array.isArray(payload)) {
    const record = payload as Record<string, unknown>
    const summary = record['summary'] ?? record['title'] ?? record['body'] ?? record['reason']
    if (typeof summary === 'string' && summary.trim() !== '') {
      const truncated = summary.length > 120 ? summary.slice(0, 117) + '...' : summary
      return truncated
    }
  }
  return kind
}

function mapApiEvent(event: ApiActivityEvent, roomId: string): RunActivityEvent {
  return {
    id: `evt-${event.seq}`,
    run_id: roomId,
    timestamp_ms: event.ts_ms,
    keeper_id: event.actor?.id ?? 'system',
    verb: verbFromKind(event.kind),
    target: targetFromSubject(event.subject, event.kind),
    detail: detailFromPayload(event.payload, event.kind),
    kind: event.kind,
    tags: event.tags ?? [],
    context: event.context ?? contextFromPayloadAndTags(event.payload, event.tags ?? []),
  }
}

async function fetchActivityEvents(): Promise<{ events: ReadonlyArray<RunActivityEvent>; roomId: string }> {
  try {
    const res = await fetch('/api/v1/activity/events?limit=50')
    if (!res.ok) return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
    const data: ApiActivityResponse = await res.json()
    const rawEvents = data.events
    if (!Array.isArray(rawEvents) || rawEvents.length === 0) {
      return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
    }
    const roomId = rawEvents[0].room_id || DEFAULT_ROOM_ID
    const mapped = rawEvents.map(e => mapApiEvent(e, roomId))
    return { events: mapped, roomId }
  } catch {
    return { events: EMPTY_ACTIVITY, roomId: DEFAULT_ROOM_ID }
  }
}

function contextFromPayloadAndTags(
  payload: unknown,
  tags: ReadonlyArray<string>,
): RunActivityContext | undefined {
  const next: MutableRunActivityContext = {}
  mergePayloadContext(next, payload)
  for (const tag of tags) mergeTagContext(next, tag)
  return Object.keys(next).length === 0 ? undefined : next
}

function mergePayloadContext(next: MutableRunActivityContext, payload: unknown): void {
  if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) return
  const record = payload as Record<string, unknown>
  const filePath = stringValue(record.file_path)
    ?? stringValue(record.path)
    ?? stringValue(record.file)
  const normalizedFilePath = filePath ? normalizeIdeContextFilePath(filePath) : null
  if (normalizedFilePath) next.file_path = normalizedFilePath
  const line = positiveInteger(record.line)
    ?? positiveInteger(record.line_start)
    ?? positiveInteger(record.lineno)
  if (line !== undefined) next.line = line
  const goalId = stringValue(record.goal_id)
  if (goalId) next.goal_id = goalId
  const taskId = stringValue(record.task_id)
  if (taskId) next.task_id = taskId
  const boardPostId = stringValue(record.board_post_id) ?? stringValue(record.post_id)
  if (boardPostId) next.board_post_id = boardPostId
  const commentId = stringValue(record.comment_id)
    ?? stringValue(record.reply_id)
    ?? numberString(record.comment_number)
  if (commentId) next.comment_id = commentId
  const prId = stringValue(record.pr_id)
    ?? stringValue(record.pull_request)
    ?? numberString(record.pr_number)
  if (prId) next.pr_id = prId
  const gitRef = stringValue(record.git_ref)
    ?? stringValue(record.commit)
    ?? stringValue(record.branch)
  if (gitRef) next.git_ref = gitRef
  const logId = stringValue(record.log_id)
  if (logId) next.log_id = logId
}

function mergeTagContext(next: MutableRunActivityContext, rawTag: string): void {
  const tag = rawTag.trim()
  if (tag === '') return
  const separator = tag.indexOf(':')
  if (separator <= 0) return
  const key = tag.slice(0, separator).trim().toLowerCase()
  const value = tag.slice(separator + 1).trim()
  if (value === '') return

  if (key === 'file') {
    const match = value.match(/^(.+?)(?::([1-9][0-9]*))?$/)
    const path = match?.[1]
    const normalizedPath = path ? normalizeIdeContextFilePath(path) : null
    if (normalizedPath) next.file_path = normalizedPath
    if (match?.[2]) next.line = Number.parseInt(match[2], 10)
    return
  }
  if (key === 'line') {
    const line = Number.parseInt(value, 10)
    if (Number.isSafeInteger(line) && line >= 1) next.line = line
    return
  }
  if (key === 'goal') next.goal_id = value
  else if (key === 'task') next.task_id = value
  else if (key === 'board' || key === 'post') next.board_post_id = value
  else if (key === 'comment' || key === 'reply') next.comment_id = value
  else if (key === 'pr' || key === 'pull_request' || key === 'review') next.pr_id = value
  else if (key === 'git' || key === 'commit' || key === 'branch') next.git_ref = value
  else if (key === 'log' || key === 'telemetry') next.log_id = value
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function numberString(value: unknown): string | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? String(value)
    : undefined
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? value
    : undefined
}

export function IdeActivityMock(props: IdeActivityMockProps = {}) {
  const {
    activeFile = '',
    annotations = EMPTY_ANNOTATIONS,
    diffRows = EMPTY_DIFF_ROWS,
  } = props
  const store = useMemo(() => {
    const store = createRunActivityStore(DEFAULT_ROOM_ID)
    store.seed(EMPTY_ACTIVITY)
    return store
  }, [])
  const [, forceRender] = useState(0)

  useEffect(() => {
    let cancelled = false
    fetchActivityEvents().then(({ events, roomId }) => {
      if (cancelled) return
      store.reset(roomId)
      store.seed(events)
    })
    return () => { cancelled = true }
  }, [store])

  useEffect(() => {
    const unsub = store.subscribe(() => forceRender(tick => tick + 1))
    return () => unsub()
  }, [store])
  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => forceRender(tick => tick + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(() => forceRender(tick => tick + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = ideConversationThreadSnapshot.subscribe(() => forceRender(tick => tick + 1))
    return () => unsub()
  }, [])
  useEffect(() => {
    const unsub = lspDiagnosticSnapshot.subscribe(() => forceRender(tick => tick + 1))
    return () => unsub()
  }, [])

  const events = store.events()
  const keepers = store.knownKeepers()
  const presence = globalPresenceSnapshot.value
  const overlay = cursorOverlaySignal.value
  const threadSnapshot = ideConversationThreadSnapshot.value
  const threads = threadSnapshot.filePath === activeFile ? threadSnapshot.threads : []
  const activeFilePath = normalizeIdeContextFilePath(activeFile)
  const diagnostics = activeFilePath === null
    ? EMPTY_DIAGNOSTICS
    : lspDiagnosticSnapshot.value.get(activeFilePath) ?? EMPTY_DIAGNOSTICS
  const progress = deriveIdeRunProgressSummary(events, activeFile)

  return html`
    <div
      class="ide-rail-panel ide-activity-panel"
      role="region"
      aria-label="EVENT TIMELINE"
    >
      <div
        class="ide-rail-head"
      >
        <span>EVENT TIMELINE</span>
        <span>${events.length} events · ${keepers.length} keepers</span>
      </div>
      <${RunProgressStrip} summary=${progress} />
      <${IdeContextLens}
        filePath=${activeFile}
        annotations=${annotations}
        diffRows=${diffRows}
        events=${events}
        threads=${threads}
        diagnostics=${diagnostics}
        overlay=${overlay}
      />
      <ol
        class="ide-rail-list ide-activity-list"
      >
        ${events.length === 0
          ? html`<li class="ide-rail-empty">no recent activity</li>`
          : events.map(item => ActivityRow(item, presence, overlay))}
      </ol>
    </div>
  `
}

export function deriveIdeRunProgressSummary(
  events: ReadonlyArray<RunActivityEvent>,
  activeFile: string,
): IdeRunProgressSummary {
  const activeFilePath = normalizeIdeContextFilePath(activeFile)
  const currentFileEvents = activeFilePath === null
    ? 0
    : events.filter(event =>
      event.context?.file_path !== undefined
      && normalizeIdeContextFilePath(event.context.file_path) === activeFilePath,
    ).length
  const linkedEvents = events.filter(event => event.context !== undefined).length
  const surfaceCounts: Array<{ readonly label: string; readonly count: number }> = PROGRESS_SURFACES.map(([key, label]) => ({
    label,
    count: events.filter(event => event.context?.[key]).length,
  }))
  surfaceCounts.push({ label: 'Telemetry', count: events.length })
  const keeperEntries = [...events.reduce((acc, event) => {
    acc.set(event.keeper_id, (acc.get(event.keeper_id) ?? 0) + 1)
    return acc
  }, new Map<string, number>())]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
  const keeperCounts = keeperEntries
    .slice(0, 3)
    .map(([keeper_id, count]) => ({ keeper_id, count }))
  return {
    totalEvents: events.length,
    currentFileEvents,
    linkedEvents,
    keeperTotalCount: keeperEntries.length,
    latestAgeLabel: latestAgeLabel(events),
    surfaceCounts,
    keeperCounts,
  }
}

function RunProgressStrip({ summary }: { readonly summary: IdeRunProgressSummary }) {
  return html`
    <section class="ide-run-progress" aria-label="Run progress summary">
      <div class="ide-run-progress-head">
        <span>RUN PROGRESS</span>
        <span>${summary.linkedEvents}/${summary.totalEvents} linked</span>
      </div>
      <div class="ide-run-progress-stats" role="list" aria-label="Run progress stats">
        <span role="listitem"><strong>${summary.totalEvents}</strong> events</span>
        <span role="listitem"><strong>${summary.currentFileEvents}</strong> file</span>
        <span role="listitem"><strong>${summary.keeperTotalCount}</strong> keepers</span>
        <span role="listitem">${summary.latestAgeLabel}</span>
      </div>
      <div class="ide-run-progress-surfaces" role="list" aria-label="Linked operational surfaces">
        ${summary.surfaceCounts.map(surface => html`
          <span role="listitem" data-active=${surface.count > 0 ? 'true' : 'false'}>
            <span>${surface.label}</span>
            <span>${surface.count}</span>
          </span>
        `)}
      </div>
      <div class="ide-run-progress-keepers" aria-label="Top active keepers">
        ${summary.keeperCounts.length === 0
          ? html`<span>no keeper activity</span>`
          : summary.keeperCounts.map(entry => html`
            <span title=${`${entry.keeper_id}: ${entry.count} events`}>
              <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" />
              <span>${entry.count}</span>
            </span>
          `)}
      </div>
    </section>
  `
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

function ActivityRow(
  item: RunActivityEvent,
  presence: KeeperPresenceSnapshot | null,
  overlay: KeeperCursorOverlay,
) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  const entry = presence?.entries.find(e => e.keeper_id === item.keeper_id)
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = overlay.cursors.get(item.keeper_id)
  // cursor stream normalizes missing line to 0; only render the focus
  // label when both file_path and a 1-based line are present so we
  // don't show `filename:0` placeholders.
  const hasFocus = !!cursor && !!cursor.file_path && cursor.line >= 1
  const focusFile = hasFocus ? cursor.file_path.split('/').pop() : null
  const eventContextFile = item.context?.file_path
  const eventFocusFile = eventContextFile === undefined ? null : normalizeIdeContextFilePath(eventContextFile)
  const eventFocusLine = normalizeIdeContextLine(item.context?.line)
  const hasEventContextFocus = eventFocusFile !== null
  const routeLinks = routeLinksForContext({
    goalId: item.context?.goal_id,
    taskId: item.context?.task_id,
    boardPostId: item.context?.board_post_id,
    commentId: item.context?.comment_id,
    prId: item.context?.pr_id,
    gitRef: item.context?.git_ref,
    logId: item.context?.log_id,
    keeperId: item.keeper_id,
    telemetry: true,
  })

  return html`
    <li
      class="ide-activity-row"
      style=${{
        '--ide-activity-dot': dot,
      }}
    >
      <span class="ide-activity-time">${formatActivityTime(item.timestamp_ms)}</span>
      <span class="ide-activity-dot" aria-hidden="true" />
      <div style=${{ display: 'flex', flexDirection: 'column', gap: '2px', minWidth: 0 }}>
        <span style=${{ fontSize: 'var(--fs-11)', display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}>
          <${KeeperBadge} id=${item.keeper_id} variant="full" size="sm" />
          ${' '}${item.verb}${' '}<span style=${{ color: 'var(--color-fg-muted)' }}>${item.target}</span>
          ${statusDot ? html`
            <span
              role="status"
              aria-label=${`Current: ${statusDot.label}`}
              style=${{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '3px',
                fontSize: 'var(--fs-10)',
                fontWeight: 600,
                letterSpacing: '0.04em',
                color: statusDot.color,
                marginLeft: 'auto',
                whiteSpace: 'nowrap',
                flexShrink: 0,
              }}
            >
              <span style=${{
                width: '4px',
                height: '4px',
                borderRadius: '50%',
                background: statusDot.color,
                display: 'inline-block',
              }} />
              ${statusDot.label}
            </span>
          ` : null}
        </span>
        ${item.detail ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>${item.detail}</span>` : null}
        ${hasEventContextFocus ? html`
          <button
            type="button"
            class="ide-activity-context-jump"
            aria-label=${activityContextLabel(item, eventFocusFile, eventFocusLine)}
            title=${activityContextTitle(eventFocusFile, eventFocusLine)}
            onClick=${() => focusIdeContextAnchor({
              file_path: eventFocusFile,
              line: eventFocusLine,
              surface: activityContextSurface(item),
              label: item.detail ?? `${item.verb} ${item.target}`,
              source_id: item.id,
              keeper_id: item.keeper_id,
              route_links: routeLinks,
            })}
          >
            ↗ ${shortContextPath(eventFocusFile, eventFocusLine)}
          </button>
        ` : null}
        ${routeLinks.length > 0 ? html`
          <div class="ide-activity-route-links" aria-label="Activity operational links">
            ${routeLinks.map(link => ActivityRouteLink(link))}
          </div>
        ` : null}
        ${hasFocus ? html`
          <span style=${{
            fontSize: 'var(--fs-10)',
            fontFamily: 'var(--font-mono)',
            color: 'var(--color-accent-fg)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
          title=${cursor.file_path}
          >↗ ${focusFile}:${cursor.line}</span>
        ` : null}
      </div>
    </li>
  `
}

function ActivityRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-activity-route-link"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

function activityContextSurface(item: RunActivityEvent): string {
  if (item.context?.pr_id) return 'PR'
  if (item.context?.board_post_id) return 'Board'
  if (item.context?.goal_id) return 'Goal'
  if (item.context?.task_id) return 'Task'
  if (item.context?.git_ref) return 'Git'
  if (item.context?.log_id) return 'Log'
  return 'Activity'
}

function activityContextLabel(
  item: RunActivityEvent,
  filePath: string,
  line: number | undefined,
): string {
  const suffix = line !== undefined ? ` line ${line}` : ''
  return `Focus ${activityContextSurface(item)} context ${filePath}${suffix}`
}

function activityContextTitle(filePath: string, line: number | undefined): string {
  return line !== undefined ? `${filePath}:${line}` : filePath
}

function shortContextPath(filePath: string, line: number | undefined): string {
  const fileLabel = filePath.split('/').pop() || filePath
  return line !== undefined ? `${fileLabel}:${line}` : fileLabel
}

function formatActivityTime(ms: number): string {
  return new Date(ms).toISOString().slice(11, 19)
}
