// MASC Dashboard — O4 · Cost & Latency dashboard
//
// Phase 2 spec (`design-system/preview/cb-group-f.jsx:CostPerAgent`)
// renders a 4-cell totals header (cost / tokens / p50 / p95) plus a
// per-agent table with cost bar + p95 latency bar. Production has
// rich cost + latency telemetry on `DashboardRuntimeModelMetric`
// (`/api/v1/models/metrics`) but no surface that consolidates it
// into a "where is the money going / where is the latency going" view.
//
// This component now supports both per-model and per-keeper views,
// toggled via a segmented control. The per-keeper view consumes the
// new `/api/v1/dashboard/keeper-costs` endpoint.

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import {
  fetchRuntimeModelMetrics,
  fetchKeeperCostMetrics,
  type DashboardRuntimeModelMetric,
  type KeeperCostMetric,
} from '../api/dashboard'
import { LoadingState, ErrorState } from './common/feedback-state'

type ViewMode = 'model' | 'keeper'

type ModelLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: DashboardRuntimeModelMetric[]; windowMinutes: number }
  | { status: 'error'; message: string }

type KeeperLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: KeeperCostMetric[]; windowMinutes: number }
  | { status: 'error'; message: string }

const viewMode = signal<ViewMode>('model')
const modelState = signal<ModelLoadState>({ status: 'idle' })
const keeperState = signal<KeeperLoadState>({ status: 'idle' })

const WINDOW_OPTIONS: Array<{ key: number; label: string }> = [
  { key: 30, label: '30분' },
  { key: 60, label: '1시간' },
  { key: 360, label: '6시간' },
  { key: 1440, label: '24시간' },
]

const windowMinutes = signal<number>(60)

async function loadModelMetrics(window: number) {
  modelState.value = { status: 'loading' }
  try {
    const resp = await fetchRuntimeModelMetrics(window, 5)
    modelState.value = {
      status: 'loaded',
      data: resp.models,
      windowMinutes: resp.window_minutes ?? window,
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'cost metrics 불러오기 실패'
    modelState.value = { status: 'error', message }
  }
}

async function loadKeeperMetrics(window: number) {
  keeperState.value = { status: 'loading' }
  try {
    const resp = await fetchKeeperCostMetrics(window)
    keeperState.value = {
      status: 'loaded',
      data: resp.keepers,
      windowMinutes: resp.window_minutes ?? window,
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'keeper cost metrics 불러오기 실패'
    keeperState.value = { status: 'error', message }
  }
}

function loadActiveView(window: number) {
  if (viewMode.value === 'model') {
    void loadModelMetrics(window)
  } else {
    void loadKeeperMetrics(window)
  }
}

const modelTotals = computed(() => {
  const s = modelState.value
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

const keeperTotals = computed(() => {
  const s = keeperState.value
  if (s.status !== 'loaded') return null
  const data = s.data
  let totalCost = 0
  let totalIn = 0
  let totalOut = 0
  let p50Sum = 0
  let p50Count = 0
  let p95Max = 0
  for (const k of data) {
    totalCost += k.total_cost_usd
    totalIn += k.total_input_tokens
    totalOut += k.total_output_tokens
    if (k.p50_latency_ms != null) {
      p50Sum += k.p50_latency_ms
      p50Count += 1
    }
    if (k.p95_latency_ms != null && k.p95_latency_ms > p95Max) p95Max = k.p95_latency_ms
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

function KeeperRow({
  keeper, maxCost, maxP95,
}: {
  keeper: KeeperCostMetric
  maxCost: number
  maxP95: number
}) {
  const cost = keeper.total_cost_usd
  const inTok = keeper.total_input_tokens
  const outTok = keeper.total_output_tokens
  const p50 = keeper.p50_latency_ms
  const p95 = keeper.p95_latency_ms
  const costPct = maxCost > 0 ? (cost / maxCost) * 100 : 0
  const p95Pct = maxP95 > 0 && p95 != null ? (p95 / maxP95) * 100 : 0
  const overBudget = p95 != null && p95 > 8000
  const topModel = keeper.model_breakdown[0]

  return html`
    <tr class="border-b border-[var(--color-border-default)]/40 align-baseline">
      <th scope="row" class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">
        ${keeper.keeper_name}
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
        ${p50 == null ? '—' : `${Math.round(p50)}ms`}
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${overBudget ? 'text-[var(--color-status-err)]' : ''}">
        ${p95 == null ? html`<span class="text-text-disabled">—</span>` : `${Math.round(p95)}ms`}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-sm bg-[var(--color-bg-surface)]">
          <div
            class="h-full rounded-sm ${overBudget ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-status-warn)]'}"
            style=${`width: ${p95Pct.toFixed(1)}%`}
          ></div>
        </div>
      </td>
      <td class="px-2 py-1.5 text-left font-mono text-2xs text-text-muted">
        ${topModel ? `${topModel.model} ($${topModel.cost_usd.toFixed(2)})` : '—'}
      </td>
    </tr>
  `
}

function CostMatrix({ models }: { models: DashboardRuntimeModelMetric[] }) {
  const providers = Array.from(new Set(models.map(m => m.provider ?? 'unknown'))).sort()
  const modelIds = Array.from(new Set(models.map(m => m.model_id))).sort((a, b) => {
    const ca = models.find(m => m.model_id === a)?.total_cost_usd ?? 0
    const cb = models.find(m => m.model_id === b)?.total_cost_usd ?? 0
    return cb - ca
  })

  const grid: number[][] = providers.map(p =>
    modelIds.map(mid => {
      const match = models.find(m => m.model_id === mid && (m.provider ?? 'unknown') === p)
      return match?.total_cost_usd ?? 0
    })
  )

  const flat = grid.flat().filter(v => v > 0)
  const max = flat.length > 0 ? Math.max(...flat) : 0

  const zone = (v: number): string => {
    if (v === 0) return 'z0'
    const p = v / max
    if (p < 0.1) return 'z1'
    if (p < 0.3) return 'z2'
    if (p < 0.7) return 'z3'
    return 'z4'
  }

  const zoneClass = (z: string): string => {
    switch (z) {
      case 'z0': return 'bg-[var(--color-bg-surface)] text-text-disabled'
      case 'z1': return 'bg-[var(--accent-5)]/30 text-text-muted'
      case 'z2': return 'bg-[var(--accent-10)]/40 text-text-strong'
      case 'z3': return 'bg-[var(--accent-15)]/50 text-accent'
      case 'z4': return 'bg-[var(--color-accent-fg)] text-white'
      default: return ''
    }
  }

  return html`
    <section class="flex flex-col gap-2" aria-label="Provider × Model cost matrix">
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">provider × model · $ spent</span>
      </div>
      <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Provider by model cost matrix">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left"></th>
              ${modelIds.map(mid => html`<th scope="col" class="px-2 py-1.5 text-left font-mono text-xs">${mid}</th>`)}
            </tr>
          </thead>
          <tbody>
            ${providers.map((p, i) => html`
              <tr key=${p} class="border-b border-[var(--color-border-default)]/40">
                <th scope="row" class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${p}</th>
                ${(grid[i] ?? []).map((v, j) => {
                  const z = zone(v)
                  return html`
                    <td key=${j} class="px-2 py-1.5 text-right font-mono text-xs ${zoneClass(z)}">
                      ${v > 0 ? `$${v.toFixed(2)}` : '—'}
                    </td>
                  `
                })}
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </section>
  `
}

export function CostDashboard() {
  const activeState = viewMode.value === 'model' ? modelState.value : keeperState.value

  if (activeState.status === 'idle') {
    void loadActiveView(windowMinutes.value)
  }

  if (activeState.status === 'loading') {
    return html`<${LoadingState}>cost / latency metrics 불러오는 중...<//>`
  }
  if (activeState.status === 'error') {
    return html`<${ErrorState} message=${activeState.message} />`
  }
  if (activeState.status !== 'loaded') return null

  const t = viewMode.value === 'model' ? modelTotals.value : keeperTotals.value
  const data = activeState.data
    .slice()
    .sort((a, b) => (viewMode.value === 'model'
      ? (b as DashboardRuntimeModelMetric).total_cost_usd ?? 0 - ((a as DashboardRuntimeModelMetric).total_cost_usd ?? 0)
      : (b as KeeperCostMetric).total_cost_usd - (a as KeeperCostMetric).total_cost_usd))
  const maxCost = Math.max(0, ...data.map(m =>
    viewMode.value === 'model' ? ((m as DashboardRuntimeModelMetric).total_cost_usd ?? 0) : (m as KeeperCostMetric).total_cost_usd))
  const maxP95 = Math.max(0, ...data.map(m => {
    const p95 = viewMode.value === 'model' ? (m as DashboardRuntimeModelMetric).p95_latency_ms : (m as KeeperCostMetric).p95_latency_ms
    return p95 ?? 0
  }))

  return html`
    <section class="flex flex-col gap-4" aria-label="비용 / 지연 대시보드">
      <header class="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-text-strong">비용 / 지연 대시보드</h2>
          <p class="text-2xs text-text-muted">최근 ${activeState.windowMinutes}분 · ${viewMode.value === 'model' ? '모델별' : 'Keeper별'} 토큰 / 비용 / latency</p>
        </div>
        <div class="flex items-center gap-2">
          <div class="flex rounded border border-card-border/40 p-0.5" role="group" aria-label="보기 모드">
            <button
              type="button"
              role="radio"
              aria-checked=${viewMode.value === 'model'}
              class="rounded px-2 py-0.5 text-2xs ${viewMode.value === 'model'
                ? 'bg-[var(--accent-15)] text-accent'
                : 'text-text-muted hover:text-text-strong'}"
              onClick=${() => { viewMode.value = 'model'; void loadModelMetrics(windowMinutes.value) }}
            >
              모델
            </button>
            <button
              type="button"
              role="radio"
              aria-checked=${viewMode.value === 'keeper'}
              class="rounded px-2 py-0.5 text-2xs ${viewMode.value === 'keeper'
                ? 'bg-[var(--accent-15)] text-accent'
                : 'text-text-muted hover:text-text-strong'}"
              onClick=${() => { viewMode.value = 'keeper'; void loadKeeperMetrics(windowMinutes.value) }}
            >
              Keeper
            </button>
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
                onClick=${() => { windowMinutes.value = o.key; void loadActiveView(o.key) }}
              >
                ${o.label}
              </button>
            `)}
          </div>
        </div>
      </header>

      ${t ? html`
        <div class="grid grid-cols-2 gap-2 md:grid-cols-4">
          <${StatCell}
            label="Total Cost"
            value=${`$${t.totalCost.toFixed(2)}`}
            sub=${`${t.count} ${viewMode.value === 'model' ? 'models' : 'keepers'}`}
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
            sub="across entries"
          />
          <${StatCell}
            label="p95 Latency (max)"
            value=${`${t.p95Max}ms`}
            sub=${t.p95Max > 8000 ? 'over 8s budget' : 'within budget'}
            tone=${t.p95Max > 8000 ? 'err' : 'default'}
          />
        </div>
      ` : null}

      ${viewMode.value === 'model' && activeState.status === 'loaded'
        ? html`<${CostMatrix} models=${activeState.data as DashboardRuntimeModelMetric[]} />`
        : null}

      ${data.length === 0 ? html`
        <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-6 text-center text-sm text-text-muted">
          이 시간 창에서 기록된 ${viewMode.value === 'model' ? '모델' : 'Keeper'} 비용이 없습니다.
        </div>
      ` : html`
        <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
          <table class="w-full" aria-label=${`${data.length}개 ${viewMode.value === 'model' ? '모델' : 'Keeper'}의 비용 / 지연`}>
            <thead>
              <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
                <th scope="col" class="px-2 py-1.5 text-left">${viewMode.value === 'model' ? 'model' : 'keeper'}</th>
                <th scope="col" class="px-2 py-1.5 text-right">in tok</th>
                <th scope="col" class="px-2 py-1.5 text-right">out tok</th>
                <th scope="col" class="px-2 py-1.5 text-right">$ cost</th>
                <th scope="col" class="px-2 py-1.5 text-left">cost</th>
                <th scope="col" class="px-2 py-1.5 text-right">p50</th>
                <th scope="col" class="px-2 py-1.5 text-right">p95</th>
                <th scope="col" class="px-2 py-1.5 text-left">p95 trend</th>
                ${viewMode.value === 'keeper' ? html`<th scope="col" class="px-2 py-1.5 text-left">top model</th>` : null}
              </tr>
            </thead>
            <tbody>
              ${viewMode.value === 'model'
                ? data.map(m => html`<${ModelRow} key=${(m as DashboardRuntimeModelMetric).model_id} model=${m as DashboardRuntimeModelMetric} maxCost=${maxCost} maxP95=${maxP95} />`)
                : data.map(k => html`<${KeeperRow} key=${(k as KeeperCostMetric).keeper_name} keeper=${k as KeeperCostMetric} maxCost=${maxCost} maxP95=${maxP95} />`)}
            </tbody>
          </table>
        </div>
      `}
    </section>
  `
}
