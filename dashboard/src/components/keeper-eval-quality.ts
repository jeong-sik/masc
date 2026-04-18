// Keeper Eval Quality Panel — RFC-MASC-005 Phase 3
// Displays OAS eval verdicts: coverage bar, layer results, 24h trend.
// Data source: GET /api/v1/keepers/:name/eval (Phase 2 API)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchKeeperEval } from '../api/keeper'
import type { KeeperEvalResponse, EvalSnapshot, EvalLayerResult } from '../api/keeper'

// ── Per-keeper cached state ─────────────────────────────

interface EvalState {
  loading: boolean
  error: string | null
  data: KeeperEvalResponse | null
}

type EvalSignal = ReturnType<typeof signal<EvalState>>
const evalCache = new Map<string, EvalSignal>()

const defaultState: EvalState = { loading: false, error: null, data: null }

function getEvalSignal(name: string): EvalSignal {
  let s = evalCache.get(name)
  if (!s) {
    s = signal<EvalState>({ ...defaultState })
    evalCache.set(name, s)
  }
  return s
}

function readEvalState(name: string): EvalState {
  return getEvalSignal(name).value ?? defaultState
}

async function loadEvalData(name: string): Promise<void> {
  const s = getEvalSignal(name)
  const current = readEvalState(name)
  if (current.loading) return
  s.value = { loading: true, error: null, data: current.data }
  try {
    const data = await fetchKeeperEval(name, 20)
    s.value = { loading: false, error: null, data }
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'eval fetch failed'
    s.value = { loading: false, error: msg, data: null }
  }
}

// ── Coverage bar ────────────────────────────────────────

function coverageColor(coverage: number): string {
  if (coverage >= 0.9) return 'var(--ok)'
  if (coverage >= 0.6) return 'var(--warn)'
  return 'var(--bad)'
}

function coverageTone(coverage: number): string {
  if (coverage >= 0.9) return 'border-[var(--ok-20)] bg-[var(--ok-6)]'
  if (coverage >= 0.6) return 'border-[var(--warn-20)] bg-[var(--warn-8)]'
  return 'border-[var(--bad-20)] bg-[var(--bad-6)]'
}

function baselineLabel(status: string | null): { text: string; cls: string } | null {
  if (!status) return null
  switch (status) {
    case 'Improved':
      return { text: 'Improved', cls: 'text-[var(--ok)]' }
    case 'Regressed':
      return { text: 'Regressed', cls: 'text-[var(--bad)]' }
    case 'Unchanged':
      return { text: 'Unchanged', cls: 'text-[var(--text-muted)]' }
    default:
      return { text: status, cls: 'text-[var(--text-muted)]' }
  }
}

// ── Layer result row ────────────────────────────────────

function LayerResultRow({ layer }: { layer: EvalLayerResult }) {
  const icon = layer.passed ? '\u2713' : '\u2717'
  const iconCls = layer.passed
    ? 'text-[var(--ok)]'
    : 'text-[var(--bad)]'
  const scoreText = layer.score != null ? layer.score.toFixed(2) : '-'
  const detail = layer.detail ?? layer.evidence[0] ?? ''

  return html`
    <div class="flex items-center gap-3 py-1.5 px-2 rounded hover:bg-[var(--white-3)] transition-colors">
      <span class="flex-shrink-0 w-4 text-center font-bold text-sm ${iconCls}">${icon}</span>
      <span class="flex-shrink-0 w-30 text-2xs font-mono text-[var(--accent)] truncate" title=${layer.layer_name}>${layer.layer_name}</span>
      <span class="flex-shrink-0 w-10 text-right text-2xs font-mono tabular-nums text-[var(--text-strong)]">${scoreText}</span>
      <span class="flex-1 text-3xs text-[var(--text-muted)] truncate" title=${detail}>${detail}</span>
    </div>
  `
}

// ── 24h Trend computation ───────────────────────────────

function computeTrend(snapshots: EvalSnapshot[]): { oldCoverage: number; newCoverage: number; deltaPercent: number } | null {
  if (snapshots.length < 2) return null
  const now = Date.now() / 1000
  const cutoff24h = now - 86400
  const recent = snapshots.filter(s => s.timestamp >= cutoff24h)
  const older = snapshots.filter(s => s.timestamp < cutoff24h)
  if (recent.length === 0) return null
  const newestRecent = recent[0]
  if (!newestRecent) return null
  const newCoverage = newestRecent.verdict.coverage
  const oldestRecent = recent[recent.length - 1]
  const firstOlder = older[0]
  const oldCoverage = firstOlder
    ? firstOlder.verdict.coverage
    : (oldestRecent?.verdict.coverage ?? newCoverage)
  if (oldCoverage === newCoverage) return null
  const deltaPercent = oldCoverage > 0 ? ((newCoverage - oldCoverage) / oldCoverage) * 100 : 0
  return { oldCoverage, newCoverage, deltaPercent }
}

// ── Main panel ──────────────────────────────────────────

export function KeeperEvalQualityPanel({ keeperName }: { keeperName: string }) {
  const evalSignal = getEvalSignal(keeperName)

  useEffect(() => {
    void loadEvalData(keeperName)
  }, [keeperName])

  // Access .value to subscribe, then fallback for strict-mode undefined
  const state = evalSignal.value ?? defaultState
  const { loading, error, data } = state

  if (loading && !data) {
    return html`
      <div class="p-4 rounded border border-[var(--card-border)] bg-[var(--white-2)]">
        <div class="text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)] mb-2">Eval Quality</div>
        <div class="text-2xs text-[var(--text-dim)] animate-pulse">데이터 로딩 중...</div>
      </div>
    `
  }

  if (error && !data) {
    return html`
      <div class="p-4 rounded border border-[var(--card-border)] bg-[var(--white-2)]">
        <div class="text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)] mb-2">Eval Quality</div>
        <div class="text-2xs text-[var(--text-dim)]">eval 데이터 없음</div>
      </div>
    `
  }

  if (!data || data.count === 0) {
    return html`
      <div class="p-4 rounded border border-[var(--card-border)] bg-[var(--white-2)]">
        <div class="text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)] mb-2">Eval Quality</div>
        <div class="text-2xs text-[var(--text-dim)]">eval 결과 없음. OAS harness가 verdict를 생성하면 여기에 표시됩니다.</div>
      </div>
    `
  }

  const latest = data.snapshots[0]
  if (!latest) return null

  const coverage = latest.verdict.coverage
  const coveragePct = Math.round(coverage * 100)
  const allPassed = latest.verdict.all_passed
  const layers = latest.verdict.layer_results
  const baseline = baselineLabel(latest.baseline_status)
  const trend = computeTrend(data.snapshots)

  return html`
    <div class="p-4 rounded border ${coverageTone(coverage)} transition-colors">
      ${'' /* Header */}
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <span class="text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)]">Eval Quality</span>
          ${allPassed
            ? html`<span class="inline-flex items-center py-0.5 px-1.5 rounded text-3xs font-semibold bg-[rgba(74,222,128,0.12)] text-[var(--ok)]">ALL PASS</span>`
            : html`<span class="inline-flex items-center py-0.5 px-1.5 rounded text-3xs font-semibold bg-[var(--bad-12)] text-[var(--bad)]">FAIL</span>`
          }
          ${baseline ? html`<span class="text-3xs font-medium ${baseline.cls}">${baseline.text}</span>` : null}
        </div>
        <button
          type="button"
          class="text-3xs text-[var(--text-dim)] hover:text-[var(--text-muted)] cursor-pointer bg-transparent border-0 p-0"
          onClick=${() => void loadEvalData(keeperName)}
          title="새로고침"
        >${loading ? '...' : '\u21bb'}</button>
      </div>

      ${'' /* Coverage bar */}
      <div class="flex items-center gap-3 mb-3">
        <span class="text-3xs text-[var(--text-muted)] flex-shrink-0 w-16">Coverage</span>
        <div class="flex-1 h-2 bg-[var(--white-6)] rounded-sm overflow-hidden">
          <div
            class="h-full rounded-sm transition-all duration-500"
            style="width:${coveragePct}%;background:${coverageColor(coverage)}"
          ></div>
        </div>
        <span class="text-sm font-bold tabular-nums flex-shrink-0" style="color:${coverageColor(coverage)}">${coverage.toFixed(2)}</span>
      </div>

      ${'' /* Layer Results */}
      ${layers.length > 0 ? html`
        <div class="mb-3">
          <div class="text-3xs uppercase tracking-wider text-[var(--text-dim)] mb-1.5">Layer Results</div>
          <div class="flex flex-col gap-0.5">
            ${layers.map((layer: EvalLayerResult) => html`<${LayerResultRow} layer=${layer} />`)}
          </div>
        </div>
      ` : null}

      ${'' /* 24h Trend */}
      ${trend ? html`
        <div class="flex items-center gap-2 pt-2 border-t border-[var(--white-8)]">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-dim)]">Trend (24h)</span>
          <span class="text-2xs font-mono tabular-nums text-[var(--text-muted)]">
            ${trend.oldCoverage.toFixed(2)} \u2192 ${trend.newCoverage.toFixed(2)}
          </span>
          <span class="text-2xs font-mono tabular-nums font-semibold ${trend.deltaPercent >= 0 ? 'text-[var(--ok)]' : 'text-[var(--bad)]'}">
            (${trend.deltaPercent >= 0 ? '+' : ''}${trend.deltaPercent.toFixed(1)}%)
          </span>
        </div>
      ` : null}

      ${'' /* Snapshot count */}
      <div class="mt-2 text-3xs text-[var(--text-dim)]">${data.count} eval snapshot${data.count !== 1 ? 's' : ''}</div>
    </div>
  `
}
