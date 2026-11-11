// MASC Dashboard — Execution trust / tool quality / perf / memory projections.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, currentDashboardActor, type AbortableRequestOptions } from './core'
import type { TelemetryFreshnessMetadata } from './dashboard-shared'
import type { BoardSortMode, DashboardExecutionResponse, DashboardMemoryResponse } from '../types'

type DashboardExecutionRequestOptions = AbortableRequestOptions & {
  force?: boolean
}

export function fetchDashboardExecution(opts?: DashboardExecutionRequestOptions): Promise<DashboardExecutionResponse> {
  const query = opts?.force ? '?force=1' : ''
  return get(`/api/v1/dashboard/execution${query}`, { signal: opts?.signal })
}

export type DashboardExecutionTrustKeeper = Record<string, unknown> & {
  name?: string
  agent_name?: string | null
  keeper_id?: string | null
  phase?: string | null
  pipeline_stage?: string | null
  status?: string | null
  trace_id?: string | null
  trust?: unknown
}

export type DashboardExecutionTrustResponse = TelemetryFreshnessMetadata & {
  generated_at?: string
  total: number
  keepers: DashboardExecutionTrustKeeper[]
}

export function fetchDashboardExecutionTrust(opts?: AbortableRequestOptions): Promise<DashboardExecutionTrustResponse> {
  return get<DashboardExecutionTrustResponse>('/api/v1/dashboard/execution-trust', { signal: opts?.signal })
}

type ToolQualityToolStat = {
  name: string
  calls: number
  success_pct: number
  avg_ms: number
  output_truncated_count?: number
  avg_output_chars?: number
}

type ToolQualityKeeperStat = {
  name: string
  calls: number
  success_pct: number
}

type ToolQualityFailureCategory = {
  category: string
  count: number
}

export type ToolQualityHourlyPoint = {
  hour: string
  calls: number
  success: number
  success_rate: number
  /** Bytes of the results the hour's calls returned (the ledger rows' `result_bytes`). */
  result_bytes: number
}

export type ToolQualityResponse = TelemetryFreshnessMetadata & {
  generated_at?: string
  sampling_mode?: 'recent_n' | 'window_hours' | string
  sample_limit?: number | null
  window_hours?: number | null
  total: number
  success: number
  failure: number
  deferred?: number
  unsettled?: number
  malformed?: number
  success_rate: number
  by_tool: ToolQualityToolStat[]
  by_keeper: ToolQualityKeeperStat[]
  by_runtime?: ToolQualityKeeperStat[]
  failure_categories: ToolQualityFailureCategory[]
  hourly_trend?: ToolQualityHourlyPoint[]
}

export function fetchToolQuality(opts?: { n?: number; windowHours?: number; signal?: AbortSignal }): Promise<ToolQualityResponse> {
  const params = new URLSearchParams()
  if (opts?.n != null) params.set('n', String(opts.n))
  if (opts?.windowHours != null) params.set('window_hours', String(opts.windowHours))
  const qs = params.toString()
  return get<ToolQualityResponse>(`/api/v1/dashboard/tool-quality${qs ? `?${qs}` : ''}`, { signal: opts?.signal })
}

interface FetchDashboardMemoryOptions {
  excludeSystem?: boolean
  excludeAutomation?: boolean
  author?: string
  hearth?: string
  /** Page size. Defaults to 200 when any filter is active, else 100. */
  limit?: number
  /** Number of posts to skip from the start of the sorted list. Defaults to 0. */
  offset?: number
}

export function fetchDashboardMemory(
  sortMode: BoardSortMode,
  opts?: FetchDashboardMemoryOptions,
): Promise<DashboardMemoryResponse> {
  const params = new URLSearchParams()
  params.set('sort_by', sortMode)
  const hasFilter = opts?.excludeSystem || opts?.excludeAutomation || opts?.author || opts?.hearth
  const defaultLimit = hasFilter ? 200 : 100
  const limit = Math.max(1, Math.min(500, opts?.limit ?? defaultLimit))
  const offset = Math.max(0, Math.min(5000, opts?.offset ?? 0))
  params.set('limit', String(limit))
  if (offset > 0) params.set('offset', String(offset))
  params.set('voter', currentDashboardActor())
  if (opts?.excludeSystem) params.set('exclude_system', 'true')
  if (opts?.excludeAutomation) params.set('exclude_automation', 'true')
  if (opts?.author) params.set('author', opts.author)
  if (opts?.hearth) params.set('hearth', opts.hearth)
  return get(`/api/v1/dashboard/board${params.toString() ? `?${params}` : ''}`)
}
