import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchLogs } from '../api/dashboard.js'
import type { LogEntry } from '../api/dashboard.js'
import { VirtualList } from './common/virtual-list'
import { TextInput } from './common/input'
import { createAsyncResource, loaded } from '../lib/async-state'

interface LogData {
  entries: LogEntry[]
  total: number
}

const logResource = createAsyncResource<LogData>()
const levelFilter = signal('INFO')
const moduleFilter = signal('')
const autoRefresh = signal(true)
const logLimit = signal(200)
const latestSeq = signal<number | null>(null)

const POLL_INTERVAL_MS = 3000
const LOG_ROW_HEIGHT = 76

let moduleDebounceTimer: ReturnType<typeof setTimeout> | null = null
let latestRequestId = 0

const LEVEL_COLORS: Record<string, string> = {
  DEBUG: 'var(--text-muted)',
  INFO: 'var(--text-body)',
  WARN: '#e6a700',
  ERROR: '#e05050',
}

const SOURCE_LABELS: Record<string, string> = {
  structured: 'structured',
  legacy_stderr: 'legacy stderr',
  legacy_traceln: 'legacy traceln',
  client_tool_host: 'client tool-host',
  sse: 'sse',
}

type LoadMode = 'reset' | 'delta'

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

function sourceTone(source: string): string {
  switch (source) {
    case 'client_tool_host':
      return 'text-[#dff3ff] bg-[rgba(71,184,255,0.12)] border-[rgba(71,184,255,0.22)]'
    case 'legacy_stderr':
      return 'text-[#ffb4b4] bg-[rgba(224,80,80,0.12)] border-[rgba(224,80,80,0.18)]'
    case 'legacy_traceln':
      return 'text-[#ffd88a] bg-[rgba(230,167,0,0.12)] border-[rgba(230,167,0,0.18)]'
    default:
      return 'text-[var(--text-muted)] bg-[rgba(255,255,255,0.04)] border-[rgba(255,255,255,0.08)]'
  }
}

async function loadLogs(mode: LoadMode = 'reset') {
  const requestId = ++latestRequestId

  if (mode === 'reset') {
    return logResource.load(async () => {
      const resp = await fetchLogs({
        limit: logLimit.value,
        level: levelFilter.value,
        module: moduleFilter.value || undefined,
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
      module: moduleFilter.value || undefined,
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
  const toolName = detailLabel(details, 'tool_name')
  const phase = detailLabel(details, 'phase')
  const requestId = detailLabel(details, 'request_id')
  const sessionId = detailLabel(details, 'session_id')
  const sourceClass = sourceTone(source)
  const backgroundClass =
    level === 'ERROR'
      ? 'bg-[rgba(224,80,80,0.08)]'
      : level === 'WARN'
        ? 'bg-[rgba(230,167,0,0.05)]'
        : 'bg-[rgba(255,255,255,0.02)]'

  return html`
    <div
      key=${entry.seq}
      class="logs-row grid grid-cols-[11rem_5rem_10rem_8rem_minmax(0,1fr)] gap-3 rounded-[18px] border border-[rgba(255,255,255,0.05)] px-3 py-3 ${backgroundClass}"
    >
      <div class="font-mono text-[11px] whitespace-nowrap text-[color:var(--text-muted)]">
        ${entry.ts.replace('T', ' ').replace('Z', '')}
      </div>
      <div class="font-mono text-[11px] font-semibold whitespace-nowrap" style="color: ${LEVEL_COLORS[level] ?? 'inherit'}">
        ${level}
      </div>
      <div class="min-w-0 font-mono text-[11px] text-[color:var(--accent)] truncate" title=${entry.module || '(root)'}>
        ${entry.module || '(root)'}
      </div>
      <div class="flex flex-wrap items-start gap-1">
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.08em] ${sourceClass}">
          ${sourceLabel(source)}
        </span>
        ${entry.legacy_classified
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">classified</span>`
          : null}
        ${rawLevelChanged
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${entry.raw_level}</span>`
          : null}
        ${clientName
          ? html`<span class="rounded-full border border-[rgba(71,184,255,0.16)] px-2 py-0.5 text-[10px] text-[#dff3ff]">${clientName}</span>`
          : null}
        ${toolName
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${toolName}</span>`
          : null}
        ${phase
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">${phase}</span>`
          : null}
        ${requestId
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">req ${requestId}</span>`
          : null}
        ${sessionId
          ? html`<span class="rounded-full border border-[rgba(255,255,255,0.08)] px-2 py-0.5 text-[10px] text-[var(--text-muted)]">session ${sessionId}</span>`
          : null}
      </div>
      <div
        class="text-[12px] leading-relaxed text-[var(--text-body)]"
        title=${entry.message}
        style=${{
          display: '-webkit-box',
          overflow: 'hidden',
          WebkitBoxOrient: 'vertical',
          WebkitLineClamp: 2,
        }}
      >
        ${entry.message}
      </div>
    </div>
  `
}

export function LogViewer() {
  useEffect(() => {
    logResource.reset()
    void loadLogs('reset')
    if (!autoRefresh.value) return
    const id = setInterval(() => {
      void loadLogs('delta')
    }, POLL_INTERVAL_MS)
    return () => clearInterval(id)
  }, [levelFilter.value, moduleFilter.value, logLimit.value, autoRefresh.value])

  const s = logResource.state.value
  const logData = s.status === 'loaded' ? s.data : undefined
  const logEntries = logData?.entries ?? []
  const logTotal = logData?.total ?? 0
  const logLoading = s.status === 'loading'
  const logError = s.status === 'error' ? s.message : null

  return html`
    <div class="logs-viewer flex h-full min-h-0 flex-col gap-4">
      <section class="flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl border border-[rgba(138,163,211,0.16)] bg-[rgba(7,13,24,0.86)]">
        <div class="logs-toolbar flex shrink-0 flex-wrap items-center justify-between gap-4 border-b border-[rgba(255,255,255,0.06)] px-4 py-4">
          <div class="logs-filters flex flex-wrap gap-2 items-center">
            <select
              class="logs-select rounded-md border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 text-[12px] text-[var(--text-body)]"
              value=${levelFilter.value}
              onChange=${(e: Event) => {
                levelFilter.value = (e.target as HTMLSelectElement).value
                latestSeq.value = null
                logResource.reset()
                void loadLogs('reset')
              }}
            >
              <option value="DEBUG">DEBUG+</option>
              <option value="INFO">INFO+</option>
              <option value="WARN">WARN+</option>
              <option value="ERROR">ERROR</option>
            </select>

            <${TextInput}
              class="min-w-[220px]"
              placeholder="모듈 필터"
              value=${moduleFilter.value}
              onInput=${(e: Event) => {
                moduleFilter.value = (e.target as HTMLInputElement).value
                if (moduleDebounceTimer) clearTimeout(moduleDebounceTimer)
                moduleDebounceTimer = setTimeout(() => {
                  latestSeq.value = null
                  logResource.reset()
                  void loadLogs('reset')
                }, 300)
              }}
              onKeyDown=${(e: KeyboardEvent) => {
                if (e.key === 'Enter') {
                  if (moduleDebounceTimer) clearTimeout(moduleDebounceTimer)
                  latestSeq.value = null
                  logResource.reset()
                  void loadLogs('reset')
                }
              }}
            />

            <select
              class="logs-select rounded-md border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 text-[12px] text-[var(--text-body)]"
              value=${String(logLimit.value)}
              onChange=${(e: Event) => {
                logLimit.value = parseInt((e.target as HTMLSelectElement).value, 10)
                latestSeq.value = null
                logResource.reset()
                void loadLogs('reset')
              }}
            >
              <option value="100">100</option>
              <option value="200">200</option>
              <option value="500">500</option>
              <option value="1000">1000</option>
              <option value="3000">3000</option>
            </select>
          </div>

          <div class="logs-actions flex flex-wrap gap-3 items-center text-[11px] text-[color:var(--text-muted)]">
            <span class="rounded-full border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 tabular-nums">${logEntries.length.toLocaleString()} / ${logTotal.toLocaleString()}</span>
            <label class="logs-auto-label flex items-center gap-1.5 cursor-pointer">
              <input
                type="checkbox"
                checked=${autoRefresh.value}
                onChange=${() => { autoRefresh.value = !autoRefresh.value }}
              />
              자동
            </label>
            <button
              type="button"
              class="logs-refresh-btn rounded-md border border-[rgba(71,184,255,0.22)] bg-[rgba(71,184,255,0.12)] px-3 py-2 text-[11px] font-medium text-[#dff3ff]"
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
          <div class="mx-4 mt-4 rounded-md border border-solid border-[#e05050] bg-[rgba(224,80,80,0.12)] px-4 py-3 text-[12px] text-[#ffb3b3]">${logError}</div>
        ` : null}

        <div class="px-3 pt-3">
          <div class="grid grid-cols-[11rem_5rem_10rem_8rem_minmax(0,1fr)] gap-3 px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">
            <div>timestamp</div>
            <div>level</div>
            <div>module</div>
            <div>source</div>
            <div>message</div>
          </div>
        </div>

        ${logEntries.length === 0
          ? html`
              <div class="flex flex-1 items-center justify-center px-6 text-[13px] text-[var(--text-muted)]">
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
