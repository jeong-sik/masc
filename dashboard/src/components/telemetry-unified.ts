// Telemetry Unified — aggregated view of all telemetry sources.
// Fetches from GET /api/v1/dashboard/telemetry

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchTelemetry, fetchTelemetrySummary } from '../api/dashboard'
import { FetchScheduler } from '../lib/fetch-scheduler'
import { formatTimeAgo } from '../lib/format-time'
import type {
  TelemetryEntry,
  TelemetrySource,
  TelemetrySourceSummary,
} from '../api/dashboard'

const TELEMETRY_AUTO_REFRESH_MS = 15_000
const TELEMETRY_CLOCK_TICK_MS = 5_000
const TELEMETRY_SNAPSHOT_STALE_MS = 45_000
const TELEMETRY_FILTER_DEBOUNCE_MS = 250
const TELEMETRY_REFRESH_COOLDOWN_MS = 5_000

const LOCAL_TS_FORMATTER = new Intl.DateTimeFormat('en-GB', {
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false,
  timeZoneName: 'short',
})

const UTC_TS_FORMATTER = new Intl.DateTimeFormat('en-GB', {
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hour12: false,
  timeZone: 'UTC',
  timeZoneName: 'short',
})

// ── Source labels & colors ───────────────────────────

const SOURCE_META: Record<TelemetrySource, { label: string; color: string; icon: string }> = {
  keeper_metric: { label: 'Keeper 메트릭', color: 'text-blue-400', icon: 'K' },
  agent_event: { label: '에이전트 이벤트', color: 'text-emerald-400', icon: 'A' },
  tool_call_io: { label: '도구 호출 I/O', color: 'text-amber-400', icon: 'T' },
  tool_usage: { label: '도구 사용', color: 'text-purple-400', icon: 'U' },
  tool_metric: { label: '도구 메트릭', color: 'text-cyan-400', icon: 'M' },
}

function sourceMeta(source: string) {
  return SOURCE_META[source as TelemetrySource] ?? { label: source, color: 'text-gray-400', icon: '?' }
}

// ── Timestamp formatting ─────────────────────────────

function timestampToMs(value: string | number | null | undefined): number | null {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null
    return value < 1_000_000_000_000 ? value * 1000 : value
  }
  if (typeof value === 'string') {
    const parsed = Date.parse(value)
    return Number.isNaN(parsed) ? null : parsed
  }
  return null
}

function entryTimestampMs(entry: TelemetryEntry): number | null {
  return timestampToMs(
    (entry.ts_unix as number | undefined)
    ?? (entry.ts as number | undefined)
    ?? (entry.timestamp as number | undefined),
  )
}

function oldestTimestampMs(...timestamps: Array<string | null | undefined>): number | null {
  const values = timestamps
    .map(timestamp => timestampToMs(timestamp))
    .filter((value): value is number => value != null)
  if (values.length === 0) return null
  return Math.min(...values)
}

function formatLocalTimestamp(ms: number | null): string {
  return ms == null ? 'time n/a' : LOCAL_TS_FORMATTER.format(ms)
}

function formatUtcTimestamp(ms: number | null): string {
  return ms == null ? 'time n/a' : UTC_TS_FORMATTER.format(ms)
}

function snapshotTone(ageMs: number | null): { label: string; className: string } {
  if (ageMs == null) {
    return {
      label: 'snapshot unavailable',
      className: 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)]',
    }
  }
  if (ageMs <= TELEMETRY_AUTO_REFRESH_MS) {
    return {
      label: 'live snapshot',
      className: 'border-emerald-400/25 bg-emerald-500/12 text-emerald-100',
    }
  }
  if (ageMs <= TELEMETRY_SNAPSHOT_STALE_MS) {
    return {
      label: 'recent snapshot',
      className: 'border-sky-400/25 bg-sky-500/12 text-sky-100',
    }
  }
  return {
    label: 'stale snapshot',
    className: 'border-amber-400/30 bg-amber-500/12 text-amber-100',
  }
}

function entryAgeTone(ageMs: number | null): string {
  if (ageMs == null) return 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)]'
  if (ageMs <= 15_000) return 'border-emerald-400/25 bg-emerald-500/12 text-emerald-100'
  if (ageMs <= 60_000) return 'border-sky-400/25 bg-sky-500/12 text-sky-100'
  if (ageMs <= 300_000) return 'border-amber-400/30 bg-amber-500/12 text-amber-100'
  return 'border-rose-400/30 bg-rose-500/12 text-rose-100'
}

function isDocumentVisible(): boolean {
  return document.visibilityState !== 'hidden'
}

// ── Summary card ─────────────────────────────────────

function SummaryCard({
  src,
  totalEntries,
}: {
  src: TelemetrySourceSummary
  totalEntries: number
}) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0
  const sharePct = totalEntries > 0 ? Math.round((src.entry_count / totalEntries) * 100) : 0

  return html`
    <div class="min-w-[170px] rounded-xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.03)] p-3 shadow-sm shadow-black/10">
      <div class="mb-2 flex items-center gap-2">
        <span class="inline-flex h-6 w-6 items-center justify-center rounded-lg border border-[var(--white-8)] bg-[rgba(255,255,255,0.04)] font-mono text-[11px] font-bold ${meta.color}">
          ${meta.icon}
        </span>
        <div class="min-w-0">
          <div class="text-[12px] font-medium text-[var(--text-strong)]">${meta.label}</div>
          <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-dim)]">${src.source}</div>
        </div>
      </div>
      <div class="text-[28px] font-semibold leading-none ${hasData ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'}">
        ${src.entry_count.toLocaleString()}
      </div>
      <div class="mt-2 flex flex-wrap items-center gap-2 text-[10px] text-[var(--text-muted)]">
        ${src.keeper_count != null ? html`<span>${src.keeper_count} keepers</span>` : null}
        ${hasData ? html`<span>${sharePct}% share</span>` : null}
        ${src.exists === false ? html`<span class="italic">store missing</span>` : null}
      </div>
    </div>
  `
}

// ── Entry row ────────────────────────────────────────

function entryPreview(entry: TelemetryEntry): string {
  switch (entry.source) {
    case 'keeper_metric': {
      const name = entry.name as string ?? ''
      const channel = entry.channel as string ?? ''
      const model = entry.model_used as string ?? ''
      const tools = (entry.tools_used as string[]) ?? []
      const toolCount = entry.tool_call_count as number ?? tools.length
      return `${name} [${channel}] model=${model} tools=${toolCount}`
    }
    case 'agent_event': {
      const event = entry.event
      if (Array.isArray(event)) return `${event[0] ?? 'unknown'}`
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = entry.tool as string ?? ''
      const keeper = entry.keeper as string ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = entry.tool_name as string ?? ''
      const caller = entry.caller as string ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'tool_metric': {
      const tool = entry.tool_name as string ?? ''
      const dur = entry.duration_ms as number
      return `${tool} ${dur != null ? `${dur.toFixed(0)}ms` : ''}`.trim()
    }
    default:
      return JSON.stringify(entry).slice(0, 120)
  }
}

function EntryRow({
  entry,
  nowMs,
}: {
  entry: TelemetryEntry
  nowMs: number
}) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const tsMs = entryTimestampMs(entry)
  const success = entry.success as boolean | undefined
  const ageMs = tsMs == null ? null : Math.max(0, nowMs - tsMs)
  const ageLabel = tsMs == null ? 'time n/a' : formatTimeAgo(tsMs)
  const localTs = formatLocalTimestamp(tsMs)
  const utcTs = formatUtcTimestamp(tsMs)

  return html`
    <div class="border-b border-[var(--card-border)] last:border-b-0 hover:bg-[rgba(255,255,255,0.02)] transition-colors">
      <div
        class="flex flex-wrap items-start gap-3 px-3 py-3 text-xs cursor-pointer select-none"
        role="button"
        tabIndex=${0}
        onClick=${() => { expanded.value = !expanded.value }}
        onKeyDown=${(event: KeyboardEvent) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault()
            expanded.value = !expanded.value
          }
        }}
      >
        <div class="flex items-center gap-2 min-w-[96px]">
          <span class="inline-flex h-7 w-7 items-center justify-center rounded-lg border border-[var(--white-8)] bg-[rgba(255,255,255,0.04)] font-mono text-[11px] font-bold ${meta.color}">
            ${meta.icon}
          </span>
          <div class="min-w-0">
            <div class="text-[11px] font-medium text-[var(--text-strong)]">${meta.label}</div>
            <div class="text-[10px] uppercase tracking-[0.18em] text-[var(--text-dim)]">${entry.source}</div>
          </div>
        </div>

        <div class="min-w-[108px]">
          <div class=${`inline-flex rounded-full border px-2 py-1 text-[11px] font-medium ${entryAgeTone(ageMs)}`}>
            ${ageLabel}
          </div>
          <div class="mt-1 text-[10px] text-[var(--text-dim)]">
            ${success == null ? 'status n/a' : success ? 'success' : 'failure'}
          </div>
        </div>

        <div class="min-w-[220px] font-mono text-[10px] leading-5 text-[var(--text-muted)]">
          <div><span class="text-[var(--text-dim)]">Local</span> ${localTs}</div>
          <div><span class="text-[var(--text-dim)]">UTC</span> ${utcTs}</div>
        </div>

        <div class="min-w-[260px] flex-1">
          <div class="flex flex-wrap items-center gap-2">
            ${success != null
              ? html`
                  <span class=${`inline-flex rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] ${
                    success
                      ? 'border-emerald-400/25 bg-emerald-500/12 text-emerald-100'
                      : 'border-rose-400/30 bg-rose-500/12 text-rose-100'
                  }`}>
                    ${success ? 'ok' : 'error'}
                  </span>
                `
              : null}
            <span class="inline-flex rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.03)] px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-[var(--text-muted)]">
              ${expanded.value ? 'expanded' : 'collapsed'}
            </span>
          </div>
          <div class="mt-1 font-mono text-[12px] leading-relaxed text-[var(--text-strong)] break-all" title=${entryPreview(entry)}>
            ${entryPreview(entry)}
          </div>
        </div>

        <div class="ml-auto text-[16px] leading-none text-[var(--text-dim)]">${expanded.value ? '−' : '+'}</div>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-3">
          <pre class="max-h-[320px] overflow-auto whitespace-pre-wrap break-all rounded-xl border border-[var(--white-8)] bg-[rgba(0,0,0,0.32)] p-3 text-[10px] font-mono text-[var(--text-muted)]">${JSON.stringify(entry, null, 2)}</pre>
        </div>
      ` : null}
    </div>
  `
}

// ── Main component ───────────────────────────────────

interface TelemetryState {
  entries: TelemetryEntry[]
  summary: TelemetrySourceSummary[]
  totalEntries: number
  telemetryGeneratedAt: string | null
  summaryGeneratedAt: string | null
  lastLoadedAtMs: number | null
  loading: boolean
  error: string | null
}

export function TelemetryUnified() {
  const state = useSignal<TelemetryState>({
    entries: [],
    summary: [],
    totalEntries: 0,
    telemetryGeneratedAt: null,
    summaryGeneratedAt: null,
    lastLoadedAtMs: null,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>('')
  const keeperFilter = useSignal('')
  const limit = useSignal(100)
  const autoRefresh = useSignal(true)
  const now = useSignal(Date.now())

  async function load() {
    state.value = { ...state.value, loading: true, error: null }
    try {
      const [telemetry, summary] = await Promise.all([
        fetchTelemetry({
          source: sourceFilter.value || undefined,
          keeper: keeperFilter.value || undefined,
          n: limit.value,
        }),
        fetchTelemetrySummary(),
      ])
      state.value = {
        entries: telemetry.entries,
        summary: summary.sources,
        totalEntries: summary.total_entries,
        telemetryGeneratedAt: telemetry.generated_at ?? null,
        summaryGeneratedAt: summary.generated_at ?? null,
        lastLoadedAtMs: Date.now(),
        loading: false,
        error: null,
      }
    } catch (error) {
      state.value = {
        ...state.value,
        loading: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  useEffect(() => {
    now.value = Date.now()
    const id = window.setInterval(() => { now.value = Date.now() }, TELEMETRY_CLOCK_TICK_MS)
    return () => window.clearInterval(id)
  }, [])

  useEffect(() => {
    const scheduler = new FetchScheduler(
      () => load(),
      {
        cooldownMs: TELEMETRY_REFRESH_COOLDOWN_MS,
        debounceMs: TELEMETRY_FILTER_DEBOUNCE_MS,
      },
    )

    scheduler.requestNow()

    const intervalId = window.setInterval(() => {
      if (!autoRefresh.value || !isDocumentVisible()) return
      scheduler.requestNow()
    }, TELEMETRY_AUTO_REFRESH_MS)

    const handleVisibilityChange = () => {
      if (!autoRefresh.value || !isDocumentVisible()) return
      scheduler.requestNow()
    }

    const handleWindowFocus = () => {
      if (!autoRefresh.value) return
      scheduler.request()
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)
    window.addEventListener('focus', handleWindowFocus)

    return () => {
      window.clearInterval(intervalId)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      window.removeEventListener('focus', handleWindowFocus)
      scheduler.dispose()
    }
  }, [sourceFilter.value, keeperFilter.value, limit.value, autoRefresh.value])

  const {
    entries,
    summary,
    totalEntries,
    telemetryGeneratedAt,
    summaryGeneratedAt,
    lastLoadedAtMs,
    loading,
    error,
  } = state.value

  const snapshotMs = oldestTimestampMs(telemetryGeneratedAt, summaryGeneratedAt)
  const snapshotAgeMs = snapshotMs == null ? null : Math.max(0, now.value - snapshotMs)
  const freshness = snapshotTone(snapshotAgeMs)

  return html`
    <div class="flex flex-col gap-4">
      <section class="rounded-2xl border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(15,23,42,0.84),rgba(8,12,22,0.96))] p-4 shadow-lg shadow-black/12">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--text-dim)]">Telemetry Stream</div>
            <div class="mt-1 text-[15px] font-medium text-[var(--text-strong)]">자동 갱신 + 상대시간 + 정확한 시각을 함께 보여줍니다.</div>
            <div class="mt-1 text-[12px] text-[var(--text-muted)]">
              탭이 보일 때는 ${Math.round(TELEMETRY_AUTO_REFRESH_MS / 1000)}초 간격으로 polling 하고, 다시 포커스되면 즉시 동기화합니다.
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              class=${`rounded-full border px-3 py-1.5 text-[11px] font-medium transition-colors ${
                autoRefresh.value
                  ? 'border-emerald-400/25 bg-emerald-500/12 text-emerald-100'
                  : 'border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] text-[var(--text-muted)]'
              }`}
              onClick=${() => { autoRefresh.value = !autoRefresh.value }}
            >
              Auto ${Math.round(TELEMETRY_AUTO_REFRESH_MS / 1000)}s ${autoRefresh.value ? 'ON' : 'OFF'}
            </button>
            <button
              class="rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] px-3 py-1.5 text-[11px] font-medium text-[var(--text-strong)] transition-colors hover:bg-[rgba(255,255,255,0.08)]"
              onClick=${() => { void load() }}
            >
              ${loading ? 'Syncing...' : 'Refresh now'}
            </button>
          </div>
        </div>

        <div class="mt-4 flex flex-wrap gap-2 text-[11px]">
          <span class=${`rounded-full border px-2.5 py-1 ${freshness.className}`}>
            ${freshness.label} ${snapshotMs == null ? '' : `· ${formatTimeAgo(snapshotMs)}`}
          </span>
          ${lastLoadedAtMs != null ? html`
            <span class="rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 text-[var(--text-muted)]">
              last fetch ${formatTimeAgo(lastLoadedAtMs)}
            </span>
          ` : null}
          ${snapshotMs != null ? html`
            <span class="rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 font-mono text-[var(--text-muted)]">
              Local ${formatLocalTimestamp(snapshotMs)}
            </span>
          ` : null}
          ${snapshotMs != null ? html`
            <span class="rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 font-mono text-[var(--text-muted)]">
              UTC ${formatUtcTimestamp(snapshotMs)}
            </span>
          ` : null}
          <span class="rounded-full border border-[var(--white-10)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 text-[var(--text-muted)]">
            showing ${entries.length} / ${limit.value}
          </span>
        </div>
      </section>

      <section class="rounded-2xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3">
        <div class="flex flex-wrap items-center gap-3">
          <select
            class="rounded-lg border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 text-xs text-[var(--text-strong)]"
            value=${sourceFilter.value}
            onChange=${(event: Event) => { sourceFilter.value = (event.target as HTMLSelectElement).value as TelemetrySource | '' }}
          >
            <option value="">All sources</option>
            ${Object.entries(SOURCE_META).map(([key, meta]) => html`
              <option value=${key}>${meta.label}</option>
            `)}
          </select>
          <input
            type="text"
            placeholder="Keeper name..."
            class="w-36 rounded-lg border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 text-xs text-[var(--text-strong)]"
            value=${keeperFilter.value}
            onInput=${(event: Event) => { keeperFilter.value = (event.target as HTMLInputElement).value }}
          />
          <select
            class="rounded-lg border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 text-xs text-[var(--text-strong)]"
            value=${String(limit.value)}
            onChange=${(event: Event) => { limit.value = Number((event.target as HTMLSelectElement).value) }}
          >
            <option value="50">50 rows</option>
            <option value="100">100 rows</option>
            <option value="200">200 rows</option>
            <option value="500">500 rows</option>
          </select>
          <span class="text-[11px] text-[var(--text-dim)]">
            hidden tab에서는 polling을 멈추고, 다시 보이면 바로 새로고침합니다.
          </span>
        </div>
      </section>

      ${summary.length > 0 || totalEntries > 0 ? html`
        <section class="flex flex-wrap gap-3">
          ${summary.map(src => html`<${SummaryCard} src=${src} totalEntries=${totalEntries} />`)}
          <div class="min-w-[170px] rounded-xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.03)] p-3 shadow-sm shadow-black/10">
            <div class="text-[12px] font-medium text-[var(--text-muted)]">Total</div>
            <div class="mt-2 text-[28px] font-semibold leading-none text-[var(--text-strong)]">${totalEntries.toLocaleString()}</div>
            <div class="mt-2 text-[10px] text-[var(--text-muted)]">all telemetry sources</div>
          </div>
        </section>
      ` : null}

      ${error ? html`
        <div class="rounded-xl border border-rose-500/25 bg-rose-500/10 px-3 py-2 text-xs text-rose-200">
          ${error}
        </div>
      ` : null}

      <section class="overflow-hidden rounded-2xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--card-border)] bg-[rgba(0,0,0,0.22)] px-3 py-2">
          <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-[var(--text-dim)]">Latest Entries</div>
          <div class="text-[11px] text-[var(--text-muted)]">${loading ? 'syncing telemetry…' : `${entries.length} rows loaded`}</div>
        </div>
        ${entries.length === 0 && !loading ? html`
          <div class="px-3 py-10 text-center text-xs text-[var(--text-muted)]">
            No telemetry entries found
          </div>
        ` : null}
        ${entries.map(entry => html`
          <${EntryRow}
            key=${JSON.stringify(entry).slice(0, 120)}
            entry=${entry}
            nowMs=${now.value}
          />
        `)}
      </section>
    </div>
  `
}
