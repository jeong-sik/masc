import { isUtilizationSpent, isWindowCurrentlySpent } from '../../lib/quota-window'
import { isJsonRecord } from '../../lib/wire-decode'
import { formatAccountEmailEntry } from './quota-rest-groups'
import {
  classifyQuotaScope,
  maxUtilizationPct,
  windowKindLabel,
  type ProviderUsageHistoryPoint,
  type ProviderUsageHistoryResponse,
  type ProviderUsageScope,
  type ProviderUsageWindow,
  type ProviderUsageWindowKind,
  type RuntimeAssignment,
  type RuntimeLaneSnapshot,
  type RuntimeResolution,
  type SetupAccountEmail,
} from './types'

export type QuotaScopeFilter = 'all' | 'attention' | 'healthy_sub' | 'resting' | 'unreported'
export type QuotaScopeSort = 'default' | 'util_desc' | 'util_asc' | 'reset_soon' | 'calls_desc' | 'name'
export type QuotaGroupKey = 'attention' | 'healthy_sub' | 'unreported'

export interface RuntimeCallMetricRow {
  readonly runtime_id: string
  readonly entry_count: number
  readonly success_count: number
  readonly error_count: number
  readonly total_tool_calls: number
  readonly total_input_tokens: number | null
  readonly total_output_tokens: number | null
  readonly total_cache_read_tokens: number | null
  readonly total_cost_usd: number | null
  readonly p50_latency_ms: number | null
  readonly p95_latency_ms: number | null
}

export type RuntimeMetrics24hSnapshot =
  | {
      readonly state: 'ready'
      readonly windowMinutes: number
      readonly observedAt: number
      readonly attributedEntries: number
      readonly unattributedEntries: number
      readonly runtimes: readonly RuntimeCallMetricRow[]
    }
  | {
      readonly state: 'unavailable'
      readonly reason: string
    }

export interface ScopeCallSummary {
  readonly calls: number
  readonly success: number
  readonly errors: number
  readonly toolCalls: number
  readonly inputTokens: number | null
  readonly outputTokens: number | null
  readonly cacheReadTokens: number | null
  readonly costUsd: number | null
  readonly runtimes: readonly RuntimeCallMetricRow[]
}

export interface WindowBurnAnalysis {
  readonly label: string
  readonly limitId: string | null
  readonly durationSec: number | null
  readonly windowStartSec: number | null
  readonly observedAtSec: number
  readonly resetsAtSec: number | null
  readonly spent: boolean
  readonly utilizationPct: number | null
  /** Elapsed time from estimated window start (resets_at - duration) to observed_at. */
  readonly elapsedSinceStartSec: number | null
  /** Remaining time from nowUnix until resets_at. */
  readonly remainingToResetSec: number | null
  /** Projected total duration at current observed burn pace (only when active, pct >= 5, elapsed >= 60s). */
  readonly projectedTotalSec: number | null
  readonly source: string
  readonly role: ProviderUsageWindow['role']
}

export interface ScopeHistorySummary {
  readonly days: number
  readonly observedDays: number
  readonly exhaustedDays: number
  readonly peakPct: number | null
  readonly points: readonly ProviderUsageHistoryPoint[]
}

export interface ScopeImpactSummary {
  readonly runtimeIds: readonly string[]
  readonly laneIds: readonly string[]
  readonly keepers: readonly string[]
}

export interface EnrichedQuotaScope {
  readonly scope: ProviderUsageScope
  readonly key: string
  readonly displayName: string
  readonly primaryProviderId: string
  readonly group: QuotaGroupKey
  readonly isResting: boolean
  readonly maxPct: number | null
  readonly soonestResetSec: number | null
  readonly classification: ReturnType<typeof classifyQuotaScope>
  readonly accountLines: readonly string[]
  readonly calls24h: ScopeCallSummary | null
  readonly windowBurns: readonly WindowBurnAnalysis[]
  readonly primaryCutoffBurn: WindowBurnAnalysis | null
  readonly history: ScopeHistorySummary | null
  readonly impact: ScopeImpactSummary
}

export interface QuotaFilterCounts {
  readonly all: number
  readonly attention: number
  readonly healthy_sub: number
  readonly resting: number
  readonly unreported: number
}

function finiteNumber(val: unknown): number | null {
  return typeof val === 'number' && Number.isFinite(val) ? val : null
}

function nonNegativeInt(val: unknown): number {
  return typeof val === 'number' && Number.isFinite(val) && val >= 0 ? Math.trunc(val) : 0
}

/** Decode GET /api/v1/runtime/metrics without inventing numbers on unavailable or empty payloads. */
export function decodeRuntimeMetrics24h(raw: unknown): RuntimeMetrics24hSnapshot {
  if (!isJsonRecord(raw)) {
    return { state: 'unavailable', reason: 'runtime metrics payload unavailable' }
  }
  const history = raw.history
  if (!isJsonRecord(history)) {
    return { state: 'unavailable', reason: 'runtime metrics history absent' }
  }
  if (history.state !== 'ready') {
    const diag = isJsonRecord(history.decision_read) && typeof history.decision_read.cause === 'string'
      ? history.decision_read.cause
      : typeof history.state === 'string'
        ? history.state
        : 'unavailable'
    return { state: 'unavailable', reason: diag }
  }
  const rawRuntimes = Array.isArray(history.runtimes) ? history.runtimes : []
  const runtimes: RuntimeCallMetricRow[] = []
  for (const item of rawRuntimes) {
    if (!isJsonRecord(item)) continue
    const runtimeId = typeof item.runtime_id === 'string' && item.runtime_id.trim().length > 0
      ? item.runtime_id.trim()
      : null
    if (!runtimeId) continue
    runtimes.push({
      runtime_id: runtimeId,
      entry_count: nonNegativeInt(item.entry_count),
      success_count: nonNegativeInt(item.success_count),
      error_count: nonNegativeInt(item.error_count),
      total_tool_calls: nonNegativeInt(item.total_tool_calls),
      total_input_tokens: finiteNumber(item.total_input_tokens),
      total_output_tokens: finiteNumber(item.total_output_tokens),
      total_cache_read_tokens: finiteNumber(item.total_cache_read_tokens),
      total_cost_usd: finiteNumber(item.total_cost_usd),
      p50_latency_ms: finiteNumber(item.p50_latency_ms),
      p95_latency_ms: finiteNumber(item.p95_latency_ms),
    })
  }
  return {
    state: 'ready',
    windowMinutes: nonNegativeInt(history.window_minutes) || 1440,
    observedAt: finiteNumber(history.observed_at) ?? 0,
    attributedEntries: nonNegativeInt(history.attributed_entries),
    unattributedEntries: nonNegativeInt(history.unattributed_entries),
    runtimes,
  }
}

export function windowDurationSec(kind: ProviderUsageWindowKind): number | null {
  switch (kind.kind) {
    case 'five_hour':
      return 5 * 3600
    case 'seven_day':
      return 7 * 86_400
    case 'duration_minutes':
      return Number.isFinite(kind.minutes) && kind.minutes > 0 ? Math.round(kind.minutes * 60) : null
    case 'provider_label':
      return null
  }
}

export function utilizationToPct(u: ProviderUsageWindow['utilization'] | ProviderUsageHistoryPoint['utilization']): number | null {
  switch (u.unit) {
    case 'fraction':
      return Math.min(100, Math.max(0, u.value * 100))
    case 'percent':
      return Math.min(100, Math.max(0, u.value))
    case 'usd':
      return u.limit !== null && u.limit > 0 ? Math.min(100, Math.max(0, (u.value / u.limit) * 100)) : null
    case 'credit_balance':
      return u.total !== null && u.total > 0
        ? Math.min(100, Math.max(0, ((u.total - u.remaining) / u.total) * 100))
        : null
    case 'credit_unlimited':
    case 'credit_retracted':
      return null
  }
}

export function formatDurationKo(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return '1분 미만'
  if (seconds < 60) return `${Math.max(1, Math.round(seconds))}초`
  if (seconds < 3600) return `${Math.max(1, Math.floor(seconds / 60))}분`
  if (seconds < 86_400) {
    const hours = Math.floor(seconds / 3600)
    const mins = Math.floor((seconds % 3600) / 60)
    return mins > 0 ? `${hours}시간 ${mins}분` : `${hours}시간`
  }
  const days = Math.floor(seconds / 86_400)
  const hours = Math.floor((seconds % 86_400) / 3600)
  return hours > 0 ? `${days}일 ${hours}시간` : `${days}일`
}

export function analyzeWindowBurn(w: ProviderUsageWindow, nowUnix: number): WindowBurnAnalysis {
  const durationSec = windowDurationSec(w.window)
  const spent = isWindowCurrentlySpent(w, nowUnix)
  const utilizationPct = utilizationToPct(w.utilization)
  const resetsAtSec = typeof w.resets_at === 'number' && Number.isFinite(w.resets_at) && w.resets_at > 0
    ? w.resets_at
    : null
  const windowStartSec = durationSec !== null && resetsAtSec !== null
    ? resetsAtSec - durationSec
    : null
  // observed_at is the latest report of this window, not the moment it ran out:
  // the server replaces it on every newer report. This is "window start to last
  // observation", never "time to exhaustion".
  const elapsedSinceStartSec = windowStartSec !== null && durationSec !== null && w.observed_at >= windowStartSec
    ? Math.min(durationSec, Math.max(0, w.observed_at - windowStartSec))
    : null
  const remainingToResetSec = resetsAtSec !== null ? Math.max(0, resetsAtSec - nowUnix) : null
  const projectedTotalSec = !spent
    && utilizationPct !== null
    && utilizationPct >= 5
    && utilizationPct < 100
    && elapsedSinceStartSec !== null
    && elapsedSinceStartSec >= 60
    ? Math.round((elapsedSinceStartSec / utilizationPct) * 100)
    : null

  return {
    label: windowKindLabel(w.window),
    limitId: w.limit_id,
    durationSec,
    windowStartSec,
    observedAtSec: w.observed_at,
    resetsAtSec,
    spent,
    utilizationPct,
    elapsedSinceStartSec,
    remainingToResetSec,
    projectedTotalSec,
    source: w.source,
    role: w.role,
  }
}

function sumOptionalNumbers(values: readonly (number | null)[]): number | null {
  let sum = 0
  let seen = false
  for (const v of values) {
    if (typeof v === 'number' && Number.isFinite(v)) {
      sum += v
      seen = true
    }
  }
  return seen ? sum : null
}

export function aggregateScopeCalls(
  scope: ProviderUsageScope,
  resolvedRuntimes: readonly RuntimeResolution[],
  metrics: RuntimeMetrics24hSnapshot | null,
): ScopeCallSummary | null {
  if (!metrics || metrics.state !== 'ready') return null
  const providerIds = new Set(scope.providers.map((p) => p.id))
  if (providerIds.size === 0) return null

  const runtimeToProvider = new Map<string, string>()
  for (const rt of resolvedRuntimes) {
    runtimeToProvider.set(rt.id, rt.provider_id)
  }

  const matched: RuntimeCallMetricRow[] = []
  for (const row of metrics.runtimes) {
    const mappedProvider = runtimeToProvider.get(row.runtime_id)
    if (mappedProvider !== undefined) {
      if (providerIds.has(mappedProvider)) matched.push(row)
      continue
    }
    for (const pid of providerIds) {
      if (row.runtime_id.startsWith(`${pid}.`)) {
        matched.push(row)
        break
      }
    }
  }

  matched.sort((a, b) => (b.entry_count - a.entry_count) || a.runtime_id.localeCompare(b.runtime_id))
  return {
    calls: matched.reduce((acc, r) => acc + r.entry_count, 0),
    success: matched.reduce((acc, r) => acc + r.success_count, 0),
    errors: matched.reduce((acc, r) => acc + r.error_count, 0),
    toolCalls: matched.reduce((acc, r) => acc + r.total_tool_calls, 0),
    inputTokens: sumOptionalNumbers(matched.map((r) => r.total_input_tokens)),
    outputTokens: sumOptionalNumbers(matched.map((r) => r.total_output_tokens)),
    cacheReadTokens: sumOptionalNumbers(matched.map((r) => r.total_cache_read_tokens)),
    costUsd: sumOptionalNumbers(matched.map((r) => r.total_cost_usd)),
    runtimes: matched,
  }
}

export function summarizeScopeHistory(
  scope: ProviderUsageScope,
  history: ProviderUsageHistoryResponse | null,
): ScopeHistorySummary | null {
  if (!history || history.state !== 'ready' || !scope.scope_id) return null
  const points = history.points
    .filter((pt) => pt.scope_id === scope.scope_id)
    .sort((a, b) => b.observed_at - a.observed_at)
  if (points.length === 0) {
    return { days: history.days, observedDays: 0, exhaustedDays: 0, peakPct: null, points: [] }
  }
  const observedDaySet = new Set<string>()
  const exhaustedDaySet = new Set<string>()
  let peakPct: number | null = null
  for (const pt of points) {
    const dayKey = new Date(pt.observed_at * 1000).toISOString().slice(0, 10)
    observedDaySet.add(dayKey)
    if (isUtilizationSpent(pt.utilization) === true) {
      exhaustedDaySet.add(dayKey)
    }
    const pct = utilizationToPct(pt.utilization)
    if (pct !== null && (peakPct === null || pct > peakPct)) peakPct = pct
  }
  return {
    days: history.days,
    observedDays: observedDaySet.size,
    exhaustedDays: exhaustedDaySet.size,
    peakPct,
    points,
  }
}

export function computeScopeImpact(
  scope: ProviderUsageScope,
  runtimes: readonly RuntimeResolution[],
  lanes: readonly RuntimeLaneSnapshot[],
  assignments: readonly RuntimeAssignment[],
): ScopeImpactSummary {
  const providerIds = new Set(scope.providers.map((p) => p.id))
  const runtimeIds = runtimes
    .filter((rt) => providerIds.has(rt.provider_id))
    .map((rt) => rt.id)
    .sort((a, b) => a.localeCompare(b))
  const runtimeIdSet = new Set(runtimeIds)

  const laneIds = lanes
    .filter((lane) => lane.declared && lane.runtime_ids.some((id) => runtimeIdSet.has(id)))
    .map((lane) => lane.id)
    .sort((a, b) => a.localeCompare(b))
  const laneIdSet = new Set(laneIds)

  const keepers = assignments
    .filter((a) => {
      if (a.resolved.kind === 'lane' && a.resolved.id !== null) {
        return laneIdSet.has(a.resolved.id) || runtimeIdSet.has(a.resolved.id)
      }
      return false
    })
    .map((a) => a.keeper)
    .sort((a, b) => a.localeCompare(b))

  return { runtimeIds, laneIds, keepers }
}

function soonestFutureReset(scope: ProviderUsageScope, nowUnix: number): number | null {
  let soonest: number | null = null
  for (const w of scope.windows) {
    if (typeof w.resets_at !== 'number' || !Number.isFinite(w.resets_at) || w.resets_at <= nowUnix) continue
    if (soonest === null || w.resets_at < soonest) soonest = w.resets_at
  }
  return soonest
}

export function enrichQuotaScopes(params: {
  readonly scopes: readonly ProviderUsageScope[]
  readonly restingProviders: ReadonlySet<string>
  readonly accountEmails: ReadonlyMap<string, SetupAccountEmail>
  readonly runtimes: readonly RuntimeResolution[]
  readonly lanes: readonly RuntimeLaneSnapshot[]
  readonly assignments: readonly RuntimeAssignment[]
  readonly metrics24h: RuntimeMetrics24hSnapshot | null
  readonly history: ProviderUsageHistoryResponse | null
  readonly nowUnix: number
}): readonly EnrichedQuotaScope[] {
  const {
    scopes,
    restingProviders,
    accountEmails,
    runtimes,
    lanes,
    assignments,
    metrics24h,
    history,
    nowUnix,
  } = params

  return scopes.map((scope, idx) => {
    const classification = classifyQuotaScope(scope, nowUnix)
    const isResting = scope.providers.some((p) => restingProviders.has(p.id))
    const maxPct = maxUtilizationPct(scope, nowUnix)
    let group: QuotaGroupKey
    if (
      classification.kind === 'exhausted_zero'
      || classification.kind === 'amount'
      || isResting
      || (maxPct !== null && maxPct >= 90)
    ) {
      group = 'attention'
    } else if (classification.kind === 'subscription_zero') {
      group = 'healthy_sub'
    } else {
      group = 'unreported'
    }

    const displayName = scope.providers.length > 0
      ? scope.providers.map((p) => p.display_name || p.id).join(' · ')
      : (scope.scope_id || scope.scope)
    const primaryProviderId = scope.providers[0]?.id ?? scope.scope_id ?? scope.scope
    const accountLines = scope.providers
      .map((p) => formatAccountEmailEntry(accountEmails.get(p.id)))
      .filter((line): line is string => line !== null)
    const windowBurns = scope.windows.map((w) => analyzeWindowBurn(w, nowUnix))
    const spentBurnsWithElapsed = windowBurns
      .filter((b) => b.spent && b.elapsedSinceStartSec !== null)
      .sort((a, b) => (a.durationSec ?? Number.MAX_SAFE_INTEGER) - (b.durationSec ?? Number.MAX_SAFE_INTEGER))
    const primaryCutoffBurn = spentBurnsWithElapsed[0] ?? null

    return {
      scope,
      key: `${scope.scope}-${idx}`,
      displayName,
      primaryProviderId,
      group,
      isResting,
      maxPct,
      soonestResetSec: soonestFutureReset(scope, nowUnix),
      classification,
      accountLines,
      calls24h: aggregateScopeCalls(scope, runtimes, metrics24h),
      windowBurns,
      primaryCutoffBurn,
      history: summarizeScopeHistory(scope, history),
      impact: computeScopeImpact(scope, runtimes, lanes, assignments),
    }
  })
}

export function countQuotaFilters(items: readonly EnrichedQuotaScope[]): QuotaFilterCounts {
  let attention = 0
  let healthy_sub = 0
  let resting = 0
  let unreported = 0
  for (const item of items) {
    if (item.group === 'attention') attention += 1
    else if (item.group === 'healthy_sub') healthy_sub += 1
    else unreported += 1
    if (item.isResting) resting += 1
  }
  return { all: items.length, attention, healthy_sub, resting, unreported }
}

function groupRank(g: QuotaGroupKey): number {
  switch (g) {
    case 'attention':
      return 0
    case 'healthy_sub':
      return 1
    case 'unreported':
      return 2
  }
}

function compareNullableAsc(a: number | null, b: number | null): number {
  if (a !== null && b !== null) return a - b
  if (a !== null) return -1
  if (b !== null) return 1
  return 0
}

function compareNullableDesc(a: number | null, b: number | null): number {
  if (a !== null && b !== null) return b - a
  if (a !== null) return -1
  if (b !== null) return 1
  return 0
}

export function filterAndSortQuotaScopes(
  items: readonly EnrichedQuotaScope[],
  opts: {
    readonly filter: QuotaScopeFilter
    readonly sort: QuotaScopeSort
    readonly query: string
  },
): readonly EnrichedQuotaScope[] {
  const needle = opts.query.trim().toLowerCase()
  const filtered = items.filter((item) => {
    if (opts.filter === 'attention' && item.group !== 'attention') return false
    if (opts.filter === 'healthy_sub' && item.group !== 'healthy_sub') return false
    if (opts.filter === 'resting' && !item.isResting) return false
    if (opts.filter === 'unreported' && item.group !== 'unreported') return false
    if (needle.length > 0) {
      const haystacks = [
        item.displayName,
        item.scope.scope,
        ...item.scope.providers.map((p) => p.id),
        ...item.scope.providers.map((p) => p.display_name),
        ...item.accountLines,
        ...item.impact.keepers,
        ...item.impact.laneIds,
      ]
      if (!haystacks.some((h) => h.toLowerCase().includes(needle))) return false
    }
    return true
  })

  if (opts.sort === 'default') return filtered

  return [...filtered].sort((a, b) => {
    switch (opts.sort) {
      case 'util_desc':
        return compareNullableDesc(a.maxPct, b.maxPct) || a.displayName.localeCompare(b.displayName)
      case 'util_asc':
        return compareNullableAsc(a.maxPct, b.maxPct) || a.displayName.localeCompare(b.displayName)
      case 'reset_soon':
        return compareNullableAsc(a.soonestResetSec, b.soonestResetSec) || a.displayName.localeCompare(b.displayName)
      case 'calls_desc':
        return compareNullableDesc(a.calls24h?.calls ?? null, b.calls24h?.calls ?? null)
          || a.displayName.localeCompare(b.displayName)
      case 'name':
        return a.displayName.localeCompare(b.displayName) || a.scope.scope.localeCompare(b.scope.scope)
      default:
        return (groupRank(a.group) - groupRank(b.group)) || a.displayName.localeCompare(b.displayName)
    }
  })
}
