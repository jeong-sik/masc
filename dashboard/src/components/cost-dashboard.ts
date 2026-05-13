// MASC Dashboard — runtime cost & latency dashboard
//
// Phase 2 spec (`design-system/preview/cb-group-f.jsx:CostPerAgent`)
// renders a 4-cell totals header (cost / tokens / p50 / p95) plus a
// per-agent table with cost bar + p95 latency bar. Production has
// redacted runtime-lane cost + latency telemetry on
// `DashboardRuntimeModelMetric` (`/api/v1/models/metrics`), consolidated into
// a "where is the money going / where is the latency going" view.
//
// This component now supports both per-runtime and per-keeper views,
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
  fetchAuditLedger,
  fetchKeeperDecisions,
  type DashboardRuntimeModelMetric,
  type KeeperCostMetric,
  type LatencyBucket,
  type HeuristicEvent,
  type HeuristicCoverage,
  type CoverageSite,
  type StressEvent,
  type AgentStressRow,
  type AuditEntry,
  type AuditLedgerResponse,
  type KeeperDecision,
  type KeeperDecisionsResponse,
} from '../api/dashboard'
import { LoadingState, ErrorState } from './common/feedback-state'
import { StatTile } from './common/stat-tile'
import { FilterChips } from './common/filter-chips'
import { formatCost, formatPct1 } from '../lib/format-number'
import { replaceRoute, route } from '../router'
import {
  type ViewMode,
  type CostFocus,
  type AuditFocus,
  type CostView,
  isCostView,
  isCostFocus,
  viewModeForCostFocus,
  isAuditFocus,
  auditRouteParams,
} from './cost/cost-types'
import { formatTokens, severityClass } from './cost/cost-formatters'
import {
  severityBuckets,
  summarizeAuditActors,
  summarizeAuditKinds,
} from './cost/audit-summarizer'

// Re-export RFC-0050 PR-1 — preserve every public symbol callers import
// from this module so the per-domain split is mechanical.
export {
  type CostFocus,
  type AuditFocus,
  type CostView,
  isCostView,
  isCostFocus,
  viewModeForCostFocus,
  isAuditFocus,
  auditRouteParams,
  formatTokens,
  summarizeAuditActors,
  summarizeAuditKinds,
}

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
  | { status: 'loaded'; events: StressEvent[]; board: AgentStressRow[]; limit: number }
  | { status: 'error'; message: string }

type CoverageLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: HeuristicCoverage }
  | { status: 'error'; message: string }

type AuditLedgerLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: AuditLedgerResponse }
  | { status: 'error'; message: string }

type KeeperDecisionsLoadState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'loaded'; data: KeeperDecisionsResponse }
  | { status: 'error'; message: string }

const viewMode = signal<ViewMode>('model')
const modelState = signal<ModelLoadState>({ status: 'idle' })
const keeperState = signal<KeeperLoadState>({ status: 'idle' })
const heuristicState = signal<HeuristicLoadState>({ status: 'idle' })
const stressState = signal<StressLoadState>({ status: 'idle' })
const coverageState = signal<CoverageLoadState>({ status: 'idle' })
const auditLedgerState = signal<AuditLedgerLoadState>({ status: 'idle' })
const keeperDecisionsState = signal<KeeperDecisionsLoadState>({ status: 'idle' })
const activeCostFocus = computed<CostFocus | null>(() => {
  const focus = route.value.params.focus
  return isCostFocus(focus) ? focus : null
})
const activeAuditFocus = computed<AuditFocus | null>(() => {
  const focus = route.value.params.focus
  return isAuditFocus(focus) ? focus : null
})

const WINDOW_OPTIONS: Array<{ key: number; label: string }> = [
  { key: 30, label: '30분' },
  { key: 60, label: '1시간' },
  { key: 360, label: '6시간' },
  { key: 1440, label: '24시간' },
]

const windowMinutes = signal<number>(60)

const COST_FOCUS_COCKPIT_TABS: Record<CostFocus, string> = {
  agent: 'ct-agt',
  matrix: 'ct-mtx',
  latency: 'ct-lat',
}

function currentHashParams(): Record<string, string> {
  const [, query = ''] = window.location.hash.split('?')
  const params: Record<string, string> = {}
  new URLSearchParams(query).forEach((value, key) => {
    params[key] = value
  })
  return params
}

function costRouteParams(
  updates: Record<string, string>,
  options: { clearFocus?: boolean } = {},
): Record<string, string> {
  const params: Record<string, string> = {
    ...currentHashParams(),
    ...route.value.params,
    section: 'runtime',
    view: 'cost',
    ...updates,
  }
  const isObserveCockpit = params.mode?.toLowerCase() === 'observe'
  const hasCostCockpitTab = Object.values(COST_FOCUS_COCKPIT_TABS).includes(params.tab ?? '')

  if (options.clearFocus) {
    delete params.focus
    if (hasCostCockpitTab) delete params.tab
  } else if (isCostFocus(params.focus) && (isObserveCockpit || hasCostCockpitTab)) {
    params.tab = COST_FOCUS_COCKPIT_TABS[params.focus]
  }

  return params
}

function updateCostFocusParam(focus: CostFocus): void {
  replaceRoute('monitoring', costRouteParams({ focus }))
}

function setCostViewMode(mode: ViewMode): void {
  const currentFocus = activeCostFocus.value
  const currentMode = currentFocus ? viewModeForCostFocus(currentFocus) : viewMode.value
  if (currentMode === mode) return

  const nextParams = mode === 'keeper'
    ? costRouteParams({ focus: 'agent' })
    : costRouteParams({}, { clearFocus: true })
  viewMode.value = mode
  replaceRoute('monitoring', nextParams)
  if (mode === 'model') {
    void loadModelMetrics(windowMinutes.value)
  } else {
    void loadKeeperMetrics(windowMinutes.value)
  }
}

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
    stressState.value = { status: 'loaded', events: resp.events, board: resp.agent_stress, limit: resp.limit }
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

async function loadAuditLedger(limit = 50) {
  auditLedgerState.value = { status: 'loading' }
  try {
    const resp = await fetchAuditLedger({ limit })
    auditLedgerState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'audit ledger 불러오기 실패'
    auditLedgerState.value = { status: 'error', message }
  }
}

async function loadKeeperDecisions(limit = 200) {
  keeperDecisionsState.value = { status: 'loading' }
  try {
    const resp = await fetchKeeperDecisions(limit)
    keeperDecisionsState.value = { status: 'loaded', data: resp }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'keeper decisions 불러오기 실패'
    keeperDecisionsState.value = { status: 'error', message }
  }
}

function loadActiveView(window: number, view: CostView) {
  if (view === 'cost') {
    if (viewMode.value === 'model') {
      void loadModelMetrics(window)
    } else {
      void loadKeeperMetrics(window)
    }
  }
  if (view === 'heuristics') {
    void loadHeuristics()
    void loadHeuristicCoverage()
  }
  if (view === 'stress') {
    void loadStress()
  }
  if (view === 'audit') {
    void loadAuditLedger()
  }
  if (view === 'decisions') {
    void loadKeeperDecisions()
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

function ThRight({ children }: { children: unknown }) {
  return html`<th scope="col" class="px-2 py-1.5 text-right">${children}</th>`
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
        ${formatCost(cost)}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-surface)]">
          <div class="h-full rounded-[var(--r-0)] bg-[var(--color-accent-fg)]" style=${`width: ${costPct.toFixed(1)}%`}></div>
        </div>
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${p50 == null ? 'text-text-disabled' : ''}">
        ${p50 == null ? '—' : `${p50}ms`}
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${overBudget ? 'text-[var(--color-status-err)]' : ''}">
        ${p95 == null ? html`<span class="text-text-disabled">—</span>` : `${p95}ms`}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-surface)]">
          <div
            class="h-full rounded-[var(--r-0)] ${overBudget ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-status-warn)]'}"
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
        ${formatCost(cost)}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-surface)]">
          <div class="h-full rounded-[var(--r-0)] bg-[var(--color-accent-fg)]" style=${`width: ${costPct.toFixed(1)}%`}></div>
        </div>
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${p50 == null ? 'text-text-disabled' : ''}">
        ${p50 == null ? '—' : `${Math.round(p50)}ms`}
      </td>
      <td class="px-2 py-1.5 text-right font-mono text-xs ${overBudget ? 'text-[var(--color-status-err)]' : ''}">
        ${p95 == null ? html`<span class="text-text-disabled">—</span>` : `${Math.round(p95)}ms`}
      </td>
      <td class="px-2 py-1.5 min-w-[80px]">
        <div class="h-1.5 rounded-[var(--r-0)] bg-[var(--color-bg-surface)]">
          <div
            class="h-full rounded-[var(--r-0)] ${overBudget ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-status-warn)]'}"
            style=${`width: ${p95Pct.toFixed(1)}%`}
          ></div>
        </div>
      </td>
      <td class="px-2 py-1.5 text-left font-mono text-2xs text-text-muted">
        ${topModel ? formatCost(topModel.cost_usd) : '—'}
      </td>
    </tr>
  `
}

function CostMatrix({ models }: { models: DashboardRuntimeModelMetric[] }) {
  const providers = models.length > 0 ? ['runtime'] : []
  const modelIds = Array.from(new Set(models.map(m => m.model_id))).sort((a, b) => {
    const ca = models.find(m => m.model_id === a)?.total_cost_usd ?? 0
    const cb = models.find(m => m.model_id === b)?.total_cost_usd ?? 0
    return cb - ca
  })

  const grid: number[][] = providers.map(() =>
    modelIds.map(mid => {
      const match = models.find(m => m.model_id === mid)
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
      case 'z3': return 'bg-[var(--accent-15)]/50 text-accent-fg'
      case 'z4': return 'bg-[var(--color-accent-fg)] text-white'
      default: return ''
    }
  }

  return html`
    <section class="flex flex-col gap-2" aria-label="Runtime lane cost matrix">
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">runtime lanes · $ spent</span>
      </div>
      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Runtime lane cost matrix">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
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
                      ${v > 0 ? formatCost(v) : '—'}
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
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">latency distribution · ${total} calls</span>
        <div class="flex gap-3 font-mono text-2xs">
          <span class="text-text-muted">p50 · <span class="text-[var(--color-accent-fg)]">${p50 == null ? '—' : `${Math.round(p50)}ms`}</span></span>
          <span class="text-text-muted">p95 · <span class="text-[var(--color-status-err)]">${p95 == null ? '—' : `${Math.round(p95)}ms`}</span></span>
        </div>
      </div>
      <div class="flex items-end gap-1 rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-3" role="img" aria-label=${`Latency histogram · ${buckets.length} buckets`}>
        ${buckets.map((b, i) => {
          const pct = (b.count / max) * 100
          const bad = b.lo_ms >= 8000
          return html`
            <div key=${i} class="flex flex-1 flex-col items-center gap-1">
              <div class="w-full rounded-[var(--r-0)] ${bad ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-accent-fg)]'}" style=${`height: ${Math.max(4, pct * 1.5).toFixed(1)}px`}></div>
              <span class="font-mono text-2xs text-text-muted">${fmtLo(b.lo_ms)}</span>
            </div>
          `
        })}
      </div>
      <div class="grid grid-cols-2 gap-1 md:grid-cols-4 rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-border-default)]" role="list" aria-label="Latency band totals">
        ${bands.map(b => html`
          <div key=${b.label} class="flex flex-col gap-0.5 bg-[var(--backdrop-deep)] p-2" role="listitem" aria-label=${`${b.label}: ${b.count} calls (${total > 0 ? Math.round((b.count / total) * 100) : 0}%)`}>
            <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">${b.label}</span>
            <span class="font-mono text-sm font-semibold ${b.color}">
              ${b.count}<span class="ml-1 text-2xs font-normal text-text-muted">· ${total > 0 ? Math.round((b.count / total) * 100) : 0}%</span>
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
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">heuristic log · ${events.length} events · ${triggeredCount} triggered</span>
        <span class="font-mono text-2xs text-text-muted">limit ${limit}</span>
      </div>
      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Heuristic events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
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
                  <span class="inline-block rounded-[var(--r-1)] px-1.5 py-0.5 text-2xs font-semibold ${e.triggered ? 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]' : 'bg-[var(--color-status-ok)]/15 text-[var(--color-status-ok)]'}">
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

function StressBoard({ rows, events, limit }: { rows: AgentStressRow[]; events: StressEvent[]; limit: number }) {
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

  const pressureTone = (value: number): string => {
    if (value >= 0.75) return 'text-[var(--color-status-err)]'
    if (value >= 0.45) return 'text-[var(--color-status-warn)]'
    return 'text-[var(--color-status-ok)]'
  }

  const sourceHint = (row: AgentStressRow): string => {
    return [
      row.budget_pressure_source ? `budget=${row.budget_pressure_source}` : '',
      row.ctx_pressure_source ? `ctx=${row.ctx_pressure_source}` : '',
      row.queue_depth_source ? `queue=${row.queue_depth_source}` : '',
    ].filter(Boolean).join(' · ')
  }

  return html`
    <section class="flex flex-col gap-2" aria-label=${`Stress board · ${rows.length} agents · ${events.length} events`}>
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">stress board · ${rows.length} agents · ${events.length} events</span>
        <span class="font-mono text-2xs text-text-muted">limit ${limit}</span>
      </div>
      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Agent stress board">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">agent</th>
              <th scope="col" class="px-2 py-1.5 text-right">budget</th>
              <th scope="col" class="px-2 py-1.5 text-right">context</th>
              <th scope="col" class="px-2 py-1.5 text-right">queue</th>
              <th scope="col" class="px-2 py-1.5 text-left">blocked</th>
              <th scope="col" class="px-2 py-1.5 text-left">source</th>
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map((row, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-text-strong">${row.agent}</td>
                <td class=${`px-2 py-1.5 text-right font-mono ${pressureTone(row.budget_pressure)}`}>${formatPct1(row.budget_pressure)}</td>
                <td class=${`px-2 py-1.5 text-right font-mono ${pressureTone(row.ctx_pressure)}`}>${formatPct1(row.ctx_pressure)}</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-muted">${row.queue_depth}</td>
                <td class="px-2 py-1.5 text-text-muted">${row.blocked_on ?? '—'}</td>
                <td class="px-2 py-1.5 text-text-muted">${sourceHint(row)}</td>
                <td class="px-2 py-1.5 font-mono text-text-muted">${row.ts > 0 ? fmtTime(row.ts) : '—'}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Recent stress events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
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
                  <span class="inline-block rounded-[var(--r-1)] px-1.5 py-0.5 text-2xs font-semibold ${severityClass(e.kind)}">
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
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">heuristic by module · ${coverage.total_events} events · ${coverage.decision_shape_count} decision shapes · ${coverage.mixed_outcome_sites} mixed sites</span>
      </div>
      <div class="flex flex-col gap-2">
        ${sortedModules.map(([moduleName, sites]) => {
          const totalCount = sites.reduce((s, x) => s + x.count, 0)
          const totalTriggered = sites.reduce((s, x) => s + x.triggered_count, 0)
          return html`
            <div key=${moduleName} class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
              <div class="flex items-center justify-between border-b border-[var(--color-border-default)]/50 px-3 py-1.5">
                <span class="text-xs font-semibold text-text-strong">${moduleName}</span>
                <span class="font-mono text-2xs text-text-muted">${sites.length} sites · ${totalCount} obs · ${totalTriggered} triggered</span>
              </div>
              <div class="overflow-x-auto">
                <table class="w-full" aria-label=${`Heuristic sites for ${moduleName}`}>
                  <thead>
                    <tr class="border-b border-[var(--color-border-default)]/30 text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
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
                        <td class="px-2 py-1 text-right font-mono text-text-muted">${s.count > 0 ? formatPct1(s.triggered_count / s.count) : '0.0%'}</td>
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

type AuditChip = 'ledger' | AuditFocus

function updateAuditFocusParam(focus: AuditChip): void {
  replaceRoute('monitoring', auditRouteParams(focus))
}

function AuditFocusRail({ focus, count }: { focus: AuditFocus | null; count: number }) {
  const active: AuditChip = focus ?? 'ledger'
  return html`
    <${FilterChips}
      chips=${[
        { key: 'ledger', label: 'Ledger', count, title: 'raw audit ledger entries' },
        { key: 'actor', label: 'By actor', count, title: 'actor별 audit ledger 집계' },
        { key: 'summary', label: 'Summary', count, title: 'kind/severity별 audit ledger 요약' },
      ]}
      value=${active}
      onChange=${updateAuditFocusParam}
      class="w-full sm:w-auto"
      size="sm"
      tone="accent"
    />
  `
}

function AuditActorBoard({ entries }: { entries: AuditEntry[] }) {
  const rows = summarizeAuditActors(entries)

  if (rows.length === 0) {
    return html`<div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-6 text-center text-sm text-text-muted">actor별로 집계할 audit entry가 없습니다.</div>`
  }

  return html`
    <section class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]" aria-label="Audit by actor" data-testid="audit-by-actor">
      <div class="flex items-center justify-between border-b border-[var(--color-border-default)]/50 px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">audit by actor · ${rows.length} actors</span>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full" aria-label="Audit entries grouped by actor">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">actor</th>
              <th scope="col" class="px-2 py-1.5 text-right">entries</th>
              <th scope="col" class="px-2 py-1.5 text-right">error</th>
              <th scope="col" class="px-2 py-1.5 text-right">warn</th>
              <th scope="col" class="px-2 py-1.5 text-right">info</th>
              <th scope="col" class="px-2 py-1.5 text-left">top kind</th>
              <th scope="col" class="px-2 py-1.5 text-left">latest</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(row => html`
              <tr key=${row.actor} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${row.actor}</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-strong">${row.count}</td>
                <td class="px-2 py-1.5 text-right font-mono text-[var(--color-danger-fg)]">${row.error}</td>
                <td class="px-2 py-1.5 text-right font-mono text-[var(--color-warning-fg)]">${row.warn}</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-muted">${row.info}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${row.topKind}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${row.latest}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </section>
  `
}

function AuditSummaryBoard({ entries, count }: { entries: AuditEntry[]; count: number }) {
  const rows = summarizeAuditKinds(entries)
  const totals = severityBuckets(entries)
  const maxCount = Math.max(1, ...rows.map(row => row.count))

  return html`
    <section class="flex flex-col gap-3" aria-label="Audit summary" data-testid="audit-summary">
      <div class="grid grid-cols-2 gap-2 md:grid-cols-4">
        <${StatTile} label="Entries" value=${String(count)} delta=${{ direction: 'flat', text: `${entries.length} loaded` }} />
        <${StatTile} label="Error" value=${String(totals.error)} status=${totals.error > 0 ? 'crit' : 'ok'} />
        <${StatTile} label="Warn" value=${String(totals.warn)} status=${totals.warn > 0 ? 'warn' : 'ok'} />
        <${StatTile} label="Kinds" value=${String(rows.length)} />
      </div>
      <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <div class="flex items-center justify-between border-b border-[var(--color-border-default)]/50 px-3 py-2">
          <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">audit summary · kind / severity</span>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full" aria-label="Audit entries grouped by kind">
            <thead>
              <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
                <th scope="col" class="px-2 py-1.5 text-left">kind</th>
                <th scope="col" class="px-2 py-1.5 text-right">count</th>
                <th scope="col" class="px-2 py-1.5 text-left">share</th>
                <th scope="col" class="px-2 py-1.5 text-right">error</th>
                <th scope="col" class="px-2 py-1.5 text-right">warn</th>
                <th scope="col" class="px-2 py-1.5 text-right">info</th>
                <th scope="col" class="px-2 py-1.5 text-left">latest</th>
              </tr>
            </thead>
            <tbody>
              ${rows.map(row => html`
                <tr key=${row.kind} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                  <td class="px-2 py-1.5 text-left font-mono text-text-strong">${row.kind}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-text-strong">${row.count}</td>
                  <td class="px-2 py-1.5">
                    <div class="h-2 min-w-20 rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
                      <div class="h-full rounded-[var(--r-0)] bg-[var(--color-accent-fg)]" style=${`width: ${Math.round((row.count / maxCount) * 100)}%`} />
                    </div>
                  </td>
                  <td class="px-2 py-1.5 text-right font-mono text-[var(--color-danger-fg)]">${row.error}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-[var(--color-warning-fg)]">${row.warn}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-text-muted">${row.info}</td>
                  <td class="px-2 py-1.5 text-left font-mono text-text-muted">${row.latest}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  `
}

function AuditLedgerTable({ entries }: { entries: AuditEntry[] }) {
  return html`
      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Audit ledger entries">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">actor</th>
              <th scope="col" class="px-2 py-1.5 text-left">kind</th>
              <th scope="col" class="px-2 py-1.5 text-left">summary</th>
              <th scope="col" class="px-2 py-1.5 text-left">sev</th>
            </tr>
          </thead>
          <tbody>
            ${entries.map((e, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${e.ts}</td>
                <td class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${e.actor}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-strong">${e.kind}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted max-w-[24ch] truncate" title=${e.summary}>${e.summary}</td>
                <td class="px-2 py-1.5 text-left font-mono ${severityClass(e.severity)}">${e.severity}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
  `
}

function AuditLedgerBoard({ entries, count, focus }: { entries: AuditEntry[]; count: number; focus: AuditFocus | null }) {
  return html`
    <section class="flex flex-col gap-4" aria-label="Audit ledger">
      <div class="flex flex-col items-start gap-2 rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2 sm:flex-row sm:items-center sm:justify-between">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">audit ledger · ${count} entries</span>
        <${AuditFocusRail} focus=${focus} count=${count} />
      </div>

      ${focus === 'actor'
        ? html`<${AuditActorBoard} entries=${entries} />`
        : focus === 'summary'
          ? html`<${AuditSummaryBoard} entries=${entries} count=${count} />`
          : html`<${AuditLedgerTable} entries=${entries} />`}
    </section>
  `
}

function KeeperDecisionsBoard({ events, limit }: { events: KeeperDecision[]; limit: number }) {
  const fmtTime = (ts: number | null): string => {
    if (ts == null) return '—'
    const d = new Date(ts * 1000)
    return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false })
  }

  return html`
    <section class="flex flex-col gap-4" aria-label="Keeper decisions">
      <div class="flex items-center justify-between rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2">
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">keeper decisions · ${events.length} events · limit ${limit}</span>
      </div>

      <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
        <table class="w-full" aria-label="Keeper decision events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">keeper</th>
              <th scope="col" class="px-2 py-1.5 text-left">event</th>
              <th scope="col" class="px-2 py-1.5 text-left">outcome</th>
              <th scope="col" class="px-2 py-1.5 text-left">runtime</th>
              <th scope="col" class="px-2 py-1.5 text-right">latency</th>
              <th scope="col" class="px-2 py-1.5 text-right">cost</th>
              <th scope="col" class="px-2 py-1.5 text-center">tool</th>
            </tr>
          </thead>
          <tbody>
            ${events.map((e, i) => html`
              <tr key=${i} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">${fmtTime(e.ts_unix)}</td>
                <td class="px-2 py-1.5 text-left font-mono text-xs text-[var(--color-accent-fg)]">${e.keeper_name}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-strong">${e.event_type}</td>
                <td class="px-2 py-1.5 text-left font-mono ${e.outcome === 'success' ? 'text-[var(--color-status-ok)]' : e.outcome === 'error' ? 'text-[var(--color-status-err)]' : 'text-text-muted'}">${e.outcome ?? '—'}</td>
                <td class="px-2 py-1.5 text-left font-mono text-text-muted">—</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-muted">${e.latency_ms == null ? '—' : `${Math.round(e.latency_ms)}ms`}</td>
                <td class="px-2 py-1.5 text-right font-mono text-text-muted">${e.cost_usd == null ? '—' : formatCost(e.cost_usd)}</td>
                <td class="px-2 py-1.5 text-center font-mono text-text-muted">${e.tool ?? '—'}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </section>
  `
}

function CostFocusRail({
  focus,
  mode,
  modelCount,
  keeperCount,
  bucketCount,
}: {
  focus: CostFocus | null
  mode: ViewMode
  modelCount: number | null
  keeperCount: number | null
  bucketCount: number | null
}) {
  const active = focus ?? (mode === 'keeper' ? 'agent' : undefined)
  return html`
    <div class="flex flex-col gap-2" aria-label="비용 포커스" data-testid="cost-focus-rail">
      <${FilterChips}
        chips=${[
          { key: 'agent', label: 'Keeper별 비용', count: keeperCount, title: 'keeper별 비용 / 토큰 / 지연 테이블' },
          { key: 'matrix', label: '비용 매트릭스', count: modelCount, title: 'runtime lane 비용 heatmap' },
          { key: 'latency', label: '지연 분포', count: bucketCount, title: 'latency histogram과 p50/p95 분포' },
        ]}
        value=${active}
        onChange=${updateCostFocusParam}
        size="sm"
        tone="accent"
      />
    </div>
  `
}

function CostDashboardContent({ view }: { view: CostView }) {
  if (view === 'cost') {
    const focus = activeCostFocus.value
    const requestedMode = focus ? viewModeForCostFocus(focus) : viewMode.value
    if (viewMode.value !== requestedMode) viewMode.value = requestedMode

    const mode = requestedMode
    const activeState = mode === 'model' ? modelState.value : keeperState.value

    if (activeState.status === 'idle') {
      void loadActiveView(windowMinutes.value, view)
    }
    if (activeState.status === 'loading') {
      return html`<${LoadingState}>cost / latency metrics 불러오는 중...<//>`
    }
    if (activeState.status === 'error') {
      return html`<${ErrorState} message=${activeState.message} />`
    }
    if (activeState.status !== 'loaded') return null

    const t = mode === 'model' ? modelTotals.value : keeperTotals.value
    const data = activeState.data
      .slice()
      .sort((a, b) => (mode === 'model'
        ? ((b as DashboardRuntimeModelMetric).total_cost_usd ?? 0) - ((a as DashboardRuntimeModelMetric).total_cost_usd ?? 0)
        : (b as KeeperCostMetric).total_cost_usd - (a as KeeperCostMetric).total_cost_usd))
    const maxCost = Math.max(0, ...data.map(m =>
      mode === 'model' ? ((m as DashboardRuntimeModelMetric).total_cost_usd ?? 0) : (m as KeeperCostMetric).total_cost_usd))
    const maxP95 = Math.max(0, ...data.map(m => {
      const p95 = mode === 'model' ? (m as DashboardRuntimeModelMetric).p95_latency_ms : (m as KeeperCostMetric).p95_latency_ms
      return p95 ?? 0
    }))
    const loadedModelCount = modelState.value.status === 'loaded' ? modelState.value.data.length : null
    const loadedKeeperCount = keeperState.value.status === 'loaded' ? keeperState.value.data.length : null
    const loadedBucketCount = modelState.value.status === 'loaded' ? modelState.value.latencyBuckets.length : null
    const modelLoadedState = mode === 'model'
      ? activeState as Extract<ModelLoadState, { status: 'loaded' }>
      : null
    const latencyBuckets = modelLoadedState?.latencyBuckets ?? []
    const showMatrix = modelLoadedState != null && data.length > 0 && (focus == null || focus === 'matrix')
    const showLatency = modelLoadedState != null && latencyBuckets.length > 0 && (focus == null || focus === 'latency')
    const showTable = focus !== 'matrix' && focus !== 'latency'
    const focusedEmptyMessage = focus === 'matrix' && data.length === 0
      ? '이 시간 창에서 기록된 Runtime 비용 매트릭스가 없습니다.'
      : focus === 'latency' && latencyBuckets.length === 0
        ? '이 시간 창에서 기록된 Runtime 지연 분포가 없습니다.'
        : null

    return html`
      <section class="flex flex-col gap-4" aria-label="비용 / 지연 대시보드">
        <header class="flex flex-wrap items-baseline justify-between gap-3">
          <div>
            <h2 class="text-base font-semibold text-text-strong">비용 / 지연 대시보드</h2>
            <p class="text-2xs text-text-muted">최근 ${activeState.windowMinutes}분 · ${mode === 'model' ? 'Runtime별' : 'Keeper별'} 토큰 / 비용 / latency</p>
          </div>
          <div class="flex items-center gap-2">
            <div class="flex rounded-[var(--r-1)] border border-card-border/40 p-0.5" role="group" aria-label="보기 모드">
              <button
                type="button"
                role="radio"
                aria-checked=${mode === 'model'}
                class="rounded-[var(--r-1)] px-2 py-0.5 text-2xs ${mode === 'model'
                  ? 'bg-[var(--accent-15)] text-accent-fg'
                  : 'text-text-muted hover:text-text-strong'}"
                onClick=${() => { setCostViewMode('model') }}
              >
                Runtime
              </button>
              <button
                type="button"
                role="radio"
                aria-checked=${mode === 'keeper'}
                class="rounded-[var(--r-1)] px-2 py-0.5 text-2xs ${mode === 'keeper'
                  ? 'bg-[var(--accent-15)] text-accent-fg'
                  : 'text-text-muted hover:text-text-strong'}"
                onClick=${() => { setCostViewMode('keeper') }}
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
                  class="rounded-[var(--r-1)] border px-2 py-0.5 text-2xs ${windowMinutes.value === o.key
                    ? 'border-[var(--accent-50)] bg-[var(--accent-15)] text-accent-fg'
                  : 'border-card-border/40 text-text-muted hover:border-card-border/60'}"
                  onClick=${() => { windowMinutes.value = o.key; void loadActiveView(o.key, view) }}
                >
                  ${o.label}
                </button>
              `)}
            </div>
          </div>
        </header>

        <${CostFocusRail}
          focus=${focus}
          mode=${mode}
          modelCount=${loadedModelCount}
          keeperCount=${loadedKeeperCount}
          bucketCount=${loadedBucketCount}
        />

        ${t ? html`
          <div class="grid grid-cols-2 gap-2 md:grid-cols-4">
            <${StatTile}
              label="Total Cost"
              value=${formatCost(t.totalCost)}
              status="ok"
              delta=${{ direction: 'up', text: `${t.count} ${mode === 'model' ? 'runtime lanes' : 'keepers'}` }}
            />
            <${StatTile}
              label="Tokens In / Out"
              value=${`${formatTokens(t.totalIn)} / ${formatTokens(t.totalOut)}`}
              delta=${{ direction: 'flat', text: 'aggregated window' }}
            />
            <${StatTile}
              label="p50 Latency (avg)"
              value=${`${Math.round(t.p50Avg)}ms`}
              delta=${{ direction: 'flat', text: 'across entries' }}
            />
            <${StatTile}
              label="p95 Latency (max)"
              value=${`${Math.round(t.p95Max)}ms`}
              status=${t.p95Max > 8000 ? 'crit' : undefined}
              delta=${{ direction: t.p95Max > 8000 ? 'down' : 'flat', text: t.p95Max > 8000 ? 'over 8s budget' : 'within budget' }}
            />
          </div>
        ` : null}

        ${showMatrix ? html`<${CostMatrix} models=${activeState.data as DashboardRuntimeModelMetric[]} />` : null}
        ${showLatency ? html`
          <${CostLatency}
            buckets=${latencyBuckets}
            p50=${t?.p50Avg ?? null}
            p95=${t?.p95Max ?? null}
          />
        ` : null}

        ${focusedEmptyMessage ? html`
          <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-6 text-center text-sm text-text-muted">
            ${focusedEmptyMessage}
          </div>
        ` : null}

        ${!showTable ? null : data.length === 0 ? html`
          <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-6 text-center text-sm text-text-muted">
            이 시간 창에서 기록된 ${mode === 'model' ? 'Runtime' : 'Keeper'} 비용이 없습니다.
          </div>
        ` : html`
          <div class="overflow-x-auto rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)]">
            <table class="w-full" aria-label=${`${data.length}개 ${mode === 'model' ? 'Runtime' : 'Keeper'}의 비용 / 지연`}>
              <thead>
                <tr class="border-b border-[var(--color-border-default)] text-2xs uppercase tracking-[var(--track-caps)] text-text-muted">
                  <th scope="col" class="px-2 py-1.5 text-left">${mode === 'model' ? 'runtime' : 'keeper'}</th>
                  <${ThRight}>in tok</${ThRight}>
                  <${ThRight}>out tok</${ThRight}>
                  <${ThRight}>$ cost</${ThRight}>
                  <th scope="col" class="px-2 py-1.5 text-left">cost</th>
                  <${ThRight}>p50</${ThRight}>
                  <${ThRight}>p95</${ThRight}>
                  <th scope="col" class="px-2 py-1.5 text-left">p95 trend</th>
                  ${mode === 'keeper' ? html`<th scope="col" class="px-2 py-1.5 text-left">runtime cost</th>` : null}
                </tr>
              </thead>
              <tbody>
                ${mode === 'model'
                  ? data.map(m => html`<${ModelRow} key=${(m as DashboardRuntimeModelMetric).model_id} model=${m as DashboardRuntimeModelMetric} maxCost=${maxCost} maxP95=${maxP95} />`)
                  : data.map(k => html`<${KeeperRow} key=${(k as KeeperCostMetric).keeper_name} keeper=${k as KeeperCostMetric} maxCost=${maxCost} maxP95=${maxP95} />`)}
              </tbody>
            </table>
          </div>
        `}
      </section>
    `
  }

  if (view === 'heuristics') {
    if (heuristicState.value.status === 'idle') {
      void loadHeuristics()
      void loadHeuristicCoverage()
    }
    return html`
      <section class="flex flex-col gap-4" aria-label="휴리스틱">
        <header class="flex items-baseline justify-between gap-3">
          <h2 class="text-base font-semibold text-text-strong">휴리스틱</h2>
        </header>
        ${heuristicState.value.status === 'loaded'
          ? html`<${HeuristicLog} events=${heuristicState.value.data} limit=${heuristicState.value.limit} />`
          : heuristicState.value.status === 'error'
            ? html`<${ErrorState} message=${heuristicState.value.message} onRetry=${() => void loadHeuristics()} />`
            : html`<${LoadingState} />`}
        ${coverageState.value.status === 'loaded'
          ? html`<${HeuristicByModule} coverage=${coverageState.value.data} />`
          : coverageState.value.status === 'error'
            ? html`<${ErrorState} message=${coverageState.value.message} onRetry=${() => void loadHeuristicCoverage()} />`
            : html`<${LoadingState} />`}
      </section>
    `
  }

  if (view === 'stress') {
    if (stressState.value.status === 'idle') {
      void loadStress()
    }
    return html`
      <section class="flex flex-col gap-4" aria-label="스트레스">
        <header class="flex items-baseline justify-between gap-3">
          <h2 class="text-base font-semibold text-text-strong">스트레스 이벤트</h2>
        </header>
        ${stressState.value.status === 'loaded'
          ? html`<${StressBoard} rows=${stressState.value.board} events=${stressState.value.events} limit=${stressState.value.limit} />`
          : stressState.value.status === 'error'
            ? html`<${ErrorState} message=${stressState.value.message} onRetry=${() => void loadStress()} />`
            : html`<${LoadingState} />`}
      </section>
    `
  }

  if (view === 'audit') {
    if (auditLedgerState.value.status === 'idle') {
      void loadAuditLedger()
    }
    return html`
      <section class="flex flex-col gap-4" aria-label="감사 원장">
        <header class="flex items-baseline justify-between gap-3">
          <h2 class="text-base font-semibold text-text-strong">감사 원장</h2>
        </header>
        ${auditLedgerState.value.status === 'loaded'
          ? html`<${AuditLedgerBoard}
              entries=${auditLedgerState.value.data.entries}
              count=${auditLedgerState.value.data.count}
              focus=${activeAuditFocus.value}
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

  if (view === 'decisions') {
    if (keeperDecisionsState.value.status === 'idle') {
      void loadKeeperDecisions()
    }
    return html`
      <section class="flex flex-col gap-4" aria-label="Keeper 결정">
        <header class="flex items-baseline justify-between gap-3">
          <h2 class="text-base font-semibold text-text-strong">Keeper 결정</h2>
        </header>
        ${keeperDecisionsState.value.status === 'loaded'
          ? html`<${KeeperDecisionsBoard}
              events=${keeperDecisionsState.value.data.events}
              limit=${keeperDecisionsState.value.data.limit}
            />`
          : keeperDecisionsState.value.status === 'error'
            ? html`<${ErrorState}
                message=${keeperDecisionsState.value.message}
                onRetry=${() => void loadKeeperDecisions()}
              />`
            : html`<${LoadingState} />`}
      </section>
    `
  }

  return null
}

export function CostDashboard({ view = 'cost' }: { view?: CostView }) {
  return html`
    <div class="contain-content flex flex-col gap-4">
      <${CostDashboardContent} view=${view} />
    </div>
  `
}
