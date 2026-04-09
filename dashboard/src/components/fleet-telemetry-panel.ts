import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchDashboardExecution,
  fetchTelemetrySummary,
  fetchToolQuality,
  type TelemetrySourceSummary,
  type ToolQualityResponse,
} from '../api/dashboard'
import { normalizeKeepers } from '../keeper-store-normalize'
import { formatElapsedCompact, formatTimeAgo } from '../lib/format-time'
import type { Keeper } from '../types'

const PRESSURE_HOT_RATIO = 0.75
const PRESSURE_WARN_RATIO = 0.5
const STALE_ACTIVITY_SEC = 900

const SOURCE_LABELS: Record<string, string> = {
  keeper_metric: 'Keeper metrics',
  agent_event: 'Agent events',
  tool_call_io: 'Tool call I/O',
  tool_usage: 'Tool usage',
  tool_metric: 'Tool metrics',
}

interface FleetRow {
  name: string
  status: string
  keepalive_running: boolean
  context_ratio: number
  turn_count: number
  last_latency_ms: number
  last_activity_ago_s: number | null
  model: string
  tool_calls: number
  tool_success_pct: number | null
  recent_tools: string[]
}

interface FleetTelemetryState {
  loading: boolean
  error: string | null
  warnings: string[]
  rows: FleetRow[]
  tool_quality: ToolQualityResponse
  telemetry_sources: TelemetrySourceSummary[]
  total_telemetry_entries: number
  updated_at: string | null
}

const EMPTY_TOOL_QUALITY: ToolQualityResponse = {
  total: 0,
  success: 0,
  failure: 0,
  success_rate: 0,
  by_tool: [],
  by_keeper: [],
  failure_categories: [],
  hourly_trend: [],
}

function emptyState(): FleetTelemetryState {
  return {
    loading: false,
    error: null,
    warnings: [],
    rows: [],
    tool_quality: EMPTY_TOOL_QUALITY,
    telemetry_sources: [],
    total_telemetry_entries: 0,
    updated_at: null,
  }
}

function sourceLabel(source: string): string {
  return SOURCE_LABELS[source] ?? source
}

function errorMessage(reason: unknown): string {
  return reason instanceof Error ? reason.message : 'unknown error'
}

function uniqueStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const items: string[] = []
  for (const value of values) {
    if (typeof value !== 'string') continue
    const trimmed = value.trim()
    if (trimmed === '' || seen.has(trimmed)) continue
    seen.add(trimmed)
    items.push(trimmed)
  }
  return items
}

function keeperModel(keeper: Keeper): string {
  return keeper.last_model_used
    || keeper.active_model
    || keeper.model
    || keeper.primary_model
    || 'unknown'
}

function keeperLastLatencyMs(keeper: Keeper): number {
  if (typeof keeper.last_latency_ms === 'number' && Number.isFinite(keeper.last_latency_ms)) {
    return keeper.last_latency_ms
  }
  const lastMetric = keeper.metrics_series?.[keeper.metrics_series.length - 1]
  return lastMetric?.latency_ms ?? 0
}

function successClass(rate: number | null): string {
  if (rate == null || !Number.isFinite(rate)) return 'text-[var(--text-dim)]'
  if (rate >= 97) return 'text-emerald-400'
  if (rate >= 90) return 'text-yellow-400'
  return 'text-red-400'
}

function keeperRecentTools(keeper: Keeper): string[] {
  return uniqueStrings([
    ...(keeper.recent_tool_names ?? []),
    ...(keeper.latest_tool_names ?? []),
  ]).slice(0, 3)
}

function buildToolQualityMap(toolQuality: ToolQualityResponse): Map<string, { calls: number; success_pct: number }> {
  const byKeeper = new Map<string, { calls: number; success_pct: number }>()
  for (const keeper of toolQuality.by_keeper) {
    byKeeper.set(keeper.name, {
      calls: keeper.calls,
      success_pct: keeper.success_pct,
    })
  }
  return byKeeper
}

function fleetSortScore(row: FleetRow): [number, number, number, number, number, number, string] {
  const liveScore = row.keepalive_running ? 1 : 0
  const hasActivityScore =
    row.last_activity_ago_s != null
    && Number.isFinite(row.last_activity_ago_s)
    && row.last_activity_ago_s >= 0
      ? 1
      : 0
  const activityScore = hasActivityScore === 1 ? row.last_activity_ago_s ?? Number.POSITIVE_INFINITY : Number.POSITIVE_INFINITY
  return [
    liveScore,
    hasActivityScore,
    activityScore,
    row.tool_calls,
    row.turn_count,
    row.context_ratio,
    row.name,
  ]
}

function compareFleetRows(a: FleetRow, b: FleetRow): number {
  const aScore = fleetSortScore(a)
  const bScore = fleetSortScore(b)
  if (aScore[0] !== bScore[0]) return bScore[0] - aScore[0]
  if (aScore[1] !== bScore[1]) return bScore[1] - aScore[1]
  if (aScore[2] !== bScore[2]) return aScore[2] - bScore[2]
  if (aScore[3] !== bScore[3]) return bScore[3] - aScore[3]
  if (aScore[4] !== bScore[4]) return bScore[4] - aScore[4]
  if (aScore[5] !== bScore[5]) return bScore[5] - aScore[5]
  return aScore[6].localeCompare(bScore[6])
}

export function buildFleetRows(keepers: Keeper[], toolQuality: ToolQualityResponse): FleetRow[] {
  const toolStats = buildToolQualityMap(toolQuality)
  const rows =
    keepers.length > 0
      ? keepers.map((keeper): FleetRow => {
          const toolQualityForKeeper = toolStats.get(keeper.name)
          return {
            name: keeper.name,
            status: keeper.status ?? (keeper.keepalive_running ? 'active' : 'offline'),
            keepalive_running: keeper.keepalive_running === true,
            context_ratio: keeper.context_ratio ?? 0,
            turn_count: keeper.total_turns ?? keeper.turn_count ?? 0,
            last_latency_ms: keeperLastLatencyMs(keeper),
            last_activity_ago_s: keeper.last_activity_ago_s ?? null,
            model: keeperModel(keeper),
            tool_calls: toolQualityForKeeper?.calls ?? 0,
            tool_success_pct: toolQualityForKeeper?.success_pct ?? null,
            recent_tools: keeperRecentTools(keeper),
          }
        })
      : toolQuality.by_keeper.map((keeper): FleetRow => ({
          name: keeper.name,
          status: 'unknown',
          keepalive_running: false,
          context_ratio: 0,
          turn_count: 0,
          last_latency_ms: 0,
          last_activity_ago_s: null,
          model: 'unknown',
          tool_calls: keeper.calls,
          tool_success_pct: keeper.success_pct,
          recent_tools: [],
        }))

  return [...rows].sort(compareFleetRows)
}

function toneForToolSuccess(rate: number): 'neutral' | 'ok' | 'warn' {
  if (rate >= 97) return 'ok'
  if (rate >= 90) return 'neutral'
  return 'warn'
}

function toneForPressure(hot: number, warn: number): 'neutral' | 'ok' | 'warn' {
  if (hot > 0) return 'warn'
  if (warn > 0) return 'neutral'
  return 'ok'
}

function pressureClass(ratio: number): string {
  if (ratio >= PRESSURE_HOT_RATIO) return 'text-red-400'
  if (ratio >= PRESSURE_WARN_RATIO) return 'text-yellow-400'
  return 'text-emerald-400'
}

function statusClass(row: FleetRow): string {
  if (!row.keepalive_running || row.status === 'offline' || row.status === 'stopped') return 'text-red-400'
  if (row.context_ratio >= PRESSURE_HOT_RATIO) return 'text-yellow-400'
  return 'text-emerald-400'
}

function formatPercent(value: number | null, digits = 0): string {
  if (value == null || !Number.isFinite(value)) return '-'
  return `${value.toFixed(digits)}%`
}

function formatLatency(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '-'
  if (ms < 1000) return `${Math.round(ms)}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

function formatActivity(seconds: number | null): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return '-'
  return formatElapsedCompact(seconds)
}

function summaryCounts(rows: FleetRow[]) {
  const live = rows.filter(row => row.keepalive_running).length
  const toolCovered = rows.filter(row => row.tool_calls > 0).length
  const hot = rows.filter(row => row.keepalive_running && row.context_ratio >= PRESSURE_HOT_RATIO).length
  const warn = rows.filter(row =>
    row.keepalive_running
    && row.context_ratio >= PRESSURE_WARN_RATIO
    && row.context_ratio < PRESSURE_HOT_RATIO,
  ).length
  const stale = rows.filter(row =>
    row.keepalive_running
    && row.last_activity_ago_s != null
    && row.last_activity_ago_s >= STALE_ACTIVITY_SEC,
  ).length
  return { live, toolCovered, hot, warn, stale }
}

function SummaryCard({
  title,
  value,
  detail,
  tone = 'neutral',
}: {
  title: string
  value: string
  detail: string
  tone?: 'neutral' | 'ok' | 'warn'
}) {
  const toneClass =
    tone === 'ok'
      ? 'border-emerald-500/20 bg-emerald-500/5'
      : tone === 'warn'
        ? 'border-amber-500/20 bg-amber-500/5'
        : 'border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]'

  return html`
    <div class="rounded-lg border ${toneClass} p-3">
      <div class="text-[10px] uppercase tracking-wider text-[var(--text-dim)]">${title}</div>
      <div class="mt-1 text-xl font-semibold text-[var(--text)]">${value}</div>
      <div class="mt-1 text-[11px] leading-relaxed text-[var(--text-dim)]">${detail}</div>
    </div>
  `
}

function WarningBanner({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return html`
    <div class="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-[11px] text-amber-200">
      <div class="font-medium text-amber-100">Partial telemetry</div>
      <div class="mt-1 flex flex-col gap-1">
        ${warnings.map(warning => html`<div>${warning}</div>`)}
      </div>
    </div>
  `
}

function PressureWatchlist({ rows }: { rows: FleetRow[] }) {
  const watchlist = rows
    .filter(row =>
      row.keepalive_running
      && (
        row.context_ratio >= PRESSURE_WARN_RATIO
        || (row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC)
      ),
    )
    .slice(0, 5)

  if (watchlist.length === 0) {
    return html`
      <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 text-[11px] text-[var(--text-dim)]">
        No keepers are near context pressure or stale activity thresholds.
      </div>
    `
  }

  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]">
      ${watchlist.map(row => html`
        <div class="flex items-center justify-between gap-3 border-b border-[var(--card-border)] px-3 py-2 text-[11px] last:border-b-0">
          <div class="min-w-0">
            <div class="font-mono text-[var(--text)]">${row.name}</div>
            <div class="text-[var(--text-dim)]">
              ${row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC
                ? `stale ${formatActivity(row.last_activity_ago_s)}`
                : `ctx ${formatPercent(row.context_ratio * 100, 1)}`}
            </div>
          </div>
          <div class="text-right">
            <div class="font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</div>
            <div class="text-[var(--text-dim)]">${formatActivity(row.last_activity_ago_s)}</div>
          </div>
        </div>
      `)}
    </div>
  `
}

function FleetComparisonTable({ rows }: { rows: FleetRow[] }) {
  if (rows.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">No keeper fleet data available.</div>`
  }

  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-[11px]">
        <thead>
          <tr class="border-b border-[var(--card-border)] text-[var(--text-dim)]">
            <th class="py-1 text-left font-normal">Keeper</th>
            <th class="py-1 text-right font-normal">Status</th>
            <th class="py-1 text-right font-normal">Activity</th>
            <th class="py-1 text-right font-normal">Tools</th>
            <th class="py-1 text-right font-normal">Success</th>
            <th class="py-1 text-right font-normal">Ctx</th>
            <th class="py-1 text-right font-normal">Latency</th>
            <th class="py-1 text-right font-normal">Model</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => html`
            <tr class="border-b border-[var(--card-border)] border-opacity-30 align-top">
              <td class="py-1.5">
                <div class="font-mono text-[var(--text)]">${row.name}</div>
                <div class="max-w-[240px] truncate text-[10px] text-[var(--text-dim)]" title=${row.recent_tools.join(', ') || 'No recent tools'}>
                  ${row.recent_tools.length > 0 ? row.recent_tools.join(', ') : 'No recent tools'}
                </div>
              </td>
              <td class="py-1.5 text-right font-mono ${statusClass(row)}">${row.status}</td>
              <td class="py-1.5 text-right text-[var(--text-dim)]">${formatActivity(row.last_activity_ago_s)}</td>
              <td class="py-1.5 text-right font-mono text-[var(--text)]">${row.tool_calls.toLocaleString()}</td>
              <td class="py-1.5 text-right font-mono ${successClass(row.tool_success_pct)}">
                ${formatPercent(row.tool_success_pct, 1)}
              </td>
              <td class="py-1.5 text-right font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</td>
              <td class="py-1.5 text-right text-[var(--text-dim)]">${formatLatency(row.last_latency_ms)}</td>
              <td class="py-1.5 text-right text-[10px] text-[var(--text-dim)]">${row.model}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function TelemetrySourcesPanel({ sources }: { sources: TelemetrySourceSummary[] }) {
  if (sources.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">Telemetry store summary is unavailable.</div>`
  }

  const sorted = [...sources].sort((a, b) => b.entry_count - a.entry_count)
  return html`
    <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
      ${sorted.map(source => html`
        <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3">
          <div class="flex items-center justify-between gap-3">
            <div class="text-[11px] font-medium text-[var(--text)]">${sourceLabel(source.source)}</div>
            <div class="font-mono text-[11px] ${source.entry_count > 0 ? 'text-emerald-400' : 'text-[var(--text-dim)]'}">
              ${source.entry_count.toLocaleString()}
            </div>
          </div>
          <div class="mt-1 text-[10px] text-[var(--text-dim)]">
            ${source.keeper_count != null
              ? `${source.keeper_count} keepers tracked`
              : source.exists === false
                ? 'store missing'
                : 'store available'}
          </div>
        </div>
      `)}
    </div>
  `
}

function FailureCategoryPanel({ toolQuality }: { toolQuality: ToolQualityResponse }) {
  if (toolQuality.failure_categories.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">No recent failure categories.</div>`
  }

  const top = toolQuality.failure_categories.slice(0, 8)
  const maxCount = top[0]?.count ?? 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${top.map(category => html`
        <div class="flex items-center gap-2 text-[11px]">
          <div class="flex min-w-0 flex-1 items-center gap-1.5">
            <div
              class="h-1.5 rounded-full bg-red-500/60"
              style="width: ${Math.max(6, (category.count / maxCount) * 100)}%"
            ></div>
            <span class="truncate font-mono text-red-300" title=${category.category}>${category.category}</span>
          </div>
          <span class="text-[var(--text-dim)]">${category.count}</span>
        </div>
      `)}
    </div>
  `
}

export function FleetTelemetryPanel() {
  const state = useSignal<FleetTelemetryState>(emptyState())

  const loadFleetTelemetry = async () => {
    state.value = {
      ...state.value,
      loading: true,
      error: null,
      warnings: [],
    }

    const [executionResult, toolQualityResult, telemetrySummaryResult] = await Promise.allSettled([
      fetchDashboardExecution(),
      fetchToolQuality({ n: 5000 }),
      fetchTelemetrySummary(),
    ])

    const warnings: string[] = []

    const keepers =
      executionResult.status === 'fulfilled'
        ? normalizeKeepers(executionResult.value.keepers)
        : []
    if (executionResult.status === 'rejected') {
      warnings.push(`Execution snapshot unavailable: ${errorMessage(executionResult.reason)}`)
    }

    const toolQuality =
      toolQualityResult.status === 'fulfilled'
        ? toolQualityResult.value
        : EMPTY_TOOL_QUALITY
    if (toolQualityResult.status === 'rejected') {
      warnings.push(`Tool quality unavailable: ${errorMessage(toolQualityResult.reason)}`)
    }

    const telemetrySummary =
      telemetrySummaryResult.status === 'fulfilled'
        ? telemetrySummaryResult.value
        : { generated_at: '', sources: [], total_entries: 0 }
    if (telemetrySummaryResult.status === 'rejected') {
      warnings.push(`Telemetry store summary unavailable: ${errorMessage(telemetrySummaryResult.reason)}`)
    }

    const rows = buildFleetRows(keepers, toolQuality)
    const updatedAt =
      (executionResult.status === 'fulfilled' ? executionResult.value.generated_at : null)
      || telemetrySummary.generated_at
      || new Date().toISOString()

    const hasAnyData =
      rows.length > 0
      || toolQuality.total > 0
      || telemetrySummary.total_entries > 0

    state.value = {
      loading: false,
      error: hasAnyData ? null : 'No fleet telemetry data available.',
      warnings,
      rows,
      tool_quality: toolQuality,
      telemetry_sources: telemetrySummary.sources,
      total_telemetry_entries: telemetrySummary.total_entries,
      updated_at: updatedAt,
    }
  }

  useEffect(() => {
    void loadFleetTelemetry()
  }, [])

  const value = state.value
  const counts = summaryCounts(value.rows)
  const liveTone: 'neutral' | 'ok' | 'warn' =
    value.rows.length === 0
      ? 'neutral'
      : counts.live === value.rows.length
        ? 'ok'
        : 'warn'
  const sourcesWithData = value.telemetry_sources.filter(source => source.entry_count > 0).length

  if (value.loading && value.rows.length === 0) {
    return html`<div class="p-4 text-[11px] text-[var(--text-dim)]">Loading fleet telemetry...</div>`
  }

  if (value.error) {
    return html`<div class="p-4 text-[11px] text-red-400">${value.error}</div>`
  }

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-medium">Fleet Telemetry</h2>
          <div class="text-[10px] text-[var(--text-dim)]">
            ${value.updated_at ? `Updated ${formatTimeAgo(value.updated_at)}` : 'Runtime + telemetry store view'}
          </div>
        </div>
        <button
          class="rounded bg-[var(--bg-subtle)] px-2 py-0.5 text-[10px] text-[var(--text-dim)] hover:text-[var(--text)]"
          onClick=${() => { void loadFleetTelemetry() }}
          aria-label="Refresh fleet telemetry"
        >Refresh</button>
      </div>

      <${WarningBanner} warnings=${value.warnings} />

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
        <${SummaryCard}
          title="Fleet Coverage"
          value=${`${counts.live}/${value.rows.length || 0}`}
          detail=${`${counts.toolCovered}/${value.rows.length || 0} keepers emitted recent tool telemetry.`}
          tone=${liveTone}
        />
        <${SummaryCard}
          title="Runtime Pressure"
          value=${`${counts.hot} hot / ${counts.warn} warn`}
          detail=${counts.stale > 0 ? `${counts.stale} keepers are stale beyond ${Math.round(STALE_ACTIVITY_SEC / 60)}m.` : 'No stale keepers crossed the activity threshold.'}
          tone=${toneForPressure(counts.hot, counts.warn)}
        />
        <${SummaryCard}
          title="Tool Success"
          value=${value.tool_quality.total > 0 ? formatPercent(value.tool_quality.success_rate, 1) : 'n/a'}
          detail=${value.tool_quality.total > 0
            ? `${value.tool_quality.failure.toLocaleString()} failures across ${value.tool_quality.total.toLocaleString()} recent calls.`
            : 'No recent tool quality samples were recorded.'}
          tone=${value.tool_quality.total > 0 ? toneForToolSuccess(value.tool_quality.success_rate) : 'neutral'}
        />
        <${SummaryCard}
          title="Telemetry Stores"
          value=${value.total_telemetry_entries.toLocaleString()}
          detail=${`${sourcesWithData}/${value.telemetry_sources.length || 0} stores currently have data.`}
          tone=${sourcesWithData > 0 ? 'ok' : 'warn'}
        />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Pressure Watchlist</div>
        <${PressureWatchlist} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Keeper Comparison</div>
        <${FleetComparisonTable} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Telemetry Sources</div>
        <${TelemetrySourcesPanel} sources=${value.telemetry_sources} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Failure Categories</div>
        <${FailureCategoryPanel} toolQuality=${value.tool_quality} />
      </div>
    </div>
  `
}
