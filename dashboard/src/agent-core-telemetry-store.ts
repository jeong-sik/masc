// Latest Agent Core inference telemetry sample — a small read model fed directly by
// the `agent_core_telemetry_sample` server push. The event payload already carries
// the sample (schema-validated at the SSE boundary, schemas/sse.ts), so the
// store hydrates from the push with zero HTTP fetch. Wire shape: sample +
// recorded_at as emitted by lib/runtime/dashboard_agent_core_bridge.ml
// (sample_entry_to_yojson), with provider/model labels at the envelope top.

import { signal } from '@preact/signals'
import { asNumber, asString, isRecord } from './components/common/normalize'

export type AgentCoreTelemetrySampleView = {
  provider_id: string
  model_id: string
  ttfb_ms: number
  total_duration_ms: number
  throughput_tokens_per_s: number | null
  cost_usd: number | null
  status_kind: string
  recorded_at: number
}

export const latestAgentCoreTelemetrySample = signal<AgentCoreTelemetrySampleView | null>(null)

export function hydrateAgentCoreTelemetrySample(event: {
  provider_id?: unknown
  model_id?: unknown
  payload?: unknown
}): void {
  const payload = isRecord(event.payload) ? event.payload : null
  const sample = payload && isRecord(payload.sample) ? payload.sample : null
  const recordedAt = payload ? asNumber(payload.recorded_at) : null
  if (!sample || recordedAt == null) return
  latestAgentCoreTelemetrySample.value = {
    provider_id: asString(event.provider_id) ?? '',
    model_id: asString(event.model_id) ?? '',
    ttfb_ms: asNumber(sample.ttfb_ms) ?? 0,
    total_duration_ms: asNumber(sample.total_duration_ms) ?? 0,
    throughput_tokens_per_s: asNumber(sample.throughput_tokens_per_s) ?? null,
    cost_usd: asNumber(sample.cost_usd) ?? null,
    status_kind: isRecord(sample.status) ? (asString(sample.status.kind) ?? 'unknown') : 'unknown',
    recorded_at: recordedAt,
  }
}
