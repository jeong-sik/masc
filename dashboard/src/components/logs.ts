import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchLogs } from '../api/dashboard.js'
import type { LogEntry } from '../api/dashboard.js'
import { VirtualList } from './common/virtual-list'
import { TextInput } from './common/input'
import { Select } from './common/select'
import { Checkbox } from './common/checkbox'
import { createAsyncResource, loaded } from '../lib/async-state'
import { toolCategory } from './tool-call-shared'
import { StatusChip } from './common/status-chip'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteContext,
  type IdeContextRouteLink,
} from './ide/ide-context-lens'

interface LogData {
  entries: LogEntry[]
  total: number
}

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
const levelFilter = signal('INFO')
const moduleInput = signal('')
const appliedModuleFilter = signal('')
const autoRefresh = signal(true)
const logLimit = signal(200)
const latestSeq = signal<number | null>(null)

const POLL_INTERVAL_MS = 3000
const LOG_ROW_HEIGHT = 92

let moduleDebounceTimer: ReturnType<typeof setTimeout> | null = null
let latestRequestId = 0

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
  legacy_stderr: 'legacy stderr',
  legacy_traceln: 'legacy traceln',
  client_tool_host: 'client tool-host',
  sse: 'sse',
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

interface LogCodeLocation {
  readonly filePath: string
  readonly line?: number
}

type LogRouteContextFields = Pick<
  IdeContextRouteContext,
  | 'filePath'
  | 'line'
  | 'goalId'
  | 'taskId'
  | 'boardPostId'
  | 'commentId'
  | 'prId'
  | 'gitRef'
  | 'logId'
  | 'sessionId'
  | 'operationId'
  | 'workerRunId'
>
type MutableLogRouteContext = {
  -readonly [K in keyof LogRouteContextFields]?: LogRouteContextFields[K]
}

function normalizedLevel(entry: LogEntry): string {
  return (entry.normalized_level || entry.level || 'INFO').toUpperCase()
}

function sortLogEntries(entries: LogEntry[]): LogEntry[] {
  return [...entries].sort((a, b) => b.seq - a.seq)
}

function latestLogSeq(entries: LogEntry[]): number | null {
  if (entries.length === 0) return null
  return entries.reduce((max, entry) => Math.max(max, entry.seq), entries[0]?.seq ?? 0)
}

function mergeLogEntries(
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

function sourceLabel(source: string): string {
  return SOURCE_LABELS[source] ?? (source || 'structured')
}

function entryDetails(entry: LogEntry): Record<string, unknown> | null {
  const details = entry.details
  if (!details || typeof details !== 'object' || Array.isArray(details)) return null
  return details
}

function detailLabel(details: Record<string, unknown> | null, key: string): string | null {
  if (!details) return null
  const value = details[key]
  if (typeof value === 'string' && value.trim() !== '') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
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

function nestedRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function nestedString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function positiveLine(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 1) return value
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return /^[1-9]\d*$/.test(trimmed) ? Number.parseInt(trimmed, 10) : undefined
}

function idString(value: unknown): string | undefined {
  const text = nestedString(value)
  if (text) return text
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? String(value)
    : undefined
}

function codeLocationFromRecord(record: Record<string, unknown> | null): LogCodeLocation | null {
  if (!record) return null
  const filePath =
    nestedString(record.file_path)
    ?? nestedString(record.path)
    ?? nestedString(record.file)
  if (filePath) {
    return {
      filePath,
      line: positiveLine(record.line) ?? positiveLine(record.line_start) ?? positiveLine(record.lineno),
    }
  }
  return null
}

function mergeLogRouteRecord(
  context: MutableLogRouteContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const location = codeLocationFromRecord(record)
  if (location && (overwrite || context.filePath === undefined)) context.filePath = location.filePath
  if (location?.line !== undefined && (overwrite || context.line === undefined)) context.line = location.line

  const goalId = idString(record.goal_id)
  if (goalId && (overwrite || context.goalId === undefined)) context.goalId = goalId
  const taskId = idString(record.task_id)
  if (taskId && (overwrite || context.taskId === undefined)) context.taskId = taskId
  const boardPostId = idString(record.board_post_id) ?? idString(record.post_id)
  if (boardPostId && (overwrite || context.boardPostId === undefined)) context.boardPostId = boardPostId
  const commentId = idString(record.comment_id) ?? idString(record.reply_id) ?? idString(record.comment_number)
  if (commentId && (overwrite || context.commentId === undefined)) context.commentId = commentId
  const prId = idString(record.pr_id) ?? idString(record.pull_request) ?? idString(record.pr_number)
  if (prId && (overwrite || context.prId === undefined)) context.prId = prId
  const gitRef = idString(record.git_ref) ?? idString(record.commit) ?? idString(record.branch)
  if (gitRef && (overwrite || context.gitRef === undefined)) context.gitRef = gitRef
  const logId = idString(record.log_id)
  if (logId && (overwrite || context.logId === undefined)) context.logId = logId
  const sessionId = idString(record.session_id)
  if (sessionId && (overwrite || context.sessionId === undefined)) context.sessionId = sessionId
  const operationId = idString(record.operation_id)
  if (operationId && (overwrite || context.operationId === undefined)) context.operationId = operationId
  const workerRunId = idString(record.worker_run_id)
  if (workerRunId && (overwrite || context.workerRunId === undefined)) context.workerRunId = workerRunId
}

function hasLogRouteContext(context: MutableLogRouteContext): boolean {
  return context.filePath !== undefined
    || context.goalId !== undefined
    || context.taskId !== undefined
    || context.boardPostId !== undefined
    || context.commentId !== undefined
    || context.prId !== undefined
    || context.gitRef !== undefined
    || context.logId !== undefined
    || context.sessionId !== undefined
    || context.operationId !== undefined
    || context.workerRunId !== undefined
}

function failureEnvelope(entry: LogEntry): FailureEnvelope | null {
  const details = entryDetails(entry)
  const envelope = nestedRecord(details?.failure_envelope)
  if (!envelope) return null

  const surface = nestedString(envelope.surface)
  const entityKind = nestedString(envelope.entity_kind)
  const causeCode = nestedString(envelope.cause_code)
  const severity = nestedString(envelope.severity)
  const summary = nestedString(envelope.summary)
  const recoverability = nestedString(envelope.recoverability)

  if (!surface || !entityKind || !causeCode || !severity || !summary || !recoverability) {
    return null
  }

  return {
    surface,
    entity_kind: entityKind,
    entity_id: nestedString(envelope.entity_id),
    cause_code: causeCode,
    severity,
    summary,
    recoverability,
    operator_action: nestedString(envelope.operator_action),
    evidence_ref: nestedRecord(envelope.evidence_ref),
  }
}

function classifyMessageCause(message: string): string | null {
  const lower = message.toLowerCase()
  if (lower.includes('oas_timeout_budget') || lower.includes('oas execution timed out')) {
    return 'oas_timeout_budget'
  }
  if (lower.includes('inter_chunk_idle')) return 'inter_chunk_idle'
  if (lower.includes('no_first_token')) return 'no_first_token'
  if (lower.includes('cascade_exhausted') || lower.includes('all cascades exhausted')) {
    return 'cascade_exhausted'
  }
  if (lower.includes('stale watchdog')) return 'stale_watchdog'
  if (lower.includes('required tool contract') || lower.includes('tool_required_unsatisfied')) {
    return 'tool_required_unsatisfied'
  }
  if (lower.includes('semaphore wait')) return 'queue_wait_timeout'
  if (lower.includes('legacy verification directory')) return 'legacy_verification_dir'
  if (lower.includes('zero_token_usage_reported')) return 'usage_zero_tokens'
  if (lower.includes('usage telemetry untrusted')) return 'usage_telemetry_untrusted'
  if (lower.includes('usage telemetry unavailable')) return 'usage_telemetry_unavailable'
  if (lower.includes('orphan threshold breached')) return 'registry_orphan_threshold'
  if (lower.includes('entry not found, update dropped')) return 'registry_orphan_update'
  if (lower.includes('archived credential')) return 'credential_archive'
  if (lower.includes('retired pg runtime env')) return 'retired_pg_env'
  if (lower.includes('rate limited') || lower.includes('temporarily limiting requests')) {
    return 'provider_rate_limit'
  }
  if (lower.includes('invalid request')) return 'provider_invalid_request'
  return null
}

export function logDiagnosticCause(entry: LogEntry): string | null {
  const failure = failureEnvelope(entry)
  if (failure) return failure.cause_code
  const details = entryDetails(entry)
  const event = detailLabel(details, 'event')
  if (event) return event
  return classifyMessageCause(entry.message)
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
  const failureEnvelopeRecord = nestedRecord(details?.failure_envelope)
  const context: MutableLogRouteContext = {}
  mergeLogRouteRecord(context, nestedRecord(details?.context))
  mergeLogRouteRecord(context, nestedRecord(details?.evidence_ref))
  mergeLogRouteRecord(context, nestedRecord(failureEnvelopeRecord?.evidence_ref))
  mergeLogRouteRecord(context, nestedRecord(details?.tool_args))
  mergeLogRouteRecord(context, nestedRecord(details?.input))
  mergeLogRouteRecord(context, details, true)
  if (!hasLogRouteContext(context)) return []
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
      return 'text-[var(--bad-light)] bg-[var(--brick-soft)] border-[var(--err-border)]'
    case 'legacy_traceln':
      return 'text-[var(--warn-fg)] bg-[var(--warn-soft)] border-[var(--warn-border)]'
    default:
      return 'text-[var(--color-fg-muted)] bg-[var(--color-bg-surface)] border-[var(--color-border-default)]'
  }
}

async function loadLogs(mode: LoadMode = 'reset') {
  const requestId = ++latestRequestId

  if (mode === 'reset') {
    return logResource.load(async () => {
      const resp = await fetchLogs({
        limit: logLimit.value,
        level: levelFilter.value,
        module: appliedModuleFilter.value || undefined,
      })
      const entries = sortLogEntries(resp.entries).slice(0, Math.max(1, logLimit.value))
      latestSeq.value = latestLogSeq(entries)
      return { entries, total: resp.total }
    })
  }

  // delta mode — update existing loaded data
  try {
    const resp = await fetchLogs({
      limit: logLimit.value,
      level: levelFilter.value,
      module: appliedModuleFilter.value || undefined,
      since_seq: latestSeq.value ?? undefined,
    })
    if (requestId !== latestRequestId) return

    const s = logResource.state.value
    const currentEntries = s.status === 'loaded' ? s.data.entries : []
    const incoming = sortLogEntries(resp.entries)
    const nextEntries = mergeLogEntries(currentEntries, incoming, logLimit.value)

    latestSeq.value = latestLogSeq(nextEntries)
    logResource.state.value = loaded({ entries: nextEntries, total: resp.total })
  } catch {
    if (requestId !== latestRequestId) return
    // Delta failures don't overwrite loaded state — keep existing data visible
  }
}

function renderLogRow(entry: LogEntry) {
  const level = normalizedLevel(entry)
  const rawLevelChanged = entry.raw_level && entry.raw_level !== level
  const source = entry.source || 'structured'
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
  const diagnosticChip = failure
    ? html`<${StatusChip} tone="bad" uppercase=${false}>${failure.cause_code}</${StatusChip}>`
    : null
  const fallbackDiagnosticChip = !failure && diagnosticCause
    ? html`<${StatusChip} tone=${level === 'ERROR' ? 'bad' : 'warn'} uppercase=${false}>${diagnosticCause}</${StatusChip}>`
    : null
  let backgroundClass = 'bg-[var(--color-bg-surface)]'
  if (level === 'ERROR') {
    backgroundClass = 'bg-[var(--bad-6)]'
  } else if (level === 'WARN') {
    backgroundClass = 'bg-[var(--warn-soft)]'
  }

  return html`
    <div
      key=${entry.seq}
      class="logs-row grid grid-cols-[11rem_5rem_10rem_8rem_minmax(0,1fr)] gap-3 rounded-card border border-[var(--color-border-divider)] px-3 py-3 ${backgroundClass}"
    >
      <div class="font-mono text-2xs whitespace-nowrap text-[color:var(--color-fg-muted)]">
        ${entry.ts.replace('T', ' ').replace('Z', '')}
      </div>
      <div class="font-mono text-2xs font-semibold whitespace-nowrap" style="color: ${LEVEL_COLORS[level] ?? 'inherit'}">
        ${level}
      </div>
      <div class="min-w-0 font-mono text-2xs text-[color:var(--color-accent-fg)] truncate" title=${entry.module || '(root)'}>
        ${entry.module || '(root)'}
      </div>
      <div class="flex flex-wrap items-start gap-1">
        <${StatusChip} tone=${sourceClass}>${sourceLabel(source)}</${StatusChip}>
        ${entry.legacy_classified
          ? html`<${MetaTag}>classified</${MetaTag}>`
          : null}
        ${rawLevelChanged
          ? html`<${MetaTag}>${entry.raw_level}</${MetaTag}>`
          : null}
        ${clientName
          ? html`<${StatusChip} tone="border-[var(--color-accent-soft)] text-[var(--color-accent-fg)]" uppercase=${false}>${clientName}</${StatusChip}>`
          : null}
        ${toolName
          ? html`<${StatusChip} tone="neutral" uppercase=${false} class="gap-1"><span class="font-mono font-bold ${toolCategory(toolName).color}">${toolCategory(toolName).icon}</span><span>${toolName}</span></${StatusChip}>`
          : null}
        ${fixes
          ? html`<${MetaTag}>fixes ${fixes}</${MetaTag}>`
          : null}
        ${phase
          ? html`<${MetaTag}>${phase}</${MetaTag}>`
          : null}
        ${event
          ? html`<${MetaTag}>event ${event}</${MetaTag}>`
          : null}
        ${requestId
          ? html`<${MetaTag}>req ${requestId}</${MetaTag}>`
          : null}
        ${sessionId
          ? html`<${MetaTag}>session ${sessionId}</${MetaTag}>`
          : null}
        ${diagnosticChip}
        ${fallbackDiagnosticChip}
        ${failure
          ? html`<${StatusChip} tone="info" uppercase=${false}>${failure.surface}</${StatusChip}>`
          : null}
        ${failure
          ? html`<${MetaTag}>${failure.recoverability}</${MetaTag}>`
          : null}
        ${failure?.operator_action
          ? html`<${StatusChip} tone="info" uppercase=${false}>next ${failure.operator_action}</${StatusChip}>`
          : null}
        ${routeLinks.length > 0
          ? html`
            ${routeLinks.map(link => html`
              <button
                key=${link.id}
                type="button"
                data-testid=${link.label === 'Code' ? 'logs-code-link' : undefined}
                class="logs-route-link rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-[var(--color-accent-fg)] hover:border-[var(--color-accent-border)] hover:bg-[var(--color-bg-hover)]"
                title=${link.evidence}
                aria-label=${`Open ${link.evidence}`}
                onClick=${() => openIdeContextRouteLink(link)}
              >${link.label}</button>
            `)}
          `
          : null}
      </div>
      <div
        class="text-xs leading-relaxed text-[var(--color-fg-primary)]"
        title=${failure ? `${renderedMessage}\n${failure.summary}` : renderedMessage}
        style=${{
          display: '-webkit-box',
          overflow: 'hidden',
          WebkitBoxOrient: 'vertical',
          WebkitLineClamp: 2,
        }}
      >
        ${renderedMessage}
      </div>
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
    <div class="mx-3 mt-3 flex flex-wrap items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 text-2xs">
      ${renderSummaryChip('ERROR', summary.errors, summary.errors > 0 ? 'bad' : 'neutral')}
      ${renderSummaryChip('WARN', summary.warnings, summary.warnings > 0 ? 'warn' : 'neutral')}
      ${renderSummaryChip('failure envelope', summary.failureEnvelopes, summary.failureEnvelopes > 0 ? 'info' : 'neutral')}
      ${summary.topModules.map(item => renderSummaryChip(`module ${item.module}`, item.count))}
      ${summary.topCauses.map(item => renderSummaryChip(`cause ${item.cause}`, item.count, 'info'))}
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
    const unsubscribeAutoRefresh = autoRefresh.subscribe(restart)

    return () => {
      if (pollId) {
        clearInterval(pollId)
      }
      unsubscribeLevel()
      unsubscribeModule()
      unsubscribeLimit()
      unsubscribeAutoRefresh()
    }
  }, [])

  useEffect(() => () => {
    if (moduleDebounceTimer) {
      clearTimeout(moduleDebounceTimer)
      moduleDebounceTimer = null
    }
  }, [])

  const s = logResource.state.value
  const logData = s.status === 'loaded' ? s.data : undefined
  const logEntries = logData?.entries ?? []
  const logTotal = logData?.total ?? 0
  const logLoading = s.status === 'loading'
  const logError = s.status === 'error' ? s.message : null
  const summary = summarizeLogWindow(logEntries)

  return html`
    <div class="logs-viewer flex h-full min-h-0 flex-col gap-4">
      <section class="contain-content flex min-h-0 flex-1 flex-col overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]" aria-label="로그 뷰어">
        <div class="logs-toolbar flex shrink-0 flex-wrap items-center justify-between gap-4 border-b border-[var(--color-border-divider)] px-4 py-4">
          <div class="logs-filters flex flex-wrap gap-2 items-center">
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
          </div>

          <div class="logs-actions flex flex-wrap gap-3 items-center text-2xs text-[color:var(--color-fg-muted)]">
            <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 tabular-nums">${logEntries.length.toLocaleString()} / ${logTotal.toLocaleString()}</span>
            <label class="logs-auto-label flex items-center gap-1.5 cursor-pointer">
              <${Checkbox}
                name="log-auto-refresh"
                ariaLabel="자동 새로고침"
                checked=${autoRefresh.value}
                onChange=${(checked: boolean) => { autoRefresh.value = checked }}
              />
              자동
            </label>
            <button
              type="button"
              class="logs-refresh-btn rounded-[var(--r-1)] border border-[var(--accent-22)] bg-[var(--accent-10)] px-3 py-2 text-2xs font-medium text-[var(--color-accent-fg)]"
              onClick=${() => {
                latestSeq.value = null
                logResource.reset()
                void loadLogs('reset')
              }}
              disabled=${logLoading}
            >
              ${logLoading ? '...' : '새로고침'}
            </button>
          </div>
        </div>

        ${logError ? html`
          <div class="mx-4 mt-4 rounded-[var(--r-1)] border border-solid border-[var(--err-border)] bg-[var(--brick-soft)] px-4 py-3 text-xs text-[var(--err-fg)]">${logError}</div>
        ` : null}

        ${renderLogSummary(summary)}

        <div class="px-3 pt-3">
          <div class="grid grid-cols-[11rem_5rem_10rem_8rem_minmax(0,1fr)] gap-3 px-3 py-2 text-left text-3xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">
            <div>timestamp</div>
            <div>level</div>
            <div>module</div>
            <div>source</div>
            <div>message</div>
          </div>
        </div>

        ${logEntries.length === 0
          ? html`
              <div class="flex flex-1 items-center justify-center px-6 text-sm text-[var(--color-fg-muted)]" role="status">
                ${logLoading ? '로그를 불러오는 중...' : '조건에 맞는 로그가 없습니다.'}
              </div>
            `
          : html`
              <${VirtualList}
                items=${logEntries}
                itemHeight=${LOG_ROW_HEIGHT}
                overscan=${6}
                getKey=${(entry: LogEntry) => String(entry.seq)}
                renderItem=${(entry: LogEntry) => renderLogRow(entry)}
                className="min-h-0 flex-1 overflow-auto px-3 pb-3"
              />
            `}
      </section>
    </div>
  `
}
