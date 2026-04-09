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
import { LoadingState } from './common/feedback-state'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'

interface RuntimeState {
  providers: DashboardRuntimeProvidersResponse | null
  metrics: DashboardRuntimeModelMetricsResponse | null
  loading: boolean
  error: string | null
}

function providerTone(provider: DashboardRuntimeProviderSnapshot): string {
  if (provider.available === false) return 'bad'
  if (provider.discovery?.healthy === false) return 'warn'
  if (provider.available === true) return 'ok'
  return 'warn'
}

function modelMetricTone(metric: DashboardRuntimeModelMetric): string {
  if ((metric.entry_count ?? 0) <= 0) return 'warn'
  if ((metric.fallback_count ?? 0) > 0) return 'warn'
  return 'ok'
}

function fmtNumber(value?: number | null, digits = 0): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '--'
  return value.toLocaleString('ko-KR', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })
}

export function RuntimeMonitor() {
  const state = useSignal<RuntimeState>({
    providers: null,
    metrics: null,
    loading: true,
    error: null,
  })
  const windowMinutes = useSignal(30)

  async function load() {
    state.value = { ...state.value, loading: true, error: null }
    try {
      const [providers, metrics] = await Promise.all([
        fetchRuntimeProviders(),
        fetchRuntimeModelMetrics(windowMinutes.value),
      ])
      state.value = {
        providers,
        metrics,
        loading: false,
        error: null,
      }
    } catch (error) {
      state.value = {
        ...state.value,
        loading: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }

  useEffect(() => {
    void load()
  }, [windowMinutes.value])

  const providers = state.value.providers
  const metrics = state.value.metrics

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
          Refresh
        </button>
        ${state.value.loading ? html`<span class="text-xs text-[var(--text-muted)]">loading...</span>` : null}
      </div>

      ${state.value.error
        ? html`<div class="rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">${state.value.error}</div>`
        : null}

      ${state.value.loading && !providers && !metrics
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
        <div class="grid grid-cols-2 gap-3 mb-4">
          <${StatCell}
            label="Telemetry Window"
            value=${`${metrics?.window_minutes ?? windowMinutes.value}m`}
            detail=${`entries ${metrics?.total_entries ?? 0}`}
          />
          <${StatCell}
            label="Tracked Models"
            value=${metrics?.models.length ?? 0}
            detail="append-only telemetry와 분리된 runtime snapshot"
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
                    <${StatusChip}
                      label=${`${fmtNumber(metric.avg_tok_per_sec, 1)} tok/s`}
                      tone=${modelMetricTone(metric)}
                    />
                  </div>
                  <div class="grid grid-cols-2 gap-3 text-[12px] text-text-body">
                    <div>latency avg/p95 · ${fmtNumber(metric.avg_latency_ms, 1)} / ${fmtNumber(metric.p95_latency_ms, 1)} ms</div>
                    <div>tok/s p50/p95 · ${fmtNumber(metric.p50_tok_per_sec, 1)} / ${fmtNumber(metric.p95_tok_per_sec, 1)}</div>
                    <div>input/output · ${fmtNumber(metric.total_input_tokens)} / ${fmtNumber(metric.total_output_tokens)}</div>
                    <div>reasoning/cache-read · ${fmtNumber(metric.total_reasoning_tokens)} / ${fmtNumber(metric.total_cache_read_tokens)}</div>
                  </div>
                </article>
              `)
            : html`<${EmptyState} message="최근 model inference metrics가 없습니다." compact />`}
        </div>
      <//>
    </div>
  `
}
