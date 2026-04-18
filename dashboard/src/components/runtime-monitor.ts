import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchRuntimeModelMetrics,
  fetchRuntimeProviders,
  type BucketMetric,
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
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

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
 * Sorts model metrics so failing providers surface first. Order:
 * 1. error_count desc (a model with 11 errors appears before one with 0)
 * 2. entry_count desc (more-exercised models appear above idle ones)
 * 3. model_id asc (stable tiebreaker)
 * Returns a new array; does not mutate the input.
 */
export function sortModelMetricsByUrgency(
  models: readonly DashboardRuntimeModelMetric[],
): readonly DashboardRuntimeModelMetric[] {
  return [...models].sort((a, b) => {
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

function fmtPct(value: number): string {
  if (Number.isNaN(value)) return '--'
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

export function RuntimeMonitor() {
  const resourceRef = useRef<ManagedAsyncResource<RuntimeData> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<RuntimeData>()
  }
  const resource = resourceRef.current
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
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
          value=${String(windowMinutes.value)}
          onChange=${(e: Event) => { windowMinutes.value = Number((e.target as HTMLSelectElement).value) }}
        >
          <option value="15">15분</option>
          <option value="30">30분</option>
          <option value="60">60분</option>
          <option value="180">180분</option>
        </select>
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void load()}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
      </div>

      ${current.error
        ? html`<${ErrorState} message=${current.error} />`
        : null}

      ${current.loading && !providers && !metrics
        ? html`<${LoadingState}>runtime snapshot 불러오는 중...<//>`
        : null}

      <${Card} title="Provider Runtime">
        <div class="grid grid-cols-2 gap-3 mb-4">
          <${StatCell}
            label="Providers"
            value=${providers?.summary?.providers ?? providers?.providers.length ?? 0}
            detail=${providers?.updated_at ?? 'updated_at 없음'}
          />
          <${StatCell}
            label="Local Models"
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

      <${Card} title="Model Metrics">
        <div class="grid grid-cols-3 gap-3 mb-4">
          <${StatCell}
            label="Telemetry Window"
            value=${`${metrics?.window_minutes ?? windowMinutes.value}m`}
            detail=${`entries ${fmtNumber(metrics?.total_entries ?? 0)}`}
          />
          <${StatCell}
            label="Tracked Models"
            value=${metrics?.models.length ?? 0}
            detail=${`errors ${fmtNumber(metrics?.total_error_entries ?? 0)}`}
          />
          <${StatCell}
            label="Total Cost"
            value=${fmtCost(metrics?.models.reduce((sum, m) => sum + (m.total_cost_usd ?? 0), 0))}
            detail=${`${fmtNumber(metrics?.models.reduce((sum, m) => sum + (m.total_tool_calls ?? 0), 0))} tool calls`}
          />
        </div>
        <div class="flex items-center justify-end mb-2">
          <${TextInput}
            type="search"
            ariaLabel="모델 ID 검색"
            placeholder="model_id 또는 도구 이름"
            class="min-w-[220px] flex-1 !py-1 !text-2xs"
            value=${modelSearch.value}
            onInput=${(e: Event) => { modelSearch.value = (e.target as HTMLInputElement).value }}
          />
        </div>
        ${(metrics?.models ?? []).length > 0 && filterModelMetrics(metrics?.models ?? [], modelSearch.value).length === 0
          ? html`<div class="text-2xs text-[var(--text-muted)] mb-2">검색 결과 없음 (${metrics?.models.length ?? 0}개 중)</div>`
          : null}
        <div class="flex flex-col gap-3">
          ${(metrics?.models ?? []).length > 0
            ? sortModelMetricsByUrgency(filterModelMetrics(metrics?.models ?? [], modelSearch.value)).map(metric => {
                const isFailing = (metric.error_count ?? 0) > 0
                const articleClass = isFailing
                  ? 'p-4 rounded border border-[var(--status-bad)] bg-[var(--status-bad)]/5 backdrop-blur-sm shadow-sm flex flex-col gap-2'
                  : 'p-4 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm flex flex-col gap-2'
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
                    </div>
                    <div class="flex gap-2 items-center">
                      <${StatusChip}
                        label=${`${fmtSuccessRate(metric)}`}
                        tone=${modelMetricTone(metric)}
                      />
                      <${StatusChip}
                        label=${`${fmtNumber(metric.avg_tok_per_sec, 1)} tok/s wall`}
                        tone=${'ok'}
                      />
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
                    <div>latency avg/p95 · ${fmtNumber(metric.avg_latency_ms, 1)} / ${fmtNumber(metric.p95_latency_ms, 1)} ms</div>
                    <div>wall tok/s p50/p95 · ${fmtNumber(metric.p50_tok_per_sec, 1)} / ${fmtNumber(metric.p95_tok_per_sec, 1)}</div>
                    <div>cost · ${fmtCost(metric.total_cost_usd)}</div>
                    <div>input/output · ${fmtNumber(metric.total_input_tokens)} / ${fmtNumber(metric.total_output_tokens)}</div>
                    <div>reasoning/cache · ${fmtNumber(metric.total_reasoning_tokens)} / ${fmtNumber(metric.total_cache_read_tokens)}</div>
                    <div>tools · ${fmtNumber(metric.avg_tool_calls_per_turn, 1)}/turn (${fmtNumber(metric.total_tool_calls)})</div>
                    ${metric.hw_decode_p50_tok_per_sec != null
                      ? html`<div class="col-span-3 text-text-muted">hw tok/s p50/p95 · ${fmtNumber(metric.hw_decode_p50_tok_per_sec, 1)} / ${fmtNumber(metric.hw_decode_p95_tok_per_sec, 1)} (decode-only; excludes queue/prefill/thinking)</div>`
                      : null}
                  </div>
                  ${(metric.buckets ?? []).length >= 2
                    ? html`<div class="flex items-center gap-4 mt-1 text-2xs text-[var(--text-muted)]">
                        <span>p95 latency</span>
                        <span dangerouslySetInnerHTML=${{ __html: sparklineSvg((metric.buckets as BucketMetric[]).map(b => b.p95_latency_ms), 'var(--status-warn)', 80, 18) }}></span>
                        <span>error rate</span>
                        <span dangerouslySetInnerHTML=${{ __html: sparklineSvg((metric.buckets as BucketMetric[]).map(b => b.error_rate), 'var(--status-bad)', 80, 18) }}></span>
                      </div>`
                    : null}
                  ${(() => {
                    const cacheRead = metric.total_cache_read_tokens ?? 0
                    const totalIn = cacheRead + (metric.total_input_tokens ?? 0)
                    const cacheRatio = totalIn > 0 ? cacheRead / totalIn : 0
                    return html`<div class="text-2xs text-[var(--text-muted)] mt-1">
                      cost ${fmtCost(metric.total_cost_usd)} · cache savings ${fmtPct(cacheRatio)} (${fmtNumber(cacheRead)} / ${fmtNumber(totalIn)} tokens)
                    </div>`
                  })()}
                  ${(metric.error_count ?? 0) > 0
                    ? html`<div class="text-2xs text-[var(--status-bad)] mt-1">errors ${fmtNumber(metric.error_count)} / success ${fmtNumber(metric.success_count)}</div>`
                    : null}
                  ${(metric.top_tools ?? []).length > 0
                    ? html`<div class="flex flex-wrap gap-1 mt-1">
                        ${metric.top_tools?.slice(0, 5).map(t => html`
                          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-3xs bg-[var(--bg-panel-hover)] text-[var(--text-muted)]">
                            ${t.tool} <span class="ml-0.5 text-[var(--text-strong)]">${t.count}</span>
                          </span>
                        `)}
                      </div>`
                    : null}
                  ${(metric.recent_entries ?? []).length > 0
                    ? html`
                      <button
                        class="text-2xs text-[var(--text-muted)] hover:text-[var(--text-strong)] mt-1 text-left"
                        onClick=${() => { expandedModel.value = expandedModel.value === metric.model_id ? null : metric.model_id }}
                      >
                        ${expandedModel.value === metric.model_id ? '▾' : '▸'} recent ${metric.recent_entries?.length ?? 0} turns
                      </button>
                      ${expandedModel.value === metric.model_id
                        ? html`<div class="mt-1 border-t border-card-border/50 pt-2">
                            <div class="grid grid-cols-6 gap-1 text-3xs text-[var(--text-muted)] font-medium mb-1">
                              <div>time</div><div>in tok</div><div>out tok</div><div>latency</div><div>cost</div><div>tools</div>
                            </div>
                            ${metric.recent_entries?.map(re => html`
                              <div class="grid grid-cols-6 gap-1 text-2xs text-[var(--text-body)]">
                                <div>${fmtTime(re.ts_unix)}</div>
                                <div>${fmtNumber(re.input_tokens)}</div>
                                <div>${fmtNumber(re.output_tokens)}</div>
                                <div>${fmtNumber(re.latency_ms, 0)}ms</div>
                                <div>${fmtCost(re.cost_usd)}</div>
                                <div>${re.tools_count}</div>
                              </div>
                            `)}
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
