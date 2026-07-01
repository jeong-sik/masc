import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { ChevronDown, ChevronRight, RefreshCw } from 'lucide-preact'
import { fetchLogs, fetchProviderLogsCatalog, fetchProviderLogTail } from '../api/dashboard.js'
import type {
  LogEntry,
  ProviderLogCatalogEntry,
  ProviderLogsCatalogResponse,
  ProviderLogTailResponse,
} from '../api/dashboard.js'
import { VirtualList } from './common/virtual-list'
import { asRecord, asNullableString, mergeRouteRecord, hasRouteContext, type MutableRouteContext } from './common/normalize'
import { TextInput } from './common/input'
import { Select } from './common/select'
import { Checkbox } from './common/checkbox'
import { LogFilter } from './common/log-filter'
import { RouteLink } from './common/route-link'
import { KeeperBadge } from './keeper-badge'
import { createAsyncResource, loaded } from '../lib/async-state'
import { toolCategory } from './tool-call-shared'
import { StatusChip } from './common/status-chip'
import {
  detailLabel,
  entryDetails,
  logDisplayKind,
  type LogDisplayKind,
} from './log-classification'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide/ide-context-lens'
import type { LogsResponse } from '../api/schemas/logs'

type LogData = LogsResponse

export interface LogCauseCount {
  cause: string
  count: number
}

export interface LogModuleCount {
  module: string
  count: number
}

export interface LogWindowSummary {
  errors: number
  warnings: number
  failureEnvelopes: number
  topCauses: LogCauseCount[]
  topModules: LogModuleCount[]
}

const logResource = createAsyncResource<LogData>()
const providerLogCatalogResource = createAsyncResource<ProviderLogsCatalogResponse>()
const providerLogTailResource = createAsyncResource<ProviderLogTailResponse>()
const levelFilter = signal('INFO')
const moduleInput = signal('')
const appliedModuleFilter = signal('')
const autoRefresh = signal(true)
const DEFAULT_LOG_LIMIT = 200
const logLimit = signal(DEFAULT_LOG_LIMIT)
const providerLogProvider = signal('')
const providerLogLines = signal(200)
const latestSeq = signal<number | null>(null)
const categoryFilter = signal('')
// Client-side display-kind filter for the primary toolbar chips
// (전체/Tool/Turn/Lifecycle/Approval/Broadcast). Complementary to the
// backend categoryFilter above: kind slices the streamed rows in the view
// without re-querying, so switching kind is instant.
const kindFilter = signal<LogDisplayKind | ''>('')
const hideFsmTransitions = signal(false)
const expandedLogSeq = signal<number | null>(null)
// "load older" backward paging: the merge cap is derived per-poll by
// [deltaMergeCap] from the currently shown rows, so it does not need to persist
// in a signal. [pagedOlder] records whether the view has been expanded past the
// base limit; while it is false the delta poller keeps a fixed newest-N sliding
// window (bounded memory, steady state), and once true the cap grows to cover
// every shown row plus genuinely-new rows so neither path evicts history the
// operator paged into.
const pagedOlder = signal(false)
const olderLoading = signal(false)
const noMoreOlder = signal(false)

const POLL_INTERVAL_MS = 3000
const ESTIMATED_LOG_ROW_HEIGHT = 78
const EMPTY_LOG_ENTRIES: LogEntry[] = []

let moduleDebounceTimer: ReturnType<typeof setTimeout> | null = null
let latestRequestId = 0
let logQueryGeneration = 0

function MetaTag({ children }: { children: unknown }) {
  return html`<${StatusChip} tone="neutral" uppercase=${false}>${children}</${StatusChip}>`
}

const LEVEL_COLORS: Record<string, string> = {
  DEBUG: 'var(--color-fg-muted)',
  INFO: 'var(--color-fg-primary)',
  WARN: 'var(--color-status-warn)',
  ERROR: 'var(--color-status-err)',
}

const SOURCE_LABELS: Record<string, string> = {
  structured: 'structured',
  legacy_stderr: 'stderr',
  legacy_traceln: 'trace line',
  client_tool_host: 'client tool-host',
  sse: 'sse',
}

const CATEGORY_LABELS: Record<string, string> = {
  fsm: 'FSM',
  lifecycle: 'Lifecycle',
  directive: 'Directive',
  heartbeat: 'Heartbeat',
  presence: 'Presence',
  task: 'Task',
  tool: 'Tool',
  memory: 'Memory',
  telemetry: 'Telemetry',
  routine: 'Routine',
  boundary: 'Boundary',
  uncategorized: 'Uncategorized',
}

const LOG_KIND_FILTERS: readonly { value: LogDisplayKind | ''; label: string }[] = [
  { value: '', label: '전체' },
  { value: 'tool', label: 'Tool' },
  { value: 'turn', label: 'Turn' },
  { value: 'lifecycle', label: 'Lifecycle' },
  { value: 'approval', label: 'Approval' },
  { value: 'broadcast', label: 'Broadcast' },
]
// Backend log category, surfaced in the advanced (details) menu so the
// provider-log category filter is preserved while the primary toolbar uses
// the client-side display-kind chips above.
const LOG_CATEGORY_OPTIONS: readonly { value: string; label: string }[] = [
  { value: '', label: '전체 카테고리' },
  { value: 'tool', label: 'tool' },
  { value: 'task', label: 'task' },
  { value: 'lifecycle', label: 'lifecycle' },
  { value: 'directive', label: 'directive' },
  { value: 'telemetry', label: 'telemetry' },
]

function categoryLabel(category: string | null | undefined): string | null {
  if (!category) return null
  return CATEGORY_LABELS[category] ?? category
}

const LOG_KIND_LABELS: Record<LogDisplayKind, string> = {
  tool: 'TOOL',
  turn: 'TURN',
  lifecycle: 'LIFECYCLE',
  approval: 'APPROVAL',
  broadcast: 'BROADCAST',
  telemetry: 'TELEMETRY',
  task: 'TASK',
  log: 'LOG',
}

type LoadMode = 'reset' | 'delta'
type FailureEnvelope = {
  surface: string
  entity_kind: string
  entity_id: string | null
  cause_code: string
  severity: string
  summary: string
  recoverability: string
  operator_action: string | null
  evidence_ref: Record<string, unknown> | null
}

function normalizedLevel(entry: LogEntry): string {
  // RFC-0079: backend now emits a typed level via Log.Ring.entry_to_json.
  // The schema rejects rows without `level`, so the read-side fallback
  // chain (`normalized_level || level || 'INFO'`) is gone.
  return entry.level.toUpperCase()
}

function sortLogEntries(entries: LogEntry[]): LogEntry[] {
  return [...entries].sort((a, b) => b.seq - a.seq)
}

function latestLogSeq(entries: LogEntry[]): number | null {
  if (entries.length === 0) return null
  return entries.reduce((max, entry) => Math.max(max, entry.seq), entries[0]?.seq ?? 0)
}

export function mergeLogEntries(
  current: LogEntry[],
  incoming: LogEntry[],
  maxEntries: number,
): LogEntry[] {
  const merged = new Map<number, LogEntry>()
  current.forEach(entry => merged.set(entry.seq, entry))
  incoming.forEach(entry => merged.set(entry.seq, entry))
  return [...merged.values()]
    .sort((a, b) => b.seq - a.seq)
    .slice(0, Math.max(1, maxEntries))
}

// Cap for the delta poll's merge with the currently loaded rows.
// Un-paged steady state: a fixed newest-N sliding window ([baseLimit]) so memory
// stays bounded and old rows roll off as new ones arrive.
// Paged-open (operator used "load older"): keep EVERY currently shown row plus
// the genuinely-new (non-overlapping) incoming rows, so newest-first slicing in
// [mergeLogEntries] cannot evict the just-paged-in oldest rows on the next poll.
export function deltaMergeCap(
  current: readonly LogEntry[],
  incoming: readonly LogEntry[],
  pagedOlder: boolean,
  baseLimit: number,
): number {
  if (!pagedOlder) return baseLimit
  const currentSeqs = new Set(current.map(entry => entry.seq))
  const freshCount = incoming.reduce(
    (n, entry) => (currentSeqs.has(entry.seq) ? n : n + 1),
    0,
  )
  return current.length + freshCount
}

function sourceLabel(source: string): string {
  return SOURCE_LABELS[source] ?? (source || '(unknown source)')
}

function logSeverity(entry: LogEntry): 'ok' | 'warn' | 'bad' | 'busy' | 'info' {
  const level = normalizedLevel(entry)
  if (level === 'ERROR') return 'bad'
  if (level === 'WARN') return 'warn'
  const kind = logDisplayKind(entry)
  if (kind === 'tool') return 'busy'
  if (kind === 'telemetry' || kind === 'broadcast') return 'info'
  return 'ok'
}

function keeperLabel(entry: LogEntry, details: Record<string, unknown> | null): string {
  const keeper = entry.keeper_name?.trim()
  if (keeper) return keeper
  const clientName = detailLabel(details, 'client_name')
  if (clientName) return clientName
  const moduleName = entry.module?.trim()
  if (moduleName) return moduleName
  return '(root)'
}

function formatLogClock(ts: string): string {
  const match = ts.match(/T(\d{2}:\d{2}:\d{2})/)
  if (match?.[1]) return match[1]
  const date = new Date(ts)
  if (!Number.isNaN(date.getTime())) {
    return date.toLocaleTimeString('ko-KR', {
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }
  return ts
}

function logTimestampMs(entry: LogEntry): number | null {
  const ms = Date.parse(entry.ts)
  return Number.isFinite(ms) ? ms : null
}

function logWindowMinutes(entries: readonly LogEntry[]): number {
  const times = entries
    .map(logTimestampMs)
    .filter((value): value is number => value !== null)
  if (times.length < 2) return 1
  const span = Math.max(...times) - Math.min(...times)
  return Math.max(1, span / 60000)
}

function logWindowLabel(entries: readonly LogEntry[]): string {
  if (entries.length === 0) return 'waiting'
  const minutes = logWindowMinutes(entries)
  if (minutes < 2) return 'last 1m'
  if (minutes < 90) return `last ${Math.round(minutes)}m`
  return `last ${(minutes / 60).toFixed(1)}h`
}

function eventRatePerMinute(entries: readonly LogEntry[]): string {
  if (entries.length === 0) return '0.0'
  return (entries.length / logWindowMinutes(entries)).toFixed(1)
}

function logActiveIdentityCount(entries: readonly LogEntry[]): number {
  const ids = new Set<string>()
  for (const entry of entries) {
    const details = entryDetails(entry)
    const id = keeperLabel(entry, details)
    if (id !== '(root)') ids.add(id)
  }
  return ids.size
}

function interpolateStructuredMessage(
  message: string,
  details: Record<string, unknown> | null,
): string {
  if (!details || !/%[sd]/.test(message)) return message
  const replacements = [
    detailLabel(details, 'tool_name') ?? detailLabel(details, 'tool'),
    detailLabel(details, 'fixes'),
    detailLabel(details, 'count'),
    detailLabel(details, 'client_name'),
    detailLabel(details, 'phase'),
    detailLabel(details, 'request_id'),
    detailLabel(details, 'session_id'),
  ].filter((value): value is string => !!value)

  let rendered = message
  for (const value of replacements) {
    if (!/%[sd]/.test(rendered)) break
    rendered = rendered.replace(/%[sd]/, value)
  }
  return rendered
}

function failureEnvelope(entry: LogEntry): FailureEnvelope | null {
  const details = entryDetails(entry)
  const envelope = asRecord(details?.failure_envelope)
  if (!envelope) return null

  const surface = asNullableString(envelope.surface)
  const entityKind = asNullableString(envelope.entity_kind)
  const causeCode = asNullableString(envelope.cause_code)
  const severity = asNullableString(envelope.severity)
  const summary = asNullableString(envelope.summary)
  const recoverability = asNullableString(envelope.recoverability)

  if (!surface || !entityKind || !causeCode || !severity || !summary || !recoverability) {
    return null
  }

  return {
    surface,
    entity_kind: entityKind,
    entity_id: asNullableString(envelope.entity_id),
    cause_code: causeCode,
    severity,
    summary,
    recoverability,
    operator_action: asNullableString(envelope.operator_action),
    evidence_ref: asRecord(envelope.evidence_ref),
  }
}

export function logDiagnosticCause(entry: LogEntry): string | null {
  const failure = failureEnvelope(entry)
  if (failure) return failure.cause_code
  const details = entryDetails(entry)
  const event = detailLabel(details, 'event')
  if (event) return event
  return null
}

function topCounts(map: Map<string, number>, limit = 3): LogCauseCount[] {
  return [...map.entries()]
    .map(([cause, count]) => ({ cause, count }))
    .sort((a, b) => b.count - a.count || a.cause.localeCompare(b.cause))
    .slice(0, limit)
}

export function summarizeLogWindow(entries: LogEntry[]): LogWindowSummary {
  const causes = new Map<string, number>()
  const modules = new Map<string, number>()
  let errors = 0
  let warnings = 0
  let failureEnvelopes = 0

  for (const entry of entries) {
    const level = normalizedLevel(entry)
    if (level === 'ERROR') errors += 1
    if (level === 'WARN') warnings += 1

    const mod = entry.module?.trim() || '(root)'
    modules.set(mod, (modules.get(mod) ?? 0) + 1)

    const failure = failureEnvelope(entry)
    if (failure) failureEnvelopes += 1
    const cause = failure?.cause_code ?? logDiagnosticCause(entry)
    if (cause) causes.set(cause, (causes.get(cause) ?? 0) + 1)
  }

  return {
    errors,
    warnings,
    failureEnvelopes,
    topCauses: topCounts(causes),
    topModules: topCounts(modules).map(({ cause, count }) => ({
      module: cause,
      count,
    })),
  }
}

export function logRouteLinks(entry: LogEntry): ReadonlyArray<IdeContextRouteLink> {
  const details = entryDetails(entry)
  const failureEnvelopeRecord = asRecord(details?.failure_envelope)
  const context: MutableRouteContext = {}
  mergeRouteRecord(context, asRecord(details?.context))
  mergeRouteRecord(context, asRecord(details?.evidence_ref))
  mergeRouteRecord(context, asRecord(failureEnvelopeRecord?.evidence_ref))
  mergeRouteRecord(context, asRecord(details?.tool_args))
  mergeRouteRecord(context, asRecord(details?.input))
  mergeRouteRecord(context, details, true)
  if (!hasRouteContext(context)) return []
  return routeLinksForContext({
    ...context,
    surface: 'Log',
    label: entry.module || entry.message,
    sourceId: `log:${entry.seq}`,
    telemetry: context.logId !== undefined
      || context.sessionId !== undefined
      || context.operationId !== undefined
      || context.workerRunId !== undefined,
  })
}

export function logCodeRouteLink(entry: LogEntry): IdeContextRouteLink | null {
  return logRouteLinks(entry).find(link => link.label === 'Code') ?? null
}

function renderLogMessage(entry: LogEntry): string {
  const details = entryDetails(entry)
  const message = interpolateStructuredMessage(entry.message, details)
  const failure = failureEnvelope(entry)
  return failure ? `${message} (${failure.summary})` : message
}

function sourceTone(source: string): string {
  switch (source) {
    case 'client_tool_host':
      return 'text-[var(--color-accent-fg)] bg-[var(--accent-10)] border-[var(--accent-22)]'
    case 'legacy_stderr':
      return 'text-[var(--bad-light)] bg-[var(--err-soft)] border-[var(--err-border)]'
    case 'legacy_traceln':
      return 'text-[var(--warn-fg)] bg-[var(--warn-soft)] border-[var(--warn-border)]'
    default:
      return 'text-[var(--color-fg-muted)] bg-[var(--color-bg-surface)] border-[var(--color-border-default)]'
  }
}

function selectableProviderLogs(
  catalog: ProviderLogsCatalogResponse | undefined,
): ProviderLogCatalogEntry[] {
  return (catalog?.providers ?? []).filter(provider =>
    provider.enabled && typeof provider.path === 'string' && provider.path.trim() !== '',
  )
}

function providerLogOptionLabel(provider: ProviderLogCatalogEntry): string {
  const pathLabel = lastPathSegment(provider.path ?? undefined)
  return pathLabel ? `${provider.display_name} - ${pathLabel}` : provider.display_name
}

async function loadLogs(mode: LoadMode = 'reset') {
  const requestId = ++latestRequestId

  if (mode === 'reset') {
    logQueryGeneration += 1
    pagedOlder.value = false
    noMoreOlder.value = false
    return logResource.load(async () => {
      const resp = await fetchLogs({
        limit: logLimit.value,
        level: levelFilter.value,
        module: appliedModuleFilter.value || undefined,
        category: categoryFilter.value || undefined,
        exclude_category: hideFsmTransitions.value ? 'fsm' : undefined,
      })
      const entries = sortLogEntries(resp.entries).slice(0, Math.max(1, logLimit.value))
      latestSeq.value = latestLogSeq(entries)
      return {
        ...resp,
        entries,
        total: resp.total,
      }
    })
  }

  // delta mode — update existing loaded data
  try {
    const resp = await fetchLogs({
      limit: logLimit.value,
      level: levelFilter.value,
      module: appliedModuleFilter.value || undefined,
      since_seq: latestSeq.value ?? undefined,
      category: categoryFilter.value || undefined,
      exclude_category: hideFsmTransitions.value ? 'fsm' : undefined,
    })
    if (requestId !== latestRequestId) return

    const s = logResource.state.value
    const currentEntries = s.status === 'loaded' ? s.data.entries : []
    const incoming = sortLogEntries(resp.entries)
    const cap = deltaMergeCap(currentEntries, incoming, pagedOlder.value, logLimit.value)
    const nextEntries = mergeLogEntries(currentEntries, incoming, cap)

    latestSeq.value = latestLogSeq(nextEntries)
    logResource.state.value = loaded({
      ...resp,
      entries: nextEntries,
      total: resp.total,
    })
  } catch {
    if (requestId !== latestRequestId) return
    // Delta failures don't overwrite loaded state — keep existing data visible
  }
}

function oldestLogSeq(entries: readonly LogEntry[]): number | null {
  if (entries.length === 0) return null
  return entries.reduce((min, entry) => Math.min(min, entry.seq), entries[0]?.seq ?? 0)
}

// "load older" backward paging: fetch entries strictly older than the smallest
// seq currently shown and append them. The merge cap here covers current + newly
// loaded rows so this merge keeps them, and [pagedOlder] then makes the delta
// poller grow its cap so it does not trim them on the next poll.
export async function loadOlder() {
  const s = logResource.state.value
  if (s.status !== 'loaded') return
  const currentEntries = s.data.entries
  const oldest = oldestLogSeq(currentEntries)
  if (oldest === null || oldest <= 0) {
    noMoreOlder.value = true
    return
  }
  if (olderLoading.value) return
  const startedGeneration = logQueryGeneration
  olderLoading.value = true
  try {
    const resp = await fetchLogs({
      limit: logLimit.value,
      level: levelFilter.value,
      module: appliedModuleFilter.value || undefined,
      before_seq: oldest,
      category: categoryFilter.value || undefined,
      exclude_category: hideFsmTransitions.value ? 'fsm' : undefined,
    })
    if (startedGeneration !== logQueryGeneration) return
    const incoming = sortLogEntries(resp.entries)
    if (incoming.length === 0) {
      noMoreOlder.value = true
      return
    }
    const latestState = logResource.state.value
    if (latestState.status !== 'loaded') return
    const latestEntries = latestState.data.entries
    const cap = latestEntries.length + incoming.length
    const nextEntries = mergeLogEntries(latestEntries, incoming, cap)
    // Mark the view as paged-open so the delta poller grows its cap for new
    // rows instead of slicing the just-loaded older rows back off.
    pagedOlder.value = true
    // latestSeq stays untouched: older paging only extends the tail, the
    // newest-cursor for delta polling is unaffected.
    logResource.state.value = loaded({
      ...latestState.data,
      entries: nextEntries,
      total: resp.total,
    })
  } catch {
    // Keep existing data on failure; the affordance stays available for retry.
  } finally {
    olderLoading.value = false
  }
}

async function loadProviderLogCatalog() {
  return providerLogCatalogResource.load(async () => {
    const resp = await fetchProviderLogsCatalog()
    const selectable = selectableProviderLogs(resp)
    const stillSelected = selectable.some(provider => provider.id === providerLogProvider.value)
    if (!stillSelected) {
      providerLogProvider.value = selectable[0]?.id ?? ''
    }
    return resp
  })
}

async function loadSelectedProviderLog() {
  const provider = providerLogProvider.value
  if (!provider) {
    providerLogTailResource.reset()
    return
  }
  return providerLogTailResource.load(() =>
    fetchProviderLogTail(provider, { lines: providerLogLines.value }),
  )
}

// Pretty-print a nested details value as a JSON code block body, matching the
// keeper-v2 prototype (`JSON.stringify(value, null, 1)`). Returns null for empty
// objects/arrays/strings so absent payloads render no `lg-code` block at all
// (no fabricated "{}" placeholders). Strings pass through verbatim — the backend
// already emits some results as pre-rendered strings.
function formatDetailCode(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed === '' ? null : trimmed
  }
  if (typeof value === 'object') {
    if (Array.isArray(value) && value.length === 0) return null
    if (!Array.isArray(value) && Object.keys(value as Record<string, unknown>).length === 0) return null
    try {
      return JSON.stringify(value, null, 1)
    } catch {
      return null
    }
  }
  return null
}

// Read a free-form note/gloss string from the details object. The backend
// `details` schema is `record(string, unknown)`, so these keys are not
// guaranteed to be present — callers render the `lg-note` block only when this
// returns a non-empty value.
function detailNote(details: Record<string, unknown> | null, ...keys: string[]): string | null {
  if (!details) return null
  for (const key of keys) {
    const value = details[key]
    if (typeof value === 'string' && value.trim() !== '') return value.trim()
  }
  return null
}

// Read a recipients[] array of human-readable strings from the details object.
// Not present in the general log stream today (the backend emits scalar detail
// fields only) — render conditionally so this never shows fabricated chips.
function detailRecipients(details: Record<string, unknown> | null): string[] {
  if (!details) return []
  const value = details.recipients
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(item => item !== '')
}

// Kind-aware key/value grid for the expanded detail panel. Fields are pulled
// from the backend `details` object via detailLabel; absent fields are dropped
// so the layout matches the keeper-v2 prototype when the data is present and
// degrades gracefully (no row) otherwise. The generic level/module/source/
// timestamp grid and tag row below it are preserved for every kind.
//
// Class vocabulary: each k/v grid carries the prototype `.lg-kv`/`.lg-kv-row`/
// `.lg-kv-k`/`.lg-kv-v` classes (vendored keeper-v2/logs.css, loaded last) plus
// the legacy `.v2-logs-detail-grid`/`.v2-logs-kind-grid` classes the tests
// query. The per-kind payload blocks (args/result code, note, recipients, the
// HILT jump) use the prototype `.lg-block`/`.lg-code`/`.lg-note`/`.lg-recips`/
// `.lg-jump` classes and render only when their data is present.
function renderLogKindGrid(
  kind: LogDisplayKind,
  details: Record<string, unknown> | null,
): VNode | null {
  if (!details) return null
  const d = detailLabel
  const row = (k: string, v: string | null): VNode | null =>
    v && v !== '' ? html`<div class="lg-kv-row"><span class="lg-kv-k mono">${k}</span><span class="lg-kv-v mono">${v}</span></div>` : null
  const grid = (...rows: Array<VNode | null>): VNode | null => {
    const filled = rows.filter((r): r is VNode => r !== null)
    return filled.length ? html`<div class="v2-logs-detail-grid v2-logs-kind-grid lg-kv">${filled}</div>` : null
  }
  const codeBlock = (label: string, value: unknown): VNode | null => {
    const body = formatDetailCode(value)
    return body === null
      ? null
      : html`<div class="lg-block"><span class="lg-block-h">${label}</span><pre class="lg-code">${body}</pre></div>`
  }
  const note = (text: string | null, dim = false): VNode | null =>
    text ? html`<div class=${`lg-note${dim ? ' dim' : ''}`}>${text}</div>` : null

  if (kind === 'tool') {
    return html`
      ${grid(
        row('tool', d(details, 'tool_name') ?? d(details, 'tool')),
        row('outcome', d(details, 'outcome') ?? d(details, 'status')),
        row('latency', d(details, 'latency_ms') ?? d(details, 'duration_ms') ?? d(details, 'dur')),
        row('namespace', d(details, 'namespace') ?? d(details, 'ns')),
      )}
      ${codeBlock('args', details.tool_args ?? details.args ?? details.input)}
      ${codeBlock('result', details.result ?? details.output)}
    `
  }
  if (kind === 'turn') {
    const tools = (details as { tools_used?: unknown }).tools_used
    const toolsStr = Array.isArray(tools) ? tools.join(', ') : d(details, 'tools_used')
    return grid(
      row('model', d(details, 'model')),
      row('tools_used', toolsStr),
      row('stop_reason', d(details, 'stop_reason')),
      row('duration', d(details, 'duration_ms') ?? d(details, 'duration')),
    )
  }
  if (kind === 'lifecycle') {
    return html`
      ${grid(
        row('from', d(details, 'from') ?? d(details, 'phase')),
        row('to', d(details, 'to') ?? d(details, 'next_phase')),
        row('trigger', d(details, 'trigger')),
      )}
      ${note(detailNote(details, 'gloss'))}
    `
  }
  if (kind === 'approval') {
    const goalJob = [d(details, 'goal_id') ?? d(details, 'goal'), d(details, 'job_id') ?? d(details, 'job')]
      .filter((v): v is string => v !== null)
      .join(' · ')
    const request = detailNote(details, 'req', 'request')
    const extra = detailNote(details, 'detail')
    return html`
      ${grid(
        row('tool', d(details, 'tool')),
        row('severity', d(details, 'severity')),
        row('goal · job', goalJob || null),
      )}
      ${request ? html`<div class="lg-note">“${request}”</div>` : null}
      ${note(extra, true)}
      <${RouteLink}
        tab="approvals"
        class="lg-jump"
        data-testid="logs-approval-jump"
        aria-label="HILT 승인 큐 열기"
      >HILT 승인 큐 열기 →<//>
    `
  }
  if (kind === 'broadcast') {
    const recipients = detailRecipients(details)
    return html`
      ${grid(
        row('scope', d(details, 'scope') ?? d(details, 'namespace')),
        row('via', d(details, 'via') ?? d(details, 'channel')),
      )}
      ${note(detailNote(details, 'note'))}
      ${recipients.length > 0
        ? html`<div class="lg-recips">${recipients.map((r, i) => html`<span key=${i} class="lg-recip mono">${r}</span>`)}</div>`
        : html`<div class="lg-recips" data-stub="no-recipients-source"><span class="lg-note dim">수신자 정보 없음 (현재 스트림에 수신자 데이터 없음)</span></div>`}
    `
  }
  return null
}

function renderLogRow(entry: LogEntry) {
  const level = normalizedLevel(entry)
  const source = entry.source || '(unknown source)'
  const details = entryDetails(entry)
  const clientName = detailLabel(details, 'client_name')
  const toolName = detailLabel(details, 'tool_name') ?? detailLabel(details, 'tool')
  const phase = detailLabel(details, 'phase')
  const requestId = detailLabel(details, 'request_id')
  const sessionId = detailLabel(details, 'session_id')
  const fixes = detailLabel(details, 'fixes')
  const event = detailLabel(details, 'event')
  const failure = failureEnvelope(entry)
  const diagnosticCause = failure?.cause_code ?? logDiagnosticCause(entry)
  const sourceClass = sourceTone(source)
  const renderedMessage = renderLogMessage(entry)
  const routeLinks = logRouteLinks(entry)
  const category = categoryLabel(entry.category)
  const displayKind = logDisplayKind(entry)
  const severity = logSeverity(entry)
  const identity = keeperLabel(entry, details)
  const isExpanded = expandedLogSeq.value === entry.seq
  const routeLinkButtons = routeLinks.length > 0
    ? html`
      ${routeLinks.map(link => html`
        <button
          key=${link.id}
          type="button"
          data-testid=${link.label === 'Code' ? 'logs-code-link' : undefined}
          class="logs-route-link"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    `
    : null
  const diagnosticChip = failure
    ? html`<${StatusChip} tone="bad" uppercase=${false}>${failure.cause_code}</${StatusChip}>`
    : null
  const fallbackDiagnosticChip = !failure && diagnosticCause
    ? html`<${StatusChip} tone=${level === 'ERROR' ? 'bad' : 'warn'} uppercase=${false}>${diagnosticCause}</${StatusChip}>`
    : null
  return html`
    <div
      key=${entry.seq}
      class=${`logs-row v2-logs-row lg-row ${isExpanded ? 'is-open open' : ''}`}
      data-testid="logs-row"
      data-log-seq=${entry.seq}
      data-sev=${severity}
      data-kind=${displayKind}
    >
      <button
        type="button"
        class="v2-logs-line lg-line"
        aria-expanded=${isExpanded}
        onClick=${() => {
          expandedLogSeq.value = isExpanded ? null : entry.seq
        }}
      >
        <span class="v2-logs-time lg-time mono">${formatLogClock(entry.ts)}</span>
        <span class="v2-logs-who lg-who">
          <${KeeperBadge} id=${identity} variant="sigil" size="md" title=${identity} />
          <span class="v2-logs-identity lg-kid" title=${identity}>${identity}</span>
        </span>
        <span class="v2-logs-kind lg-kind" data-kind=${displayKind}>${LOG_KIND_LABELS[displayKind]}</span>
        <span class="v2-logs-message lg-msg" title=${failure ? `${renderedMessage}\n${failure.summary}` : renderedMessage}>
          ${renderedMessage}
        </span>
        <span class="v2-logs-caret lg-caret" aria-hidden="true">
          ${isExpanded ? html`<${ChevronDown} size=${14} />` : html`<${ChevronRight} size=${14} />`}
        </span>
      </button>
      ${routeLinkButtons
        ? html`<div class="v2-logs-inline-links">${routeLinkButtons}</div>`
        : null}
      ${isExpanded
        ? html`
          <div class="v2-logs-detail lg-detail">
            ${renderLogKindGrid(displayKind, details) ?? ''}
            <div class="v2-logs-detail-grid">
              <div><span>level</span><b style=${{ color: LEVEL_COLORS[level] ?? 'inherit' }}>${level}</b></div>
              <div><span>module</span><b>${entry.module || '(root)'}</b></div>
              <div><span>source</span><b>${sourceLabel(source)}</b></div>
              <div><span>timestamp</span><b>${entry.ts.replace('T', ' ').replace('Z', '')}</b></div>
            </div>
            <div class="v2-logs-tags">
              <${StatusChip} tone=${sourceClass}>${sourceLabel(source)}</${StatusChip}>
              ${category ? html`<${MetaTag}>${category}</${MetaTag}>` : null}
              ${clientName
                ? html`<${StatusChip} tone="border-[var(--color-accent-soft)] text-[var(--color-accent-fg)]" uppercase=${false}>${clientName}</${StatusChip}>`
                : null}
              ${toolName
                ? html`<${StatusChip} tone="neutral" uppercase=${false} class="gap-1"><span class="font-mono font-bold ${toolCategory(toolName).color}">${toolCategory(toolName).icon}</span><span>${toolName}</span></${StatusChip}>`
                : null}
              ${fixes ? html`<${MetaTag}>fixes ${fixes}</${MetaTag}>` : null}
              ${phase ? html`<${MetaTag}>${phase}</${MetaTag}>` : null}
              ${event ? html`<${MetaTag}>event ${event}</${MetaTag}>` : null}
              ${requestId ? html`<${MetaTag}>req ${requestId}</${MetaTag}>` : null}
              ${sessionId ? html`<${MetaTag}>session ${sessionId}</${MetaTag}>` : null}
              ${diagnosticChip}
              ${fallbackDiagnosticChip}
              ${failure ? html`<${StatusChip} tone="info" uppercase=${false}>${failure.surface}</${StatusChip}>` : null}
              ${failure ? html`<${MetaTag}>${failure.recoverability}</${MetaTag}>` : null}
              ${failure?.operator_action
                ? html`<${StatusChip} tone="info" uppercase=${false}>next ${failure.operator_action}</${StatusChip}>`
                : null}
            </div>
          </div>
        `
        : null}
    </div>
  `
}

function renderSummaryChip(label: string, value: string | number, tone = 'neutral') {
  return html`
    <${StatusChip} tone=${tone} uppercase=${false}>
      <span>${label}</span>
      <span class="font-mono tabular-nums">${value}</span>
    </${StatusChip}>
  `
}

function renderLogSummary(summary: LogWindowSummary) {
  return html`
    <div class="v2-logs-summary flex flex-wrap items-center gap-2 text-2xs">
      ${renderSummaryChip('ERROR', summary.errors, summary.errors > 0 ? 'bad' : 'neutral')}
      ${renderSummaryChip('WARN', summary.warnings, summary.warnings > 0 ? 'warn' : 'neutral')}
      ${renderSummaryChip('failure envelope', summary.failureEnvelopes, summary.failureEnvelopes > 0 ? 'info' : 'neutral')}
      ${summary.topModules.map(item => renderSummaryChip(`module ${item.module}`, item.count))}
      ${summary.topCauses.map(item => renderSummaryChip(`cause ${item.cause}`, item.count, 'info'))}
    </div>
  `
}

function lastPathSegment(path: string | undefined): string | null {
  if (!path) return null
  const normalized = path.replace(/\\/g, '/')
  return normalized.split('/').filter(Boolean).pop() ?? normalized
}

function renderLogProvenance(data: LogData | undefined) {
  if (!data) return null
  const scope = data.retention?.scope
  const store = lastPathSegment(data.retention?.durable_store)
  const latestSeq = typeof data.latest_seq === 'number' ? String(data.latest_seq) : null
  const generatedAt = data.generated_at_iso?.replace('T', ' ').replace('Z', '')

  if (!data.source && !scope && !store && !latestSeq && !generatedAt) return null

  return html`
    <div class="flex flex-wrap items-center gap-1.5" data-testid="logs-provenance">
      ${data.source ? renderSummaryChip('source', data.source, 'info') : null}
      ${scope ? renderSummaryChip('scope', scope) : null}
      ${latestSeq ? renderSummaryChip('seq', latestSeq) : null}
      ${store ? html`
        <${StatusChip}
          tone="neutral"
          uppercase=${false}
        >store ${store}</${StatusChip}>
      ` : null}
      ${generatedAt ? renderSummaryChip('at', generatedAt) : null}
    </div>
  `
}

function renderProviderLogPanel() {
  const catalogState = providerLogCatalogResource.state.value
  const catalog = catalogState.status === 'loaded' ? catalogState.data : undefined
  const configuredProviders = catalog?.providers ?? []
  const selectableProviders = selectableProviderLogs(catalog)
  const selectedProvider =
    selectableProviders.find(provider => provider.id === providerLogProvider.value) ?? null
  const tailState = providerLogTailResource.state.value
  const tail = tailState.status === 'loaded' ? tailState.data : undefined
  const tailText = tail?.entries.map(entry => entry.text).join('\n') ?? ''
  const disabledCount = configuredProviders.filter(provider => !provider.enabled).length

  if (
    catalogState.status === 'idle'
    || (configuredProviders.length === 0 && catalogState.status !== 'error')
  ) {
    return null
  }

  return html`
    <div class="v2-logs-provider-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-[var(--color-border-divider)] px-3 py-2">
        <div class="flex flex-wrap items-center gap-2 text-2xs">
          <${StatusChip} tone="info" uppercase=${false}>provider logs</${StatusChip}>
          ${selectedProvider
            ? html`<${StatusChip} tone="neutral" uppercase=${false}>${selectedProvider.protocol}</${StatusChip}>`
            : null}
          ${selectedProvider?.path
            ? html`<${StatusChip} tone="neutral" uppercase=${false}>${lastPathSegment(selectedProvider.path)}</${StatusChip}>`
            : null}
          ${disabledCount > 0
            ? html`<${StatusChip} tone="warn" uppercase=${false}>disabled ${disabledCount}</${StatusChip}>`
            : null}
        </div>

        <div class="flex flex-wrap items-center gap-2">
          ${selectableProviders.length > 0
            ? html`
              <${Select}
                class="logs-select px-3 py-2 text-xs"
                name="provider-log-provider"
                ariaLabel="Provider log"
                value=${providerLogProvider.value}
                options=${selectableProviders.map(provider => ({
                  value: provider.id,
                  label: providerLogOptionLabel(provider),
                }))}
                onInput=${(value: string) => { providerLogProvider.value = value }}
              />
              <${Select}
                class="logs-select px-3 py-2 text-xs"
                name="provider-log-lines"
                ariaLabel="Provider log lines"
                value=${String(providerLogLines.value)}
                options=${['50', '100', '200', '500', '1000', '3000']}
                onInput=${(value: string) => { providerLogLines.value = parseInt(value, 10) }}
              />
              <button
                type="button"
                class="logs-refresh-btn rounded-[var(--r-1)] border border-[var(--accent-22)] bg-[var(--accent-10)] px-3 py-2 text-2xs font-medium text-[var(--color-accent-fg)]"
                onClick=${() => { void loadSelectedProviderLog() }}
                disabled=${tailState.status === 'loading'}
              >
                ${tailState.status === 'loading' ? '...' : 'tail'}
              </button>
            `
            : null}
        </div>
      </div>

      ${catalogState.status === 'error'
        ? html`<div class="px-3 py-3 text-xs text-[var(--err-fg)]">${catalogState.message}</div>`
        : null}
      ${catalog?.error
        ? html`<div class="px-3 py-3 text-xs text-[var(--err-fg)]">${catalog.error}</div>`
        : null}
      ${selectableProviders.length === 0 && catalogState.status === 'loaded'
        ? html`<div class="px-3 py-3 text-xs text-[var(--color-fg-muted)]">runtime.toml provider log tail is disabled.</div>`
        : null}
      ${tailState.status === 'error'
        ? html`<div class="px-3 py-3 text-xs text-[var(--err-fg)]">${tailState.message}</div>`
        : null}
      ${selectedProvider && tailState.status !== 'error'
        ? html`
          <pre
            class="m-0 max-h-72 min-h-32 overflow-auto whitespace-pre-wrap break-words px-3 py-3 font-mono text-2xs leading-relaxed text-[var(--color-fg-primary)]"
            data-testid="provider-log-tail"
          >${tailState.status === 'loading' && !tail ? 'loading...' : tailText}</pre>
        `
        : null}
    </div>
  `
}

export function LogViewer() {
  useEffect(() => {
    let pollId: ReturnType<typeof setInterval> | null = null

    const restart = () => {
      if (pollId) {
        clearInterval(pollId)
        pollId = null
      }
      latestSeq.value = null
      logResource.reset()
      void loadLogs('reset')
      if (!autoRefresh.value) return
      pollId = setInterval(() => {
        void loadLogs('delta')
      }, POLL_INTERVAL_MS)
    }

    restart()

    const unsubscribeLevel = levelFilter.subscribe(restart)
    const unsubscribeModule = appliedModuleFilter.subscribe(restart)
    const unsubscribeLimit = logLimit.subscribe(restart)
    const unsubscribeCategory = categoryFilter.subscribe(restart)
    const unsubscribeHideFsm = hideFsmTransitions.subscribe(restart)
    const unsubscribeAutoRefresh = autoRefresh.subscribe(restart)

    return () => {
      if (pollId) {
        clearInterval(pollId)
      }
      unsubscribeLevel()
      unsubscribeModule()
      unsubscribeLimit()
      unsubscribeCategory()
      unsubscribeHideFsm()
      unsubscribeAutoRefresh()
    }
  }, [])

  useEffect(() => () => {
    if (moduleDebounceTimer) {
      clearTimeout(moduleDebounceTimer)
      moduleDebounceTimer = null
    }
  }, [])

  useEffect(() => {
    providerLogCatalogResource.reset()
    providerLogTailResource.reset()
    void loadProviderLogCatalog()
  }, [])

  useEffect(() => {
    let pollId: ReturnType<typeof setInterval> | null = null

    const restart = () => {
      if (pollId) {
        clearInterval(pollId)
        pollId = null
      }
      providerLogTailResource.reset()
      void loadSelectedProviderLog()
      if (!autoRefresh.value || !providerLogProvider.value) return
      pollId = setInterval(() => {
        void loadSelectedProviderLog()
      }, POLL_INTERVAL_MS)
    }

    restart()

    const unsubscribeProvider = providerLogProvider.subscribe(restart)
    const unsubscribeLines = providerLogLines.subscribe(restart)
    const unsubscribeAutoRefresh = autoRefresh.subscribe(restart)

    return () => {
      if (pollId) {
        clearInterval(pollId)
      }
      unsubscribeProvider()
      unsubscribeLines()
      unsubscribeAutoRefresh()
    }
  }, [])

  const s = logResource.state.value
  const logData = s.status === 'loaded' ? s.data : undefined
  const logEntries = logData?.entries ?? EMPTY_LOG_ENTRIES
  const logTotal = logData?.total ?? 0
  const logLoading = s.status === 'loading'
  const logError = s.status === 'error' ? s.message : null
  // summarizeLogWindow iterates the full entries array (counts errors/warnings,
  // builds cause/module Maps). When logData is loaded the entries ref is stable
  // across unrelated re-renders (toolbar interactions, polling status flips);
  // memoizing on [logEntries] skips the recount. In the loading state logEntries
  // is a fresh `[]` so the memo misses, but the derivation is cheap then.
  const summary = useMemo(() => summarizeLogWindow(logEntries), [logEntries])
  const toolCalls = useMemo(
    () => logEntries.filter(entry => logDisplayKind(entry) === 'tool').length,
    [logEntries],
  )
  const errRate = logEntries.length > 0
    ? ((summary.errors / logEntries.length) * 100).toFixed(1)
    : '0.0'
  const currentFilterLabel =
    LOG_KIND_FILTERS.find(filter => filter.value === kindFilter.value)?.label
    ?? LOG_CATEGORY_OPTIONS.find(option => option.value === categoryFilter.value)?.label
    ?? '전체'
  // kindFilter is a preact signal: reading .value subscribes this render,
  // so a plain derivation recomputes on kind change without a memo dep.
  const visibleEntries = kindFilter.value === ''
    ? logEntries
    : logEntries.filter(entry => logDisplayKind(entry) === kindFilter.value)
  let emptyMessage = '조건에 맞는 로그가 없습니다.'
  if (logLoading) emptyMessage = '로그를 불러오는 중...'
  else if (kindFilter.value !== '') emptyMessage = '해당하는 이벤트 없음'
  const providerDiagnostics = renderProviderLogPanel()

  return html`
    <div class="logs-viewer v2-logs-surface lg">
      <section class="v2-logs-panel" aria-label="로그 뷰어">
        <header class="v2-logs-head lg-head">
          <div class="v2-logs-head-main lg-head-l">
            <span class="v2-logs-eyebrow ov-eyebrow">Observatory</span>
            <h1>이벤트 로그</h1>
            <p class="v2-logs-sub lg-sub mono">live trace stream · masc runtime · ${logWindowLabel(logEntries)}</p>
          </div>
          <div class="v2-logs-stats lg-stats" aria-label="로그 요약">
            <div class="v2-logs-stat lg-stat"><span class="k">이벤트/분</span><span class="v mono">${eventRatePerMinute(logEntries)}</span></div>
            <div class="v2-logs-stat lg-stat"><span class="k">오류율</span><span class=${`v mono ${summary.errors > 0 ? 'bad' : ''}`}>${errRate}%</span></div>
            <div class="v2-logs-stat lg-stat"><span class="k">tool 호출</span><span class="v mono">${toolCalls}</span></div>
            <div class="v2-logs-stat lg-stat"><span class="k">활성 keeper</span><span class="v mono">${logActiveIdentityCount(logEntries)}</span></div>
          </div>
        </header>

        <div class="logs-toolbar v2-logs-toolbar lg-toolbar">
          <div class="logs-filters v2-logs-filters lg-filters">
            ${LOG_KIND_FILTERS.map(filter => html`
              <${LogFilter}
                key=${filter.value || 'all'}
                active=${kindFilter.value === filter.value}
                class="v2-logs-filter-chip lg-fchip"
                data-testid=${`logs-filter-${filter.value || 'all'}`}
                onClick=${() => {
                  kindFilter.value = filter.value
                }}
              >${filter.label}<//>
            `)}
          </div>

          <div class="v2-logs-toolbar-break lg-tb-spacer"></div>

          <div class="logs-actions v2-logs-actions">
            ${renderLogProvenance(logData)}
            <button
              type="button"
              class=${`v2-logs-attention lg-onlyerr ${levelFilter.value === 'WARN' ? 'on' : ''}`}
              aria-pressed=${levelFilter.value === 'WARN'}
              onClick=${() => { levelFilter.value = levelFilter.value === 'WARN' ? 'INFO' : 'WARN' }}
            >
              주의·실패만
            </button>
            <span class="v2-logs-count mono" title=${`현재 필터: ${currentFilterLabel}`}>
              ${logEntries.length.toLocaleString()} / ${logTotal.toLocaleString()}
            </span>
            <details class="v2-logs-advanced-menu">
              <summary>필터</summary>
              <div class="v2-logs-advanced">
                <${Select}
                  class="logs-select px-3 py-2 text-xs"
                  name="log-level"
                  ariaLabel="로그 레벨"
                  value=${levelFilter.value}
                  options=${[
                    { value: 'DEBUG', label: 'DEBUG+' },
                    { value: 'INFO', label: 'INFO+' },
                    { value: 'WARN', label: 'WARN+' },
                    { value: 'ERROR', label: 'ERROR' },
                  ]}
                  onInput=${(v: string) => { levelFilter.value = v }}
                />

                <${Select}
                  class="logs-select px-3 py-2 text-xs"
                  name="log-category"
                  ariaLabel="카테고리"
                  value=${categoryFilter.value}
                  options=${LOG_CATEGORY_OPTIONS}
                  onInput=${(v: string) => { categoryFilter.value = v }}
                />

                <${TextInput}
                  class="min-w-55"
                  name="log-module-filter"
                  ariaLabel="모듈 필터"
                  placeholder="모듈 필터"
                  value=${moduleInput.value}
                  onInput=${(e: Event) => {
                    moduleInput.value = (e.target as HTMLInputElement).value
                    if (moduleDebounceTimer) clearTimeout(moduleDebounceTimer)
                    moduleDebounceTimer = setTimeout(() => {
                      appliedModuleFilter.value = moduleInput.value
                    }, 300)
                  }}
                  onKeyDown=${(e: KeyboardEvent) => {
                    if (e.key === 'Enter') {
                      if (moduleDebounceTimer) clearTimeout(moduleDebounceTimer)
                      moduleDebounceTimer = null
                      appliedModuleFilter.value = moduleInput.value
                    }
                  }}
                />

                <${Select}
                  class="logs-select px-3 py-2 text-xs"
                  name="log-limit"
                  ariaLabel="로그 개수"
                  value=${String(logLimit.value)}
                  options=${['100', '200', '500', '1000', '3000']}
                  onInput=${(v: string) => { logLimit.value = parseInt(v, 10) }}
                />

                <label class="logs-hide-fsm-label flex items-center gap-1.5 cursor-pointer text-2xs text-[var(--color-fg-muted)]">
                  <${Checkbox}
                    name="log-hide-fsm"
                    ariaLabel="Hide FSM transitions"
                    checked=${hideFsmTransitions.value}
                    onChange=${(checked: boolean) => { hideFsmTransitions.value = checked }}
                  />
                  Hide FSM transitions
                </label>
              </div>
            </details>
            <label class="logs-auto-label flex items-center gap-1.5 cursor-pointer">
              <${Checkbox}
                name="log-auto-refresh"
                ariaLabel="자동 새로고침"
                checked=${autoRefresh.value}
                onChange=${(checked: boolean) => { autoRefresh.value = checked }}
              />
              자동
            </label>
            <span class="v2-logs-live lg-live mono"><span class="dot" />${autoRefresh.value ? `masc-mcp · 3s polling · ${eventRatePerMinute(logEntries)}δ/min` : 'masc-mcp · WS paused'}</span>
            <button
              type="button"
              class="logs-refresh-btn v2-logs-refresh"
              aria-label="새로고침"
              onClick=${() => {
                latestSeq.value = null
                logResource.reset()
                void loadLogs('reset')
                void loadProviderLogCatalog()
                void loadSelectedProviderLog()
              }}
              disabled=${logLoading}
            >
              <${RefreshCw} size=${14} class=${logLoading ? 'animate-spin' : ''} />
            </button>
          </div>
        </div>

        ${logError ? html`
          <div class="mx-4 mt-4 rounded-[var(--r-1)] border border-solid border-[var(--err-border)] bg-[var(--brick-soft)] px-4 py-3 text-xs text-[var(--err-fg)]">${logError}</div>
        ` : null}

        <div class="v2-logs-support">
          ${renderLogSummary(summary)}
          ${providerDiagnostics
            ? html`
              <details class="v2-logs-diagnostics" data-testid="logs-provider-diagnostics">
                <summary>
                  <span>Provider diagnostics</span>
                  <span class="mono">runtime.toml log tail</span>
                </summary>
                <div class="v2-logs-diagnostics-body">
                  ${providerDiagnostics}
                </div>
              </details>
            `
            : null}
        </div>

        <div class="v2-logs-table-header lg-colhd">
          <span>시각</span>
          <span>keeper</span>
          <span>유형</span>
          <span>이벤트</span>
          <span></span>
        </div>

        ${visibleEntries.length === 0
          ? html`
              <div class="lg-empty" role="status">
                ${emptyMessage}
              </div>
            `
          : html`
              <${VirtualList}
                items=${visibleEntries}
                estimatedItemHeight=${ESTIMATED_LOG_ROW_HEIGHT}
                overscan=${6}
                getKey=${(entry: LogEntry) => String(entry.seq)}
                renderItem=${(entry: LogEntry) => renderLogRow(entry)}
                className="v2-logs-stream lg-stream"
              />
            `}

        ${logEntries.length > 0
          ? html`
              <div class="v2-logs-load-older flex items-center justify-center px-4 py-3">
                ${noMoreOlder.value
                  ? html`<span class="text-2xs text-[var(--color-fg-muted)]">더 오래된 기록이 없습니다.</span>`
                  : html`
                      <button
                        type="button"
                        class="logs-refresh-btn rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-2xs font-medium text-[var(--color-fg-muted)]"
                        data-testid="logs-load-older"
                        onClick=${() => { void loadOlder() }}
                        disabled=${olderLoading.value}
                      >
                        ${olderLoading.value ? '불러오는 중...' : '이전 기록 더 보기'}
                      </button>
                    `}
              </div>
            `
          : null}
      </section>
    </div>
  `
}
