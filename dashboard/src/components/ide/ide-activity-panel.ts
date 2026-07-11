import { html } from 'htm/preact'
import { memo } from 'preact/compat'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { useSignalValue, useStoreSubscription } from './use-signal-value'
import { get } from '../../api/core'
import { fetchIdeEvents, type IdeBridgeEvent } from '../../api/ide'
import { asRecord, isPositiveSafeInteger } from '../common/normalize'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import type { UnifiedDiffRow } from '../../api/workspace'
import { KeeperBadge } from '../keeper-badge'
import type { Goal, Task } from '../../types'
import { goals, tasks } from '../../store'
import {
  formatProgressPct,
  goalPhaseLabel,
  type GoalProgress,
} from '../goals/goal-helpers'
import { ideConversationThreadSnapshot } from './ide-context-bridge'
import { globalPresenceSnapshot, PRESENCE_DOT, presenceEntries, type KeeperPresenceSnapshot } from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursorOverlay } from './keeper-cursor-overlay'
import {
  IdeContextLens,
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteContext,
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
import { bridgeRunActivityEventsToTrace } from './run-activity-trace-bridge'
import { isRecord } from '../../lib/type-guards'

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
  readonly workspace_id: string
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

interface GraphFetchResult {
  readonly events: ReadonlyArray<RunActivityEvent>
  readonly workspaceId: string
  readonly ok: boolean
}

type ActivityFetchResult = GraphFetchResult

type ActivityRefreshTone = 'loading' | 'live' | 'stale' | 'offline'

interface ActivityRefreshState {
  readonly tone: ActivityRefreshTone
  readonly lastOkMs: number | null
  readonly lastAttemptMs: number | null
  readonly failedCount: number
}

const EMPTY_ACTIVITY: ReadonlyArray<RunActivityEvent> = []
const EMPTY_KEEPERS: ReadonlyArray<string> = []
const EMPTY_ANNOTATIONS: ReadonlyArray<IdeAnnotation> = []
const EMPTY_DIFF_ROWS: ReadonlyArray<UnifiedDiffRow> = []
const EMPTY_DIAGNOSTICS: ReadonlyArray<LspDiagnosticAnchor> = []
const INITIAL_REFRESH_STATE: ActivityRefreshState = {
  tone: 'loading',
  lastOkMs: null,
  lastAttemptMs: null,
  failedCount: 0,
}
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

const DEFAULT_WORKSPACE_ID = 'run-default'
type MutableRunActivityContext = {
  -readonly [K in keyof RunActivityContext]?: RunActivityContext[K]
}

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
  readonly phase: string
  readonly progress: GoalProgress
  readonly progressLabel: string
}

export interface IdeActivityPanelProps {
  readonly activeFile?: string | null
  readonly repoId?: string | null
  /**
   * Keeper whose repo-unattributed lane (turn/coordination events) is
   * merged into the feed alongside repo-scoped events.
   */
  readonly keeperLane?: string | null
  readonly annotations?: ReadonlyArray<IdeAnnotation>
  readonly diffRows?: ReadonlyArray<UnifiedDiffRow>
  readonly pollMs?: number
  readonly compact?: boolean
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
  if (isRecord(payload)) {
    const summary = payload['summary'] ?? payload['title'] ?? payload['body'] ?? payload['reason']
    if (typeof summary === 'string' && summary.trim() !== '') {
      const truncated = summary.length > 120 ? summary.slice(0, 117) + '...' : summary
      return truncated
    }
  }
  return kind
}

function mapApiEvent(event: ApiActivityEvent, workspaceId: string): RunActivityEvent {
  return {
    id: `evt-${event.seq}`,
    run_id: workspaceId,
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

async function fetchActivityEvents(
  repoId?: string | null,
  keeperLane?: string | null,
): Promise<ActivityFetchResult> {
  const graph = await fetchActivityGraphEvents()
  const bridge = await fetchIdeBridgeRunActivityEvents(graph.workspaceId, repoId, keeperLane)
  return {
    workspaceId: graph.workspaceId,
    // A bridge fetch failure must degrade the refresh tone instead of
    // rendering an empty-but-"live" feed: an operator cannot distinguish
    // "no keeper activity" from "the activity source is broken" otherwise.
    ok: graph.ok && bridge.ok,
    events: mergeRunActivityEvents(graph.events, bridge.events),
  }
}

async function fetchActivityGraphEvents(): Promise<GraphFetchResult> {
  try {
    const data = await get<ApiActivityResponse>('/api/v1/activity/events?limit=50')
    const rawEvents = data.events
    if (!Array.isArray(rawEvents) || rawEvents.length === 0) {
      return { events: EMPTY_ACTIVITY, workspaceId: DEFAULT_WORKSPACE_ID, ok: true }
    }
    const workspaceId = rawEvents[0].workspace_id || DEFAULT_WORKSPACE_ID
    const mapped = rawEvents.map(e => mapApiEvent(e, workspaceId))
    return { events: mapped, workspaceId, ok: true }
  } catch {
    return { events: EMPTY_ACTIVITY, workspaceId: DEFAULT_WORKSPACE_ID, ok: false }
  }
}

interface BridgeFetchResult {
  readonly events: ReadonlyArray<RunActivityEvent>
  readonly ok: boolean
}

/**
 * Repo-scoped events cover file-attributed observations; the keeper lane
 * covers turn/coordination events that carry no file and live in the
 * repo-unattributed bucket, unreachable through any repo scope. Both
 * sources are queried, and a failure in either is reported through
 * [ok=false] rather than silently collapsing to an empty feed.
 */
async function fetchIdeBridgeRunActivityEvents(
  workspaceId: string,
  repoId?: string | null,
  keeperLane?: string | null,
): Promise<BridgeFetchResult> {
  const sources: Array<Promise<ReadonlyArray<IdeBridgeEvent>>> = []
  const repo = repoId?.trim()
  if (repo) sources.push(fetchIdeEvents({ limit: 50, repoId: repo }))
  const lane = keeperLane?.trim()
  if (lane) {
    sources.push(fetchIdeEvents({ limit: 50, scope: { kind: 'keeper_lane', keeperId: lane } }))
  }
  // Neither scope is set: there is nothing to query, not a request that
  // happened to find zero events. The caller derives the visible no-scope
  // state from the current props, before any asynchronous response arrives.
  if (sources.length === 0) return { events: EMPTY_ACTIVITY, ok: true }
  const settled = await Promise.allSettled(sources)
  const events: RunActivityEvent[] = []
  let ok = true
  for (const result of settled) {
    if (result.status === 'fulfilled') {
      for (const event of result.value) {
        events.push(mapIdeBridgeEvent(event, workspaceId, events.length))
      }
    } else {
      ok = false
    }
  }
  return { events, ok }
}

function mergeRunActivityEvents(
  graphEvents: ReadonlyArray<RunActivityEvent>,
  bridgeEvents: ReadonlyArray<RunActivityEvent>,
): ReadonlyArray<RunActivityEvent> {
  if (bridgeEvents.length === 0) return graphEvents
  if (graphEvents.length === 0) return bridgeEvents
  return [...graphEvents, ...bridgeEvents].sort(compareRunActivityEvents)
}

function mapIdeBridgeEvent(
  event: IdeBridgeEvent,
  workspaceId: string,
  index: number,
): RunActivityEvent {
  return {
    id: `ide-${event.type}-${event.turn_id}-${event.timestamp_ms}-${index}`,
    run_id: workspaceId,
    timestamp_ms: event.timestamp_ms,
    keeper_id: event.keeper_id,
    verb: 'noted',
    target: bridgeEventTarget(event),
    detail: bridgeEventDetail(event),
    kind: `ide.bridge.${event.type}`,
    tags: [`ide:${event.type}`, `turn:${event.turn_id}`],
    context: bridgeEventContext(event),
  }
}

function bridgeEventTarget(event: IdeBridgeEvent): string {
  if (event.type === 'tool') return `tool:${event.tool_name}`
  if (event.type === 'turn') return `turn:${event.phase}`
  return `pr:${event.pr_number}`
}

function bridgeEventDetail(event: IdeBridgeEvent): string {
  if (event.type === 'tool') {
    const outcome = event.typed_outcome || event.outcome
    return `${outcome}: ${event.summary}`
  }
  if (event.type === 'turn') {
    return [event.phase, event.model_used, event.stop_reason]
      .filter((item): item is string => typeof item === 'string' && item.trim() !== '')
      .join(' · ') || event.phase
  }
  return event.pr_title || event.pull_request_url || event.pr_state || `PR ${event.pr_number}`
}

function bridgeEventContext(event: IdeBridgeEvent): RunActivityContext | undefined {
  const context: MutableRunActivityContext = {}
  if (event.turn_id) context.log_id = event.turn_id
  if (event.type === 'tool') {
    const filePath = event.file_path ? normalizeIdeContextFilePath(event.file_path) : null
    if (filePath) context.file_path = filePath
    mergeCommandDescriptorContext(context, event.command_descriptor)
  } else if (event.type === 'pr') {
    if (event.pr_number > 0) context.pr_id = String(event.pr_number)
  }
  return Object.keys(context).length === 0 ? undefined : context
}

function mergeCommandDescriptorContext(
  context: MutableRunActivityContext,
  descriptor: unknown,
): void {
  if (!isRecord(descriptor)) return
  const prNumber = positiveInteger(descriptor.pr_number)
  if (prNumber !== undefined) context.pr_id = String(prNumber)
  const branch = stringValue(descriptor.branch)
  if (branch) context.git_ref = branch
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
  mergeContextRecord(next, asRecord(record.context))
  mergeContextRecord(next, asRecord(record.evidence_ref))
  const failureEnvelope = asRecord(record.failure_envelope)
  mergeContextRecord(next, asRecord(failureEnvelope?.evidence_ref))
  mergeContextRecord(next, asRecord(record.tool_args))
  mergeContextRecord(next, asRecord(record.input))
  mergeContextRecord(next, record, true)
}

function mergeContextRecord(
  next: MutableRunActivityContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const filePath = stringValue(record.file_path)
    ?? stringValue(record.path)
    ?? stringValue(record.file)
  const normalizedFilePath = filePath ? normalizeIdeContextFilePath(filePath) : null
  if (normalizedFilePath && (overwrite || next.file_path === undefined)) next.file_path = normalizedFilePath
  const line = positiveInteger(record.line)
    ?? positiveInteger(record.line_start)
    ?? positiveInteger(record.lineno)
  if (line !== undefined && (overwrite || next.line === undefined)) next.line = line
  const goalId = stringValue(record.goal_id)
  if (goalId && (overwrite || next.goal_id === undefined)) next.goal_id = goalId
  const taskId = stringValue(record.task_id)
  if (taskId && (overwrite || next.task_id === undefined)) next.task_id = taskId
  const boardPostId = stringValue(record.board_post_id) ?? stringValue(record.post_id)
  if (boardPostId && (overwrite || next.board_post_id === undefined)) next.board_post_id = boardPostId
  const commentId = stringValue(record.comment_id)
    ?? stringValue(record.reply_id)
    ?? numberString(record.comment_number)
  if (commentId && (overwrite || next.comment_id === undefined)) next.comment_id = commentId
  const prId = stringValue(record.pr_id)
    ?? stringValue(record.pull_request)
    ?? numberString(record.pr_number)
  if (prId && (overwrite || next.pr_id === undefined)) next.pr_id = prId
  const gitRef = stringValue(record.git_ref)
    ?? stringValue(record.commit)
    ?? stringValue(record.branch)
  if (gitRef && (overwrite || next.git_ref === undefined)) next.git_ref = gitRef
  const logId = stringValue(record.log_id)
  if (logId && (overwrite || next.log_id === undefined)) next.log_id = logId
  const sessionId = stringValue(record.session_id)
  if (sessionId && (overwrite || next.session_id === undefined)) next.session_id = sessionId
  const operationId = stringValue(record.operation_id)
  if (operationId && (overwrite || next.operation_id === undefined)) next.operation_id = operationId
  const workerRunId = stringValue(record.worker_run_id)
  if (workerRunId && (overwrite || next.worker_run_id === undefined)) next.worker_run_id = workerRunId
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
    if (!normalizedPath) return
    next.file_path = normalizedPath
    if (match?.[2]) next.line = Number.parseInt(match[2], 10)
    return
  }
  if (key === 'line') {
    const line = Number.parseInt(value, 10)
    if (isPositiveSafeInteger(line)) next.line = line
    return
  }
  if (key === 'goal') next.goal_id = value
  else if (key === 'task') next.task_id = value
  else if (key === 'board' || key === 'post') next.board_post_id = value
  else if (key === 'comment' || key === 'reply') next.comment_id = value
  else if (key === 'pr' || key === 'pull_request' || key === 'review') next.pr_id = value
  else if (key === 'git' || key === 'commit' || key === 'branch') next.git_ref = value
  else if (key === 'log' || key === 'telemetry') next.log_id = value
  else if (key === 'session' || key === 'session_id') next.session_id = value
  else if (key === 'operation' || key === 'operation_id' || key === 'op') next.operation_id = value
  else if (key === 'worker_run' || key === 'worker_run_id' || key === 'worker') next.worker_run_id = value
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

function numberString(value: unknown): string | undefined {
  return isPositiveSafeInteger(value) ? String(value) : undefined
}

function positiveInteger(value: unknown): number | undefined {
  return isPositiveSafeInteger(value) ? value : undefined
}

function normalizedPollMs(value: number | undefined): number | null {
  if (value === undefined || value <= 0 || !Number.isFinite(value)) return null
  return Math.floor(value)
}

function activityScopeKey(repoId?: string | null, keeperLane?: string | null): string {
  return JSON.stringify([repoId?.trim() || null, keeperLane?.trim() || null])
}

function hasActivityBridgeScope(repoId?: string | null, keeperLane?: string | null): boolean {
  return Boolean(repoId?.trim()) || Boolean(keeperLane?.trim())
}

export function IdeActivityPanel(props: IdeActivityPanelProps = {}) {
  const {
    activeFile: rawActiveFile = '',
    repoId = null,
    keeperLane = null,
    annotations = EMPTY_ANNOTATIONS,
    diffRows = EMPTY_DIFF_ROWS,
    pollMs = 0,
    compact = false,
  } = props
  const activeFile = rawActiveFile ?? ''
  const store = useMemo(() => {
    const store = createRunActivityStore(DEFAULT_WORKSPACE_ID)
    store.seed(EMPTY_ACTIVITY)
    return store
  }, [])
  const [refreshState, setRefreshState] = useState<ActivityRefreshState>(INITIAL_REFRESH_STATE)
  const requestedScopeKey = activityScopeKey(repoId, keeperLane)
  const bridgeScoped = hasActivityBridgeScope(repoId, keeperLane)
  const [loadedScopeKey, setLoadedScopeKey] = useState<string | null>(null)
  const loadedScopeKeyRef = useRef<string | null>(null)
  const [compactInsightsOpen, setCompactInsightsOpen] = useState(false)
  const emittedTraceIds = useRef<ReadonlySet<string>>(new Set())
  const refreshMs = normalizedPollMs(pollMs)

  useEffect(() => {
    if (loadedScopeKeyRef.current !== requestedScopeKey) {
      setRefreshState(INITIAL_REFRESH_STATE)
    }
  }, [requestedScopeKey])

  useEffect(() => {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const load = async () => {
      const attemptMs = Date.now()
      setRefreshState(prev => ({
        ...prev,
        lastAttemptMs: attemptMs,
        tone: prev.lastOkMs === null && prev.failedCount === 0 ? 'loading' : prev.tone,
      }))
      const { events, workspaceId, ok } = await fetchActivityEvents(repoId, keeperLane)
      if (cancelled) return
      if (ok) {
        store.reset(workspaceId)
        store.seed(events)
        loadedScopeKeyRef.current = requestedScopeKey
        setLoadedScopeKey(requestedScopeKey)
        setRefreshState({
          tone: 'live',
          lastOkMs: Date.now(),
          lastAttemptMs: attemptMs,
          failedCount: 0,
        })
      } else {
        const sameScopeSnapshot = loadedScopeKeyRef.current === requestedScopeKey
        setRefreshState(prev => ({
          tone: sameScopeSnapshot && prev.lastOkMs !== null ? 'stale' : 'offline',
          lastOkMs: sameScopeSnapshot ? prev.lastOkMs : null,
          lastAttemptMs: attemptMs,
          failedCount: prev.failedCount + 1,
        }))
      }
      if (refreshMs !== null) timer = setTimeout(load, refreshMs)
    }
    void load()
    return () => {
      cancelled = true
      if (timer !== null) clearTimeout(timer)
    }
  }, [store, refreshMs, repoId, keeperLane, requestedScopeKey])

  useStoreSubscription(store.subscribe)
  useSignalValue(globalPresenceSnapshot)
  useSignalValue(cursorOverlaySignal)
  useSignalValue(ideConversationThreadSnapshot)
  useSignalValue(lspDiagnosticSnapshot)

  const snapshotMatchesScope = loadedScopeKey === requestedScopeKey
  const events = snapshotMatchesScope ? store.events() : EMPTY_ACTIVITY
  const keepers = snapshotMatchesScope ? store.knownKeepers() : EMPTY_KEEPERS
  const presence = globalPresenceSnapshot.value
  const overlay = cursorOverlaySignal.value
  const threadSnapshot = ideConversationThreadSnapshot.value
  const threads = threadSnapshot.filePath === activeFile ? threadSnapshot.threads : []
  const activeFilePath = normalizeIdeContextFilePath(activeFile)
  const diagnostics = activeFilePath === null
    ? EMPTY_DIAGNOSTICS
    : lspDiagnosticSnapshot.value.get(activeFilePath) ?? EMPTY_DIAGNOSTICS
  const progress = deriveIdeRunProgressSummary(events, activeFile, goals.value, tasks.value)

  useEffect(() => {
    emittedTraceIds.current = bridgeRunActivityEventsToTrace(events, emittedTraceIds.current)
  }, [events])

  return html`
    <div
      class=${`ide-rail-panel ide-activity-panel ${compact ? 'is-compact' : ''}`}
      role="region"
      aria-label="EVENT TIMELINE"
    >
      ${compact ? null : html`
        <div
          class="ide-rail-head"
        >
          <span>EVENT TIMELINE</span>
          <span class="ide-activity-head-meta">
            <span>${events.length} events · ${keepers.length} keepers</span>
            <span
              class="ide-activity-refresh-status"
              data-state=${refreshState.tone}
              role="status"
              aria-label=${`Activity refresh ${activityRefreshLabel(refreshState, refreshMs)}`}
              title=${activityRefreshTitle(refreshState, refreshMs)}
            >
              ${activityRefreshLabel(refreshState, refreshMs)}
            </span>
          </span>
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
      `}
      ${compact ? html`
        <div
          class="ide-activity-compact-status"
          data-state=${refreshState.tone}
          role="status"
          aria-label=${`Activity refresh ${activityRefreshLabel(refreshState, refreshMs)}`}
          title=${activityRefreshTitle(refreshState, refreshMs)}
        >
          <span>${events.length} events · ${keepers.length} keepers</span>
          <span>${activityRefreshLabel(refreshState, refreshMs)}</span>
        </div>
        <div class="ide-activity-compact-insights">
          <button
            type="button"
            aria-expanded=${compactInsightsOpen ? 'true' : 'false'}
            onClick=${() => setCompactInsightsOpen(current => !current)}
          >
            Observation context
            <span>${progress.linkedEvents}/${progress.totalEvents} linked</span>
          </button>
          ${compactInsightsOpen ? html`
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
          ` : null}
        </div>
      ` : null}
      <ol
        class="ide-rail-list ide-activity-list"
      >
        ${events.length === 0
          ? bridgeScoped
            ? html`<li class="ide-rail-empty">no recent activity</li>`
            : html`<li class="ide-rail-empty" data-testid="ide-activity-no-scope">관측 스코프(저장소/keeper)가 선택되지 않았습니다</li>`
          : events.map(item => html`<${ActivityRow} item=${item} presence=${presence} overlay=${overlay} />`)}
      </ol>
    </div>
  `
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

function RunProgressStrip({ summary }: { readonly summary: IdeRunProgressSummary }) {
  return html`
    <section class="ide-run-progress" aria-label="Run progress summary">
      <div class="ide-run-progress-head">
        <span>RUN PROGRESS</span>
        <span>${summary.linkedEvents}/${summary.totalEvents} linked</span>
      </div>
      <div class="ide-run-progress-coverage">
        <div class="ide-run-progress-coverage-head">
          <span>CONTEXT COVERAGE</span>
          <span>${summary.linkedCoverageLabel}</span>
        </div>
        <div
          class="ide-run-progress-coverage-bar"
          role="progressbar"
          aria-label=${`Linked context coverage ${summary.linkedEvents} of ${summary.totalEvents} events`}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow=${summary.linkedCoveragePercent}
        >
          <span style=${{ width: summary.linkedCoverageLabel }} />
        </div>
      </div>
      <div class="ide-run-progress-stats" role="list" aria-label="Run progress stats">
        <span role="listitem"><strong>${summary.totalEvents}</strong> events</span>
        <span role="listitem"><strong>${summary.currentFileEvents}</strong> file</span>
        <span role="listitem"><strong>${summary.keeperTotalCount}</strong> keepers</span>
        <span role="listitem">${summary.latestAgeLabel}</span>
      </div>
      ${summary.activeGoal ? RunProgressGoalTrack(summary.activeGoal) : null}
      <div class="ide-run-progress-surfaces" role="list" aria-label="Linked operational surfaces">
        ${summary.surfaceCounts.map(surface => RunProgressSurfaceChip(surface))}
      </div>
      <div class="ide-run-progress-keepers" aria-label="Top active keepers">
        ${summary.keeperCounts.length === 0
          ? html`<span>no keeper activity</span>`
          : summary.keeperCounts.map(entry => RunProgressKeeperChip(entry))}
      </div>
    </section>
  `
}

function RunProgressKeeperChip(entry: IdeRunProgressKeeperCount) {
  const routeLink = entry.routeLink
  return html`
    <span
      title=${`${entry.keeper_id}: ${entry.count} events`}
      data-actionable=${routeLink ? 'true' : 'false'}
    >
      ${routeLink
        ? html`
          <button
            type="button"
            class="ide-run-progress-keeper-link v2-ide-action"
            title=${routeLink.evidence}
            aria-label=${`Open ${routeLink.evidence}`}
            onClick=${() => openIdeContextRouteLink(routeLink)}
          >
            <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" />
            <span>${entry.count}</span>
          </button>
        `
        : html`
          <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" />
          <span>${entry.count}</span>
        `}
    </span>
  `
}

function RunProgressSurfaceChip(surface: IdeRunProgressSurfaceCount) {
  const routeLink = surface.routeLink
  return html`
    <span role="listitem" data-active=${surface.count > 0 ? 'true' : 'false'}>
      ${routeLink
        ? html`
          <button
            type="button"
            class="ide-run-progress-surface-link v2-ide-action"
            title=${routeLink.evidence}
            aria-label=${`Open ${routeLink.evidence}`}
            onClick=${() => openIdeContextRouteLink(routeLink)}
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

function RunProgressGoalTrack(goal: IdeRunProgressGoal) {
  const percent = Math.round(goal.progress.ratio * 100)
  const links = routeLinksForContext({
    goalId: goal.goalId,
    taskId: goal.taskId ?? undefined,
  })
  return html`
    <div
      class="ide-run-progress-goal"
      role="status"
      aria-label=${`Run goal ${goal.goalId} progress ${goal.progressLabel}`}
    >
      <div class="ide-run-progress-goal-top">
        <span>GOAL TRACK</span>
        <span>${goal.phase}</span>
      </div>
      <strong title=${goal.title}>${goal.title}</strong>
      <div class="ide-run-progress-goal-bar" aria-hidden="true">
        <span style=${{ width: `${percent}%` }} />
      </div>
      <div class="ide-run-progress-goal-meta">
        <span>${goal.progress.done}/${goal.progress.total} tasks</span>
        <span>${goal.progressLabel}</span>
        <span title=${goal.goalId}>${goal.goalId}</span>
      </div>
      ${links.length > 0
        ? html`
          <div class="ide-run-progress-goal-links" aria-label="Run goal planning links">
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
        : null}
    </div>
  `
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

function compareRunActivityEvents(left: RunActivityEvent, right: RunActivityEvent): number {
  if (left.timestamp_ms !== right.timestamp_ms) return right.timestamp_ms - left.timestamp_ms
  return left.id.localeCompare(right.id)
}

function activityRouteLinks(item: RunActivityEvent): ReadonlyArray<IdeContextRouteLink> {
  return routeLinksForContext(activityRouteContext(item))
}

function activityRouteContext(item: RunActivityEvent): IdeContextRouteContext {
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

function activityRefreshLabel(state: ActivityRefreshState, refreshMs: number | null): string {
  if (state.tone === 'loading') return 'syncing'
  if (state.tone === 'live') return refreshMs === null ? 'loaded' : 'live'
  const failures = state.failedCount === 1 ? '1 failed' : `${state.failedCount} failed`
  return state.tone === 'offline' ? `offline ${failures}` : `stale ${failures}`
}

function activityRefreshTitle(state: ActivityRefreshState, refreshMs: number | null): string {
  const parts = [`Activity refresh ${activityRefreshLabel(state, refreshMs)}`]
  if (state.lastOkMs !== null) parts.push(`last update ${formatActivityTime(state.lastOkMs)}`)
  if (state.lastAttemptMs !== null) parts.push(`last attempt ${formatActivityTime(state.lastAttemptMs)}`)
  if (refreshMs !== null) parts.push(`poll ${Math.max(1, Math.round(refreshMs / 1000))}s`)
  return parts.join(' | ')
}

const ActivityRow = memo(function ActivityRow({
  item,
  presence,
  overlay,
}: {
  item: RunActivityEvent
  presence: KeeperPresenceSnapshot | null
  overlay: KeeperCursorOverlay
}) {
  const hue = keeperHueIndex(item.keeper_id)
  const dot = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  const entry = presenceEntries(presence).find(e => e.keeper_id === item.keeper_id)
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
  const routeLinks = activityRouteLinks(item)

  return html`
    <li
      class="ide-activity-row v2-ide-row"
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
            class="ide-activity-context-jump v2-ide-action"
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
            }, 'operator')}
          >
            ↗ ${shortContextPath(eventFocusFile, eventFocusLine)}
          </button>
        ` : null}
        ${routeLinks.length > 0 ? html`
          <div class="ide-activity-route-links" aria-label="Activity operational links">
            <${ActivityRouteCount} count=${routeLinks.length} />
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
})

function ActivityRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-activity-route-link v2-ide-action"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

function ActivityRouteCount({ count }: { count: number }) {
  return html`
    <span
      class="ide-activity-route-count"
      title=${`${count} linked activity context routes`}
      aria-label=${`${count} linked activity context routes`}
    >
      CTX ${count}
    </span>
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
