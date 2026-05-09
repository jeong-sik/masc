import { html } from 'htm/preact'
import { formatTokens } from '../lib/format-number'
import { ProgressBar } from './common/progress-bar'
import { Eyebrow } from './common/eyebrow'
import { StatusChip } from './common/status-chip'
import type { Keeper, KeeperMetricPoint } from '../types'
import {
  ctxColor,
  CTX_CRITICAL_PCT,
  CTX_WARN_PCT,
  CTX_COLOR_WARN,
} from './keeper-detail-ctx-utils'
import { MutedSpan, DetailCard, DetailRow } from './keeper-detail-kpi'

const SPARKLINE_W = 200
const SPARKLINE_H = 40
const SPARKLINE_PAD = 2
const MODEL_NAME_MAX_LEN = 20

// ── Context Chart ────────────────────────────────────────

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context_ratio ?? keeper.context?.context_ratio ?? 0) * 100)
    const color = ctxColor(pct)
    return html`
      <${DetailCard} class="flex items-center gap-3 mb-5">
        <${ProgressBar} pct=${pct} size="md" trackTone="dim" trackClass="flex-1" class=${`bg-[${color}]`} />
        <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${pct.toFixed(1)}%</span>
      <//>`
  }

  const W = 200, H = 60, pad = 2
  const n = series.length
  const pts = series.map((p: KeeperMetricPoint, i: number) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (p.context_ratio ?? 0) * (H - 2 * pad)
    return { x, y, p }
  })
  const polyline = pts.map(({ x, y }) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  const lastRatio = (series[series.length - 1]?.context_ratio ?? 0) * 100
  const lineColor = ctxColor(lastRatio)

  return html`
    <${DetailCard} class="flex items-center gap-3 mb-5">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)]" role="img" aria-label="컨텍스트 비율 스파크라인" style="background:var(--bg-deepest);">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="var(--color-line-3)" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="var(--color-line-3)" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="${CTX_COLOR_WARN}" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="var(--color-status-err)" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y, p }) => {
          const trigger = p.compaction_trigger ?? 'unknown'
          const saved = p.compaction_saved_tokens ?? 0
          const tip = saved > 0 ? `${trigger} · ${formatTokens(saved)} saved` : trigger
          return html`
            <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3" fill="var(--purple)" style="cursor:pointer">
              <title>${tip}</title>
            </circle>
          `
        })}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${lastRatio.toFixed(1)}%</span>
    <//>`
}

// ── Token Trend Chart (per-turn input/output tokens) ────

const TOKEN_CHART_W = 200
const TOKEN_CHART_H = 50

export function TokenTrendChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const points = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings != null,
  )
  if (points.length < 2) return null

  const inputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.prompt_n ?? 0,
  )
  const outputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_n ?? 0,
  )
  const totalPerTurn = inputTokens.map((inp, i) => inp + (outputTokens[i] ?? 0))
  const maxVal = Math.max(...totalPerTurn, 1)

  const W = TOKEN_CHART_W, H = TOKEN_CHART_H, pad = 2
  const n = points.length

  const inputLine = inputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const outputLine = outputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const lastInput = inputTokens[inputTokens.length - 1] ?? 0
  const lastOutput = outputTokens[outputTokens.length - 1] ?? 0
  const avgRatio = inputTokens.reduce((a, b) => a + b, 0) / Math.max(outputTokens.reduce((a, b) => a + b, 0), 1)

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">턴 토큰 추세</span>
        <${MutedSpan}>${points.length} turns</${MutedSpan}>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        ${'' /* Dual-line chart: input (cyan) + output (green) */}
        <${DetailCard} class="md:col-span-2">
          <div class="flex items-center gap-4 mb-1.5">
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--cyan)]"></span> input
              <span class="font-mono text-[var(--cyan)]">${formatTokens(lastInput)}</span>
            </span>
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--color-status-ok)]"></span> output
              <span class="font-mono text-[var(--good)]">${formatTokens(lastOutput)}</span>
            </span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="입출력 토큰 추이" style="background:var(--bg-deepest);">
            ${inputLine ? html`<polyline points="${inputLine}" fill="none" stroke="var(--cyan)" stroke-width="1.5" opacity="0.8"/>` : null}
            ${outputLine ? html`<polyline points="${outputLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5" opacity="0.8"/>` : null}
          </svg>
        <//>

        ${'' /* Input/Output ratio */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>In/Out 비율</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-accent-fg)]">${avgRatio.toFixed(1)}x</span>
          <${MutedSpan}>${avgRatio > 10 ? '프롬프트 비대 주의' : avgRatio > 5 ? '프롬프트 무거움' : '정상 범위'}</${MutedSpan}>
        <//>
      </div>
    </div>
  `
}

// ── Sparkline helpers ────────────────────────────────────

function isFiniteMetricValue(value: number | null | undefined): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

export function miniSparkline(
  data: Array<number | null | undefined>,
  maxOverride?: number,
): string {
  const W = SPARKLINE_W, H = SPARKLINE_H, pad = SPARKLINE_PAD
  const n = data.length
  const points = data
    .map((value, index) => ({ value, index }))
    .filter((point): point is { value: number; index: number } =>
      isFiniteMetricValue(point.value),
    )
  if (points.length < 2) return ''
  const maxVal = maxOverride ?? Math.max(...points.map(point => point.value), 1)
  return points.map(({ value, index }) => {
    const x = pad + (index / Math.max(n - 1, 1)) * (W - 2 * pad)
    const y = H - pad - (value / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

// ── Metrics Charts (Latency + Cost + Model) ─────────────

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) return null

  const latencySeries = series.map((p: KeeperMetricPoint) => p.latency_ms)
  const costs = series.map((p: KeeperMetricPoint) => p.cost_usd ?? 0)
  const W = SPARKLINE_W, H = SPARKLINE_H

  const lastLatency = latencySeries[latencySeries.length - 1] ?? null
  const totalCost = costs.reduce((a: number, b: number) => a + b, 0)

  const modelSwitches: { index: number; model: string }[] = []
  for (let i = 1; i < series.length; i++) {
    const curr = series[i]
    const prev = series[i - 1]
    if (curr && prev && curr.model_used !== prev.model_used) {
      modelSwitches.push({ index: i, model: curr.model_used })
    }
  }

  const latencyLine = miniSparkline(latencySeries)
  const costLine = miniSparkline(costs)

  // Fallback markers on latency chart
  const n = series.length
  const fallbackIndices = series
    .map((p: KeeperMetricPoint, i: number) => p.fallback_applied ? i : -1)
    .filter((i: number) => i >= 0)
  const fallbackCount = fallbackIndices.length

  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-5">
      ${'' /* Latency + fallback markers */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>지연 시간</${Eyebrow}>
          <span class="flex items-center gap-2">
            ${fallbackCount > 0 ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--bad-soft)] text-[var(--color-status-err)] font-mono">FB ${fallbackCount}</span>` : null}
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${isFiniteMetricValue(lastLatency) && lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${fallbackIndices.map((idx: number) => {
            const x = SPARKLINE_PAD + (idx / Math.max(n - 1, 1)) * (W - 2 * SPARKLINE_PAD)
            return html`<line x1="${x.toFixed(1)}" y1="${SPARKLINE_PAD}" x2="${x.toFixed(1)}" y2="${H - SPARKLINE_PAD}" stroke="var(--color-status-err)" stroke-width="1.5" opacity="0.6"/>`
          })}
          ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
        </svg>
      <//>

      ${'' /* Cost */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>비용</${Eyebrow}>
          <span class="text-xs font-mono tabular-nums text-[var(--purple)]">$${totalCost.toFixed(4)}</span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${costLine ? html`<polyline points="${costLine}" fill="none" stroke="var(--purple)" stroke-width="1.5"/>` : null}
        </svg>
      <//>

      ${'' /* Model timeline */}
      ${modelSwitches.length > 0 ? html`
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>모델 전환</${Eyebrow}>
            <${MutedSpan}>${modelSwitches.length}회</${MutedSpan}>
          </${DetailRow}>
          <div class="flex flex-wrap gap-1.5">
            ${modelSwitches.map(s => html`
              <${StatusChip} tone="warn" uppercase=${false} class="font-mono">
                T${s.index} -> ${s.model.length > MODEL_NAME_MAX_LEN ? s.model.slice(0, MODEL_NAME_MAX_LEN) + '...' : s.model}
              <//>
            `)}
          </div>
        <//>
      ` : null}

      ${'' /* Cascade fallback events */}
      ${fallbackCount > 0 ? html`
        <div class="md:col-span-2 p-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-6)]">
          <${DetailRow}>
            <>캐스케이드 폰백</>
            <span class="text-3xs text-[var(--color-status-err)]">${fallbackCount}회</span>
          </${DetailRow}>
          <div class="flex flex-wrap gap-1.5">
            ${series.filter((p: KeeperMetricPoint) => p.fallback_applied).slice(-10).map((p: KeeperMetricPoint) => html`
              <${StatusChip} tone="bad" uppercase=${false} class="font-mono">
                ${p.fallback_from ?? '?'} -> ${p.fallback_to ?? p.model_used}${p.fallback_reason ? ` (${p.fallback_reason.length > 20 ? p.fallback_reason.slice(0, 20) + '...' : p.fallback_reason})` : ''}
              <//>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}
