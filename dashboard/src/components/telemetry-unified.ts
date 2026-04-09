// Telemetry Unified — MASC runtime diagnosis view.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardShell,
  fetchDashboardTools,
  fetchDashboardNamespaceTruth,
  fetchTelemetry,
  fetchTelemetrySummary,
  type TelemetryEntry,
  type TelemetrySource,
  type TelemetrySourceSummary,
} from '../api/dashboard'
import { route } from '../router'
import { formatTimeAgo } from '../lib/format-time'

const SOURCE_META: Record<TelemetrySource, { label: string; sublabel: string; color: string; icon: string }> = {
  keeper_metric: { label: 'Keeper 턴 로그', sublabel: 'heartbeat ~80%, 실제 추론 턴 ~20%', color: 'text-blue-400', icon: 'K' },
  agent_event: { label: 'Agent 이벤트', sublabel: 'tool_called 다수, join/leave/task 포함', color: 'text-emerald-400', icon: 'A' },
  tool_call_io: { label: 'Keeper Tool I/O', sublabel: 'keeper->tool 입출력 전체 기록', color: 'text-amber-400', icon: 'T' },
  tool_usage: { label: 'Keeper 내부 호출', sublabel: 'keeper_internal caller 기록', color: 'text-purple-400', icon: 'U' },
  tool_metric: { label: 'Tool 성능', sublabel: 'duration/success 측정', color: 'text-cyan-400', icon: 'M' },
}

interface StoreSnapshot {
  keepers: number
  agents: number
  tasks: number
  activeSessions: number
  activeOperations: number
  continuityAlerts: number
  toolsRegistered: number
  toolsPublic: number
  toolsTotalCalls: number
  toolsNeverCalled: number
  version: string | null
  uptime: number | null
}

const EMPTY_STORE: StoreSnapshot = {
  keepers: 0, agents: 0, tasks: 0,
  activeSessions: 0, activeOperations: 0, continuityAlerts: 0,
  toolsRegistered: 0, toolsPublic: 0, toolsTotalCalls: 0, toolsNeverCalled: 0,
  version: null, uptime: null,
}

interface TelemetryState {
  entries: TelemetryEntry[]
  summary: TelemetrySourceSummary[]
  totalEntries: number
  store: StoreSnapshot
  loading: boolean
  error: string | null
}

function sourceMeta(source: string) {
  return SOURCE_META[source as TelemetrySource] ?? { label: source, sublabel: '', color: 'text-gray-400', icon: '?' }
}

function entryTimestamp(e: TelemetryEntry): number {
  const numeric = (e.ts_unix as number) ?? (e.ts as number) ?? (e.timestamp as number) ?? 0
  if (numeric > 0) return numeric
  if (typeof e.ts_iso === 'string') {
    const parsed = Date.parse(e.ts_iso)
    if (!Number.isNaN(parsed)) return parsed / 1000
  }
  return 0
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
  return formatTimeAgo(ts)
}

function normalizeText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function normalizeStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string' && item.trim() !== '') : []
}

function compactId(value: string | null | undefined, prefix: string): string | null {
  if (!value) return null
  return `${prefix} ${value}`
}

function telemetryScopeBadges(entry: TelemetryEntry): string[] {
  return [
    compactId(normalizeText(entry.session_id), 'S'),
    compactId(normalizeText(entry.operation_id), 'OP'),
    compactId(normalizeText(entry.worker_run_id), 'WR'),
  ].filter((value): value is string => Boolean(value))
}

function entryPreview(e: TelemetryEntry): string {
  switch (e.source) {
    case 'keeper_metric': {
      const name = normalizeText(e.name) ?? '-'
      const channel = normalizeText(e.channel) ?? '-'
      const rawModel = normalizeText(e.model_used)
      const isStatusTag = rawModel != null && /^(turn-exhausted|unknown|none|-)$/i.test(rawModel)
      const model = rawModel == null ? '-' : isStatusTag ? `(${rawModel})` : rawModel
      const tools = normalizeStringArray(e.tools_used)
      const toolCount = typeof e.tool_call_count === 'number' ? e.tool_call_count : tools.length
      return `${name} [${channel}] model=${model} tools=${toolCount}`
    }
    case 'agent_event': {
      const event = e.event
      if (Array.isArray(event)) {
        const tag = String(event[0] ?? 'unknown')
        const detail = event[1] as Record<string, unknown> | undefined
        if (detail) {
          const parts = [
            normalizeText(detail.agent_id as string),
            normalizeText(detail.tool_name as string),
          ].filter(Boolean)
          return parts.length > 0 ? `${tag}: ${parts.join(' -> ')}` : tag
        }
        return tag
      }
      return String(event ?? '')
    }
    case 'tool_call_io': {
      const tool = normalizeText(e.tool) ?? ''
      const keeper = normalizeText(e.keeper) ?? ''
      return `${keeper} -> ${tool}`
    }
    case 'tool_usage': {
      const tool = normalizeText(e.tool_name) ?? ''
      const caller = normalizeText(e.caller) ?? ''
      return `${caller || 'unknown'} -> ${tool}`
    }
    case 'tool_metric': {
      const tool = normalizeText(e.tool_name) ?? ''
      const dur = typeof e.duration_ms === 'number' ? e.duration_ms : null
      return `${tool} ${dur != null ? dur.toFixed(0) + 'ms' : ''}`
    }
    default:
      return JSON.stringify(e).slice(0, 80)
  }
}

function SummaryCard({ src }: { src: TelemetrySourceSummary }) {
  const meta = sourceMeta(src.source)
  const hasData = src.entry_count > 0

  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
      <div class="flex items-center gap-2 mb-1">
        <span class="font-mono font-bold ${meta.color}">${meta.icon}</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${meta.label}</span>
      </div>
      ${meta.sublabel ? html`<div class="text-[10px] text-[var(--text-dim)] mb-1">${meta.sublabel}</div>` : null}
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

function EntryRow({ entry }: { entry: TelemetryEntry }) {
  const expanded = useSignal(false)
  const meta = sourceMeta(entry.source)
  const ts = entryTimestamp(entry)
  const success = entry.success as boolean | undefined
  const scopeBadges = telemetryScopeBadges(entry)

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
        ${scopeBadges.length > 0 ? html`
          <span class="hidden xl:flex items-center gap-1 flex-shrink-0">
            ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-1.5 py-0.5 text-[10px] text-[var(--text-dim)] font-mono">${badge}</span>`)}
          </span>
        ` : null}
        <span class="flex-shrink-0 w-4 text-[var(--text-muted)]">${expanded.value ? '-' : '+'}</span>
      </div>
      ${expanded.value ? html`
        <div class="px-3 pb-3 flex flex-col gap-2">
          ${scopeBadges.length > 0 ? html`
            <div class="flex flex-wrap gap-1.5">
              ${scopeBadges.map(badge => html`<span class="rounded bg-[var(--white-4)] px-2 py-1 text-[10px] text-[var(--text-dim)] font-mono">${badge}</span>`)}
            </div>
          ` : null}
          <pre class="text-[10px] font-mono text-[var(--text-muted)] bg-[rgba(0,0,0,0.3)] rounded p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">
${JSON.stringify(entry, null, 2)}</pre>
        </div>
      ` : null}
    </div>
  `
}

export function TelemetryUnified() {
  const params = route.value.params
  const state = useSignal<TelemetryState>({
    entries: [],
    summary: [],
    totalEntries: 0,
    store: EMPTY_STORE,
    loading: true,
    error: null,
  })
  const sourceFilter = useSignal<TelemetrySource | ''>('')
  const keeperFilter = useSignal('')
  const sessionFilter = useSignal(params.session_id ?? '')
  const operationFilter = useSignal(params.operation_id ?? '')
  const workerRunFilter = useSignal(params.worker_run_id ?? '')
  const limit = useSignal(100)

  useEffect(() => {
    sessionFilter.value = route.value.params.session_id ?? ''
    operationFilter.value = route.value.params.operation_id ?? ''
    workerRunFilter.value = route.value.params.worker_run_id ?? ''
  }, [
    route.value.params.session_id,
    route.value.params.operation_id,
    route.value.params.worker_run_id,
  ])

  async function load() {
    state.value = { ...state.value, loading: true, error: null }
    try {
      const storePromise = Promise.all([
        fetchDashboardShell().catch(() => null),
        fetchDashboardTools().catch(() => null),
        fetchDashboardNamespaceTruth().catch(() => null),
      ]).then(([shell, tools, truth]) => {
        const counts = shell?.counts
        const execSummary = truth?.execution?.summary
        const inv = tools?.tool_inventory
        const usage = tools?.tool_usage
        const surfacePublic = inv?.surface_summary?.public_mcp?.count ?? inv?.surface_summary?.public?.count ?? 0
        return {
          keepers: counts?.keepers ?? 0,
          agents: counts?.agents ?? 0,
          tasks: counts?.tasks ?? 0,
          activeSessions: execSummary?.active_sessions ?? 0,
          activeOperations: execSummary?.active_operations ?? 0,
          continuityAlerts: execSummary?.continuity_alerts ?? 0,
          toolsRegistered: inv?.count ?? 0,
          toolsPublic: surfacePublic,
          toolsTotalCalls: usage?.total_calls ?? 0,
          toolsNeverCalled: usage?.never_called_count ?? 0,
          version: shell?.status?.version ?? null,
          uptime: shell?.status?.build?.uptime_seconds ?? null,
        } satisfies StoreSnapshot
      })
      const [telemetry, summary, store] = await Promise.all([
        fetchTelemetry({
          source: sourceFilter.value || undefined,
          keeper: keeperFilter.value || undefined,
          session_id: sessionFilter.value || undefined,
          operation_id: operationFilter.value || undefined,
          worker_run_id: workerRunFilter.value || undefined,
          n: limit.value,
        }),
        fetchTelemetrySummary(),
        storePromise,
      ])
      state.value = {
        entries: telemetry.entries,
        summary: summary.sources,
        totalEntries: summary.total_entries,
        store,
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

  useEffect(() => { void load() }, [
    sourceFilter.value,
    keeperFilter.value,
    sessionFilter.value,
    operationFilter.value,
    workerRunFilter.value,
    limit.value,
  ])

  const { entries, summary, totalEntries, store, loading, error } = state.value

  return html`
    <div class="flex flex-col gap-4">
      <div class="rounded-xl border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-4">
        <div class="text-[12px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">Runtime Diagnosis</div>
        <div class="mt-1 text-[14px] leading-relaxed text-[var(--text-body)]">
          MASC telemetry store (keeper/tool/agent) 진단 뷰.
        </div>
        <div class="mt-3 flex flex-wrap gap-2">
          <span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-dim)]">MASC: keeper/tool/agent store</span>
          ${sessionFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">session ${sessionFilter.value}</span>` : null}
          ${operationFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">operation ${operationFilter.value}</span>` : null}
          ${workerRunFilter.value ? html`<span class="rounded-md bg-[var(--white-4)] px-2 py-1 text-[11px] font-mono text-[var(--text-dim)]">worker_run ${workerRunFilter.value}</span>` : null}
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        ${summary.map(src => html`<${SummaryCard} src=${src} />`)}
        <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 min-w-[140px]">
          <div class="text-xs font-medium text-[var(--text-muted)] mb-1">Total</div>
          <div class="text-2xl font-bold text-[var(--text-strong)]">${totalEntries.toLocaleString()}</div>
        </div>
      </div>

      <div class="flex flex-wrap gap-3">
        <${DiagnosisCard}
          title="Keeper 현황 (live)"
          value=${String(store.keepers)}
          detail=${[
            `${store.activeSessions} 활성 세션`,
            `${store.continuityAlerts} continuity 알림`,
            store.version ? `v${store.version}` : null,
            store.uptime != null ? `uptime ${Math.floor(store.uptime / 60)}m` : null,
          ].filter(Boolean).join(' · ')}
          tone=${store.continuityAlerts > 0 ? 'warn' : store.keepers > 0 ? 'ok' : 'neutral'}
        />
        <${DiagnosisCard}
          title="Tool 등록 현황 (live)"
          value=${String(store.toolsRegistered)}
          detail=${`${store.toolsPublic} public · ${store.toolsTotalCalls.toLocaleString()} 총 호출 · ${store.toolsNeverCalled} 미사용`}
          tone=${store.toolsRegistered > 0 ? 'ok' : 'warn'}
        />
        <${DiagnosisCard}
          title="Agent 현황 (live)"
          value=${String(store.agents)}
          detail=${`${store.tasks} 태스크 · ${store.activeOperations} 활성 작전`}
          tone=${store.agents > 0 ? 'ok' : 'neutral'}
        />
      </div>

      <div class="flex items-center gap-3 flex-wrap">
        <select
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${sourceFilter.value}
          onChange=${(e: Event) => { sourceFilter.value = (e.target as HTMLSelectElement).value as TelemetrySource | '' }}
        >
          <option value="">All sources</option>
          ${Object.entries(SOURCE_META).map(([key, m]) => html`<option value=${key}>${m.label}</option>`)}
        </select>
        <input
          type="text"
          placeholder="Keeper name..."
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-32"
          value=${keeperFilter.value}
          onInput=${(e: Event) => { keeperFilter.value = (e.target as HTMLInputElement).value }}
        />
        <input
          type="text"
          placeholder="session_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${sessionFilter.value}
          onInput=${(e: Event) => { sessionFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="operation_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${operationFilter.value}
          onInput=${(e: Event) => { operationFilter.value = (e.target as HTMLInputElement).value.trim() }}
        />
        <input
          type="text"
          placeholder="worker_run_id"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)] w-40 font-mono"
          value=${workerRunFilter.value}
          onInput=${(e: Event) => { workerRunFilter.value = (e.target as HTMLInputElement).value.trim() }}
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

      ${error ? html`
        <div class="rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">
          ${error}
        </div>
      ` : null}

      <div class="rounded-xl border border-[var(--card-border)] overflow-hidden">
        <div class="px-3 py-2 border-b border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-muted)]">
          MASC telemetry store entries ${entries.length.toLocaleString()}건
        </div>
        <div class="max-h-[600px] overflow-y-auto">
          ${entries.length > 0
            ? entries.map((entry, index) => html`<${EntryRow} key=${`${entry.source}-${entryTimestamp(entry)}-${index}`} entry=${entry} />`)
            : html`<div class="px-4 py-6 text-sm text-[var(--text-muted)]">선택한 scope에 해당하는 MASC telemetry entry가 없습니다.</div>`}
        </div>
      </div>
    </div>
  `
}
