// SidecarLogViewer — manual-refresh tail of a sidecar's run.sh log via
// /api/v1/sidecar/logs?name=<id>&lines=N. Mounted inside ConnectorLivePanel
// when the operator clicks "📋 Logs" so we don't pay fetch cost for cards
// the operator isn't actively triaging.
//
// Filtering (added 2026-04): level pills + keyword input + match-count
// badge so the operator doesn't have to drop to terminal+grep to read a
// busy log. Borrows Hermes Web UI's "filter by level + keyword" pattern.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import { SkeletonText } from './common/skeleton'

interface LogResponse {
  ok: boolean
  log_path: string
  available: boolean
  lines: string[]
}

type LogLevel = 'all' | 'debug' | 'info' | 'warn' | 'error'

const LEVEL_PATTERNS: Record<Exclude<LogLevel, 'all'>, RegExp> = {
  error: /\bERROR\b/i,
  warn: /\bWARN(?:ING)?\b/i,
  info: /\bINFO\b/i,
  debug: /\bDEBUG\b/i,
}

// Filtering a 10k+ line log on every keystroke is a UI jank hazard.
// We only search the tail window; above that, the operator should fetch
// a smaller window from the backend (`Show 1000` defaults us to 1000).
const MAX_FILTER_WINDOW = 1000

/** Pure: return the subset of `lines` matching the current filter, after
    trimming to the tail window if the input is too long. Exposed for
    unit tests so the filtering logic is verifiable without DOM. */
export function filterLines(
  lines: string[],
  level: LogLevel,
  keyword: string,
  maxWindow: number = MAX_FILTER_WINDOW,
): string[] {
  const window = lines.length > maxWindow ? lines.slice(-maxWindow) : lines
  const needle = keyword.trim().toLowerCase()
  const levelRe = level === 'all' ? null : LEVEL_PATTERNS[level]
  return window.filter(line => {
    if (levelRe !== null && !levelRe.test(line)) return false
    if (needle !== '' && !line.toLowerCase().includes(needle)) return false
    return true
  })
}

interface LogEntry {
  open: boolean
  lines: string[]
  logPath: string
  available: boolean
  loading: boolean
  error: string | null
  requestedLines: number
  level: LogLevel
  keyword: string
}

// Per-connector state — keyed so toggling one panel doesn't affect another.
const logsState = signal<Record<string, LogEntry>>({})

function getEntry(id: string): LogEntry {
  return logsState.value[id] ?? {
    open: false,
    lines: [],
    logPath: '',
    available: false,
    loading: false,
    error: null,
    requestedLines: 200,
    level: 'all',
    keyword: '',
  }
}

function setEntry(id: string, patch: Partial<LogEntry>) {
  logsState.value = {
    ...logsState.value,
    [id]: { ...getEntry(id), ...patch },
  }
}

async function fetchLogs(id: string, lines: number) {
  setEntry(id, { loading: true, error: null, requestedLines: lines })
  try {
    const res = await fetch(`/api/v1/sidecar/logs?name=${encodeURIComponent(id)}&lines=${lines}`, {
      headers: { Accept: 'application/json' },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const data = (await res.json()) as LogResponse
    setEntry(id, {
      lines: data.lines ?? [],
      logPath: data.log_path ?? '',
      available: data.available === true,
      loading: false,
    })
  } catch (err) {
    setEntry(id, {
      loading: false,
      error: err instanceof Error ? err.message : 'log fetch failed',
    })
  }
}

export function SidecarLogToggle({ connectorId }: { connectorId: string }) {
  const entry = getEntry(connectorId)
  const onClick = () => {
    if (entry.open) {
      setEntry(connectorId, { open: false })
    } else {
      setEntry(connectorId, { open: true })
      void fetchLogs(connectorId, entry.requestedLines)
    }
  }
  return html`
    <button type="button"
      class="cursor-pointer rounded border border-[var(--white-8)] px-2 py-0.5 text-3xs uppercase tracking-4 text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"
      aria-expanded=${entry.open}
      aria-controls=${`sidecar-log-${connectorId}`}
      onClick=${onClick}
    ><span aria-hidden="true">📋</span> 로그</button>
  `
}

const LEVELS: LogLevel[] = ['all', 'error', 'warn', 'info', 'debug']
const LEVEL_LABEL: Record<LogLevel, string> = {
  all: 'ALL',
  error: 'ERROR',
  warn: 'WARN',
  info: 'INFO',
  debug: 'DEBUG',
}

function LevelPills({ connectorId, active }: { connectorId: string; active: LogLevel }) {
  return html`
    <div class="flex items-center gap-1" role="radiogroup" aria-label="로그 레벨 필터">
      ${LEVELS.map(level => {
        const isActive = level === active
        const base = 'cursor-pointer rounded border px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4'
        const activeCls = 'border-[var(--accent-1)] bg-[var(--accent-1)]/15 text-[var(--text-body)]'
        const idleCls = 'border-[var(--white-8)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]'
        return html`
          <button type="button"
            role="radio"
            aria-checked=${isActive}
            class=${`${base} ${isActive ? activeCls : idleCls}`}
            data-log-level=${level}
            onClick=${() => setEntry(connectorId, { level })}
          >${LEVEL_LABEL[level]}</button>
        `
      })}
    </div>
  `
}

export function SidecarLogViewer({ connectorId }: { connectorId: string }) {
  const entry = getEntry(connectorId)
  if (!entry.open) return null

  // Poll every 30s while open so the panel stays roughly fresh without
  // the dashboard fetching for closed cards.
  useEffect(() => {
    const id = setInterval(() => {
      if (getEntry(connectorId).open) {
        void fetchLogs(connectorId, getEntry(connectorId).requestedLines)
      }
    }, 30000)
    return () => clearInterval(id)
  }, [connectorId])

  const showMore = entry.requestedLines < 1000
  const onRefresh = () => fetchLogs(connectorId, entry.requestedLines)
  const onShowMore = () => fetchLogs(connectorId, 1000)
  const filtered = filterLines(entry.lines, entry.level, entry.keyword)
  const hasFilter = entry.level !== 'all' || entry.keyword.trim() !== ''

  return html`
    <div
      id=${`sidecar-log-${connectorId}`}
      class="mt-3 rounded border border-[var(--white-8)] bg-[var(--bg-1)] p-2"
    >
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="min-w-0 truncate text-3xs uppercase tracking-4 text-[var(--text-dim)]" title=${entry.logPath}>
          ${entry.logPath || '(log path unknown)'}
        </div>
        <div class="flex items-center gap-2">
          <span class="text-3xs uppercase tracking-4 text-[var(--text-dim)]" data-log-count role="status">
            ${entry.available
              ? hasFilter
                ? `${filtered.length} / ${entry.lines.length} lines`
                : `${entry.lines.length} / ${entry.requestedLines} lines`
              : 'no log yet'}
          </span>
          ${showMore
            ? html`<${ActionButton} variant="ghost" size="sm" disabled=${entry.loading} onClick=${onShowMore}>Show 1000<//>`
            : null}
          <${ActionButton} variant="ghost" size="sm" disabled=${entry.loading} onClick=${onRefresh}>
            ${entry.loading ? '...' : 'Refresh'}
          <//>
        </div>
      </div>
      ${entry.available && entry.lines.length > 0
        ? html`
            <div class="mb-2 flex flex-wrap items-center gap-2">
              <${LevelPills} connectorId=${connectorId} active=${entry.level} />
              <input
                type="search"
                value=${entry.keyword}
                placeholder="키워드 필터 (대소문자 무관)"
                aria-label="로그 키워드 필터"
                autoComplete="off"
                class="min-w-0 flex-1 rounded border border-[var(--white-8)] bg-[var(--bg-0)] px-2 py-0.5 text-2xs text-[var(--text-body)] focus:border-[var(--accent-1)] focus:outline-none"
                data-log-keyword
                onInput=${(ev: Event) => {
                  const v = (ev.target as HTMLInputElement).value
                  setEntry(connectorId, { keyword: v })
                }}
              />
              ${hasFilter
                ? html`
                    <button type="button"
                      class="cursor-pointer rounded border border-[var(--white-8)] px-1.5 py-0.5 text-3xs uppercase tracking-4 text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"
                      aria-label="필터 초기화"
                      data-log-filter-clear
                      onClick=${() => setEntry(connectorId, { level: 'all', keyword: '' })}
                    >초기화</button>
                  `
                : null}
            </div>
          `
        : null}
      ${entry.error
        ? html`<div role="alert" class="rounded border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-1 text-2xs text-[var(--bad-light)]">${entry.error}</div>`
        : entry.loading && entry.lines.length === 0
          ? html`
              <div class="rounded bg-[var(--bg-0)] p-2">
                <${SkeletonText} lines=${8} ariaLabel="로그 불러오는 중" />
              </div>
            `
          : entry.available
            ? filtered.length === 0 && hasFilter
              ? html`
                  <div role="status" class="rounded border border-dashed border-[var(--white-8)] px-3 py-3 text-center text-2xs text-[var(--text-dim)]">
                    필터 조건에 맞는 라인이 없습니다.
                    ${entry.lines.length > MAX_FILTER_WINDOW
                      ? ` (최근 ${MAX_FILTER_WINDOW}줄만 검색)`
                      : ''}
                  </div>
                `
              : html`
                  <pre role="log" aria-label="${connectorId} 로그" class="max-h-[40vh] overflow-auto whitespace-pre-wrap break-words rounded bg-[var(--bg-0)] p-2 font-mono text-3xs leading-[1.4] text-[var(--text-body)]" tabindex="0">${filtered.join('\n')}</pre>
                `
            : html`
                <div role="status" class="rounded border border-dashed border-[var(--white-8)] px-3 py-3 text-center text-2xs text-[var(--text-dim)]">
                  오늘 날짜 로그 파일이 아직 없습니다. sidecar를 시작하면 자동 생성됩니다.
                </div>
              `}
    </div>
  `
}

/** Open the log viewer for [connectorId] + kick off a fetch.
    Exposed so other components (e.g. the startup-check banner) can
    redirect an operator to "the logs explain why" without opening
    the header toggle themselves. */
export function openSidecarLogs(connectorId: string) {
  const entry = getEntry(connectorId)
  if (!entry.open) {
    setEntry(connectorId, { open: true })
    void fetchLogs(connectorId, entry.requestedLines)
  }
}

export function resetSidecarLogState() {
  logsState.value = {}
}
