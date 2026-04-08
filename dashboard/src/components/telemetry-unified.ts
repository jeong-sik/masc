// Telemetry Unified — aggregated view of all telemetry sources.
// Fetches from GET /api/v1/dashboard/telemetry

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchTelemetry, fetchTelemetrySummary } from '../api/dashboard'
import type {
  TelemetryEntry,
  TelemetrySource,
  TelemetrySourceSummary,
} from '../api/dashboard'

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

function entryTimestamp(e: TelemetryEntry): number {
  return (e.ts_unix as number) ?? (e.ts as number) ?? (e.timestamp as number) ?? 0
}

function formatTs(ts: number): string {
  if (ts === 0) return '-'
  const d = new Date(ts * 1000)
  return d.toLocaleString('ko-KR', {
    month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function timeAgo(ts: number): string {
  if (ts === 0) return ''
  const diff = Date.now() / 1000 - ts
  if (diff < 60) return `${Math.floor(diff)}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

// ── Summary card ─────────────────────────────────────

function SummaryCard({ src }: { src: TelemetrySourceSummary }) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0

  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
      <div class="flex items-center gap-2 mb-1">
        <span class="font-mono font-bold ${meta.color}">${meta.icon}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${meta.label}</span>
      </div>
      <div class="text-2xl font-bold ${hasData ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'}">
        ${src.entry_count.toLocaleString()}
      </div>
      ${src.keeper_count != null ? html`
        <div class="text-xs text-[var(--text-muted)]">${src.keeper_count} keepers</div>
      ` : null}
      ${src.exists === false ? html`
        <div class="text-xs text-[var(--text-muted)] italic">store not found</div>
      ` : null}
    </div>
  `
}

// ── Entry row ────────────────────────────────────────

function entryPreview(e: TelemetryEntry): string {
  // Show key identifying fields based on source
  switch (e.source) {
    case 'keeper_metric': {
      const name = e.name as string ?? ''
      const channel = e.channel as string ?? ''
      const model = e.model_used as string ?? ''
      const tools = (e.tools_used as string[]) ?? []
      const toolCount = e.tool_call_count as number ?? tools.length
      return `${name} [${channel}] model=${model} tools=${toolCount}`
    }
    case 'agent_event': {
      const event = e.event
      if (Array.isArray(event)) return `${event[0] ?? 'unknown'}`
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = e.tool as string ?? ''
      const keeper = e.keeper as string ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = e.tool_name as string ?? ''
      const caller = e.caller as string ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'tool_metric': {
      const tool = e.tool_name as string ?? ''
      const dur = e.duration_ms as number
      return `${tool} ${dur != null ? dur.toFixed(0) + 'ms' : ''}`
    }
    default:
      return JSON.stringify(e).slice(0, 80)
  }
}

function EntryRow({ entry }: { entry: TelemetryEntry }) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const ts = entryTimestamp(entry)
  const success = entry.success as boolean | undefined

  return html`
    <div class="border-b border-[var(--card-border)] hover:bg-[var(--bg-panel-hover)] transition-colors">
      <div
        class="flex items-center gap-2 px-3 py-1.5 text-xs cursor-pointer select-none"
        role="button"
        tabIndex=${0}
        onClick=${() => { expanded.value = !expanded.value }}
        onKeyDown=${(e: KeyboardEvent) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            expanded.value = !expanded.value
          }
        }}
      >
        <span class="font-mono font-bold ${meta.color} w-4 text-center flex-shrink-0">${meta.icon}</span>
        <span class="font-mono text-[var(--text-muted)] w-28 flex-shrink-0" title=${formatTs(ts)}>
          ${timeAgo(ts)}
        </span>
        ${success != null ? html`
          <span class="flex-shrink-0 w-4 ${success ? 'text-green-400' : 'text-red-400'}">
            ${success ? 'O' : 'X'}
          </span>
        ` : html`<span class="w-4"></span>`}
        <span class="font-mono text-[var(--text-strong)] truncate flex-1" title=${entryPreview(entry)}>
          ${entryPreview(entry)}
        </span>
        <span class="flex-shrink-0 w-4 text-[var(--text-muted)]">${expanded.value ? '-' : '+'}</span>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-2">
          <pre class="text-[10px] font-mono text-[var(--text-muted)] bg-[rgba(0,0,0,0.3)] rounded p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">
${JSON.stringify(entry, null, 2)}</pre>
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
  loading: boolean
  error: string | null
}

export function TelemetryUnified() {
  const state = useSignal<TelemetryState>({
    entries: [],
    summary: [],
    totalEntries: 0,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>('')
  const keeperFilter = useSignal('')
  const limit = useSignal(100)

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
        loading: false,
        error: null,
      }
    } catch (e) {
      state.value = {
        ...state.value,
        loading: false,
        error: e instanceof Error ? e.message : String(e),
      }
    }
  }

  useEffect(() => { void load() }, [sourceFilter.value, keeperFilter.value, limit.value])

  const { entries, summary, totalEntries, loading, error } = state.value

  return html`
    <div class="flex flex-col gap-4">
      <!-- Summary cards -->
      <div class="flex flex-wrap gap-3">
        ${summary.map(src => html`<${SummaryCard} src=${src} />`)}
        <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
          <div class="text-xs font-medium text-[var(--text-muted)] mb-1">Total</div>
          <div class="text-2xl font-bold text-[var(--text-strong)]">${totalEntries.toLocaleString()}</div>
        </div>
      </div>

      <!-- Filters -->
      <div class="flex items-center gap-3 flex-wrap">
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${sourceFilter.value}
          onChange=${(e: Event) => { sourceFilter.value = (e.target as HTMLSelectElement).value as TelemetrySource | '' }}
        >
          <option value="">All sources</option>
          ${Object.entries(SOURCE_META).map(([key, m]) => html`
            <option value=${key}>${m.label}</option>
          `)}
        </select>
        <input
          type="text"
          placeholder="Keeper name..."
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-32"
          value=${keeperFilter.value}
          onInput=${(e: Event) => { keeperFilter.value = (e.target as HTMLInputElement).value }}
        />
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${String(limit.value)}
          onChange=${(e: Event) => { limit.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="50">50</option>
          <option value="100">100</option>
          <option value="200">200</option>
          <option value="500">500</option>
        </select>
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load()}
        >
          Refresh
        </button>
        ${loading ? html`<span class="text-xs text-[var(--text-muted)]">loading...</span>` : null}
      </div>

      <!-- Error -->
      ${error ? html`
        <div class="rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">
          ${error}
        </div>
      ` : null}

      <!-- Entry list -->
      <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] overflow-hidden">
        <div class="flex items-center gap-2 px-3 py-2 text-[10px] uppercase tracking-wider text-[var(--text-muted)] border-b border-[var(--card-border)] bg-[rgba(0,0,0,0.2)]">
          <span class="w-4">Src</span>
          <span class="w-28">Time</span>
          <span class="w-4">Ok</span>
          <span class="flex-1">Detail</span>
        </div>
        ${entries.length === 0 && !loading ? html`
          <div class="px-3 py-8 text-center text-xs text-[var(--text-muted)]">
            No telemetry entries found
          </div>
        ` : null}
        ${entries.map(entry => html`<${EntryRow} key=${JSON.stringify(entry).slice(0, 50)} entry=${entry} />`)}
      </div>
    </div>
  `
}
