import type { ComponentChildren } from 'preact'
import {
  OBSERVER_SSE_INSTANCE_HEADER,
  authSession,
  currentSessionEpoch,
  getObserverSseInstanceId,
  getSingleUserToken,
  isEpochCurrent,
  observedAbsent,
  observedUnreported,
  observedValue,
  parseSseBlock,
  resolveWorkspaceUrl,
  type Observed,
  type ObserverFrame,
} from '../../core'

export interface WorkspaceInspectPayload {
  title: string
  subtitle?: string
  kind: string
  data?: unknown
  render?: () => ComponentChildren
}

export interface WorkspaceViewProps {
  subroute: string
  entityId?: string
  entityTab?: string
  onNavigate: (path: string) => void
  onInspect: (payload: WorkspaceInspectPayload) => void
}

export type RuntimeSubroute = 'quotas' | 'efficiency' | 'lanes' | 'tools' | 'addons'

export const RUNTIME_TABS: readonly { readonly id: RuntimeSubroute; readonly label: string }[] = [
  { id: 'quotas', label: 'Quotas & Rate Limits' },
  { id: 'efficiency', label: 'Efficiency & Cache' },
  { id: 'lanes', label: 'Lanes & Exact Output' },
  { id: 'tools', label: 'Tools, Skills & Plug-ins' },
  { id: 'addons', label: 'Lane-Addons & Browser' },
]

export function normalizeRuntimeSubroute(raw: string): RuntimeSubroute {
  const cleaned = raw.trim().toLowerCase()
  if (cleaned === 'efficiency' || cleaned === 'lanes' || cleaned === 'tools' || cleaned === 'addons') {
    return cleaned
  }
  return 'quotas'
}

// ── Wire Types (authoritative OCaml schemas per #36 & wire_runtime.mli) ──

export type ProviderUsageWindowKind =
  | { readonly kind: 'five_hour' }
  | { readonly kind: 'seven_day' }
  | { readonly kind: 'duration_minutes'; readonly minutes: number }
  | { readonly kind: 'provider_label'; readonly label: string }

export type ProviderUsageUtilization =
  | { readonly unit: 'fraction'; readonly value: number }
  | { readonly unit: 'percent'; readonly value: number }
  | { readonly unit: 'usd'; readonly value: number; readonly limit: number | null }
  | { readonly unit: 'credit_balance'; readonly currency: string; readonly total: number | null; readonly remaining: number }
  | { readonly unit: 'credit_unlimited' }
  | { readonly unit: 'credit_retracted' }

export interface ProviderUsageWindow {
  readonly limit_id: string | null
  readonly window: ProviderUsageWindowKind
  readonly utilization: ProviderUsageUtilization
  readonly resets_at: number | null
  readonly observed_at: number
  readonly source: string
  readonly role: 'gates_model_calls' | 'counts_other_use' | 'unclassified_limit'
}

export interface ProviderUsageScope {
  readonly scope: string
  readonly scope_id?: string
  readonly providers: readonly { readonly id: string; readonly display_name: string }[]
  readonly state: 'reported' | 'reported_no_windows' | 'not_reported_since_start'
  readonly observed_at?: number
  readonly source?: string
  readonly windows: readonly ProviderUsageWindow[]
}

export interface RuntimeQuotaRest {
  readonly cause: 'payment_refused' | 'provider_quota_refused' | 'usage_read'
  readonly reset_stated: boolean
  readonly until: number
}

export interface RuntimeResolution {
  readonly id: string
  readonly provider: string
  readonly model: string
  readonly effective_max_context: number
  readonly max_context_source: string
  readonly max_output_tokens: number | null
  readonly is_local: boolean
  readonly is_default: boolean
  readonly quota_rest: RuntimeQuotaRest | null
}

export interface RuntimeLaneSnapshot {
  readonly id: string
  readonly declared: boolean
  readonly runtime_ids: readonly string[]
}

export interface RuntimeAssignment {
  readonly keeper: string
  readonly assignment_source: 'explicit' | 'default'
  readonly resolved:
    | { readonly kind: 'lane' | 'single_runtime' | 'missing'; readonly id: string | null }
    | {
        readonly kind: 'unavailable'
        readonly id: string
        readonly reason: {
          readonly kind: string
          readonly message: string
          readonly provider_id: string
          readonly provider_label: string
          readonly model_id: string
        }
      }
}

export interface RuntimeResolvedPayload {
  readonly generated_at_iso?: string
  readonly config_path: string | null
  readonly default_route: string | null
  readonly default_runtime: RuntimeResolution | null
  readonly runtimes: readonly RuntimeResolution[]
  readonly lanes: readonly RuntimeLaneSnapshot[]
  readonly assignments: readonly RuntimeAssignment[]
  readonly provider_usage_windows_since?: number
  readonly provider_usage_windows?: readonly ProviderUsageScope[]
}

export interface ProviderUsageHistoryPoint {
  readonly scope_id: string
  readonly source: string
  readonly kind: string
  readonly limit_id: string | null
  readonly observed_at: number
  readonly resets_at: number | null
  readonly unit: 'fraction' | 'percent' | 'usd' | 'credit_balance' | 'credit_unlimited'
  readonly value?: number
  readonly limit?: number | null
  readonly currency?: string
  readonly total?: number | null
  readonly remaining?: number
}

export type ProviderUsageHistoryResponse =
  | { readonly state: 'unavailable'; readonly reason: string }
  | {
      readonly state?: 'ready'
      readonly days: number
      readonly generated_at: number
      readonly sampling: string
      readonly unreadable_reports: number
      readonly reported_no_windows: readonly { readonly scope_id: string; readonly observed_at: number }[]
      readonly points: readonly ProviderUsageHistoryPoint[]
    }

export interface SetupIntegration {
  readonly id: string
  readonly display_name: string
  readonly protocol?: string | null
  readonly origin?: string
  readonly setup_support: string
  readonly enabled?: boolean
  readonly credential_kind?: string | null
  readonly configured_runtime_ids?: readonly string[]
}

/** One row of the setup inventory's `account_emails`: the email and plan
 *  labels the client's own login file reports for a provider's account. */
export type SetupAccountEmail =
  | { readonly integration_id: string; readonly state: 'read'; readonly email: string; readonly plan?: readonly string[] }
  | { readonly integration_id: string; readonly state: 'not_read'; readonly cause: string }

export interface SetupInventoryPayload {
  readonly default_runtime_id?: string | null
  readonly integrations: readonly SetupIntegration[]
  readonly account_emails?: readonly SetupAccountEmail[]
}

export interface MultiAccountProviderAccount {
  readonly provider_account_id?: string
  readonly id?: string
  readonly account_ref?: string
  readonly integration_id?: string
  readonly provider?: string
  readonly display_name?: string
  readonly kind?: 'login' | 'key' | string
  readonly key?: string
  readonly removal?: string
  readonly replacement?: string
  readonly status?: string
  readonly verified?: boolean
  readonly label?: string
}

export interface MultiAccountProviderAccountsResponse {
  readonly provider_accounts?: readonly MultiAccountProviderAccount[]
  readonly accounts?: readonly MultiAccountProviderAccount[]
  readonly runtimes?: readonly {
    readonly runtime_id: string
    readonly provider_account_id: string
    readonly integration_id?: string
  }[]
}

export interface MultiAccountIntegration {
  readonly integration_id: string
  readonly display_name: string
  readonly connect: readonly string[]
  readonly models: readonly string[]
  readonly calls?: string
}

export interface MultiAccountIntegrationsResponse {
  readonly integrations?: readonly MultiAccountIntegration[]
}

export interface LaneAddonAskQuestion {
  readonly id?: string
  readonly question_id?: string
  readonly prompt?: string
  readonly text?: string
  readonly label?: string
  readonly choices?: readonly { readonly id: string; readonly label?: string }[]
}

export interface LaneAddonAskRow {
  readonly declaration_id: string
  readonly title: string
  readonly ask_id: string
  readonly asked_at: number
  readonly context: string | null
  readonly questions: readonly LaneAddonAskQuestion[]
  readonly resolution: { readonly state?: string }
}

export interface LaneAddonAsksResponse {
  readonly asks?: readonly LaneAddonAskRow[]
}

export interface CacheStatsPayload {
  readonly entries: number
  readonly fresh: number
  readonly stale: number
  readonly expired: number
  readonly ready_fresh: number
  readonly ready_stale: number
  readonly computing: number
  readonly max_entries: number
  readonly hits_total: number
  readonly misses_total: number
  readonly hit_ratio: number
  readonly timeout_circuit_open: number
  readonly timeout_circuit_tracked: number
  readonly entries_truncated_to: number
  readonly entry_details: readonly (
    | {
        readonly key: string
        readonly kind: 'fresh' | 'stale' | 'expired'
        readonly ttl_remaining_ms: number
        readonly stale_remaining_ms: number
      }
    | {
        readonly key: string
        readonly kind: 'computing'
        readonly computing_for_ms: number
        readonly has_stale_fallback: boolean
      }
  )[]
}

export interface ModelMetricsBucket {
  readonly ts_start: number
  readonly entry_count: number
  readonly success_count: number
  readonly error_count: number
  readonly p50_latency_ms: number | null
  readonly p95_latency_ms: number | null
  readonly error_rate: number
  readonly total_cost_usd: number | null
  readonly cache_hit_ratio: number | null
  readonly input_tokens?: number | null
  readonly output_tokens?: number | null
}

export interface ModelMetricsRow {
  readonly model_id: string
  readonly entry_count: number
  readonly avg_tok_per_sec: number | null
  readonly p50_latency_ms: number | null
  readonly p95_latency_ms: number | null
  readonly total_input_tokens: number | null
  readonly total_output_tokens: number | null
  readonly total_cache_read_tokens: number | null
  readonly cached_input: {
    readonly input_tokens: number
    readonly cache_read_tokens: number
    readonly sample_count: number
  } | null
  readonly total_cache_creation_tokens: number | null
  readonly success_count: number
  readonly error_count: number
  readonly total_cost_usd: number | null
  readonly total_tool_calls: number
  readonly buckets: readonly ModelMetricsBucket[]
}

export interface ModelsMetricsPayload {
  readonly window_minutes: number
  readonly bucket_minutes: number
  readonly total_entries: number
  readonly total_error_entries: number
  readonly cost_ledger_read?:
    | { readonly state: 'available'; readonly malformed_rows: number }
    | { readonly state: 'unavailable'; readonly detail: string }
  readonly models: readonly ModelMetricsRow[]
}

export interface KeeperCostRow {
  readonly keeper_name: string
  readonly total_cost_usd: number | null
  readonly cost_reported_samples: number
  readonly cost_unreported_samples: number
  readonly total_input_tokens: number | null
  readonly total_output_tokens: number | null
  readonly total_tokens: number | null
  readonly tokens_reported_samples: number
  readonly p50_latency_ms: number | null
  readonly p95_latency_ms: number | null
  readonly sample_count: number
}

export interface KeeperCostsPayload {
  readonly window_minutes?: number
  readonly keepers: readonly KeeperCostRow[]
  readonly generated_at?: number | null
}

export interface KeeperEfficiencyRow {
  readonly keeper: string
  readonly turns: number
  readonly input_tokens: number
  readonly output_tokens: number
  readonly cache_read_tokens?: number | null
  readonly cost_usd: number
  readonly calls: number
  readonly failed: number
  readonly deferred: number
  readonly tool_ms: number
}

export interface KeeperEfficiencyPayload {
  readonly month: string
  readonly generated_at: number
  readonly days_covered: number
  readonly keepers: readonly KeeperEfficiencyRow[]
  readonly fleet: {
    readonly turns_total: number
    readonly calls_per_turn: number
    readonly tool_s_per_turn: number
    readonly output_tokens_per_turn: number
    readonly input_tokens_per_turn: number
    readonly cost_usd_per_turn: number
  }
}

export interface RuntimeProbeProviderRow {
  readonly runtime_id: string
  readonly provider_id: string
  readonly provider_display_name: string
  readonly model_id: string
  readonly protocol: string
  readonly runtime_kind: 'cli' | 'local' | 'http'
  readonly transport: 'cli' | 'http'
  readonly status: string
  readonly reachable: boolean | null
  readonly http_status: number | null
  readonly latency_ms: number | null
  readonly error: string | null
  readonly checked_at: string
}

export interface RuntimeProbePayload {
  readonly generated_at: string
  readonly cache_ttl_sec: number
  readonly cache_age_sec: number | null
  readonly cache_hit: boolean
  readonly refresh_state: 'fresh' | 'recent' | 'served_stale' | 'warming_up'
  readonly probe: {
    readonly status: string
    readonly probe_ok: boolean
    readonly checked_at: string
    readonly summary: {
      readonly runtimes: number
      readonly probed: number
      readonly reachable: number
      readonly failed: number
      readonly skipped: number
      readonly default_runtime_id: string | null
    }
    readonly providers: readonly RuntimeProbeProviderRow[]
    readonly errors: readonly string[]
    readonly observations: readonly string[]
    readonly limitations: readonly string[]
  }
}

export type ExactRunKind = 'exact_output' | 'task_verification' | 'goal_verification'

export interface ExactLaneRunRow {
  readonly run_id: string
  readonly run_kind: ExactRunKind
  readonly lane: string
  readonly subject_id: string | null
  readonly actor: string
  readonly started_at: number
  readonly status: string
  readonly elapsed_s?: number | null
  readonly selected_slot?: string | null
  readonly completion_origin?: string
  readonly slot_observations?: {
    readonly state: 'unobserved' | 'unavailable' | 'available'
    readonly detail?: string
    readonly observations?: unknown
  }
  readonly usage?: {
    readonly input_tokens?: number
    readonly output_tokens?: number
    readonly cache_read_input_tokens?: number
    readonly cost_usd?: number
  } | null
  readonly code?: string
  readonly detail?: string
  readonly input?: unknown
  readonly output?: unknown
  readonly payload_availability?: {
    readonly input?: { readonly state: string; readonly error?: { readonly code: string; readonly message: string } }
    readonly output?: { readonly state: string; readonly error?: { readonly code: string; readonly message: string } } | null
  }
}

export interface ExactLaneRunsPayload {
  readonly generated_at: string
  readonly count: number
  readonly total: number
  readonly has_more: boolean
  readonly runs: readonly ExactLaneRunRow[]
}

export type FusionTopology =
  | 'simple'
  | 'refine'
  | 'conditional'
  | 'judge_of_judges'
  | 'staged_judge_of_judges'

export const FUSION_TOPOLOGIES: readonly { readonly value: FusionTopology; readonly label: string }[] = [
  { value: 'simple', label: 'Simple' },
  { value: 'refine', label: 'Refine' },
  { value: 'conditional', label: 'Conditional' },
  { value: 'judge_of_judges', label: 'Judge of Judges' },
  { value: 'staged_judge_of_judges', label: 'Staged Judge of Judges' },
]

export interface FusionRunRow {
  readonly run_id: string
  readonly keeper: string
  readonly preset: string
  readonly topology: FusionTopology
  readonly started_at: number
  readonly status: 'running' | 'completed' | 'failed'
  readonly error?: string
  readonly failure_code?: string
}

export interface FusionRunsPayload {
  readonly generated_at: string
  readonly count: number
  readonly runs: readonly FusionRunRow[]
}

export interface ToolMetricStat {
  readonly call_count: number
  readonly failure_count: number
  readonly failure_classes: {
    readonly dependency_unavailable: number
    readonly policy_rejection: number
    readonly runtime_failure: number
    readonly workflow_rejection: number
    readonly operator_cancelled: number
  }
  readonly failure_unclassified_count: number
  readonly deferred_count: number
  readonly total_ms: number
  readonly p50_ms: number | null
  readonly p95_ms: number | null
  readonly max_ms: number | null
}

export interface ToolMetricsSeriesPayload {
  readonly generated_at: number
  readonly window: {
    readonly since: number
    readonly until: number
    readonly bucket: 'hour' | 'day'
    readonly bucket_seconds: number
  }
  readonly tool: string | null
  readonly total: ToolMetricStat
  readonly buckets: readonly ({ readonly start: number } & ToolMetricStat)[]
  readonly top_by_time?: readonly ({ readonly name: string } & ToolMetricStat)[]
}

export interface DashboardToolRow {
  readonly name: string
  readonly description?: string | null
  readonly calls?: number | null
  readonly failure_count?: number
  readonly failure_rate?: number | null
  readonly p95_ms?: number | null
  readonly domain?: string
  readonly family?: string
}

export interface GateConnectorRow {
  readonly connector_id: string
  readonly display_name: string
  readonly channel: string
  readonly status: string
  readonly available: boolean
  readonly connected: boolean
  readonly stale: boolean
  readonly error?: string
  readonly configured_bindings?: readonly { readonly channel_id: string; readonly keeper_name: string }[]
}

export interface McpClientRow {
  readonly name: string
  readonly agent_type?: string
  readonly keeper_name?: string | null
  readonly status: string
  readonly current_task?: string | null
  readonly last_seen_unix?: number | null
  readonly capabilities?: readonly string[]
}

export interface LaneAddonInstanceRow {
  readonly instance_id: string
  readonly addon_id: string
  readonly title: string
  readonly revision: string
  readonly incarnation: string
  readonly run_id: string
  readonly runtime_presence?: 'live' | 'retained'
  readonly phase: { readonly kind: string; readonly message?: string }
  readonly observation_seq: number
  readonly rows_count: number
  readonly observation_pending?: boolean
  readonly action_schema: Record<string, unknown> | null
  readonly host_requests?: {
    readonly cycles?: number
    readonly waiting?: readonly { readonly request_id: string; readonly reason: Record<string, unknown> }[]
    readonly issue?: Record<string, unknown> | null
  }
}

export interface LaneAddonsPayload {
  readonly configuration: {
    readonly directory: string
    readonly complete: boolean
    readonly issues: readonly { readonly source_path: string; readonly id: string | null; readonly message: string }[]
    readonly declarations: readonly {
      readonly id: string
      readonly source_path: string
      readonly enabled: boolean
      readonly instance_id: string | null
      readonly application: { readonly kind: string; readonly messages?: readonly string[] }
    }[]
  } | null
  readonly instances: readonly LaneAddonInstanceRow[]
  readonly rows: readonly Record<string, unknown>[]
  readonly coverage: readonly Record<string, unknown>[]
}

export interface BrowserClientRow {
  readonly clientId: string
  readonly browser: string
  readonly version: string
  readonly engineVersion?: string
  readonly transport: string
  readonly space?: { readonly id: number; readonly name: string } | null
  readonly interactions?: readonly {
    readonly requestId: string
    readonly actor: string | null
    readonly action: string
    readonly tabId: number | null
    readonly phase: string
  }[]
}

export interface BrowserClientsPayload {
  readonly clients: readonly BrowserClientRow[]
  readonly inventoryComplete: boolean
  readonly inventoryIssues: readonly { readonly kind: string; readonly instanceId?: string; readonly message?: string }[]
  readonly automatic?: { readonly browse: { readonly ok: boolean; readonly data?: unknown; readonly error?: unknown } }
}

export interface BrowserTabRow {
  readonly id: number
  readonly title: string
  readonly url: string
  readonly active: boolean
  readonly windowId?: number | null
  readonly openedBy?: string | null
}

// ── 3-Tier Quota Billing Honesty Classifier (mirrors wire_runtime.mli) ──

export type QuotaCostClassification =
  | { readonly kind: 'subscription_zero'; readonly badge: '$0 Sub' }
  | { readonly kind: 'exhausted_zero'; readonly badge: '$0 Exhausted' }
  | { readonly kind: 'amount'; readonly amount: number; readonly currency: string; readonly badge: string }
  | { readonly kind: 'unreported'; readonly badge: '? Unreported' }

export function classifyQuotaScope(scope: ProviderUsageScope): QuotaCostClassification {
  if (scope.state !== 'reported' || scope.windows.length === 0) {
    return { kind: 'unreported', badge: '? Unreported' }
  }

  let hasSub = false
  let hasExhausted = false
  let bestAmount: { amount: number; currency: string } | null = null

  for (const w of scope.windows) {
    const u = w.utilization
    switch (u.unit) {
      case 'fraction':
        hasSub = true
        if (u.value >= 1.0) hasExhausted = true
        break
      case 'percent':
        hasSub = true
        if (u.value >= 100) hasExhausted = true
        break
      case 'credit_unlimited':
        hasSub = true
        break
      case 'credit_balance':
        if (u.remaining <= 0) {
          hasExhausted = true
        } else {
          bestAmount = { amount: u.remaining, currency: u.currency || 'USD' }
        }
        break
      case 'usd':
        if (u.limit !== null && u.value >= u.limit) {
          hasExhausted = true
        } else {
          bestAmount = { amount: u.value, currency: 'USD' }
        }
        break
      case 'credit_retracted':
        break
    }
  }

  if (hasExhausted) return { kind: 'exhausted_zero', badge: '$0 Exhausted' }
  if (bestAmount !== null) {
    const formatted = bestAmount.currency === 'USD'
      ? `$${bestAmount.amount.toFixed(2)}`
      : `${bestAmount.amount.toFixed(2)} ${bestAmount.currency}`
    return { kind: 'amount', amount: bestAmount.amount, currency: bestAmount.currency, badge: formatted }
  }
  if (hasSub) return { kind: 'subscription_zero', badge: '$0 Sub' }
  return { kind: 'unreported', badge: '? Unreported' }
}

export function maxUtilizationPct(scope: ProviderUsageScope): number | null {
  let maxPct: number | null = null
  for (const w of scope.windows) {
    const u = w.utilization
    let pct: number | null = null
    if (u.unit === 'fraction') pct = Math.min(100, Math.max(0, u.value * 100))
    else if (u.unit === 'percent') pct = Math.min(100, Math.max(0, u.value))
    else if (u.unit === 'usd' && u.limit && u.limit > 0) pct = Math.min(100, Math.max(0, (u.value / u.limit) * 100))
    else if (u.unit === 'credit_balance' && u.total && u.total > 0) {
      pct = Math.min(100, Math.max(0, ((u.total - u.remaining) / u.total) * 100))
    }
    if (pct !== null && (maxPct === null || pct > maxPct)) maxPct = pct
  }
  return maxPct
}

export interface PartitionedQuotas {
  readonly tier1ExhaustedOrCredits: readonly ProviderUsageScope[]
  readonly tier2ActiveSubscriptions: readonly ProviderUsageScope[]
  readonly tier3Unreported: readonly ProviderUsageScope[]
}

export function partitionQuotaScopes(
  scopes: readonly ProviderUsageScope[],
  restingProviders: ReadonlySet<string> = new Set(),
): PartitionedQuotas {
  const tier1: ProviderUsageScope[] = []
  const tier2: ProviderUsageScope[] = []
  const tier3: ProviderUsageScope[] = []

  for (const scope of scopes) {
    const cls = classifyQuotaScope(scope)
    const isResting = scope.providers.some((p) => restingProviders.has(p.id))
    const pct = maxUtilizationPct(scope)

    if (cls.kind === 'exhausted_zero' || cls.kind === 'amount' || isResting || (pct !== null && pct >= 90)) {
      tier1.push(scope)
    } else if (cls.kind === 'subscription_zero') {
      tier2.push(scope)
    } else {
      tier3.push(scope)
    }
  }

  return {
    tier1ExhaustedOrCredits: tier1,
    tier2ActiveSubscriptions: tier2,
    tier3Unreported: tier3,
  }
}

// ── Shared Formatting & Honest Observation Helpers ──

export function toObservedNumber(val: number | null | undefined, unreportedIfNull = false): Observed<number> {
  if (typeof val === 'number' && Number.isFinite(val)) return observedValue(val)
  return unreportedIfNull ? observedUnreported() : observedAbsent()
}

export function formatCompactNumber(val: number): string {
  if (!Number.isFinite(val)) return '없음'
  const abs = Math.abs(val)
  if (abs >= 1_000_000_000) return `${(val / 1_000_000_000).toFixed(2)}B`
  if (abs >= 1_000_000) return `${(val / 1_000_000).toFixed(2)}M`
  if (abs >= 1_000) return `${(val / 1_000).toFixed(1)}k`
  return Number.isInteger(val) ? String(val) : val.toFixed(1)
}

export function formatUsd(val: number): string {
  if (!Number.isFinite(val)) return '없음'
  if (val === 0) return '$0.00'
  if (Math.abs(val) < 0.01) return `$${val.toFixed(4)}`
  return `$${val.toFixed(2)}`
}

export function formatPercent(val: number): string {
  if (!Number.isFinite(val)) return '없음'
  return `${val.toFixed(1)}%`
}

export function formatMs(val: number): string {
  if (!Number.isFinite(val)) return '없음'
  if (val >= 1000) return `${(val / 1000).toFixed(2)}s`
  return `${Math.round(val)}ms`
}

export function formatUnixTime(unixSec: number | null | undefined): string {
  if (typeof unixSec !== 'number' || !Number.isFinite(unixSec) || unixSec <= 0) return '없음'
  const d = new Date(unixSec * 1000)
  return d.toISOString().replace('T', ' ').slice(5, 19)
}

export function formatResetCountdown(resetsAtUnix: number | null | undefined, nowUnix = Date.now() / 1000): string {
  if (typeof resetsAtUnix !== 'number' || !Number.isFinite(resetsAtUnix) || resetsAtUnix <= 0) return '없음'
  const diff = Math.max(0, Math.round(resetsAtUnix - nowUnix))
  if (diff === 0) return '리셋됨'
  const hours = Math.floor(diff / 3600)
  const mins = Math.floor((diff % 3600) / 60)
  if (hours >= 24) return `${Math.floor(hours / 24)}d ${hours % 24}h`
  if (hours > 0) return `${hours}h ${mins}m`
  return `${mins}m`
}

export function windowKindLabel(kind: ProviderUsageWindowKind): string {
  switch (kind.kind) {
    case 'five_hour': return '5h'
    case 'seven_day': return '7d'
    case 'duration_minutes': return `${kind.minutes}m`
    case 'provider_label': return kind.label
  }
}

export function snapshotUnavailableReason(obs: Observed<unknown>): string | null {
  if (obs.kind === 'failed') return obs.error.message
  if (obs.kind === 'absent' || obs.kind === 'unreported') return obs.reason ?? '응답을 확인할 수 없습니다.'
  return null
}

// ── Single-user view SSE ──

export function openViewSseStream(
  url: string,
  signal: AbortSignal,
  onFrame: (frame: ObserverFrame) => void,
  onStatus?: (status: 'open' | 'error' | 'closed', detail?: string) => void,
  fetchImpl: typeof fetch = globalThis.fetch,
): void {
  if (authSession.peek().kind !== 'single_user_local') return
  const startEpoch = currentSessionEpoch()
  const sseInstanceId = getObserverSseInstanceId()
  if (!sseInstanceId) {
    onStatus?.('closed', 'observer_instance_pending')
    return
  }
  const resolvedUrl = resolveWorkspaceUrl(url)
  const headers: Record<string, string> = {
    Accept: 'text/event-stream',
    [OBSERVER_SSE_INSTANCE_HEADER]: sseInstanceId,
  }
  const token = getSingleUserToken()
  if (token) headers.Authorization = `Bearer ${token}`

  void (async () => {
    try {
      const res = await fetchImpl(resolvedUrl, {
        method: 'GET',
        credentials: 'same-origin',
        headers,
        signal,
      })
      if (signal.aborted || !isEpochCurrent(startEpoch)) return
      if (!res.ok || !res.body) {
        onStatus?.('error', `HTTP ${res.status}`)
        return
      }
      onStatus?.('open')
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      try {
        while (!signal.aborted && isEpochCurrent(startEpoch)) {
          const { value, done } = await reader.read()
          if (done) break
          if (signal.aborted || !isEpochCurrent(startEpoch)) break
          buffer += decoder.decode(value, { stream: true })
          const blocks = buffer.split(/\r?\n\r?\n/)
          buffer = blocks.pop() ?? ''
          for (const block of blocks) {
            if (signal.aborted || !isEpochCurrent(startEpoch)) return
            const frame = parseSseBlock(block)
            if (frame) onFrame(frame)
          }
        }
      } finally {
        reader.releaseLock()
      }
      if (!signal.aborted && isEpochCurrent(startEpoch)) onStatus?.('closed')
    } catch (err) {
      if (!signal.aborted && isEpochCurrent(startEpoch)) {
        onStatus?.('error', err instanceof Error ? err.message : String(err))
      }
    }
  })()
}
