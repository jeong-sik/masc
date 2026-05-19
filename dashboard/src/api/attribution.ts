// MASC Dashboard — Attribution REST client (Layer 4).
//
// Reads from the in-process ring buffer in `lib/dashboard/dashboard_attribution.ml`
// via /api/v1/attribution/{recent,summary}. Plain types — no valibot schema yet
// because the envelope is frozen at the OCaml side (Attribution.to_yojson) and
// the dashboard is the only consumer.

import { get, type GetOptions } from './core'
import {
  type AttributionOrigin,
  type AttributionOutcome,
  type Attribution as SseAttribution,
} from '../types/sse'

export type { AttributionOrigin, AttributionOutcome }
export type Attribution = SseAttribution

export interface AttributionEvent {
  attribution: Attribution
  recorded_at: number
}

interface AttributionRecentResponse {
  events: AttributionEvent[]
  count: number
}

export interface GateSummary {
  gate: string
  passed: number
  policy_failed: number
  transition_blocked: number
  partial_pass: number
  total: number
}

export interface AttributionSummaryResponse {
  gates: GateSummary[]
}

export async function fetchAttributionSummary(
  opts: GetOptions = {},
): Promise<AttributionSummaryResponse> {
  return get<AttributionSummaryResponse>('/api/v1/attribution/summary', opts)
}

export async function fetchAttributionRecent(
  params: { gate?: string; limit?: number } = {},
  opts: GetOptions = {},
): Promise<AttributionRecentResponse> {
  const sp = new URLSearchParams()
  if (params.gate) sp.set('gate', params.gate)
  if (params.limit !== undefined) sp.set('limit', String(params.limit))
  const query = sp.toString()
  const path = query
    ? `/api/v1/attribution/recent?${query}`
    : '/api/v1/attribution/recent'
  return get<AttributionRecentResponse>(path, opts)
}
