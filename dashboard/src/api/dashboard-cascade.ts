import { get, post } from './core'
import {
  parseCascadeConfigResponse,
  parseCascadeHealthResponse,
  parseCascadeRawConfigResponse,
} from './schemas/cascade'
import type {
  CascadeConfigResponse,
  CascadeHealthResponse,
  CascadeInvalidProfile,
  CascadeRawConfigResponse,
} from './schemas/cascade'
export { CascadeSchemaDriftError } from './schemas/cascade'
export type {
  CascadeCandidate,
  CascadeConfigResponse,
  CascadeHealthProvider,
  CascadeHealthResponse,
  CascadeInvalidProfile,
  CascadeKeeperProfile,
  CascadeProfile,
  CascadeProviderStatus,
  CascadeRawConfigResponse,
  CascadeValidationStatus,
} from './schemas/cascade'

// --- Keeper Cascade Config ---

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

export function fetchCascadeConfig(
  opts?: { signal?: AbortSignal },
): Promise<CascadeConfigResponse> {
  return get<unknown>('/api/v1/cascade/config', { signal: opts?.signal })
    .then(parseCascadeConfigResponse)
}

export function fetchCascadeConfigRaw(
  opts?: { signal?: AbortSignal },
): Promise<CascadeRawConfigResponse> {
  return get<unknown>('/api/v1/cascade/config/raw', {
    signal: opts?.signal,
  }).then(parseCascadeRawConfigResponse)
}

export function updateCascadeConfigRaw(source_text: string): Promise<CascadeConfigResponse> {
  return post<unknown>('/api/v1/cascade/config/raw', { source_text })
    .then(parseCascadeConfigResponse)
}

export function fetchCascadeHealth(
  opts?: { signal?: AbortSignal },
): Promise<CascadeHealthResponse> {
  return get<unknown>('/api/v1/cascade/health', { signal: opts?.signal })
    .then(parseCascadeHealthResponse)
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

export type CascadeAuditHopStatus = 'success' | 'fallback' | 'error' | 'attempted'

export interface CascadeAuditHop {
  i: number
  model: string
  status: CascadeAuditHopStatus
  ms: number
  reason?: string
  ms_source?: string
}

export interface CascadeAuditRun {
  id: string
  cascade: string
  trigger: string
  at: number
  outcome: string
  error_category?: string
  configured: string[]
  primary: string | null
  selected: string | null
  total_ms: number
  total_ms_source?: string
  hops: CascadeAuditHop[]
}

export interface CascadeAuditRunsResponse {
  updated_at: string
  total_runs: number
  audit_runs: CascadeAuditRun[]
}

export function fetchCascadeAuditRuns(opts?: {
  limit?: number
  cascade?: string
  signal?: AbortSignal
}): Promise<CascadeAuditRunsResponse> {
  const params = new URLSearchParams()
  if (typeof opts?.limit === 'number' && opts.limit > 0) {
    params.set('limit', String(opts.limit))
  }
  if (opts?.cascade) params.set('cascade', opts.cascade)
  const qs = params.toString()
  return get<CascadeAuditRunsResponse>(
    `/api/v1/cascade/audit_runs${qs ? `?${qs}` : ''}`,
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
