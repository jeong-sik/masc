import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchDashboardRuntimeProbe,
  fetchRuntimeModelMetrics,
  fetchRuntimeProviders,
  type DashboardRuntimeProbeResponse,
  type DashboardRuntimeModelMetric,
  type DashboardRuntimeModelMetricsResponse,
  type DashboardRuntimeProviderProbe,
  type DashboardRuntimeProviderSnapshot,
  type DashboardRuntimeProvidersResponse,
} from '../api/dashboard'
import { ActionButton } from './common/button'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { Select } from './common/select'
import { StatTile } from './common/stat-tile'
import { StatusChip } from './common/status-chip'
import { TextInput } from './common/input'
import { Table, type TableColumn } from './common/table'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { formatCost, formatNumber, formatPct1 } from '../lib/format-number'
import { errorToString, MISSING_DATA_DASH } from '../lib/format-string'
import { formatTimeHms } from '../lib/format-time'

/**
 * Filters model metrics by case-insensitive substring match against
 * visible `top_tools[].tool` names. Empty/whitespace query
 * returns the input reference unchanged (ref-equal). No mutation.
 */
function filterModelMetrics(
  models: readonly DashboardRuntimeModelMetric[],
  query: string,
): readonly DashboardRuntimeModelMetric[] {
  const trimmed = query.trim().toLowerCase()
  if (trimmed.length === 0) return models
  return models.filter(m => {
    const tools = m.top_tools ?? []
    for (const t of tools) {
      if (t.tool.toLowerCase().includes(trimmed)) return true
    }
    return false
  })
}

/**
 * Sorts model metrics so coverage gaps and failures surface first. Order:
 * 1. coverage_status urgency (error_only → none → partial → full)
 * 2. error_count desc
 * 3. entry_count desc
 * 4. stable internal id asc
 * Returns a new array; does not mutate the input.
 */
function sortModelMetricsByUrgency(
  models: readonly DashboardRuntimeModelMetric[],
): readonly DashboardRuntimeModelMetric[] {
  return [...models].sort((a, b) => {
    const aCoverage = COVERAGE_PRIORITY[a.coverage_status ?? 'full'] ?? 3
    const bCoverage = COVERAGE_PRIORITY[b.coverage_status ?? 'full'] ?? 3
    if (aCoverage !== bCoverage) return aCoverage - bCoverage
    const ae = a.error_count ?? 0
    const be = b.error_count ?? 0
    if (ae !== be) return be - ae
    const ac = a.entry_count ?? 0
    const bc = b.entry_count ?? 0
    if (ac !== bc) return bc - ac
    return a.model_id.localeCompare(b.model_id)
  })
}

interface RuntimeData {
  providers: DashboardRuntimeProvidersResponse | null
  metrics: DashboardRuntimeModelMetricsResponse | null
  probe: DashboardRuntimeProbeResponse | null
  probeError: string | null
}

const COVERAGE_PRIORITY: Record<string, number> = {
  error_only: 0,
  none: 1,
  partial: 2,
  full: 3,
}

const COVERAGE_LABELS: Record<string, string> = {
  error_only: 'error-only',
  none: 'coverage missing',
  partial: 'coverage partial',
  full: 'coverage full',
}

const COVERAGE_REASON_LABELS: Record<string, string> = {
  error_turn: 'error turn',
  missing_usage_and_inference: 'usage/inference missing',
  missing_usage: 'usage missing',
  missing_inference: 'inference missing',
  untrusted_usage: 'usage untrusted',
  text_only_unmetered: 'text-only n/a',
  unknown: 'unknown reason',
}

const COVERAGE_STAGE_LABELS: Record<string, string> = {
  oas: 'OAS',
  keeper: 'keeper',
  projection: 'projection',
  unknown: 'unknown stage',
}

async function loadRuntimeData(
  resource: ManagedAsyncResource<RuntimeData>,
  windowMinutes: number,
  forceProbe = false,
) {
  await resource.load(async (signal) => {
    const probeResult = fetchDashboardRuntimeProbe(forceProbe, { signal })
      .then(probe => ({ probe, probeError: null }))
      .catch(error => ({ probe: null, probeError: errorToString(error) }))
    const [providers, metrics, probe] = await Promise.all([
      fetchRuntimeProviders({ signal }),
      fetchRuntimeModelMetrics(windowMinutes, 5, { signal }),
      probeResult,
    ])
    return { providers, metrics, probe: probe.probe, probeError: probe.probeError }
  })
}

// Current-reachability axis: does the provider respond right now?
// Orthogonal to runtime-config-panel.ts:providerTone which scores historical
// performance (success_rate, cooldown). Both signals can be shown together
// without being duplicates.
function runtimeProviderTone(provider: DashboardRuntimeProviderSnapshot): string {
  const advertised = provider.status?.trim().toLowerCase()
  if (advertised === 'missing_auth' || advertised === 'unsupported' || advertised === 'offline') {
    return 'bad'
  }
  if (advertised === 'vertex_adc') {
    return 'warn'
  }
  if (provider.available === false) return 'bad'
  if (provider.discovery?.healthy === false) return 'warn'
  if (provider.available === true) return 'ok'
  return 'warn'
}

function runtimeStatusLabel(provider: DashboardRuntimeProviderSnapshot): string {
  const advertised = provider.status?.trim().toLowerCase()
  if (advertised === 'missing_auth') return 'missing auth'
  if (advertised === 'unsupported') return 'unsupported'
  if (advertised === 'offline') return 'offline'
  if (provider.available === true) return 'available'
  if (provider.available === false) return 'unavailable'
  return provider.discovery?.healthy === false ? 'degraded' : 'unknown'
}

function runtimeParameterPolicyText(provider: DashboardRuntimeProviderSnapshot): string | null {
  const policy = provider.parameter_policy
  if (!policy) return null
  const parts = [
    policy.reasoning_toggle_wire ? `wire ${policy.reasoning_toggle_wire}` : null,
    policy.reasoning_replay_policy ? `replay ${policy.reasoning_replay_policy}` : null,
    policy.ignored_sampling_params.length > 0
      ? `ignored ${policy.ignored_sampling_params.join(',')}`
      : null,
    policy.always_ignored_sampling_params.length > 0
      ? `always ignored ${policy.always_ignored_sampling_params.join(',')}`
      : null,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

function providerProbeKey(probe: DashboardRuntimeProviderProbe): string | null {
  return probe.runtime_id ?? null
}

function providerRuntimeKey(provider: DashboardRuntimeProviderSnapshot): string {
  return provider.runtime_id ?? provider.provider
}

function runtimeProbeTone(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe) return 'neutral'
  if (probe.reachable === true) return 'ok'
  if (probe.status === 'skipped_cli') return 'neutral'
  if (probe.status === 'missing_auth' || probe.status === 'auth_failed') return 'bad'
  if (probe.status === 'network_error' || probe.status === 'server_error') return 'bad'
  if (probe.reachable === false) return 'bad'
  return 'warn'
}

function runtimeProbeLabel(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe) return 'not probed'
  switch (probe.status) {
    case 'reachable':
      return 'reachable'
    case 'missing_auth':
      return 'missing auth'
    case 'auth_failed':
      return 'auth failed'
    case 'network_error':
      return 'network error'
    case 'server_error':
      return 'server error'
    case 'endpoint_not_found':
      return 'not found'
    case 'skipped_cli':
      return 'cli skipped'
    case 'invalid_endpoint':
      return 'bad endpoint'
    default:
      return probe.status ?? 'unknown'
  }
}

function runtimeProbeAuthLabel(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (probe?.credential_required !== true) return 'none'
  return probe.auth_present === true ? 'present' : 'missing'
}

function runtimeProbeSummaryText(probe: DashboardRuntimeProbeResponse | null): string {
  const summary = probe?.probe?.summary
  if (!summary) return 'live probe 없음'
  return `Reachable ${summary.reachable ?? 0} · Failed ${summary.failed ?? 0} · Skipped ${summary.skipped ?? 0}`
}

function providerProbeMap(probe: DashboardRuntimeProbeResponse | null): Map<string, DashboardRuntimeProviderProbe> {
  const map = new Map<string, DashboardRuntimeProviderProbe>()
  for (const item of probe?.probe?.providers ?? []) {
    const key = providerProbeKey(item)
    if (key) map.set(key, item)
  }
  return map
}

function fmtProbeLatency(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  if (!probe || probe.latency_ms == null) return MISSING_DATA_DASH
  return `${formatNumber(probe.latency_ms, 1)} ms`
}

function fmtProbeHttpStatus(probe: DashboardRuntimeProviderProbe | null | undefined): string {
  return probe?.http_status == null ? MISSING_DATA_DASH : String(probe.http_status)
}

function modelMetricTone(metric: DashboardRuntimeModelMetric): string {
  if ((metric.entry_count ?? 0) <= 0) return 'warn'
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total > 0) {
    const rate = success / total
    if (rate < 0.85) return 'bad'
    if (rate < 0.95) return 'warn'
  }
  if ((metric.fallback_count ?? 0) > 0) return 'warn'
  return 'ok'
}


function fmtSuccessRate(metric: DashboardRuntimeModelMetric): string {
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total === 0) return MISSING_DATA_DASH
  const pct = (success / total) * 100
  return `${pct.toFixed(1)}%`
}


function sparklineSvg(values: number[], color: string, w = 80, h = 20): string {
  if (values.length < 2) return ''
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const points = values.map((v, i) => {
    const x = (i / (values.length - 1)) * w
    const y = h - ((v - min) / range) * (h - 2) - 1
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
  return `<svg aria-hidden="true" width="${w}" height="${h}" class="inline-block align-middle" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg"><polyline fill="none" stroke="${color}" stroke-width="1.5" stroke-linejoin="round" points="${points}"/></svg>`
}

function sumNullable(values: Array<number | null | undefined>): number | null {
  let sawNumber = false
  let total = 0
  for (const value of values) {
    if (typeof value === 'number' && !Number.isNaN(value)) {
      sawNumber = true
      total += value
    }
  }
  return sawNumber ? total : null
}

function coverageStatusLabel(status?: DashboardRuntimeModelMetric['coverage_status']): string | null {
  if (!status) return null
  return COVERAGE_LABELS[status] ?? status
}

function coverageReasonLabel(reason?: string | null): string | null {
  if (!reason) return null
  return COVERAGE_REASON_LABELS[reason] ?? reason
}

function coverageStageLabel(stage?: string | null): string | null {
  if (!stage) return null
  return COVERAGE_STAGE_LABELS[stage] ?? stage
}

function metricCoverageTone(metric: DashboardRuntimeModelMetric): string {
  switch (metric.coverage_status) {
    case 'full':
      return 'ok'
    case 'partial':
      return 'warn'
    case 'none':
    case 'error_only':
      return 'bad'
    default:
      return 'warn'
  }
}

function metricMissingLabel(metric: DashboardRuntimeModelMetric): string {
  if (metric.coverage_status === 'error_only') return 'error-only'
  if (metric.primary_coverage_reason === 'text_only_unmetered') return 'n/a'
  if (metric.coverage_status === 'none') return 'missing'
  if (metric.coverage_status === 'partial') return 'partial'
  return MISSING_DATA_DASH
}

function fmtCoverageAwareNumber(
  metric: DashboardRuntimeModelMetric,
  value?: number | null,
  digits = 0,
): string {
  const formatted = formatNumber(value, digits)
  return formatted !== MISSING_DATA_DASH ? formatted : metricMissingLabel(metric)
}

function fmtCoverageAwareCost(metric: DashboardRuntimeModelMetric, value?: number | null): string {
  const formatted = formatCost(value)
  return formatted !== MISSING_DATA_DASH ? formatted : metricMissingLabel(metric)
}

function recentEntryMissingLabel(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
): string {
  // Order: most-specific to least-specific.
  // Goal: make "why is this cell empty?" observable instead of rendering an
  // opaque `--`. The `telemetry_reported`/`usage_reported` flags land earlier
  // in the response than `coverage_reason`, so they give the most direct
  // signal when the cell is empty due to missing OAS timings vs. missing
  // per-turn usage accounting.
  if (entry.outcome === 'error') return 'error-only'
  if (entry.usage_trust === 'untrusted') return 'untrusted'
  if (entry.coverage_reason === 'text_only_unmetered') return 'n/a'
  if (entry.telemetry_reported === false && entry.usage_reported === false)
    return 'no-telemetry'
  if (entry.telemetry_reported === false) return 'no-timings'
  if (entry.usage_reported === false) return 'no-usage'
  if (entry.coverage_reason) return 'missing'
  return '—'
}

function fmtRecentEntryNumber(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
  value?: number | null,
  digits = 0,
): string {
  const formatted = formatNumber(value, digits)
  return formatted !== MISSING_DATA_DASH ? formatted : recentEntryMissingLabel(entry)
}

function fmtRecentEntryCost(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
  value?: number | null,
): string {
  const formatted = formatCost(value)
  return formatted !== MISSING_DATA_DASH ? formatted : recentEntryMissingLabel(entry)
}

function recentEntryDetail(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
): string | null {
  const parts = [
    entry.outcome?.trim(),
    entry.usage_trust === 'untrusted'
      ? [
          'usage untrusted',
          ...(entry.usage_anomaly_reasons ?? []),
        ].join(': ')
      : null,
    coverageStageLabel(entry.coverage_stage),
    coverageReasonLabel(entry.coverage_reason),
    entry.turn_lane?.trim(),
    entry.stop_reason?.trim(),
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

type RecentEntry = NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number]

const recentEntryColumns: TableColumn<RecentEntry>[] = [
  {
    key: 'time',
    header: 'time',
    render: (re) => {
      const detail = recentEntryDetail(re)
      return html`
        <div>
          <div>${re.ts_unix > 0 ? formatTimeHms(re.ts_unix) : MISSING_DATA_DASH}</div>
          ${detail ? html`<div class="text-3xs text-[var(--color-fg-muted)] mt-0.5">${detail}</div>` : null}
        </div>
      `
    },
  },
  { key: 'input_tokens', header: 'in tok', render: (re) => fmtRecentEntryNumber(re, re.input_tokens) },
  { key: 'output_tokens', header: 'out tok', render: (re) => fmtRecentEntryNumber(re, re.output_tokens) },
  {
    key: 'latency_ms',
    header: 'latency',
    render: (re) => re.latency_ms == null ? recentEntryMissingLabel(re) : `${formatNumber(re.latency_ms, 0)}ms`,
  },
  { key: 'prompt_tok_per_sec', header: 'prefill tok/s', render: (re) => fmtRecentEntryNumber(re, re.prompt_tok_per_sec, 1) },
  { key: 'cost_usd', header: 'cost', render: (re) => fmtRecentEntryCost(re, re.cost_usd) },
  { key: 'tools_count', header: 'tools', render: (re) => String(re.tools_count) },
]

function metricCoverageText(metric: DashboardRuntimeModelMetric): string | null {
  if (metric.coverage_status === 'full' && metric.primary_coverage_reason == null) return null
  if (metric.coverage_status === 'error_only') return 'error-only window'
  const successCount = metric.success_count ?? 0
  if (successCount <= 0) return null
  const usageCount = metric.usage_sample_count ?? 0
  const telemetryCount = metric.telemetry_sample_count ?? 0
  if (
    metric.coverage_status == null
    && usageCount >= successCount
    && telemetryCount >= successCount
  ) return null
  const parts = [
    coverageStatusLabel(metric.coverage_status),
    coverageStageLabel(metric.primary_coverage_stage),
    coverageReasonLabel(metric.primary_coverage_reason),
    `usage ${formatNumber(usageCount)}/${formatNumber(successCount)}`,
    `telemetry ${formatNumber(telemetryCount)}/${formatNumber(successCount)}`,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

export function RuntimeMonitor() {
  const resource = useManagedAsyncResource<RuntimeData>()
  const windowMinutes = useSignal(30)
  const expandedModel = useSignal<string | null>(null)
  const modelSearch = useSignal('')

  const load = (forceProbe = false) => loadRuntimeData(resource, windowMinutes.value, forceProbe)

  useEffect(() => {
    void loadRuntimeData(resource, windowMinutes.value)
    return () => {
      resource.cancel()
    }
  }, [resource, windowMinutes.value])

  const current = resource.state.value
  const providers = current.data?.providers ?? null
  const metrics = current.data?.metrics ?? null
  const probe = current.data?.probe ?? null
  const probeError = current.data?.probeError ?? null
  const providerProbes = providerProbeMap(probe)

  // filterModelMetrics was called twice per render (no-results check + the
  // sorted list) with identical args. Memoize once and reuse so it runs at most
  // once per render — only re-deriving when the metrics payload or the search
  // term changes.
  const filteredModels = useMemo(
    () => filterModelMetrics(metrics?.models ?? [], modelSearch.value),
    [metrics, modelSearch.value],
  )
  const sortedModels = useMemo(
    () => sortModelMetricsByUrgency(filteredModels),
    [filteredModels],
  )

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <${Select}
          class="px-2 py-1 text-xs"
          value=${String(windowMinutes.value)}
          ariaLabel="시간 윈도우 선택"
          options=${[
            { value: '15', label: '15분' },
            { value: '30', label: '30분' },
            { value: '60', label: '60분' },
            { value: '180', label: '180분' },
          ]}
          onInput=${(v: string) => { windowMinutes.value = Number(v) }}
        />
        <${ActionButton}
          variant="ghost"
          size="sm"
          ariaLabel="runtime snapshot 새로고침"
          onClick=${() => void load(true)}
        >새로고침<//>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
      </div>

      ${current.error
        ? html`<${ErrorState} message=${current.error} />`
        : null}

      ${current.loading && !providers && !metrics
        ? html`<${LoadingState}>runtime snapshot 불러오는 중...<//>`
        : null}

      <${SectionCard} label="런타임 상태">
        ${probeError
          ? html`<div class="mb-3 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 px-3 py-2 text-xs text-[var(--status-warn)]">
              live probe 실패 · ${probeError}
            </div>`
          : null}
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-4">
          <${StatTile}
            label="런타임"
            value=${String(providers?.summary?.runtimes ?? providers?.providers.length ?? 0)}
            delta=${{ direction: 'flat', text: `Providers ${providers?.summary?.providers ?? 0} · ${providers?.updated_at ?? 'updated_at 없음'}` }}
          />
          <${StatTile}
            label="로컬 런타임"
            value=${String(providers?.summary?.local_models ?? 0)}
            delta=${{ direction: 'flat', text: `Cloud ${providers?.summary?.cloud_models ?? 0} · CLI ${providers?.summary?.cli_models ?? 0}` }}
          />
          <${StatTile}
            label="Live reachability"
            value=${String(probe?.probe?.summary?.reachable ?? 0)}
            delta=${{ direction: probe?.probe?.summary?.failed ? 'down' : 'flat', text: runtimeProbeSummaryText(probe) }}
          />
        </div>
        ${providers?.config_path
          ? html`<div class="mb-3 break-all font-mono text-2xs text-[var(--color-fg-muted)]">config · ${providers.config_path}</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(providers?.providers ?? []).length > 0
            ? providers?.providers.map(provider => {
                const liveProbe = providerProbes.get(providerRuntimeKey(provider)) ?? null
                const parameterPolicy = runtimeParameterPolicyText(provider)
                return html`
                <article class="v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/40 backdrop-blur-sm flex flex-col gap-2">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-sm text-[var(--color-fg-primary)]">${provider.runtime_id ?? provider.provider}</strong>
                      <span class="text-xs text-[var(--color-fg-muted)]">${provider.provider_id ?? '(unknown provider)'}</span>
                    </div>
                    <div class="flex items-center gap-2 flex-wrap justify-end">
                      <${StatusChip} tone=${runtimeProviderTone(provider)}>${runtimeStatusLabel(provider)}<//>
                      <${StatusChip} tone=${runtimeProbeTone(liveProbe)} uppercase=${false}>live ${runtimeProbeLabel(liveProbe)}<//>
                    </div>
                  </div>
                  <div class="grid grid-cols-2 gap-3 text-xs text-[var(--color-fg-secondary)]">
                    <div>model · ${provider.model_api_name ?? provider.model_id ?? '-'}</div>
                    <div>default · ${provider.is_default_runtime ? 'yes' : 'no'}</div>
                    <div>transport · ${provider.runtime_kind ?? provider.transport ?? '-'}</div>
                    <div>ctx · ${formatNumber(provider.max_context)}</div>
                    <div>http · ${fmtProbeHttpStatus(liveProbe)}</div>
                    <div>latency · ${fmtProbeLatency(liveProbe)}</div>
                    <div>models · ${formatNumber(liveProbe?.model_count)}</div>
                    <div>auth · ${runtimeProbeAuthLabel(liveProbe)}</div>
                  </div>
                  ${liveProbe?.probe_url || provider.endpoint_url
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${liveProbe?.probe_url ?? provider.endpoint_url ?? ''}>
                        probe · ${liveProbe?.probe_url ?? provider.endpoint_url}
                      </div>`
                    : null}
                  ${parameterPolicy
                    ? html`<div class="truncate text-2xs text-[var(--color-fg-muted)]" title=${parameterPolicy}>
                        params · ${parameterPolicy}
                      </div>`
                    : null}
                  ${liveProbe?.error
                    ? html`<div class="text-2xs text-[var(--status-bad)]">${liveProbe.error}</div>`
                    : null}
                  ${provider.discovery
                    ? html`<div class="grid grid-cols-2 gap-3 text-xs text-[var(--color-fg-secondary)] pt-2 border-t border-[var(--color-border-default)]/50">
                        <div>discovery · ${provider.discovery.healthy ? 'healthy' : 'degraded'}</div>
                        <div>ctx · ${formatNumber(provider.discovery.ctx_size)}</div>
                        <div>slots · ${formatNumber(provider.discovery.busy_slots)}/${formatNumber(provider.discovery.total_slots)}</div>
                      </div>`
                    : null}
                </article>
              `})
            : html`<${EmptyState} message="runtime snapshot이 없습니다." compact />`}
        </div>
      <//>

      <${SectionCard} label="런타임 메트릭">
        <div class="grid grid-cols-3 gap-3 mb-4">
          <${StatTile}
            label="텔레메트리 윈도우"
            value=${`${metrics?.window_minutes ?? windowMinutes.value}m`}
            delta=${{ direction: 'flat', text: `항목 ${formatNumber(metrics?.total_entries ?? 0)}` }}
          />
          <${StatTile}
            label="추적 중인 런타임"
            value=${String(metrics?.models.length ?? 0)}
            delta=${{ direction: 'flat', text: `오류 ${formatNumber(metrics?.total_error_entries ?? 0)}` }}
          />
          <${StatTile}
            label="총 비용"
            value=${formatCost(sumNullable((metrics?.models ?? []).map(m => m.total_cost_usd)))}
            delta=${{ direction: 'flat', text: `${formatNumber(metrics?.models.reduce((sum, m) => sum + (m.total_tool_calls ?? 0), 0))} tool calls` }}
          />
        </div>
        <div class="flex items-center justify-end mb-2">
          <${TextInput}
            type="search"
            ariaLabel="런타임 도구 검색"
            placeholder="도구 이름"
            class="min-w-55 flex-1 !py-1 !text-2xs"
            value=${modelSearch.value}
            onInput=${(e: Event) => { modelSearch.value = (e.target as HTMLInputElement).value }}
          />
        </div>
        ${(metrics?.models ?? []).length > 0 && filteredModels.length === 0
          ? html`<div class="text-2xs text-[var(--color-fg-muted)] mb-2">검색 결과 없음 (${metrics?.models.length ?? 0}개 중)</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(metrics?.models ?? []).length > 0
            ? sortedModels.map(metric => {
                const isFailing = (metric.error_count ?? 0) > 0
                const hasCoverageGap =
                  metric.coverage_status === 'none'
                  || metric.coverage_status === 'partial'
                  || metric.coverage_status === 'error_only'
                let articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/40 backdrop-blur-sm flex flex-col gap-2'
                if (isFailing) {
                  articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--status-bad)] bg-[var(--status-bad)]/5 backdrop-blur-sm flex flex-col gap-2'
                } else if (hasCoverageGap) {
                  articleClass = 'v2-monitoring-card p-4 rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--status-warn)]/5 backdrop-blur-sm flex flex-col gap-2'
                }
                const runtimeLabel = metric.model_id
                const ariaLabel = isFailing
                  ? `Runtime failing: ${runtimeLabel}, ${metric.error_count ?? 0} errors out of ${metric.entry_count ?? 0}`
                  : undefined
                return html`
                <article
                  key=${metric.model_id}
                  class=${articleClass}
                  role=${isFailing ? 'alert' : undefined}
                  aria-label=${ariaLabel}
                >
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-sm text-[var(--color-fg-primary)]">${runtimeLabel}</strong>
                      <span class="text-xs text-[var(--color-fg-muted)]">entries ${formatNumber(metric.entry_count)} · fallback ${formatNumber(metric.fallback_count)}</span>
                      ${metricCoverageText(metric)
                        ? html`<span class="text-2xs ${hasCoverageGap ? 'text-[var(--status-warn)]' : 'text-[var(--color-fg-muted)]'}">${metricCoverageText(metric)}</span>`
                        : null}
                    </div>
                    <div class="flex gap-2 items-center">
                      ${metric.coverage_status
                        ? html`<${StatusChip}
                            label=${coverageStatusLabel(metric.coverage_status) ?? metric.coverage_status}
                            tone=${metricCoverageTone(metric)}
                          />`
                        : null}
                      <${StatusChip}
                        label=${`${fmtSuccessRate(metric)}`}
                        tone=${modelMetricTone(metric)}
                      />
                      ${metric.avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.avg_tok_per_sec, 1)} tok/s wall`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.prompt_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.prompt_avg_tok_per_sec, 1)} tok/s prefill`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.hw_decode_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${formatNumber(metric.hw_decode_avg_tok_per_sec, 1)} tok/s hw`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.thinking_fraction != null
                        ? html`<${StatusChip}
                            label=${`think ${formatNumber((metric.thinking_fraction ?? 0) * 100, 0)}%`}
                            tone=${(metric.thinking_fraction ?? 0) > 0.5 ? 'warn' : 'ok'}
                          />`
                        : null}
                    </div>
                  </div>
                  <div class="grid grid-cols-3 gap-3 text-xs text-[var(--color-fg-secondary)]">
                    <div>latency avg/p95 · ${fmtCoverageAwareNumber(metric, metric.avg_latency_ms, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_latency_ms, 1)} ms</div>
                    <div>wall tok/s p50/p95 · ${fmtCoverageAwareNumber(metric, metric.p50_tok_per_sec, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_tok_per_sec, 1)}</div>
                    <div>cost · ${fmtCoverageAwareCost(metric, metric.total_cost_usd)}</div>
                    <div>input/output · ${fmtCoverageAwareNumber(metric, metric.total_input_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_output_tokens)}</div>
                    <div>reasoning/cache · ${fmtCoverageAwareNumber(metric, metric.total_reasoning_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_cache_read_tokens)}</div>
                    <div>tools · ${formatNumber(metric.avg_tool_calls_per_turn, 1)}/turn (${formatNumber(metric.total_tool_calls)})</div>
                    ${metric.prompt_p50_tok_per_sec != null || metric.prompt_p95_tok_per_sec != null
                      ? html`<div class="col-span-3 text-[var(--color-fg-muted)]">prefill tok/s p50/p95 · ${formatNumber(metric.prompt_p50_tok_per_sec, 1)} / ${formatNumber(metric.prompt_p95_tok_per_sec, 1)} (prompt_eval only; complements wall + hw rows)</div>`
                      : null}
                    ${metric.hw_decode_p50_tok_per_sec != null
                      ? html`<div class="col-span-3 text-[var(--color-fg-muted)]">hw tok/s p50/p95 · ${formatNumber(metric.hw_decode_p50_tok_per_sec, 1)} / ${formatNumber(metric.hw_decode_p95_tok_per_sec, 1)} (decode-only; excludes queue/prefill/thinking)</div>`
                      : null}
                  </div>
                  ${(() => {
                    const latencySeries = (metric.buckets ?? [])
                      .map(b => b.p95_latency_ms)
                      .filter((value): value is number => typeof value === 'number' && !Number.isNaN(value))
                    const errorSeries = (metric.buckets ?? [])
                      .map(b => b.error_rate)
                      .filter((value): value is number => typeof value === 'number' && !Number.isNaN(value))
                    if (latencySeries.length < 2 || errorSeries.length < 2) return null
                    return html`<div class="flex items-center gap-4 mt-1 text-2xs text-[var(--color-fg-muted)]">
                        <span>p95 latency</span>
                        <span aria-hidden="true" dangerouslySetInnerHTML=${{ __html: sparklineSvg(latencySeries, 'var(--status-warn)', 80, 18) }}></span>
                        <span>error rate</span>
                        <span aria-hidden="true" dangerouslySetInnerHTML=${{ __html: sparklineSvg(errorSeries, 'var(--status-bad)', 80, 18) }}></span>
                      </div>`
                  })()}
                  ${(() => {
                    const cacheRead = metric.total_cache_read_tokens
                    const inputTokens = metric.total_input_tokens
                    const hasCacheNumbers =
                      typeof cacheRead === 'number' && typeof inputTokens === 'number'
                    let cacheRatio: number | null = null
                    if (hasCacheNumbers) {
                      const totalTokens = cacheRead + inputTokens
                      cacheRatio = totalTokens > 0 ? cacheRead / totalTokens : 0
                    }
                    const totalIn =
                      hasCacheNumbers
                        ? cacheRead + inputTokens
                        : null
                    return html`<div class="text-2xs text-[var(--color-fg-muted)] mt-1">
                      cost ${fmtCoverageAwareCost(metric, metric.total_cost_usd)} · cache savings ${formatPct1(cacheRatio)} (${fmtCoverageAwareNumber(metric, cacheRead)} / ${fmtCoverageAwareNumber(metric, totalIn)} tokens)
                    </div>`
                  })()}
                  ${(metric.error_count ?? 0) > 0
                    ? html`<div class="text-2xs text-[var(--status-bad)] mt-1">errors ${formatNumber(metric.error_count)} / success ${formatNumber(metric.success_count)}</div>`
                    : null}
                  ${(metric.top_tools ?? []).length > 0
                    ? html`<div class="flex flex-wrap gap-1 mt-1">
                        ${metric.top_tools?.slice(0, 5).map(t => html`
                          <span class="inline-flex items-center px-1.5 py-0.5 rounded-[var(--r-1)] text-3xs bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]">
                            ${t.tool} <span class="ml-0.5 text-[var(--color-fg-secondary)]">${t.count}</span>
                          </span>
                        `)}
                      </div>`
                    : null}
                  ${(metric.recent_entries ?? []).length > 0
                    ? html`
                      <button
                        class="v2-monitoring-action text-2xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] mt-1 text-left"
                        onClick=${() => { expandedModel.value = expandedModel.value === metric.model_id ? null : metric.model_id }}
                      >
                        ${expandedModel.value === metric.model_id ? '▾' : '▸'} recent ${metric.recent_entries?.length ?? 0} turns
                      </button>
                      ${expandedModel.value === metric.model_id
                        ? html`<div class="mt-1 border-t border-[var(--color-border-default)]/50 pt-2">
                            <${Table}
                              columns=${recentEntryColumns}
                              rows=${metric.recent_entries ?? []}
                              getRowId=${(re: RecentEntry) => `${metric.model_id}-${re.ts_unix}`}
                            />
                          </div>`
                        : null}
                    `
                    : null}
                </article>
              `
              })
            : html`<${EmptyState} message="최근 runtime inference metrics가 없습니다." compact />`}
        </div>
      <//>
    </div>
  `
}
