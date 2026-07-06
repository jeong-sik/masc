// MASC Dashboard — Keeper cost metrics / decisions / cost-latency fetchers.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, type AbortableRequestOptions } from './core'
import { isRecord, asInt, asNumber, asNullableString, asString, asStringArray, asRecordArray } from '../components/common/normalize'
import { DEFAULT_WINDOW_MINUTES_24H } from '../config/constants'
import { decodeDashboardFeedMetadata, type DashboardFeedMetadata } from './dashboard-shared'

const REDACTED_RUNTIME_LABEL = 'runtime'
const UNKNOWN_MODEL_LABEL = 'unknown_model'
const UNKNOWN_PROVIDER_LABEL = 'unknown_provider'
const MODEL_PLACEHOLDERS = new Set(['unknown', 'none', '-', 'n/a', 'null', 'undefined', 'default', 'auto'])

function normalizedModelEvidence(value: string | null | undefined): string | null {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!text || MODEL_PLACEHOLDERS.has(text.toLowerCase())) return null
  return text
}

function publicRuntimeModelLabel(value: string | null | undefined): string {
  const model = normalizedModelEvidence(value)
  if (model == null) return UNKNOWN_MODEL_LABEL
  if (model === REDACTED_RUNTIME_LABEL || model.startsWith('runtime_lane_')) return model
  return REDACTED_RUNTIME_LABEL
}

function costMatrixModelLabel(value: string | undefined, index: number): string {
  const label = publicRuntimeModelLabel(value)
  return label === UNKNOWN_MODEL_LABEL ? `${UNKNOWN_MODEL_LABEL}_${index + 1}` : label
}

export interface KeeperCostMetric {
  keeper_name: string
  total_cost_usd: number
  total_input_tokens: number
  total_output_tokens: number
  total_tokens: number
  p50_latency_ms: number | null
  p95_latency_ms: number | null
  sample_count: number
  model_breakdown: Array<{ model: string; cost_usd: number }>
}

export interface KeeperCostMetricsResponse {
  window_minutes?: number
  keepers: KeeperCostMetric[]
  generated_at?: number | null
}

function decodeKeeperCostMetric(raw: unknown): KeeperCostMetric | null {
  if (!isRecord(raw)) return null
  const keeperName = asString(raw.keeper_name)
  if (!keeperName) return null
  const modelCosts = new Map<string, number>()
  if (Array.isArray(raw.model_breakdown)) {
    for (const item of raw.model_breakdown) {
      if (!isRecord(item)) continue
      const cost = asNumber(item.cost_usd) ?? 0
      if (!Number.isFinite(cost) || cost <= 0) continue
      const model = publicRuntimeModelLabel(asString(item.model))
      modelCosts.set(model, (modelCosts.get(model) ?? 0) + cost)
    }
  }
  return {
    keeper_name: keeperName,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? 0,
    total_input_tokens: asNumber(raw.total_input_tokens) ?? 0,
    total_output_tokens: asNumber(raw.total_output_tokens) ?? 0,
    total_tokens: asNumber(raw.total_tokens) ?? 0,
    p50_latency_ms: asNumber(raw.p50_latency_ms) ?? null,
    p95_latency_ms: asNumber(raw.p95_latency_ms) ?? null,
    sample_count: asNumber(raw.sample_count) ?? 0,
    model_breakdown: Array.from(modelCosts.entries()).map(([model, cost_usd]) => ({ model, cost_usd })),
  }
}

function decodeKeeperCostMetricsResponse(raw: unknown): KeeperCostMetricsResponse | null {
  if (!isRecord(raw)) return null
  return {
    window_minutes: asNumber(raw.window_minutes),
    keepers: asRecordArray(raw.keepers)
      .map(decodeKeeperCostMetric)
      .filter((metric): metric is KeeperCostMetric => metric !== null),
    generated_at: asNumber(raw.generated_at) ?? null,
  }
}

export async function fetchKeeperCostMetrics(
  windowMinutes = DEFAULT_WINDOW_MINUTES_24H,
  opts?: AbortableRequestOptions,
): Promise<KeeperCostMetricsResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/keeper-costs?window=${windowMinutes}`, { signal: opts?.signal })
  const decoded = decodeKeeperCostMetricsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 keeper cost metrics payload')
  return decoded
}

export interface KeeperDecision {
  ts_unix: number | null
  keeper_name: string
  event_type: string
  outcome: string | null
  choice: string | null
  reason: string | null
  context: KeeperDecisionContext | null
  model_used: string | null
  latency_ms: number | null
  cost_usd: number | null
  input_tokens: number | null
  output_tokens: number | null
  stop_reason: string | null
  error_category: string | null
  tool: string | null
  duration_ms: number | null
  match_count: number | null
  // Closed-sum terminal cause of the turn (completed / api_error /
  // runtime_exhausted / tool_contract / required_tool_use_unsatisfied),
  // computed by dashboard_http_keeper_feeds.ml; the table can only show the
  // coarse `outcome` without it.
  terminal_reason_code: string | null
}

export interface KeeperDecisionContext {
  file_path?: string | null
  line?: number | null
  goal_id?: string
  task_id?: string
  board_post_id?: string
  comment_id?: string
  pr_id?: string
  git_ref?: string
  log_id?: string
  session_id?: string
  operation_id?: string
  worker_run_id?: string
}

export interface KeeperDecisionsResponse extends DashboardFeedMetadata {
  events: KeeperDecision[]
  limit: number
  generated_at: number | null
}

function decodeKeeperDecisionContext(raw: unknown): KeeperDecisionContext | null {
  if (!isRecord(raw)) return null
  const context: KeeperDecisionContext = {}
  const filePath = asNullableString(raw.file_path)
  if (filePath !== null) context.file_path = filePath
  const line = asNumber(raw.line)
  if (line !== undefined) context.line = line
  const stringFields = [
    ['goal_id', 'goal_id'],
    ['task_id', 'task_id'],
    ['board_post_id', 'board_post_id'],
    ['comment_id', 'comment_id'],
    ['pr_id', 'pr_id'],
    ['git_ref', 'git_ref'],
    ['log_id', 'log_id'],
    ['session_id', 'session_id'],
    ['operation_id', 'operation_id'],
    ['worker_run_id', 'worker_run_id'],
  ] as const
  for (const [sourceKey, targetKey] of stringFields) {
    const value = asString(raw[sourceKey])
    if (value !== undefined) context[targetKey] = value
  }
  return Object.keys(context).length > 0 ? context : null
}

function decodeKeeperDecision(raw: unknown): KeeperDecision | null {
  if (!isRecord(raw)) return null
  return {
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_name: asString(raw.keeper_name) ?? '',
    event_type: asString(raw.event_type) ?? '(unknown event_type)',
    outcome: asNullableString(raw.outcome),
    choice: asNullableString(raw.choice),
    reason: asNullableString(raw.reason),
    context: decodeKeeperDecisionContext(raw.context),
    model_used: null,
    latency_ms: asNumber(raw.latency_ms) ?? null,
    cost_usd: asNumber(raw.cost_usd) ?? null,
    input_tokens: asNumber(raw.input_tokens) ?? null,
    output_tokens: asNumber(raw.output_tokens) ?? null,
    stop_reason: asNullableString(raw.stop_reason),
    error_category: asNullableString(raw.error_category),
    tool: asNullableString(raw.tool),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    match_count: asNumber(raw.match_count) ?? null,
    terminal_reason_code: asNullableString(raw.terminal_reason_code),
  }
}

function decodeKeeperDecisionsResponse(raw: unknown): KeeperDecisionsResponse | null {
  if (!isRecord(raw)) return null
  return {
    ...decodeDashboardFeedMetadata(raw),
    events: asRecordArray(raw.events)
      .map(decodeKeeperDecision)
      .filter((d): d is KeeperDecision => d !== null),
    limit: asInt(raw.limit) ?? 0,
    generated_at: asNumber(raw.generated_at) ?? null,
  }
}

export async function fetchKeeperDecisions(
  limit = 200,
  opts?: AbortableRequestOptions,
): Promise<KeeperDecisionsResponse> {
  const raw = await get<Record<string, unknown>>(`/api/v1/dashboard/keeper-decisions?limit=${limit}`, { signal: opts?.signal })
  const decoded = decodeKeeperDecisionsResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 keeper decisions payload')
  return decoded
}

// --- Cost-per-agent / cost-matrix / cost-latency ---
// payload required by the CostPerAgent / CostMatrix / CostLatency
// frontend components (Phase 2 spec cb-group-f.jsx:291-429).

export interface CostPerAgentRow {
  agent: string
  in_tok: number
  out_tok: number
  cost: number
  p50_ms: number | null
  p95_ms: number | null
}

export interface CostMatrix {
  providers: string[]
  models: string[]
  grid: number[][]
}

export interface CostLatencyBucket {
  lo: number
  hi: number | null
  n: number
}

export interface CostLatencyResponse {
  perAgent: CostPerAgentRow[]
  matrix: CostMatrix
  latencyBuckets: CostLatencyBucket[]
  p50: number | null
  p95: number | null
  total_cost_usd: number
  window_minutes: number
  generated_at: number
}

function decodeCostPerAgentRow(raw: unknown): CostPerAgentRow | null {
  if (!isRecord(raw)) return null
  const agent = asString(raw.agent)
  if (!agent) return null
  return {
    agent,
    in_tok: asNumber(raw.in_tok) ?? 0,
    out_tok: asNumber(raw.out_tok) ?? 0,
    cost: asNumber(raw.cost) ?? 0,
    p50_ms: asNumber(raw.p50_ms) ?? null,
    p95_ms: asNumber(raw.p95_ms) ?? null,
  }
}

function decodeCostMatrix(raw: unknown): CostMatrix | null {
  if (!isRecord(raw)) return null
  const rawModels = asStringArray(raw.models)
  const rawProviders = asStringArray(raw.providers)
  const rawGrid = Array.isArray(raw.grid)
    ? (raw.grid as unknown[]).map(row =>
        Array.isArray(row)
          ? (row as unknown[]).map(v => asNumber(v) ?? 0)
          : []
      )
    : []
  const colCount = Math.max(
    rawModels.length,
    rawGrid.reduce((max, row) => Math.max(max, row.length), 0),
  )
  const models = Array.from({ length: colCount }, (_, index) =>
    costMatrixModelLabel(rawModels[index], index),
  )
  const hasProviderEvidence = rawProviders.some(provider => normalizedModelEvidence(provider) != null)
  const providers = colCount > 0 || rawProviders.length > 0
    ? [hasProviderEvidence ? REDACTED_RUNTIME_LABEL : UNKNOWN_PROVIDER_LABEL]
    : []
  const grid = providers.length === 0
    ? []
    : [
        Array.from({ length: colCount }, (_, column) =>
          rawGrid.reduce((sum, row) => sum + (row[column] ?? 0), 0),
        ),
      ]
  return { providers, models, grid }
}

function decodeCostLatencyResponse(raw: unknown): CostLatencyResponse | null {
  if (!isRecord(raw)) return null
  const matrix = decodeCostMatrix(raw.matrix)
  if (!matrix) return null
  return {
    perAgent: asRecordArray(raw.perAgent)
      .map(row => decodeCostPerAgentRow(row))
      .filter((r): r is CostPerAgentRow => r !== null),
    matrix,
    latencyBuckets: Array.isArray(raw.latencyBuckets)
      ? (raw.latencyBuckets as unknown[])
          .filter(isRecord)
          .map(b => ({
            lo: asNumber(b.lo) ?? 0,
            hi: b.hi == null ? null : (asNumber(b.hi) ?? null),
            n: asNumber(b.n) ?? 0,
          }))
      : [],
    p50: asNumber(raw.p50) ?? null,
    p95: asNumber(raw.p95) ?? null,
    total_cost_usd: asNumber(raw.total_cost_usd) ?? 0,
    window_minutes: asNumber(raw.window_minutes) ?? DEFAULT_WINDOW_MINUTES_24H,
    generated_at: asNumber(raw.generated_at) ?? 0,
  }
}

export async function fetchCostLatency(
  windowMinutes = DEFAULT_WINDOW_MINUTES_24H,
  opts?: AbortableRequestOptions,
): Promise<CostLatencyResponse> {
  const raw = await get<Record<string, unknown>>(
    `/api/v1/dashboard/cost-latency?window=${windowMinutes}`,
    { signal: opts?.signal },
  )
  const decoded = decodeCostLatencyResponse(raw)
  if (!decoded) throw new Error('유효하지 않은 cost-latency payload')
  return decoded
}
