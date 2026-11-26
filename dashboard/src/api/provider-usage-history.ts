// MASC Dashboard — provider usage history decoder.
//
// Backend: lib/server/server_provider_usage_history_projection.ml response_json
// Route:   GET /api/v1/dashboard/provider-usage-history?days=1|7|14
//
// One reading per window per UTC day. The utilization fields are
// lib/runtime/runtime_provider_usage_window.ml utilization_fields; the history
// drops credit_retracted before it answers, so five units reach this decoder.
// A reading the decoder cannot read is counted in `undecodable_points`, not
// turned into a zero reading. A response that is not the history at all
// throws, so the caller's request fails instead of drawing an empty chart.

import { isRecord } from '../components/common/normalize'

export type ProviderUsageUtilization =
  | { readonly unit: 'fraction'; readonly value: number }
  | { readonly unit: 'percent'; readonly value: number }
  | { readonly unit: 'usd'; readonly value: number; readonly limit: number | null }
  | {
      readonly unit: 'credit_balance'
      readonly currency: string
      readonly total: number | null
      readonly remaining: number
    }
  | { readonly unit: 'credit_unlimited' }

export interface ProviderUsageHistoryPoint {
  readonly scope_id: string
  readonly source: string
  readonly kind: string
  readonly limit_id: string | null
  /** Unix seconds the provider reported this reading. */
  readonly observed_at: number
  /** Unix seconds the window resets; `null` when the provider did not say. */
  readonly resets_at: number | null
  readonly utilization: ProviderUsageUtilization
}

export interface ProviderUsageReportedNoWindows {
  readonly scope_id: string
  readonly observed_at: number
}

export type ProviderUsageHistoryResponse =
  | { readonly state: 'unavailable'; readonly reason: string }
  | {
      readonly state: 'ready'
      readonly days: number
      readonly generated_at: number
      readonly sampling: string
      /** Journal reports the server could not read. */
      readonly unreadable_reports: number
      /** Scope-days whose latest report stated no window at all. */
      readonly reported_no_windows: readonly ProviderUsageReportedNoWindows[]
      readonly points: readonly ProviderUsageHistoryPoint[]
      /** Points this decoder could not read (identity, time or unit). */
      readonly undecodable_points: number
    }

function fail(message: string): never {
  throw new Error(`Invalid provider usage history response: ${message}`)
}

function finite(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function nonEmpty(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

// `null` on the wire is a stated absence; any other non-number is a broken row.
type NullableNumber = { readonly ok: true; readonly value: number | null } | { readonly ok: false }

function nullableNumber(value: unknown): NullableNumber {
  if (value === null) return { ok: true, value: null }
  const n = finite(value)
  return n === null ? { ok: false } : { ok: true, value: n }
}

function decodeUtilization(pt: Record<string, unknown>): ProviderUsageUtilization | null {
  switch (pt.unit) {
    case 'fraction': {
      const value = finite(pt.value)
      return value === null ? null : { unit: 'fraction', value }
    }
    case 'percent': {
      const value = finite(pt.value)
      return value === null ? null : { unit: 'percent', value }
    }
    case 'usd': {
      const value = finite(pt.value)
      const limit = nullableNumber(pt.limit)
      return value === null || !limit.ok ? null : { unit: 'usd', value, limit: limit.value }
    }
    case 'credit_balance': {
      const currency = nonEmpty(pt.currency)
      const remaining = finite(pt.remaining)
      const total = nullableNumber(pt.total)
      if (currency === null || remaining === null || !total.ok) return null
      return { unit: 'credit_balance', currency, total: total.value, remaining }
    }
    case 'credit_unlimited':
      return { unit: 'credit_unlimited' }
    default:
      return null
  }
}

function decodePoint(raw: unknown): ProviderUsageHistoryPoint | null {
  if (!isRecord(raw)) return null
  const scopeId = nonEmpty(raw.scope_id)
  const source = nonEmpty(raw.source)
  const kind = nonEmpty(raw.kind)
  const observedAt = finite(raw.observed_at)
  const resetsAt = nullableNumber(raw.resets_at)
  const utilization = decodeUtilization(raw)
  const limitId = raw.limit_id === null ? null : nonEmpty(raw.limit_id)
  if (scopeId === null || source === null || kind === null || observedAt === null || !resetsAt.ok || utilization === null) {
    return null
  }
  if (raw.limit_id !== null && limitId === null) return null
  return {
    scope_id: scopeId,
    source,
    kind,
    limit_id: limitId,
    observed_at: observedAt,
    resets_at: resetsAt.value,
    utilization,
  }
}

function decodeReportedNoWindows(raw: unknown, index: number): ProviderUsageReportedNoWindows {
  if (!isRecord(raw)) fail(`reported_no_windows[${index}] must be an object`)
  const scopeId = nonEmpty(raw.scope_id)
  const observedAt = finite(raw.observed_at)
  if (scopeId === null || observedAt === null) fail(`reported_no_windows[${index}] needs scope_id and observed_at`)
  return { scope_id: scopeId, observed_at: observedAt }
}

export function parseProviderUsageHistoryResponse(raw: unknown): ProviderUsageHistoryResponse {
  if (!isRecord(raw)) fail('root must be an object')
  if (raw.state === 'unavailable') {
    const reason = nonEmpty(raw.reason)
    if (reason === null) fail('unavailable response needs a reason')
    return { state: 'unavailable', reason }
  }
  if (raw.state !== undefined) fail(`unknown state ${JSON.stringify(raw.state)}`)
  const days = finite(raw.days)
  const generatedAt = finite(raw.generated_at)
  const sampling = nonEmpty(raw.sampling)
  const unreadable = raw.unreadable_reports
  if (days === null || generatedAt === null || sampling === null) fail('days, generated_at and sampling are required')
  if (!Number.isSafeInteger(unreadable) || (unreadable as number) < 0) fail('unreadable_reports must be a non-negative integer')
  if (!Array.isArray(raw.points)) fail('points must be an array')
  if (!Array.isArray(raw.reported_no_windows)) fail('reported_no_windows must be an array')
  const points: ProviderUsageHistoryPoint[] = []
  let undecodable = 0
  for (const pt of raw.points) {
    const point = decodePoint(pt)
    if (point === null) undecodable += 1
    else points.push(point)
  }
  return {
    state: 'ready',
    days,
    generated_at: generatedAt,
    sampling,
    unreadable_reports: unreadable as number,
    reported_no_windows: raw.reported_no_windows.map(decodeReportedNoWindows),
    points,
    undecodable_points: undecodable,
  }
}
