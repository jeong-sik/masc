import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchRuntimeModelMetrics,
  fetchRuntimeProviders,
  type DashboardRuntimeModelMetric,
  type DashboardRuntimeModelMetricsResponse,
  type DashboardRuntimeProviderSnapshot,
  type DashboardRuntimeProvidersResponse,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'
import { TextInput } from './common/input'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'

/**
 * Filters model metrics by case-insensitive substring match against
 * `model_id` and any `top_tools[].tool` name. Empty/whitespace query
 * returns the input reference unchanged (ref-equal). No mutation.
 */
export function filterModelMetrics(
  models: readonly DashboardRuntimeModelMetric[],
  query: string,
): readonly DashboardRuntimeModelMetric[] {
  const trimmed = query.trim().toLowerCase()
  if (trimmed.length === 0) return models
  return models.filter(m => {
    if (m.model_id.toLowerCase().includes(trimmed)) return true
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
 * 4. model_id asc
 * Returns a new array; does not mutate the input.
 */
export function sortModelMetricsByUrgency(
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

async function loadRuntimeData(resource: ManagedAsyncResource<RuntimeData>, windowMinutes: number) {
  await resource.load(async (signal) => {
    const [providers, metrics] = await Promise.all([
      fetchRuntimeProviders({ signal }),
      fetchRuntimeModelMetrics(windowMinutes, 5, { signal }),
    ])
    return { providers, metrics }
  })
}

// Current-reachability axis: does the provider respond right now?
// Orthogonal to cascade-config-panel.ts:providerTone which scores historical
// performance (success_rate, cooldown). Both signals can be shown together
// without being duplicates.
export function runtimeProviderTone(provider: DashboardRuntimeProviderSnapshot): string {
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

export function modelMetricTone(metric: DashboardRuntimeModelMetric): string {
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

export function fmtCost(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  if (value === 0) return '$0'
  if (value < 0.01) return `$${value.toFixed(4)}`
  return `$${value.toFixed(2)}`
}

export function fmtSuccessRate(metric: DashboardRuntimeModelMetric): string {
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total === 0) return '--'
  const pct = (success / total) * 100
  return `${pct.toFixed(1)}%`
}

export function fmtNumber(value?: number | null, digits = 0): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  return value.toLocaleString('ko-KR', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })
}

function fmtTime(tsUnix: number): string {
  if (tsUnix <= 0) return '--'
  const d = new Date(tsUnix * 1000)
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

function fmtPct(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  return `${(value * 100).toFixed(1)}%`
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
  return `<svg width="${w}" height="${h}" class="inline-block align-middle" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg"><polyline fill="none" stroke="${color}" stroke-width="1.5" stroke-linejoin="round" points="${points}"/></svg>`
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
  return '--'
}

function fmtCoverageAwareNumber(
  metric: DashboardRuntimeModelMetric,
  value?: number | null,
  digits = 0,
): string {
  const formatted = fmtNumber(value, digits)
  return formatted !== '--' ? formatted : metricMissingLabel(metric)
}

function fmtCoverageAwareCost(metric: DashboardRuntimeModelMetric, value?: number | null): string {
  const formatted = fmtCost(value)
  return formatted !== '--' ? formatted : metricMissingLabel(metric)
}

export function recentEntryMissingLabel(
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
  const formatted = fmtNumber(value, digits)
  return formatted !== '--' ? formatted : recentEntryMissingLabel(entry)
}

function fmtRecentEntryCost(
  entry: NonNullable<DashboardRuntimeModelMetric['recent_entries']>[number],
  value?: number | null,
): string {
  const formatted = fmtCost(value)
  return formatted !== '--' ? formatted : recentEntryMissingLabel(entry)
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

export function metricCoverageText(metric: DashboardRuntimeModelMetric): string | null {
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
    `usage ${fmtNumber(usageCount)}/${fmtNumber(successCount)}`,
    `telemetry ${fmtNumber(telemetryCount)}/${fmtNumber(successCount)}`,
  ].filter((value): value is string => Boolean(value))
  return parts.length > 0 ? parts.join(' · ') : null
}

export function RuntimeMonitor() {
  const resource = useManagedAsyncResource<RuntimeData>()
  const windowMinutes = useSignal(30)
  const expandedModel = useSignal<string | null>(null)
  const modelSearch = useSignal('')

  const load = () => loadRuntimeData(resource, windowMinutes.value)

  useEffect(() => {
    void loadRuntimeData(resource, windowMinutes.value)
    return () => {
      resource.cancel()
    }
  }, [resource, windowMinutes.value])

  const current = resource.state.value
  const providers = current.data?.providers ?? null
  const metrics = current.data?.metrics ?? null

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <select
          class="rounded border border-[var(--color-border-default)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)]"
          value=${String(windowMinutes.value)}
          onChange=${(e: Event) => { windowMinutes.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="15">15분</option>
          <option value="30">30분</option>
          <option value="60">60분</option>
          <option value="180">180분</option>
        </select>
        <button
          class="rounded border border-[var(--color-border-default)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]"
          onClick=${() => void load()}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]">로딩 중...</span>` : null}
      </div>

      ${current.error
        ? html`<${ErrorState} message=${current.error} />`
        : null}

      ${current.loading && !providers && !metrics
        ? html`<${LoadingState}>runtime snapshot 불러오는 중...<//>`
        : null}

      <${Card} title="프로바이더 런타임">
        <div class="grid grid-cols-2 gap-3 mb-4">
          <${StatCell}
            label="프로바이더"
            value=${providers?.summary?.providers ?? providers?.providers.length ?? 0}
            detail=${providers?.updated_at ?? 'updated_at 없음'}
          />
          <${StatCell}
            label="로컬 모델"
            value=${providers?.summary?.local_models ?? 0}
            detail=${`Cloud ${providers?.summary?.cloud_models ?? 0} · CLI ${providers?.summary?.cli_models ?? 0}`}
          />
        </div>
        <div class="flex flex-col gap-3">
          ${(providers?.providers ?? []).length > 0
            ? providers?.providers.map(provider => html`
                <article class="p-4 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm flex flex-col gap-2">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-sm text-text-strong">${provider.provider}</strong>
                      <span class="text-xs text-text-muted">${provider.runtime_kind ?? 'runtime'} · ${provider.auth_kind ?? 'auth'} · ${provider.source ?? 'source unknown'}</span>
                    </div>
                    <${StatusChip}
                      label=${provider.status ?? (provider.available ? 'available' : 'unknown')}
                      tone=${runtimeProviderTone(provider)}
                    />
                  </div>
                  <div class="grid grid-cols-2 gap-3 text-xs text-text-body">
                    <div>default model · ${provider.default_model ?? '없음'}</div>
                    <div>catalog · ${provider.models.join(', ') || '없음'}</div>
                    <div>single-run · ${provider.supports_single_agent_run ? 'yes' : 'no'}</div>
                    <div>endpoint · ${provider.endpoint_url ?? '없음'}</div>
                  </div>
                  ${provider.discovery
                    ? html`<div class="grid grid-cols-2 gap-3 text-xs text-text-body pt-2 border-t border-card-border/50">
                        <div>discovery · ${provider.discovery.healthy ? 'healthy' : 'degraded'}</div>
                        <div>ctx · ${fmtNumber(provider.discovery.ctx_size)}</div>
                        <div>slots · ${fmtNumber(provider.discovery.busy_slots)}/${fmtNumber(provider.discovery.total_slots)}</div>
                        <div>model · ${provider.discovery.discovered_model ?? '없음'}</div>
                      </div>`
                    : null}
                  ${provider.note ? html`<div class="text-xs text-text-muted">${provider.note}</div>` : null}
                </article>
              `)
            : html`<${EmptyState} message="provider runtime snapshot이 없습니다." compact />`}
        </div>
      <//>

      <${Card} title="모델 메트릭">
        <div class="grid grid-cols-3 gap-3 mb-4">
          <${StatCell}
            label="텔레메트리 윈도우"
            value=${`${metrics?.window_minutes ?? windowMinutes.value}m`}
            detail=${`항목 ${fmtNumber(metrics?.total_entries ?? 0)}`}
          />
          <${StatCell}
            label="추적 중인 모델"
            value=${metrics?.models.length ?? 0}
            detail=${`오류 ${fmtNumber(metrics?.total_error_entries ?? 0)}`}
          />
          <${StatCell}
            label="총 비용"
            value=${fmtCost(sumNullable((metrics?.models ?? []).map(m => m.total_cost_usd)))}
            detail=${`${fmtNumber(metrics?.models.reduce((sum, m) => sum + (m.total_tool_calls ?? 0), 0))} tool calls`}
          />
        </div>
        <div class="flex items-center justify-end mb-2">
          <${TextInput}
            type="search"
            ariaLabel="모델 ID 검색"
            placeholder="model_id 또는 도구 이름"
            class="min-w-55 flex-1 !py-1 !text-2xs"
            value=${modelSearch.value}
            onInput=${(e: Event) => { modelSearch.value = (e.target as HTMLInputElement).value }}
          />
        </div>
        ${(metrics?.models ?? []).length > 0 && filterModelMetrics(metrics?.models ?? [], modelSearch.value).length === 0
          ? html`<div class="text-2xs text-[var(--color-fg-muted)] mb-2">검색 결과 없음 (${metrics?.models.length ?? 0}개 중)</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(metrics?.models ?? []).length > 0
            ? sortModelMetricsByUrgency(filterModelMetrics(metrics?.models ?? [], modelSearch.value)).map(metric => {
                const isFailing = (metric.error_count ?? 0) > 0
                const hasCoverageGap =
                  metric.coverage_status === 'none'
                  || metric.coverage_status === 'partial'
                  || metric.coverage_status === 'error_only'
                let articleClass = 'p-4 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm flex flex-col gap-2'
                if (isFailing) {
                  articleClass = 'p-4 rounded border border-[var(--status-bad)] bg-[var(--status-bad)]/5 backdrop-blur-sm shadow-sm flex flex-col gap-2'
                } else if (hasCoverageGap) {
                  articleClass = 'p-4 rounded border border-[var(--status-warn)] bg-[var(--status-warn)]/5 backdrop-blur-sm shadow-sm flex flex-col gap-2'
                }
                const ariaLabel = isFailing
                  ? `Provider failing: ${metric.model_id}, ${metric.error_count ?? 0} errors out of ${metric.entry_count ?? 0}`
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
                      <strong class="text-sm text-text-strong">${metric.model_id}</strong>
                      <span class="text-xs text-text-muted">entries ${fmtNumber(metric.entry_count)} · fallback ${fmtNumber(metric.fallback_count)}</span>
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
                            label=${`${fmtNumber(metric.avg_tok_per_sec, 1)} tok/s wall`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.prompt_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${fmtNumber(metric.prompt_avg_tok_per_sec, 1)} tok/s prefill`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.hw_decode_avg_tok_per_sec != null
                        ? html`<${StatusChip}
                            label=${`${fmtNumber(metric.hw_decode_avg_tok_per_sec, 1)} tok/s hw`}
                            tone=${'ok'}
                          />`
                        : null}
                      ${metric.thinking_fraction != null
                        ? html`<${StatusChip}
                            label=${`think ${fmtNumber((metric.thinking_fraction ?? 0) * 100, 0)}%`}
                            tone=${(metric.thinking_fraction ?? 0) > 0.5 ? 'warn' : 'ok'}
                          />`
                        : null}
                    </div>
                  </div>
                  <div class="grid grid-cols-3 gap-3 text-xs text-text-body">
                    <div>latency avg/p95 · ${fmtCoverageAwareNumber(metric, metric.avg_latency_ms, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_latency_ms, 1)} ms</div>
                    <div>wall tok/s p50/p95 · ${fmtCoverageAwareNumber(metric, metric.p50_tok_per_sec, 1)} / ${fmtCoverageAwareNumber(metric, metric.p95_tok_per_sec, 1)}</div>
                    <div>cost · ${fmtCoverageAwareCost(metric, metric.total_cost_usd)}</div>
                    <div>input/output · ${fmtCoverageAwareNumber(metric, metric.total_input_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_output_tokens)}</div>
                    <div>reasoning/cache · ${fmtCoverageAwareNumber(metric, metric.total_reasoning_tokens)} / ${fmtCoverageAwareNumber(metric, metric.total_cache_read_tokens)}</div>
                    <div>tools · ${fmtNumber(metric.avg_tool_calls_per_turn, 1)}/turn (${fmtNumber(metric.total_tool_calls)})</div>
                    ${metric.prompt_p50_tok_per_sec != null || metric.prompt_p95_tok_per_sec != null
                      ? html`<div class="col-span-3 text-text-muted">prefill tok/s p50/p95 · ${fmtNumber(metric.prompt_p50_tok_per_sec, 1)} / ${fmtNumber(metric.prompt_p95_tok_per_sec, 1)} (prompt_eval only; complements wall + hw rows)</div>`
                      : null}
                    ${metric.hw_decode_p50_tok_per_sec != null
                      ? html`<div class="col-span-3 text-text-muted">hw tok/s p50/p95 · ${fmtNumber(metric.hw_decode_p50_tok_per_sec, 1)} / ${fmtNumber(metric.hw_decode_p95_tok_per_sec, 1)} (decode-only; excludes queue/prefill/thinking)</div>`
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
                        <span dangerouslySetInnerHTML=${{ __html: sparklineSvg(latencySeries, 'var(--status-warn)', 80, 18) }}></span>
                        <span>error rate</span>
                        <span dangerouslySetInnerHTML=${{ __html: sparklineSvg(errorSeries, 'var(--status-bad)', 80, 18) }}></span>
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
                      cost ${fmtCoverageAwareCost(metric, metric.total_cost_usd)} · cache savings ${fmtPct(cacheRatio)} (${fmtCoverageAwareNumber(metric, cacheRead)} / ${fmtCoverageAwareNumber(metric, totalIn)} tokens)
                    </div>`
                  })()}
                  ${(metric.error_count ?? 0) > 0
                    ? html`<div class="text-2xs text-[var(--status-bad)] mt-1">errors ${fmtNumber(metric.error_count)} / success ${fmtNumber(metric.success_count)}</div>`
                    : null}
                  ${(metric.top_tools ?? []).length > 0
                    ? html`<div class="flex flex-wrap gap-1 mt-1">
                        ${metric.top_tools?.slice(0, 5).map(t => html`
                          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]">
                            ${t.tool} <span class="ml-0.5 text-[var(--color-fg-secondary)]">${t.count}</span>
                          </span>
                        `)}
                      </div>`
                    : null}
                  ${(metric.recent_entries ?? []).length > 0
                    ? html`
                      <button
                        class="text-2xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] mt-1 text-left"
                        onClick=${() => { expandedModel.value = expandedModel.value === metric.model_id ? null : metric.model_id }}
                      >
                        ${expandedModel.value === metric.model_id ? '▾' : '▸'} recent ${metric.recent_entries?.length ?? 0} turns
                      </button>
                      ${expandedModel.value === metric.model_id
                        ? html`<div class="mt-1 border-t border-card-border/50 pt-2">
                            <div class="grid grid-cols-7 gap-1 text-3xs text-[var(--color-fg-muted)] font-medium mb-1">
                              <div>time</div><div>in tok</div><div>out tok</div><div>latency</div><div>prefill tok/s</div><div>cost</div><div>tools</div>
                            </div>
                            ${metric.recent_entries?.map(re => {
                              const detail = recentEntryDetail(re)
                              return html`
                                <div class="mb-1">
                                  <div class="grid grid-cols-7 gap-1 text-2xs text-[var(--color-fg-primary)]">
                                    <div>${fmtTime(re.ts_unix)}</div>
                                    <div>${fmtRecentEntryNumber(re, re.input_tokens)}</div>
                                    <div>${fmtRecentEntryNumber(re, re.output_tokens)}</div>
                                    <div>${re.latency_ms == null ? recentEntryMissingLabel(re) : `${fmtNumber(re.latency_ms, 0)}ms`}</div>
                                    <div>${fmtRecentEntryNumber(re, re.prompt_tok_per_sec, 1)}</div>
                                    <div>${fmtRecentEntryCost(re, re.cost_usd)}</div>
                                    <div>${re.tools_count}</div>
                                  </div>
                                  ${detail
                                    ? html`<div class="text-3xs text-[var(--color-fg-muted)]">${detail}</div>`
                                    : null}
                                </div>
                              `
                            })}
                          </div>`
                        : null}
                    `
                    : null}
                </article>
              `
              })
            : html`<${EmptyState} message="최근 model inference metrics가 없습니다." compact />`}
        </div>
      <//>
    </div>
  `
}
