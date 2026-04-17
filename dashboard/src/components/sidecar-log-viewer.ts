// SidecarLogViewer — manual-refresh tail of a sidecar's run.sh log via
// /api/v1/sidecar/logs?name=<id>&lines=N. Mounted inside ConnectorLivePanel
// when the operator clicks "📋 Logs" so we don't pay fetch cost for cards
// the operator isn't actively triaging.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import { LoadingState } from './common/feedback-state'

interface LogResponse {
  ok: boolean
  log_path: string
  available: boolean
  lines: string[]
}

// Per-connector state — keyed so toggling one panel doesn't affect another.
const logsState = signal<Record<string, {
  open: boolean
  lines: string[]
  logPath: string
  available: boolean
  loading: boolean
  error: string | null
  requestedLines: number
}>>({})

function getEntry(id: string) {
  return logsState.value[id] ?? {
    open: false,
    lines: [],
    logPath: '',
    available: false,
    loading: false,
    error: null,
    requestedLines: 200,
  }
}

function setEntry(id: string, patch: Partial<ReturnType<typeof getEntry>>) {
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
    <button
      type="button"
      class="cursor-pointer rounded border border-[var(--white-8)] px-2 py-0.5 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"
      aria-expanded=${entry.open}
      aria-controls=${`sidecar-log-${connectorId}`}
      onClick=${onClick}
    >📋 Logs</button>
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

  return html`
    <div
      id=${`sidecar-log-${connectorId}`}
      class="mt-3 rounded-md border border-[var(--white-8)] bg-[var(--bg-1)] p-2"
    >
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="min-w-0 truncate text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]" title=${entry.logPath}>
          ${entry.logPath || '(log path unknown)'}
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">
            ${entry.available ? `${entry.lines.length} / ${entry.requestedLines} lines` : 'no log yet'}
          </span>
          ${showMore
            ? html`<${ActionButton} variant="ghost" size="sm" disabled=${entry.loading} onClick=${onShowMore}>Show 1000<//>`
            : null}
          <${ActionButton} variant="ghost" size="sm" disabled=${entry.loading} onClick=${onRefresh}>
            ${entry.loading ? '...' : 'Refresh'}
          <//>
        </div>
      </div>
      ${entry.error
        ? html`<div class="rounded border border-rose-400/30 bg-rose-500/10 px-2 py-1 text-[11px] text-rose-100">${entry.error}</div>`
        : entry.loading && entry.lines.length === 0
          ? html`<${LoadingState}>로그 불러오는 중...<//>`
          : entry.available
            ? html`
                <pre class="max-h-[40vh] overflow-auto whitespace-pre-wrap break-words rounded bg-[var(--bg-0)] p-2 font-mono text-[10px] leading-[1.4] text-[var(--text-body)]">${entry.lines.join('\n')}</pre>
              `
            : html`
                <div class="rounded border border-dashed border-[var(--white-8)] px-3 py-3 text-center text-[11px] text-[var(--text-dim)]">
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
