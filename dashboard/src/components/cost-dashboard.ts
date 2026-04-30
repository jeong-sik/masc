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
  fetchHeuristics,
  fetchHeuristicCoverage,
  fetchStress,
  fetchCascadeHealth,
  fetchCascadeConfig,
  fetchAuditLedger,
  type DashboardRuntimeModelMetric,
  type KeeperCostMetric,
  type LatencyBucket,
  type HeuristicEvent,
  type HeuristicCoverage,
  type CoverageSite,
  type StressEvent,
  type CascadeHealthResponse,
  type CascadeConfigResponse,
  type AuditEntry,
  type AuditLedgerResponse,
} from '../api/dashboard'
import { LoadingState, ErrorState } from './common/feedback-state'

type ViewMode = 'model' | 'keeper'

type ModelLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: DashboardRuntimeModelMetric[]; latencyBuckets: LatencyBucket[]; windowMinutes: number }
  | { status: 'error'; message: string }

type KeeperLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: KeeperCostMetric[]; windowMinutes: number }
  | { status: 'error'; message: string }

type HeuristicLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: HeuristicEvent[]; limit: number }
  | { status: 'error'; message: string }

type StressLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: StressEvent[]; limit: number }
  | { status: 'error'; message: string }

type CoverageLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: HeuristicCoverage }
  | { status: 'error'; message: string }

type CascadeHealthLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: CascadeHealthResponse }
  | { status: 'error'; message: string }

type CascadeConfigLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: CascadeConfigResponse }
  | { status: 'error'; message: string }

type AuditLedgerLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: AuditLedgerResponse }
  | { status: 'error'; message: string }

const viewMode = signal<ViewMode>('model')
const modelState = signal<ModelLoadState>({ status: 'idle' })
const keeperState = signal<KeeperLoadState>({ status: 'idle' })
const heuristicState = signal<HeuristicLoadState>({ status: 'idle' })
const stressState = signal<StressLoadState>({ status: 'idle' })
const coverageState = signal<CoverageLoadState>({ status: 'idle' })
const cascadeHealthState = signal<CascadeHealthLoadState>({ status: 'idle' })
const cascadeConfigState = signal<CascadeConfigLoadState>({ status: 'idle' })
const auditLedgerState = signal<AuditLedgerLoadState>({ status: 'idle' })

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
      latencyBuckets: resp.latency_buckets ?? [],
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

async function loadHeuristics(limit = 100) {
  heuristicState.value = { status: 'loading' }
  try {
    const resp = await fetchHeuristics(limit)
    heuristicState.value = { status: 'loaded', data: resp.events, limit: resp.limit }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'heuristic metrics 불러오기 실패'
    heuristicState.value = { status: 'error', message }
  }
}

async function loadStress(limit = 100) {
  stressState.value = { status: 'loading' }
  try {
    const resp = await fetchStress(limit)
    stressState.value = { status: 'loaded', data: resp.events, limit: resp.limit }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'stress events 불러오기 실패'
    stressState.value = { status: 'error', message }
  }
}

async function loadHeuristicCoverage(limit = 100) {
  coverageState.value = { status: 'loading' }
  try {
    const resp = await fetchHeuristicCoverage(limit)
    coverageState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'heuristic coverage 불러오기 실패'
    coverageState.value = { status: 'error', message }
  }
}

async function loadCascadeHealth() {
  cascadeHealthState.value = { status: 'loading' }
  try {
    const resp = await fetchCascadeHealth()
    cascadeHealthState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'cascade health 불러오기 실패'
    cascadeHealthState.value = { status: 'error', message }
  }
}

async function loadCascadeConfig() {
  cascadeConfigState.value = { status: 'loading' }
  try {
    const resp = await fetchCascadeConfig()
    cascadeConfigState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'cascade config 불러오기 실패'
    cascadeConfigState.value = { status: 'error', message }
  }
}

async function loadAuditLedger(limit = 50) {
  auditLedgerState.value = { status: 'loading' }
  try {
    const resp = await fetchAuditLedger(limit)
    auditLedgerState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'audit ledger 불러오기 실패'
    auditLedgerState.value = { status: 'error', message }
  }
}

function loadActiveView(window: number) {
  if (viewMode.value === 'model') {
    void loadModelMetrics(window)
  } else {
    void loadKeeperMetrics(window)
  }
  void loadHeuristics()
  void loadStress()
  void loadHeuristicCoverage()
  void loadCascadeHealth()
  void loadCascadeConfig()
  void loadAuditLedger()
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

function CostLatency({ buckets, p50, p95 }: {
  buckets: LatencyBucket[]
  p50: number | null
  p95: number | null
}) {
  const max = Math.max(1, ...buckets.map(b => b.count))
  const total = buckets.reduce((s, b) => s + b.count, 0)

  const fmtLo = (lo: number): string => {
    if (lo < 1000) return `${lo}`
    if (lo < 60000) return `${(lo / 1000).toFixed(0)}k`
    return `${Math.floor(lo / 60000)}m`
  }

  const bands = [
    {
      label: '< 1s',
      count: buckets.filter(b => b.hi_ms != null && b.hi_ms <= 1000).reduce((s, b) => s + b.count, 0),
      color: 'text-[var(--color-status-ok)]',
    },
    {
      label: '1–4s',
      count: buckets.filter(b => b.lo_ms >= 1000 && b.hi_ms != null && b.hi_ms <= 4000).reduce((s, b) => s + b.count, 0),
      color: 'text-[var(--color-accent-fg)]',
    },
    {
      label: '4–16s',
      count: buckets.filter(b => b.lo_ms >= 4000 && b.hi_ms != null && b.hi_ms <= 16000).reduce((s, b) => s + b.count, 0),
      color: 'text-[var(--color-status-warn)]',
    },
    {
      label: '> 16s',
      count: buckets.filter(b => b.lo_ms >= 16000).reduce((s, b) => s + b.count, 0),
      color: 'text-[var(--color-status-err)]',
    },
  ]

  return html`
    <section class="flex flex-col gap-2" aria-label=${`Latency distribution · ${total} calls`}>
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">latency distribution · ${total} calls</span>
        <div class="flex gap-3 font-mono text-2xs">
          <span class="text-text-muted">p50 · <span class="text-[var(--color-accent-fg)]">${p50 == null ? '—' : `${Math.round(p50)}ms`}</span></span>
          <span class="text-text-muted">p95 · <span class="text-[var(--color-status-err)]">${p95 == null ? '—' : `${Math.round(p95)}ms`}</span></span>
        </div>
      </div>
      <div class="flex items-end gap-1 rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-3" role="img" aria-label=${`Latency histogram · ${buckets.length} buckets`}>
        ${buckets.map((b, i) => {
          const pct = (b.count / max) * 100
          const bad = b.lo_ms >= 8000
          return html`
            <div key=${i} class="flex flex-1 flex-col items-center gap-1">
              <div class="w-full rounded-sm ${bad ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-accent-fg)]'}" style=${`height: ${Math.max(4, pct * 1.5).toFixed(1)}px`}></div>
              <span class="font-mono text-2xs text-text-muted">${fmtLo(b.lo_ms)}</span>
            </div>
          `
        })}
      </div>
      <div class="grid grid-cols-4 gap-px rounded border border-card-border/60 bg-[var(--color-border-default)]" role="list" aria-label="Latency band totals">
        ${bands.map(b => html`
          <div key=${b.label} class="flex flex-col gap-0.5 bg-[var(--backdrop-deep)] p-2" role="listitem" aria-label=${`${b.label}: ${b.count} calls (${total > 0 ? ((b.count / total) * 100).toFixed(0) : 0}%)`}>
            <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">${b.label}</span>
            <span class="font-mono text-sm font-semibold ${b.color}">
              ${b.count}<span class="ml-1 text-2xs font-normal text-text-muted">· ${total > 0 ? ((b.count / total) * 100).toFixed(0) : 0}%</span>
            </span>
          </div>
        `)}
      </div>
    </section>
  `
}

function HeuristicLog({ events, limit }: { events: HeuristicEvent[]; limit: number }) {
  const fmtTime = (ts: number): string => {
    const d = new Date(ts * 1000)
    return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  }

  const triggeredCount = events.filter(e => e.triggered).length

  return html`
    <section class="flex flex-col gap-2" aria-label=${`Heuristic log · ${events.length} events`}>
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">heuristic log · ${events.length} events · ${triggeredCount} triggered</span>
        <span class="font-mono text-2xs text-text-muted">limit ${limit}</span>
      </div>
      <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Heuristic events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">module</th>
              <th scope="col" class="px-2 py-1.5 text-left">site</th>
              <th scope="col" class="px-2 py-1.5 text-right">value</th>
              <th scope="col" class="px-2 py-1.5 text-right">threshold</th>
              <th scope="col" class="px-2 py-1.5 text-center">state</th>
              <th scope="col" class="px-2 py-1.5 text-left">provenance</th>
            </tr>
          </thead>
          <tbody>
            ${events.map((e, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs ${e.triggered ? 'bg-[var(--color-status-err)]/5' : ''}">
                <td class="px-2 py-1.5 font-mono text-text-muted">${fmtTime(e.timestamp)}</td>
                <td class="px-2 py-1.5 text-text-strong">${e.module}</td>
                <td class="px-2 py-1.5 text-text-muted">${e.site}</td>
                <td class="px-2 py-1.5 text-right font-mono">${e.raw_value.toFixed(3)}</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-muted">${e.threshold.toFixed(3)}</td>
                <td class="px-2 py-1.5 text-center">
                  <span class="inline-block rounded px-1.5 py-0.5 text-2xs font-semibold ${e.triggered ? 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]' : 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'}">
                    ${e.triggered ? 'TRIGGERED' : 'ok'}
                  </span>
                </td>
                <td class="px-2 py-1.5 text-text-muted">${e.provenance.type}${e.provenance.detail ? ` · ${e.provenance.detail}` : ''}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </section>
  `
}

function StressBoard({ events, limit }: { events: StressEvent[]; limit: number }) {
  const fmtTime = (ts: number): string => {
    const d = new Date(ts * 1000)
    return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  }

  const fmtKind = (kind: StressEvent['kind']): string => {
    switch (kind.type) {
      case 'failure_streak': return `failure_streak · ${kind.count ?? '?'}`
      case 'turn_failure': return `turn_failure · c=${kind.consecutive ?? '?'} t=${kind.threshold ?? '?'}`
      case 'fallback_approval': return 'fallback_approval'
      case 'timeout': return 'timeout'
      case 'parse_degraded': return 'parse_degraded'
      case 'task_released': return 'task_released'
      default: return kind.type
    }
  }

  const severityClass = (kind: StressEvent['kind']): string => {
    switch (kind.type) {
      case 'failure_streak':
      case 'turn_failure':
        return 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]'
      case 'timeout':
      case 'parse_degraded':
        return 'bg-[var(--color-status-warn)]/15 text-[var(--color-status-warn)]'
      default:
        return 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'
    }
  }

  return html`
    <section class="flex flex-col gap-2" aria-label=${`Stress board · ${events.length} events`}>
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">stress board · ${events.length} events</span>
        <span class="font-mono text-2xs text-text-muted">limit ${limit}</span>
      </div>
      <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Stress events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">agent</th>
              <th scope="col" class="px-2 py-1.5 text-left">room</th>
              <th scope="col" class="px-2 py-1.5 text-left">kind</th>
            </tr>
          </thead>
          <tbody>
            ${events.map((e, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 font-mono text-text-muted">${fmtTime(e.timestamp)}</td>
                <td class="px-2 py-1.5 text-text-strong">${e.agent_name}</td>
                <td class="px-2 py-1.5 font-mono text-text-muted">${e.room_id}</td>
                <td class="px-2 py-1.5">
                  <span class="inline-block rounded px-1.5 py-0.5 text-2xs font-semibold ${severityClass(e.kind)}">
                    ${fmtKind(e.kind)}
                  </span>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </section>
  `
}

function HeuristicByModule({ coverage }: { coverage: HeuristicCoverage }) {
  const byModule = coverage.sites.reduce((acc, site) => {
    const arr = acc.get(site.module) ?? []
    arr.push(site)
    acc.set(site.module, arr)
    return acc
  }, new Map<string, CoverageSite[]>())

  const sortedModules = Array.from(byModule.entries()).sort((a, b) => b[1].length - a[1].length)

  return html`
    <section class="flex flex-col gap-2" aria-label="Heuristic by module">
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">heuristic by module · ${coverage.total_events} events · ${coverage.unique_decision_tuples} unique tuples</span>
      </div>
      <div class="flex flex-col gap-2">
        ${sortedModules.map(([moduleName, sites]) => {
          const totalCount = sites.reduce((s, x) => s + x.count, 0)
          const totalTriggered = sites.reduce((s, x) => s + x.triggered_count, 0)
          return html`
            <div key=${moduleName} class="rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
              <div class="flex items-center justify-between border-b border-[var(--color-border-default)]/50 px-3 py-1.5">
                <span class="text-xs font-semibold text-text-strong">${moduleName}</span>
                <span class="font-mono text-2xs text-text-muted">${sites.length} sites · ${totalCount} obs · ${totalTriggered} triggered</span>
              </div>
              <div class="overflow-x-auto">
                <table class="w-full" aria-label=${`Heuristic sites for ${moduleName}`}>
                  <thead>
                    <tr class="border-b border-[var(--color-border-default)]/30 text-2xs uppercase tracking-1 text-text-muted">
                      <th scope="col" class="px-2 py-1 text-left">site</th>
                      <th scope="col" class="px-2 py-1 text-right">count</th>
                      <th scope="col" class="px-2 py-1 text-right">triggered</th>
                      <th scope="col" class="px-2 py-1 text-right">rate</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${sites.sort((a, b) => b.count - a.count).map((s, i) => html`
                      <tr key=${i} class="border-b border-[var(--color-border-default)]/20 text-2xs">
                        <td class="px-2 py-1 text-text-muted">${s.site}</td>
                        <td class="px-2 py-1 text-right font-mono">${s.count}</td>
                        <td class="px-2 py-1 text-right font-mono ${s.triggered_count > 0 ? 'text-[var(--color-status-err)]' : ''}">${s.triggered_count}</td>
                        <td class="px-2 py-1 text-right font-mono text-text-muted">${s.count > 0 ? ((s.triggered_count / s.count) * 100).toFixed(1) : '0.0'}%</td>
                      </tr>
                    `)}
                  </tbody>
                </table>
              </div>
            </div>
          `
        })}
      </div>
    </section>
  `
}

function CascadeBoard({ health, config }: { health: CascadeHealthResponse; config: CascadeConfigResponse }) {
  const fmtTime = (iso: string): string => {
    const d = new Date(iso)
    return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  }

  const sortedProviders = [...health.providers].sort((a, b) => b.success_rate - a.success_rate)

  return html`
    <section class="flex flex-col gap-4" aria-label="Cascade inspector">
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">cascade inspector · ${health.providers.length} providers · updated ${fmtTime(health.updated_at)}</span>
        <span class="font-mono text-2xs text-text-muted">window ${health.window_sec}s · cooldown ${health.cooldown_threshold} failures / ${health.cooldown_sec}s</span>
      </div>

      <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Provider health">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">provider</th>
              <th scope="col" class="px-2 py-1.5 text-right">success</th>
              <th scope="col" class="px-2 py-1.5 text-right">events</th>
              <th scope="col" class="px-2 py-1.5 text-right">rejected</th>
              <th scope="col" class="px-2 py-1.5 text-right">latency</th>
              <th scope="col" class="px-2 py-1.5 text-center">status</th>
              <th scope="col" class="px-2 py-1.5 text-center">cooldown</th>
            </tr>
          </thead>
          <tbody>
            ${sortedProviders.map((p, i) => {
              const successPct = Math.round(p.success_rate * 100)
              const status = p.status ?? 'configured'
              const statusClass =
                status === 'active' ? 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'
                  : status === 'cooldown' ? 'bg-[var(--color-status-warn)]/15 text-[var(--color-status-warn)]'
                  : 'bg-[var(--color-text-muted)]/15 text-[var(--color-text-muted)]'
              const latency = p.p50_latency_ms ?? p.avg_latency_ms ?? null
              const rejected = p.rejected_in_window ?? 0
              return html`
                <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                  <td class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${p.provider_key}</td>
                  <td class="px-2 py-1.5 text-right font-mono ${successPct >= 95 ? 'text-[var(--color-status-ok)]' : successPct >= 80 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-status-err)]'}">${successPct}%</td>
                  <td class="px-2 py-1.5 text-right font-mono text-text-muted">${p.events_in_window}</td>
                  <td class="px-2 py-1.5 text-right font-mono ${rejected > 0 ? 'text-[var(--color-status-err)]' : 'text-text-muted'}">${rejected}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-text-muted">${latency == null ? '—' : `${Math.round(latency)}ms`}</td>
                  <td class="px-2 py-1.5 text-center">
                    <span class="inline-block rounded px-1.5 py-0.5 text-2xs font-semibold ${statusClass}">${status}</span>
                  </td>
                  <td class="px-2 py-1.5 text-center">
                    <span class="inline-block rounded px-1.5 py-0.5 text-2xs font-semibold ${p.in_cooldown ? 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]' : 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'}">
                      ${p.in_cooldown ? 'YES' : 'no'}
                    </span>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>

      ${config.profiles.length > 0 ? html`
        <div class="flex flex-col gap-2">
          <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">cascade profiles · ${config.profiles.length} profiles · ${config.keeper_profiles.length} keeper assignments</span>
          <div class="flex flex-col gap-2">
            ${config.profiles.map((prof, i) => html`
              <div key=${i} class="rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
                <div class="flex items-center justify-between border-b border-[var(--color-border-default)]/50 px-3 py-1.5">
                  <span class="text-xs font-semibold text-text-strong">${prof.name}</span>
                  <span class="font-mono text-2xs text-text-muted">${prof.candidates.length} candidates · ${prof.source}</span>
                </div>
                <div class="overflow-x-auto">
                  <table class="w-full" aria-label=${`Candidates for ${prof.name}`}>
                    <thead>
                      <tr class="border-b border-[var(--color-border-default)]/30 text-2xs uppercase tracking-1 text-text-muted">
                        <th scope="col" class="px-2 py-1 text-left">model</th>
                        <th scope="col" class="px-2 py-1 text-right">weight</th>
                        <th scope="col" class="px-2 py-1 text-right">success</th>
                        <th scope="col" class="px-2 py-1 text-center">cooldown</th>
                      </tr>
                    </thead>
                    <tbody>
                      ${prof.candidates.map((c, j) => html`
                        <tr key=${j} class="border-b border-[var(--color-border-default)]/20 text-2xs">
                          <td class="px-2 py-1 text-left font-mono text-text-strong">${c.model}</td>
                          <td class="px-2 py-1 text-right font-mono text-text-muted">${c.effective_weight.toFixed(2)}</td>
                          <td class="px-2 py-1 text-right font-mono ${Math.round(c.success_rate * 100) >= 95 ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'}">${Math.round(c.success_rate * 100)}%</td>
                          <td class="px-2 py-1 text-center">
                            <span class="inline-block rounded px-1.5 py-0.5 text-2xs font-semibold ${c.in_cooldown ? 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]' : 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'}">
                              ${c.in_cooldown ? 'YES' : 'no'}
                            </span>
                          </td>
                        </tr>
                      `)}
                    </tbody>
                  </table>
                </div>
              </div>
            `)}
          </div>
        </div>
      ` : null}
    </section>
  `
}

function AuditLedgerBoard({ entries, count }: { entries: AuditEntry[]; count: number }) {
  const fmtTime = (ts: number): string => {
    const d = new Date(ts * 1000)
    return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  }

  const fmtValue = (v: unknown): string => {
    if (v === null) return 'null'
    if (v === undefined) return 'undefined'
    if (typeof v === 'string') return v
    return JSON.stringify(v)
  }

  return html`
    <section class="flex flex-col gap-4" aria-label="Audit ledger">
      <div class="flex items-center justify-between rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-1 text-text-muted">audit ledger · ${count} entries</span>
      </div>

      <div class="overflow-x-auto rounded border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Parameter audit entries">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-1 text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">actor</th>
              <th scope="col" class="px-2 py-1.5 text-left">key</th>
              <th scope="col" class="px-2 py-1.5 text-left">old</th>
              <th scope="col" class="px-2 py-1.5 text-left">new</th>
              <th scope="col" class="px-2 py-1.5 text-left">case</th>
            </tr>
          </thead>
          <tbody>
            ${entries.map((e, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${fmtTime(e.timestamp)}</td>
                <td class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${e.actor}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-strong">${e.key}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted max-w-[12ch] truncate" title=${fmtValue(e.old_value)}>${fmtValue(e.old_value)}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted max-w-[12ch] truncate" title=${fmtValue(e.new_value)}>${fmtValue(e.new_value)}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${e.case_id ?? '—'}</td>
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
        ? html`
          <${CostMatrix} models=${activeState.data as DashboardRuntimeModelMetric[]} />
          <${CostLatency}
            buckets=${(activeState as Extract<ModelLoadState, { status: 'loaded' }>).latencyBuckets}
            p50=${t?.p50Avg ?? null}
            p95=${t?.p95Max ?? null}
          />
        `
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

      ${heuristicState.value.status === 'loaded'
        ? html`<${HeuristicLog} events=${heuristicState.value.data} limit=${heuristicState.value.limit} />`
        : heuristicState.value.status === 'error'
          ? html`<${ErrorState} message=${heuristicState.value.message} onRetry=${() => void loadHeuristics()} />`
          : html`<${LoadingState} />`}

      ${stressState.value.status === 'loaded'
        ? html`<${StressBoard} events=${stressState.value.data} limit=${stressState.value.limit} />`
        : stressState.value.status === 'error'
          ? html`<${ErrorState} message=${stressState.value.message} onRetry=${() => void loadStress()} />`
          : html`<${LoadingState} />`}

      ${coverageState.value.status === 'loaded'
        ? html`<${HeuristicByModule} coverage=${coverageState.value.data} />`
        : coverageState.value.status === 'error'
          ? html`<${ErrorState} message=${coverageState.value.message} onRetry=${() => void loadHeuristicCoverage()} />`
          : html`<${LoadingState} />`}

      ${cascadeHealthState.value.status === 'loaded' && cascadeConfigState.value.status === 'loaded'
        ? html`<${CascadeBoard}
            health=${cascadeHealthState.value.data}
            config=${cascadeConfigState.value.data}
          />`
        : cascadeHealthState.value.status === 'error'
          ? html`<${ErrorState}
              message=${cascadeHealthState.value.message}
              onRetry=${() => void loadCascadeHealth()}
            />`
          : cascadeConfigState.value.status === 'error'
            ? html`<${ErrorState}
                message=${cascadeConfigState.value.message}
                onRetry=${() => void loadCascadeConfig()}
              />`
            : html`<${LoadingState} />`}

      ${auditLedgerState.value.status === 'loaded'
        ? html`<${AuditLedgerBoard}
            entries=${auditLedgerState.value.data.entries}
            count=${auditLedgerState.value.data.count}
          />`
        : auditLedgerState.value.status === 'error'
          ? html`<${ErrorState}
              message=${auditLedgerState.value.message}
              onRetry=${() => void loadAuditLedger()}
            />`
          : html`<${LoadingState} />`}
    </section>
  `
}
