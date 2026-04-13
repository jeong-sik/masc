import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
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
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

interface RuntimeData {
  providers: DashboardRuntimeProvidersResponse | null
  metrics: DashboardRuntimeModelMetricsResponse | null
}

async function loadRuntimeData(resource: ManagedAsyncResource<RuntimeData>, windowMinutes: number) {
  await resource.load(async (signal) => {
    const [providers, metrics] = await Promise.all([
      fetchRuntimeProviders({ signal }),
      fetchRuntimeModelMetrics(windowMinutes, { signal }),
    ])
    return { providers, metrics }
  })
}

function providerTone(provider: DashboardRuntimeProviderSnapshot): string {
  if (provider.available === false) return 'bad'
  if (provider.discovery?.healthy === false) return 'warn'
  if (provider.available === true) return 'ok'
  return 'warn'
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

function fmtCost(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  if (value === 0) return '$0'
  if (value < 0.01) return `$${value.toFixed(4)}`
  return `$${value.toFixed(2)}`
}

function fmtSuccessRate(metric: DashboardRuntimeModelMetric): string {
  const success = metric.success_count ?? metric.entry_count ?? 0
  const errors = metric.error_count ?? 0
  const total = success + errors
  if (total === 0) return '--'
  const pct = (success / total) * 100
  return `${pct.toFixed(1)}%`
}

function fmtNumber(value?: number | null, digits = 0): string {
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

export function RuntimeMonitor() {
  const resourceRef = useRef<ManagedAsyncResource<RuntimeData> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<RuntimeData>()
  }
  const resource = resourceRef.current
  const windowMinutes = useSignal(30)
  const expandedModel = useSignal<string | null>(null)

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
            detail=${`Cloud ${providers?.summary?.cloud_models ?? 0}`}
          />
        </div>
        <div class="flex flex-col gap-3">
          ${(providers?.providers ?? []).length > 0
            ? providers?.providers.map(provider => html`
                <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm flex flex-col gap-2">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-[13px] text-text-strong">${provider.provider}</strong>
                      <span class="text-[12px] text-text-muted">${provider.runtime_kind ?? 'runtime'} · ${provider.auth_kind ?? 'auth'} · ${provider.source ?? 'source unknown'}</span>
                    </div>
                    <${StatusChip}
                      label=${provider.status ?? (provider.available ? 'available' : 'unknown')}
                      tone=${providerTone(provider)}
                    />
                  </div>
                  <div class="grid grid-cols-2 gap-3 text-[12px] text-text-body">
                    <div>default model · ${provider.default_model ?? '없음'}</div>
                    <div>catalog · ${provider.models.join(', ') || '없음'}</div>
                    <div>single-run · ${provider.supports_single_agent_run ? 'yes' : 'no'}</div>
                    <div>endpoint · ${provider.endpoint_url ?? '없음'}</div>
                  </div>
                  ${provider.discovery
                    ? html`<div class="grid grid-cols-2 gap-3 text-[12px] text-text-body pt-2 border-t border-card-border/50">
                        <div>discovery · ${provider.discovery.healthy ? 'healthy' : 'degraded'}</div>
                        <div>ctx · ${fmtNumber(provider.discovery.ctx_size)}</div>
                        <div>slots · ${fmtNumber(provider.discovery.busy_slots)}/${fmtNumber(provider.discovery.total_slots)}</div>
                        <div>model · ${provider.discovery.discovered_model ?? '없음'}</div>
                      </div>`
                    : null}
                  ${provider.note ? html`<div class="text-[12px] text-text-muted">${provider.note}</div>` : null}
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
        <div class="flex flex-col gap-3">
          ${(metrics?.models ?? []).length > 0
            ? metrics?.models.map(metric => html`
                <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm flex flex-col gap-2">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <div class="grid gap-1">
                      <strong class="text-[13px] text-text-strong">${metric.model_id}</strong>
                      <span class="text-[12px] text-text-muted">entries ${fmtNumber(metric.entry_count)} · fallback ${fmtNumber(metric.fallback_count)}</span>
                    </div>
                    <div class="flex gap-2 items-center">
                      <${StatusChip}
                        label=${`${fmtSuccessRate(metric)}`}
                        tone=${modelMetricTone(metric)}
                      />
                      <${StatusChip}
                        label=${`${fmtNumber(metric.avg_tok_per_sec, 1)} tok/s`}
                        tone=${'ok'}
                      />
                    </div>
                  </div>
                  <div class="grid grid-cols-3 gap-3 text-[12px] text-text-body">
                    <div>latency avg/p95 · ${fmtNumber(metric.avg_latency_ms, 1)} / ${fmtNumber(metric.p95_latency_ms, 1)} ms</div>
                    <div>tok/s p50/p95 · ${fmtNumber(metric.p50_tok_per_sec, 1)} / ${fmtNumber(metric.p95_tok_per_sec, 1)}</div>
                    <div>cost · ${fmtCost(metric.total_cost_usd)}</div>
                    <div>input/output · ${fmtNumber(metric.total_input_tokens)} / ${fmtNumber(metric.total_output_tokens)}</div>
                    <div>reasoning/cache · ${fmtNumber(metric.total_reasoning_tokens)} / ${fmtNumber(metric.total_cache_read_tokens)}</div>
                    <div>tools · ${fmtNumber(metric.avg_tool_calls_per_turn, 1)}/turn (${fmtNumber(metric.total_tool_calls)})</div>
                  </div>
                  ${(metric.error_count ?? 0) > 0
                    ? html`<div class="text-[11px] text-[var(--status-bad)] mt-1">errors ${fmtNumber(metric.error_count)} / success ${fmtNumber(metric.success_count)}</div>`
                    : null}
                  ${(metric.top_tools ?? []).length > 0
                    ? html`<div class="flex flex-wrap gap-1 mt-1">
                        ${metric.top_tools?.slice(0, 5).map(t => html`
                          <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] bg-[var(--bg-panel-hover)] text-[var(--text-muted)]">
                            ${t.tool} <span class="ml-0.5 text-[var(--text-strong)]">${t.count}</span>
                          </span>
                        `)}
                      </div>`
                    : null}
                  ${(metric.recent_entries ?? []).length > 0
                    ? html`
                      <button
                        class="text-[11px] text-[var(--text-muted)] hover:text-[var(--text-strong)] mt-1 text-left"
                        onClick=${() => { expandedModel.value = expandedModel.value === metric.model_id ? null : metric.model_id }}
                      >
                        ${expandedModel.value === metric.model_id ? '▾' : '▸'} recent ${metric.recent_entries?.length ?? 0} turns
                      </button>
                      ${expandedModel.value === metric.model_id
                        ? html`<div class="mt-1 border-t border-card-border/50 pt-2">
                            <div class="grid grid-cols-6 gap-1 text-[10px] text-[var(--text-muted)] font-medium mb-1">
                              <div>time</div><div>in tok</div><div>out tok</div><div>latency</div><div>cost</div><div>tools</div>
                            </div>
                            ${metric.recent_entries?.map(re => html`
                              <div class="grid grid-cols-6 gap-1 text-[11px] text-[var(--text-body)]">
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
              `)
            : html`<${EmptyState} message="최근 model inference metrics가 없습니다." compact />`}
        </div>
      <//>
    </div>
  `
}
