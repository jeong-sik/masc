import type { TelemetrySourceSummary, ToolQualityResponse } from '../api/dashboard'
import { telemetrySourceLabel } from '../config/telemetry-sources'
import type { Keeper } from '../types'
import { formatElapsedCompact } from '../lib/format-time'

export const PRESSURE_HOT_RATIO = 0.75
export const PRESSURE_WARN_RATIO = 0.5
export const STALE_ACTIVITY_SEC = 900
const TELEMETRY_ACTIVITY_FRESH_SEC = 300
const TELEMETRY_SOURCE_STALE_SEC = 900
const OAS_EVENT_LAG_WARN_SEC = 600

export interface FleetRow {
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
  tool_activity_known: boolean
  recent_tools: string[]
  runtime_blocker_class: Keeper['runtime_blocker_class'] | null
  runtime_blocker_summary: string | null
  tool_audit_at: string | null
  budget_source: 'override' | 'override_invalid' | 'env' | null
}

export interface FleetTelemetryState {
  loading: boolean
  error: string | null
  warnings: string[]
  rows: FleetRow[]
  tool_quality: ToolQualityResponse
  telemetry_sources: TelemetrySourceSummary[]
  total_telemetry_entries: number
  updated_at: string | null
}

export const EMPTY_TOOL_QUALITY: ToolQualityResponse = {
  total: 0,
  success: 0,
  failure: 0,
  success_rate: 0,
  by_tool: [],
  by_keeper: [],
  failure_categories: [],
  hourly_trend: [],
}

export function emptyState(): FleetTelemetryState {
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

// Delegated to config/telemetry-sources (SSOT)
export const sourceLabel = telemetrySourceLabel

export function errorMessage(reason: unknown): string {
  return reason instanceof Error ? reason.message : 'unknown error'
}

export function normalizeText(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

const MODEL_PLACEHOLDERS = new Set(['unknown', 'none', '-', 'n/a'])

export function isPlaceholderModel(value: string): boolean {
  return MODEL_PLACEHOLDERS.has(value.toLowerCase())
}

export function normalizeModelText(value: string | null | undefined): string | null {
  const text = normalizeText(value)
  return text == null || isPlaceholderModel(text) ? null : text
}

export function firstNonEmptyString(...values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    const normalized = normalizeText(value)
    if (normalized) return normalized
  }
  return null
}

export function uniqueStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const items: string[] = []
  for (const value of values) {
    const trimmed = normalizeText(value)
    if (!trimmed || seen.has(trimmed)) continue
    seen.add(trimmed)
    items.push(trimmed)
  }
  return items
}

function keeperLatestMetricModel(keeper: Keeper): string | null {
  const series = keeper.metrics_series ?? []
  for (let index = series.length - 1; index >= 0; index -= 1) {
    const model = normalizeModelText(series[index]?.model_used)
    if (model) return model
  }
  return null
}

function keeperMetricsWindowModel(keeper: Keeper): string | null {
  const primary = keeper.metrics_window?.primary_model
  return typeof primary === 'string' ? normalizeModelText(primary) : null
}

function keeperModel(keeper: Keeper): string {
  return firstNonEmptyString(
    keeper.last_model_used,
    keeperLatestMetricModel(keeper),
    keeperMetricsWindowModel(keeper),
    keeper.active_model,
    keeper.model,
    keeper.primary_model,
  ) ?? 'unknown'
}

function keeperLastLatencyMs(keeper: Keeper): number {
  if (typeof keeper.last_latency_ms === 'number' && Number.isFinite(keeper.last_latency_ms)) {
    return keeper.last_latency_ms
  }
  const lastMetric = keeper.metrics_series?.[keeper.metrics_series.length - 1]
  return lastMetric?.latency_ms ?? 0
}

export function successClass(rate: number | null): string {
  if (rate == null || !Number.isFinite(rate)) return 'text-[var(--text-dim)]'
  if (rate >= 97) return 'text-[var(--ok)]'
  if (rate >= 90) return 'text-[var(--warn)]'
  return 'text-[var(--bad-light)]'
}

function keeperMetricsWindowTools(keeper: Keeper): string[] {
  const topTools = keeper.metrics_window?.top_tools ?? []
  return uniqueStrings(topTools.map(item =>
    firstNonEmptyString(
      typeof item.tool === 'string' ? item.tool : null,
      typeof item.kind === 'string' ? item.kind : null,
    )))
}

function keeperRecentTools(keeper: Keeper): string[] {
  return uniqueStrings([
    ...(keeper.recent_tool_names ?? []),
    ...(keeper.latest_tool_names ?? []),
    ...keeperMetricsWindowTools(keeper),
  ]).slice(0, 3)
}

function keeperToolCallCount(keeper: Keeper, toolQualityCalls?: number): number {
  if (typeof toolQualityCalls === 'number' && Number.isFinite(toolQualityCalls) && toolQualityCalls >= 0) {
    return toolQualityCalls
  }

  const counts = [
    keeper.latest_tool_call_count,
    keeper.metrics_window?.tool_call_count,
  ].filter((value): value is number =>
    typeof value === 'number' && Number.isFinite(value) && value >= 0)
  return counts.length > 0 ? Math.max(...counts) : 0
}

function hasMeaningfulToolAuditSource(keeper: Keeper): boolean {
  const source = normalizeText(keeper.tool_audit_source)
  return source === 'heartbeat_task'
    || source === 'heartbeat_result'
    || source === 'keeper_decision_log'
    || source === 'keeper_metrics'
}

function keeperHasToolTelemetry(keeper: Keeper, toolCalls: number, recentTools: string[]): boolean {
  return toolCalls > 0
    || recentTools.length > 0
    || hasMeaningfulToolAuditSource(keeper)
    || normalizeText(keeper.tool_audit_at) != null
    || keeper.latest_tool_call_count != null
    || (typeof keeper.metrics_window?.tool_call_count === 'number' && Number.isFinite(keeper.metrics_window.tool_call_count))
}

export function buildToolQualityMap(toolQuality: ToolQualityResponse): Map<string, { calls: number; success_pct: number }> {
  const byKeeper = new Map<string, { calls: number; success_pct: number }>()
  for (const keeper of toolQuality.by_keeper) {
    byKeeper.set(keeper.name, {
      calls: keeper.calls,
      success_pct: keeper.success_pct,
    })
  }
  return byKeeper
}

type FleetBand = 'attention' | 'active' | 'paused' | 'offline'

export function fleetBand(row: FleetRow): FleetBand {
  const normalizedStatus = normalizeText(row.status)?.toLowerCase() ?? 'unknown'
  if (
    !row.keepalive_running
    || normalizedStatus === 'offline'
    || normalizedStatus === 'inactive'
    || normalizedStatus === 'unbooted'
    || normalizedStatus === 'stopped'
    || normalizedStatus === 'dead'
    || normalizedStatus === 'crashed'
  ) {
    return 'offline'
  }
  if (normalizedStatus === 'paused') return 'paused'
  if (
    row.runtime_blocker_class != null
    || row.context_ratio >= PRESSURE_WARN_RATIO
    || (row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC)
    || (row.tool_success_pct != null && row.tool_success_pct < 90)
  ) {
    return 'attention'
  }
  return 'active'
}

export function fleetBandScore(row: FleetRow): number {
  const band = fleetBand(row)
  if (band === 'attention') return 3
  if (band === 'active') return 2
  if (band === 'paused') return 1
  return 0
}

export function rowUrgencyScore(row: FleetRow): number {
  let score = 0
  if (row.runtime_blocker_class != null) score += 100
  if (row.context_ratio >= PRESSURE_WARN_RATIO) score += row.context_ratio * 100
  if (row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC) {
    score += Math.min(row.last_activity_ago_s / STALE_ACTIVITY_SEC, 5)
  }
  if (typeof row.tool_success_pct === 'number' && row.tool_success_pct < 90) {
    score += (100 - row.tool_success_pct) / 5
  }
  return score
}

function hasKnownActivity(row: FleetRow): boolean {
  return row.last_activity_ago_s != null
    && Number.isFinite(row.last_activity_ago_s)
    && row.last_activity_ago_s >= 0
}

function activityAge(row: FleetRow): number {
  return hasKnownActivity(row) ? row.last_activity_ago_s ?? Number.POSITIVE_INFINITY : Number.POSITIVE_INFINITY
}

export function compareFleetRows(a: FleetRow, b: FleetRow): number {
  const aBand = fleetBandScore(a)
  const bBand = fleetBandScore(b)
  if (aBand !== bBand) return bBand - aBand

  const aUrgency = rowUrgencyScore(a)
  const bUrgency = rowUrgencyScore(b)
  if (aUrgency !== bUrgency) return bUrgency - aUrgency

  const aKnownActivity = hasKnownActivity(a) ? 1 : 0
  const bKnownActivity = hasKnownActivity(b) ? 1 : 0
  if (aKnownActivity !== bKnownActivity) return bKnownActivity - aKnownActivity

  const aAge = activityAge(a)
  const bAge = activityAge(b)
  if (aAge !== bAge) return aAge - bAge
  if (a.tool_calls !== b.tool_calls) return b.tool_calls - a.tool_calls
  if (a.context_ratio !== b.context_ratio) return b.context_ratio - a.context_ratio
  if (a.turn_count !== b.turn_count) return b.turn_count - a.turn_count
  return a.name.localeCompare(b.name)
}

export function buildFleetRows(keepers: Keeper[], toolQuality: ToolQualityResponse): FleetRow[] {
  const toolStats = buildToolQualityMap(toolQuality)
  const rows =
    keepers.length > 0
      ? keepers.map((keeper): FleetRow => {
          const toolQualityForKeeper = toolStats.get(keeper.name)
          const recentTools = keeperRecentTools(keeper)
          const toolCalls = keeperToolCallCount(keeper, toolQualityForKeeper?.calls)
          return {
            name: keeper.name,
            status: keeper.status ?? (keeper.keepalive_running ? 'active' : 'offline'),
            keepalive_running: keeper.keepalive_running === true,
            context_ratio: keeper.context_ratio ?? 0,
            turn_count: keeper.total_turns ?? keeper.turn_count ?? 0,
            last_latency_ms: keeperLastLatencyMs(keeper),
            last_activity_ago_s: keeper.last_activity_ago_s ?? null,
            model: keeperModel(keeper),
            tool_calls: toolCalls,
            tool_success_pct: toolQualityForKeeper?.success_pct ?? null,
            tool_activity_known: keeperHasToolTelemetry(keeper, toolCalls, recentTools),
            recent_tools: recentTools,
            runtime_blocker_class: keeper.runtime_blocker_class ?? null,
            runtime_blocker_summary:
              firstNonEmptyString(keeper.runtime_blocker_summary, keeper.last_blocker) ?? null,
            tool_audit_at: keeper.tool_audit_at ?? null,
            budget_source:
              keeper.turn_budget?.reactive.source === 'override' ||
              keeper.turn_budget?.reactive.source === 'override_invalid' ||
              keeper.turn_budget?.scheduled_autonomous.source === 'override' ||
              keeper.turn_budget?.scheduled_autonomous.source === 'override_invalid'
                ? (keeper.turn_budget?.reactive.source === 'override_invalid' ||
                   keeper.turn_budget?.scheduled_autonomous.source === 'override_invalid'
                    ? 'override_invalid'
                    : 'override')
                : 'env',
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
          tool_activity_known: keeper.calls > 0,
          recent_tools: [],
          runtime_blocker_class: null,
          runtime_blocker_summary: null,
          tool_audit_at: null,
          budget_source: null,
        }))

  return [...rows].sort(compareFleetRows)
}

export function toneForToolSuccess(rate: number): 'neutral' | 'ok' | 'warn' {
  if (rate >= 97) return 'ok'
  if (rate >= 90) return 'neutral'
  return 'warn'
}

export function toneForPressure(hot: number, warn: number): 'neutral' | 'ok' | 'warn' {
  if (hot > 0) return 'warn'
  if (warn > 0) return 'neutral'
  return 'ok'
}

export function pressureClass(ratio: number): string {
  if (ratio >= PRESSURE_HOT_RATIO) return 'text-[var(--bad-light)]'
  if (ratio >= PRESSURE_WARN_RATIO) return 'text-[var(--warn)]'
  return 'text-[var(--ok)]'
}

export function statusClass(row: FleetRow): string {
  if (!row.keepalive_running || row.status === 'offline' || row.status === 'stopped') return 'text-[var(--bad-light)]'
  if (row.runtime_blocker_class != null) return 'text-[var(--warn)]'
  if (row.context_ratio >= PRESSURE_HOT_RATIO) return 'text-[var(--warn)]'
  return 'text-[var(--ok)]'
}

export function formatPercent(value: number | null, digits = 0): string {
  if (value == null || !Number.isFinite(value)) return '-'
  return `${value.toFixed(digits)}%`
}

export function formatLatency(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '-'
  if (ms < 1000) return `${Math.round(ms)}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

export function formatActivity(seconds: number | null): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return '-'
  return formatElapsedCompact(seconds)
}

export function numericAge(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
}

function formatSourceAge(seconds: number | null | undefined): string | null {
  const age = numericAge(seconds)
  return age == null ? null : formatElapsedCompact(age)
}

export function sourceCountClass(source: TelemetrySourceSummary): string {
  if (source.exists === false) return 'text-[var(--bad-light)]'
  if (source.entry_count <= 0) return 'text-[var(--text-dim)]'
  const age = numericAge(source.latest_age_s)
  if (age != null && age >= TELEMETRY_SOURCE_STALE_SEC) return 'text-[var(--warn)]'
  return 'text-[var(--ok)]'
}

export function sourceDetail(source: TelemetrySourceSummary): string {
  const parts: string[] = []
  if (source.keeper_count != null) {
    parts.push(`${source.keeper_count} keepers tracked`)
  } else if (source.exists === false) {
    parts.push('store missing')
  } else {
    parts.push('store available')
  }

  if (source.entry_count > 0) {
    const age = formatSourceAge(source.latest_age_s)
    parts.push(age ? `last ${age} ago` : 'latest ts unavailable')
  }

  return parts.join(' · ')
}

export function buildTelemetryWarnings(sources: TelemetrySourceSummary[]): string[] {
  const warnings: string[] = []
  const bySource = new Map(sources.map(source => [source.source, source]))
  const oasEvent = bySource.get('oas_event')
  if (!oasEvent) return warnings

  if (oasEvent.exists === false) {
    warnings.push('OAS event relay store is missing.')
    return warnings
  }

  if (oasEvent.entry_count <= 0) return warnings

  const oasAge = numericAge(oasEvent.latest_age_s)
  const agentEvent = bySource.get('agent_event')
  const agentAge = numericAge(agentEvent?.latest_age_s)
  const oasTs = numericAge(oasEvent.latest_ts_unix)
  const agentTs = numericAge(agentEvent?.latest_ts_unix)

  if (agentTs != null && oasTs != null) {
    const lag = agentTs - oasTs
    if (lag >= OAS_EVENT_LAG_WARN_SEC) {
      warnings.push(`OAS event relay trails agent events by ${formatElapsedCompact(lag)}.`)
      return warnings
    }
  }

  if (oasAge != null && oasAge >= TELEMETRY_SOURCE_STALE_SEC) {
    if (agentAge == null || agentAge <= TELEMETRY_ACTIVITY_FRESH_SEC) {
      warnings.push(`OAS event relay stale: last durable event ${formatElapsedCompact(oasAge)} ago.`)
    }
  }

  return warnings
}

export function buildRuntimeWarnings(rows: FleetRow[]): string[] {
  const warnings: string[] = []
  const admissionBlocked = rows.filter(row => row.runtime_blocker_class === 'admission_queue_wait_timeout')
  if (admissionBlocked.length > 0) {
    warnings.push(
      `${admissionBlocked.length} keepers are blocked in the admission queue; tool telemetry can look stale because turns never reached tool execution.`,
    )
  }

  const slotBlocked = rows.filter(row => row.runtime_blocker_class === 'autonomous_slot_wait_timeout')
  if (slotBlocked.length > 0) {
    warnings.push(
      `${slotBlocked.length} keepers skipped their autonomous cycle while waiting for a local keeper slot.`,
    )
  }

  const otherBlocked = rows.filter(row =>
    row.runtime_blocker_class != null
    && row.runtime_blocker_class !== 'admission_queue_wait_timeout'
    && row.runtime_blocker_class !== 'autonomous_slot_wait_timeout',
  )
  if (otherBlocked.length > 0) {
    warnings.push(
      `${otherBlocked.length} keepers have other runtime blockers; inspect the row-level blocker hints for details.`,
    )
  }

  return warnings
}

export function toolSummary(row: FleetRow): { label: string; title: string } {
  if (row.recent_tools.length > 0) {
    const text = row.recent_tools.join(', ')
    return { label: text, title: text }
  }
  if (row.tool_calls > 0) {
    const label = `${row.tool_calls.toLocaleString()} tool calls`
    return {
      label,
      title: `${label}; names unavailable`,
    }
  }
  if (row.tool_activity_known) {
    return {
      label: 'No recent tools recorded',
      title: 'No recent tools recorded',
    }
  }
  return {
    label: 'Tool telemetry unavailable',
    title: 'Tool telemetry unavailable',
  }
}

export function summaryCounts(rows: FleetRow[]) {
  const live = rows.filter(row => row.keepalive_running).length
  const toolCovered = rows.filter(row => row.tool_calls > 0 || row.recent_tools.length > 0).length
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
