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

interface LogData {
  entries: LogEntry[]
  total: number
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

export function failureEnvelope(entry: LogEntry): FailureEnvelope | null {
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

export function renderLogMessage(entry: LogEntry): string {
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
      return 'text-[var(--color-fg-muted)] bg-[var(--white-3)] border-[var(--white-10)]'
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

export function renderLogRow(entry: LogEntry) {
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
  const failure = failureEnvelope(entry)
  const sourceClass = sourceTone(source)
  const renderedMessage = renderLogMessage(entry)
  let backgroundClass = 'bg-[var(--white-1)]'
  if (level === 'ERROR') {
    backgroundClass = 'bg-[var(--bad-6)]'
  } else if (level === 'WARN') {
    backgroundClass = 'bg-[var(--warn-soft)]'
  }

  return html`
    <div
      key=${entry.seq}
      class="logs-row grid grid-cols-[11rem_5rem_10rem_8rem_minmax(0,1fr)] gap-3 rounded-card border border-[var(--white-5)] px-3 py-3 ${backgroundClass}"
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
        ${requestId
          ? html`<${MetaTag}>req ${requestId}</${MetaTag}>`
          : null}
        ${sessionId
          ? html`<${MetaTag}>session ${sessionId}</${MetaTag}>`
          : null}
        ${failure
          ? html`<${StatusChip} tone="bad" uppercase=${false}>${failure.cause_code}</${StatusChip}>`
          : null}
        ${failure
          ? html`<${MetaTag}>${failure.recoverability}</${MetaTag}>`
          : null}
        ${failure?.operator_action
          ? html`<${StatusChip} tone="info" uppercase=${false}>next ${failure.operator_action}</${StatusChip}>`
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

  return html`
    <div class="logs-viewer flex h-full min-h-0 flex-col gap-4">
      <section class="contain-content flex min-h-0 flex-1 flex-col overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]" aria-label="로그 뷰어">
        <div class="logs-toolbar flex shrink-0 flex-wrap items-center justify-between gap-4 border-b border-[var(--white-5)] px-4 py-4">
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
            <span class="rounded-sm border border-[var(--white-10)] bg-[var(--white-3)] px-2.5 py-1 tabular-nums">${logEntries.length.toLocaleString()} / ${logTotal.toLocaleString()}</span>
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
