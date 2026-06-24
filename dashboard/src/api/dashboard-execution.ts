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
}

export type ToolQualityResponse = TelemetryFreshnessMetadata & {
  generated_at?: string
  sampling_mode?: 'recent_n' | 'window_hours' | string
  sample_limit?: number | null
  window_hours?: number | null
  total: number
  success: number
  failure: number
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

export interface DashboardPerfRow {
  benchmark: string
  avg_ms: number
  p50_ms: number
  p95_ms: number
  max_ms: number
  notes: string
  note_tags?: Record<string, string>
}

export interface DashboardPerfComparisonRow {
  benchmark: string
  avg_delta_ms: number
  avg_delta_pct?: number | null
  p95_delta_ms: number
  p95_delta_pct?: number | null
  max_delta_ms: number
  verdict: 'improved' | 'stable' | 'mixed' | 'regressed' | string
}

export interface DashboardPerfResponse {
  generated_at?: string
  status: 'ok' | 'empty' | string
  message?: string
  candidate_dirs?: string[]
  source?: {
    results_dir: string
    result_file: string
    meta_file?: string | null
    baseline_file?: string | null
  }
  latest_run?: {
    timestamp?: string | null
    started_at?: string | null
    pattern?: string | null
    iterations?: number | null
    warmup_iterations?: number | null
    session_warmup_iterations?: number | null
    benchmark_count?: number
  }
  highlights?: {
    session_init?: DashboardPerfRow | null
    worst_live_mcp?: DashboardPerfRow | null
    runtime_status?: DashboardPerfRow | null
    runtime_single?: DashboardPerfRow | null
  }
  benchmarks: DashboardPerfRow[]
  comparison?: {
    baseline_file?: string | null
    verdict_counts?: {
      improved?: number
      stable?: number
      mixed?: number
      regressed?: number
    }
    top_changes?: DashboardPerfComparisonRow[]
  } | null
}

export function fetchDashboardPerf(): Promise<DashboardPerfResponse> {
  return get('/api/v1/dashboard/perf')
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
  params.set('blind_votes', 'true')
  if (opts?.excludeSystem) params.set('exclude_system', 'true')
  if (opts?.excludeAutomation) params.set('exclude_automation', 'true')
  if (opts?.author) params.set('author', opts.author)
  if (opts?.hearth) params.set('hearth', opts.hearth)
  return get(`/api/v1/dashboard/board${params.toString() ? `?${params}` : ''}`)
}
