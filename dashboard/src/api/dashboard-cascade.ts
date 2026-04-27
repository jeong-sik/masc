import { get, post } from './core'

// --- Keeper Cascade Config ---

export interface CascadeInvalidProfile {
  name: string
  errors: string[]
}

export function fetchCascadeProfiles(): Promise<{
  profiles: string[]
  invalid_profiles: CascadeInvalidProfile[]
}> {
  return get<{
    profiles: string[]
    invalid_profiles: CascadeInvalidProfile[]
  }>('/api/v1/keeper/cascades')
}

export function updateKeeperCascade(keeper: string, cascade_name: string): Promise<{ ok: boolean }> {
  return post<{ ok: boolean }>('/api/v1/keeper/cascade', { keeper, cascade_name })
}

// --- Cascade config + health (observability) ---

export interface CascadeCandidate {
  model: string
  display_model?: string | null
  provider_name?: string | null
  display_provider_name?: string | null
  runtime_kind?: string | null
  expanded_models?: string[] | null
  config_weight: number
  effective_weight: number
  success_rate: number
  in_cooldown: boolean
}

export interface CascadeProfile {
  name: string
  /** [load_failed] is emitted when the cascade.toml/json file failed
   *  to load (parse / IO / unknown field).  Distinguishes a fault
   *  from operator-intended absence of a profile, so the UI can render
   *  a `bad`-tone badge instead of the `warn` chip used for the
   *  benign hardcoded_defaults path. */
  source: 'named' | 'default_fallback' | 'hardcoded_defaults' | 'load_failed'
  keeper_assignable: boolean
  candidates: CascadeCandidate[]
}

export interface CascadeKeeperProfile {
  keeper: string
  cascade_name: string
  canonical: string
}

export type CascadeValidationStatus =
  | 'validated'
  | 'serving_valid_subset'
  | 'serving_last_known_good'
  | 'invalid'

export interface CascadeConfigResponse {
  updated_at: string
  config_path: string | null
  source_kind: 'json' | 'toml'
  source_path: string
  validation_status: CascadeValidationStatus
  validation_errors: string[]
  invalid_profiles: CascadeInvalidProfile[]
  profiles: CascadeProfile[]
  keeper_profiles: CascadeKeeperProfile[]
}

export interface CascadeRawConfigResponse {
  updated_at: string
  config_path: string | null
  source_kind: 'json' | 'toml'
  source_path: string
  source_editable: boolean
  source_text: string
  raw_json_editable: boolean
  raw_json: string
  /** Surfaced when ensure_materialized_json fails (cascade.toml parse
   *  error / IO error / unknown field).  Non-null means [raw_json]
   *  may be a stale snapshot; the latest source_text edit was rejected
   *  by the strict-field validator.  Backend always emits the field
   *  (null on success) — frontend may treat undefined as null for
   *  forward compat. */
  materialization_error?: string | null
}

/** Operational state reported next to [provider_key] on the dashboard.
 *  - `active`: tracker recorded at least one event in the current window.
 *  - `cooldown`: tracker opened a cooldown window.
 *  - `configured`: declared in `cascade.json` but zero traffic in the
 *    current window (either untouched since startup or expired out).
 *  @since 0.173.0 */
export type CascadeProviderStatus = 'active' | 'cooldown' | 'configured'

export interface CascadeHealthProvider {
  provider_key: string
  success_rate: number
  consecutive_failures: number
  in_cooldown: boolean
  cooldown_expires_at: number | null
  events_in_window: number
  /** Subset of [events_in_window] with outcome "rejected" — response
   *  arrived but was rejected by the cascade's accept predicate. Split
   *  so the dashboard can tell "provider down" from "provider returns
   *  unusable output".
   *  @since 0.160.0 — optional for backward compat with older servers. */
  rejected_in_window?: number
  /** `true` iff any `cascade.json` profile lists a model whose scheme
   *  prefix matches `provider_key`. `false` surfaces providers that
   *  were tracked but are no longer referenced by config (e.g. after
   *  a cascade rename).
   *  @since 0.173.0 — optional for backward compat with older servers. */
  declared?: boolean
  /** @since 0.173.0 — optional for backward compat with older servers. */
  status?: CascadeProviderStatus
  /** Entry-weighted mean prefill throughput across all models that
   *  share this provider scheme, over the last `perf_window_minutes`
   *  of keeper decisions.jsonl. `null` when no contributing model
   *  reported inference_timings (Anthropic/Gemini path).
   *  @since 0.173.1 — optional; backend returns only when `base_path`
   *  is wired (always in production, never in test harnesses). */
  avg_prompt_tok_per_sec?: number | null
  /** @since 0.173.1 */
  avg_decode_tok_per_sec?: number | null
  /** @since 0.173.1 */
  avg_tok_per_sec?: number | null
  /** @since 0.173.1 */
  avg_latency_ms?: number | null
  /** Approximation: entry-weighted mean of per-model p50.  Not a true
   *  cross-model percentile; fine for dashboard sparklines.  When
   *  exact values are needed, compute from recent_entries in
   *  `/api/v1/runtime/model-metrics`.
   *  @since 0.173.1 */
  p50_latency_ms?: number | null
  /** @since 0.173.1 — see `p50_latency_ms`. */
  p95_latency_ms?: number | null
  /** Number of keeper turns attributed to this provider in the perf
   *  window.  `null` when the backend was unable to run the aggregate
   *  (missing `base_path`); `0` when it ran and found none.
   *  @since 0.173.1 */
  request_count?: number | null
}

export interface CascadeHealthResponse {
  updated_at: string
  window_sec: number
  cooldown_threshold: number
  cooldown_sec: number
  providers: CascadeHealthProvider[]
  /** Window used by the per-provider perf aggregate.  `null` when the
   *  backend did not compute perf (no `base_path`, matches every
   *  provider having null perf fields).
   *  @since 0.173.1 — optional for backward compat with older servers. */
  perf_window_minutes?: number | null
}

export function fetchCascadeConfig(
  opts?: { signal?: AbortSignal },
): Promise<CascadeConfigResponse> {
  return get<CascadeConfigResponse>('/api/v1/cascade/config', { signal: opts?.signal })
}

export function fetchCascadeConfigRaw(
  opts?: { signal?: AbortSignal },
): Promise<CascadeRawConfigResponse> {
  return get<CascadeRawConfigResponse>('/api/v1/cascade/config/raw', {
    signal: opts?.signal,
  })
}

export function updateCascadeConfigRaw(source_text: string): Promise<CascadeConfigResponse> {
  return post<CascadeConfigResponse>('/api/v1/cascade/config/raw', { source_text })
}

export function fetchCascadeHealth(
  opts?: { signal?: AbortSignal },
): Promise<CascadeHealthResponse> {
  return get<CascadeHealthResponse>('/api/v1/cascade/health', { signal: opts?.signal })
}

type CascadeCapacityKind = 'cli' | 'ollama' | 'other'

export interface CascadeClientCapacityEntry {
  key: string
  kind: CascadeCapacityKind
  total: number
  active: number
  available: number
}

export interface CascadeClientCapacityResponse {
  updated_at: string
  entries: CascadeClientCapacityEntry[]
}

export function fetchCascadeClientCapacity(
  opts?: { signal?: AbortSignal },
): Promise<CascadeClientCapacityResponse> {
  return get<CascadeClientCapacityResponse>('/api/v1/cascade/client_capacity', {
    signal: opts?.signal,
  })
}

export type CascadeCapacityEventKind = 'acquired' | 'released' | 'rejected_full'

export interface CascadeClientCapacityHistoryEvent {
  ts: number
  key: string
  kind: CascadeCapacityEventKind
  active_after: number
}

export interface CascadeClientCapacityHistoryResponse {
  updated_at: string
  total_events: number
  events: CascadeClientCapacityHistoryEvent[]
}

export function fetchCascadeClientCapacityHistory(opts?: {
  limit?: number
  kind?: CascadeCapacityKind
  signal?: AbortSignal
}): Promise<CascadeClientCapacityHistoryResponse> {
  const params = new URLSearchParams()
  if (typeof opts?.limit === 'number' && opts.limit > 0) {
    params.set('limit', String(opts.limit))
  }
  if (opts?.kind) params.set('kind', opts.kind)
  const qs = params.toString()
  return get<CascadeClientCapacityHistoryResponse>(
    `/api/v1/cascade/client_capacity/history${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

export type CascadeStrategyTraceKind = 'ordered' | 'filtered_empty' | 'exhausted'

export interface CascadeStrategyTraceEvent {
  ts: number
  cascade_name: string
  strategy: string
  cycle: number
  candidates_in: number
  candidates_out: number
  backoff_ms: number
  kind: CascadeStrategyTraceKind
}

export interface CascadeStrategyTraceResponse {
  updated_at: string
  total_events: number
  events: CascadeStrategyTraceEvent[]
}

export function fetchCascadeStrategyTrace(opts?: {
  limit?: number
  cascade?: string
  signal?: AbortSignal
}): Promise<CascadeStrategyTraceResponse> {
  const params = new URLSearchParams()
  if (typeof opts?.limit === 'number' && opts.limit > 0) {
    params.set('limit', String(opts.limit))
  }
  if (opts?.cascade) params.set('cascade', opts.cascade)
  const qs = params.toString()
  return get<CascadeStrategyTraceResponse>(
    `/api/v1/cascade/strategy_trace${qs ? `?${qs}` : ''}`,
    { signal: opts?.signal },
  )
}

export type CascadeSloStatus = 'ok' | 'warn' | 'violated'

interface CascadeSloTargets {
  ordered_ratio_min: number
  exhaustion_count_max: number
  burn_rate_max: number
}

interface CascadeSloCurrent {
  ordered_ratio: number
  exhaustion_count: number
  burn_rate: number
  total_events: number
}

export interface CascadeSloResponse {
  updated_at: string
  window_sample_size: number
  targets: CascadeSloTargets
  current: CascadeSloCurrent
  status: CascadeSloStatus
  violations: string[]
}

export function fetchCascadeSlo(
  opts?: { signal?: AbortSignal },
): Promise<CascadeSloResponse> {
  return get<CascadeSloResponse>('/api/v1/cascade/slo', {
    signal: opts?.signal,
  })
}
