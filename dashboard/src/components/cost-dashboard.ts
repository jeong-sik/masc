// MASC Dashboard — O4 · Cost & Latency dashboard
//
// Phase 2 spec (`design-system/preview/cb-group-f.jsx:CostPerAgent`)
// renders a 4-cell totals header (cost / tokens / p50 / p95) plus a
// per-agent table with cost bar + p95 latency bar. Production has
// rich cost + latency telemetry on `DashboardRuntimeModelMetric`
// (`/api/v1/models/metrics`) but no surface that consolidates it
// into a "where is the money going / where is the latency going" view.
//
// Production renders per-model rather than per-agent (cost is naturally
// tracked by model in OAS pipelines), but the spec's intent — quick
// scan of cost / latency hotspots — is preserved.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import {
  fetchRuntimeModelMetrics,
  type DashboardRuntimeModelMetric,
} from '../api/dashboard'
import { LoadingState, ErrorState } from './common/feedback-state'

type LoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: DashboardRuntimeModelMetric[]; windowMinutes: number }
  | { status: 'error'; message: string }

const state = signal<LoadState>({ status: 'idle' })

const WINDOW_OPTIONS: Array<{ key: number; label: string }> = [
  { key: 30, label: '30분' },
  { key: 60, label: '1시간' },
  { key: 360, label: '6시간' },
  { key: 1440, label: '24시간' },
]

const windowMinutes = signal<number>(60)

async function loadMetrics(window: number) {
  state.value = { status: 'loading' }
  try {
    const resp = await fetchRuntimeModelMetrics(window, 5)
    state.value = {
      status: 'loaded',
      data: resp.models,
      windowMinutes: resp.window_minutes ?? window,
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'cost metrics 불러오기 실패'
    state.value = { status: 'error', message }
  }
}

const totals = computed(() => {
  const s = state.value
  if (s.status !== 'loaded') return null
  const data = s.data
  let totalCost = 0
  let totalIn = 0
  let totalOut = 0
  let p50Sum = 0
  let p50Count = 0
  let p95Max = 0
  for (const m of data) {
    totalCost += m.total_cost_usd ?? 0
    totalIn += m.total_input_tokens ?? 0
    totalOut += m.total_output_tokens ?? 0
    if (m.p50_latency_ms != null) {
      p50Sum += m.p50_latency_ms
      p50Count += 1
    }
    if (m.p95_latency_ms != null && m.p95_latency_ms > p95Max) p95Max = m.p95_latency_ms
  }
  const p50Avg = p50Count > 0 ? Math.round(p50Sum / p50Count) : 0
  return { totalCost, totalIn, totalOut, p50Avg, p95Max, count: data.length }
})

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return `${n}`
}

function StatCell({
  label, value, sub, tone,
}: {
  label: string
  value: string
  sub?: string
  tone?: 'ok' | 'warn' | 'err' | 'default'
}) {
  const toneClass =
    tone === 'err' ? 'text-[var(--color-status-err)]'
      : tone === 'warn' ? 'text-[var(--color-status-warn)]'
      : tone === 'ok' ? 'text-[var(--color-status-ok)]'
      : 'text-text-strong'
  return html`
    <div class="flex flex-col gap-0.5 rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <span class="text-2xs uppercase tracking-1 text-text-muted">${label}</span>
      <span class="text-lg font-semibold ${toneClass}">${value}</span>
      ${sub ? html`<span class="text-2xs text-text-disabled">${sub}</span>` : null}
    </div>
  `
}

function ModelRow({
  model, maxCost, maxP95,
}: {
  model: DashboardRuntimeModelMetric
  maxCost: number
  maxP95: number
}) {
  const cost = model.total_cost_usd ?? 0
  const inTok = model.total_input_tokens ?? 0
  const outTok = model.total_output_tokens ?? 0
  const p50 = model.p50_latency_ms ?? null
  const p95 = model.p95_latency_ms ?? null
  const costPct = maxCost > 0 ? (cost / maxCost) * 100 : 0
  const p95Pct = maxP95 > 0 && p95 != null ? (p95 / maxP95) * 100 : 0
  const overBudget = p95 != null && p95 > 8000

  return html`
    <tr class="border-b border-[var(--color-border-default)]/40 align-baseline">
      <th scope="row" class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">
        ${model.model_id}
      </th>
      <td class="px-2 py-1.5 text-right font-mono text-xs">${formatTokens(inTok)}</td>
      <td class="px-2 py-1.5 text-right font-mono text-xs">${formatTokens(outTok)}</td>
      <td class="px-2 py-1.5 text-right font-mono text-xs text-[var(--color-accent-fg)]">
        $${cost.toFixed(2)}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-sm bg-[var(--color-bg-surface)]">
          <div class="h-full rounded-sm bg-[var(--color-accent-fg)]" style=${`width: ${costPct.toFixed(1)}%`}></div>
        </div>
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${p50 == null ? 'text-text-disabled' : ''}">
        ${p50 == null ? '—' : `${p50}ms`}
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${overBudget ? 'text-[var(--color-status-err)]' : ''}">
        ${p95 == null ? html`<span class="text-text-disabled">—</span>` : `${p95}ms`}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-sm bg-[var(--color-bg-surface)]">
          <div
            class="h-full rounded-sm ${overBudget ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-status-warn)]'}"
            style=${`width: ${p95Pct.toFixed(1)}%`}
          ></div>
        </div>
      </td>
    </tr>
  `
}

export function CostDashboard() {
  if (state.value.status === 'idle') {
    void loadMetrics(windowMinutes.value)
  }

  if (state.value.status === 'loading') {
    return html`<${LoadingState}>cost / latency metrics 불러오는 중...<//>`
  }
  if (state.value.status === 'error') {
    return html`<${ErrorState} message=${state.value.message} />`
  }
  if (state.value.status !== 'loaded') return null

  const t = totals.value
  const data = state.value.data
    .slice()
    .sort((a, b) => (b.total_cost_usd ?? 0) - (a.total_cost_usd ?? 0))
  const maxCost = Math.max(0, ...data.map(m => m.total_cost_usd ?? 0))
  const maxP95 = Math.max(0, ...data.map(m => m.p95_latency_ms ?? 0))

  return html`
    <section class="flex flex-col gap-4" aria-label="비용 / 지연 대시보드">
      <header class="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-text-strong">비용 / 지연 대시보드</h2>
          <p class="text-2xs text-text-muted">최근 ${state.value.windowMinutes}분 · 모델별 토큰 / 비용 / latency</p>
        </div>
        <div class="flex gap-1" role="radiogroup" aria-label="시간 창">
          ${WINDOW_OPTIONS.map(o => html`
            <button
              key=${o.key}
              type="button"
              role="radio"
              aria-checked=${windowMinutes.value === o.key}
              class="rounded border px-2 py-0.5 text-2xs ${windowMinutes.value === o.key
                ? 'border-accent/50 bg-[var(--accent-15)] text-accent'
                : 'border-card-border/40 text-text-muted hover:border-card-border/60'}"
              onClick=${() => { windowMinutes.value = o.key; void loadMetrics(o.key) }}
            >
              ${o.label}
            </button>
          `)}
        </div>
      </header>

      ${t ? html`
        <div class="grid grid-cols-2 gap-2 md:grid-cols-4">
          <${StatCell}
            label="Total Cost"
            value=${`$${t.totalCost.toFixed(2)}`}
            sub=${`${t.count} models`}
            tone="ok"
          />
          <${StatCell}
            label="Tokens In / Out"
            value=${`${formatTokens(t.totalIn)} / ${formatTokens(t.totalOut)}`}
            sub="aggregated window"
          />
          <${StatCell}
            label="p50 Latency (avg)"
            value=${`${t.p50Avg}ms`}
            sub="across models"
          />
          <${StatCell}
            label="p95 Latency (max)"
            value=${`${t.p95Max}ms`}
            sub=${t.p95Max > 8000 ? 'over 8s budget' : 'within budget'}
            tone=${t.p95Max > 8000 ? 'err' : 'default'}
          />
        </div>
      ` : null}

      ${data.length === 0 ? html`
        <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-6 text-center text-sm text-text-muted">
          이 시간 창에서 기록된 모델 비용이 없습니다.
        </div>
      ` : html`
        <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
          <table class="w-full" aria-label=${`${data.length}개 모델의 비용 / 지연`}>
            <thead>
              <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
                <th scope="col" class="px-2 py-1.5 text-left">model</th>
                <th scope="col" class="px-2 py-1.5 text-right">in tok</th>
                <th scope="col" class="px-2 py-1.5 text-right">out tok</th>
                <th scope="col" class="px-2 py-1.5 text-right">$ cost</th>
                <th scope="col" class="px-2 py-1.5 text-left">cost</th>
                <th scope="col" class="px-2 py-1.5 text-right">p50</th>
                <th scope="col" class="px-2 py-1.5 text-right">p95</th>
                <th scope="col" class="px-2 py-1.5 text-left">p95 trend</th>
              </tr>
            </thead>
            <tbody>
              ${data.map(m => html`<${ModelRow} key=${m.model_id} model=${m} maxCost=${maxCost} maxP95=${maxP95} />`)}
            </tbody>
          </table>
        </div>
      `}
    </section>
  `
}
